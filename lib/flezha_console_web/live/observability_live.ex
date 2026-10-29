defmodule FlezhaConsoleWeb.ObservabilityLive do
  @moduledoc """
  What each part of the controllers reports about itself, what it reported
  recently, and a live view of it.

  The controllers describe every source and signal and count what their ring
  buffers hold, so this screen explains and summarises without a table of its
  own. Each source is listed once with its state on every controller, and a
  switch applies to every one. The tail rides `FlezhaConsole.Service.EventFeed`,
  the same feed the runtime events use, and opens with the source's buffered
  history; each line names the controller that emitted it.
  """

  use FlezhaConsoleWeb, :live_view

  use FlezhaConsoleWeb.Live.Refresh, every: 5_000
  use FlezhaConsoleWeb.Live.Tail, tag: :observability_tail, max: 200

  alias FlezhaConsole.Format
  alias FlezhaConsole.Service.NodeManager

  @history 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> start_refresh()
     |> init_tail()
     |> assign(
       page_title: "Observability",
       sources: [],
       sinks: [],
       source_filter: "",
       load_error: nil,
       disabled?: false,
       toggle_error: nil,
       toggle_missed: nil,
       unreachable: [],
       history_error: nil,
       tail_source: nil
     )
     |> refresh()}
  end

  @doc """
  A forwarded signal, as a plain map with an id for its line. The controller
  sends its `%Flezha.Observability.Signal{}` struct, which this node has no
  module for and which `Access` cannot read.
  """
  @impl FlezhaConsoleWeb.Live.Tail
  def unwrap_tail(signal) when is_map(signal) do
    signal
    |> Map.delete(:__struct__)
    |> Map.put(:line_id, System.unique_integer([:positive]))
  end

  @impl true
  def handle_event("toggle_source", %{"source" => name}, socket) do
    case named_source(socket, name) do
      nil -> {:noreply, socket}
      source -> {:noreply, socket |> apply_toggle(source) |> refresh()}
    end
  end

  @impl true
  def handle_event("filter_sources", %{"q" => text}, socket) do
    {:noreply, assign(socket, source_filter: text)}
  end

  @impl true
  def handle_event("start_tail", %{"source" => name}, socket) do
    case named_source(socket, name) do
      nil -> {:noreply, socket}
      source -> {:noreply, open_tail(socket, source[:name])}
    end
  end

  @impl true
  def handle_event("stop_tail", _params, socket) do
    {:noreply, stop_tail(socket)}
  end

  @impl true
  def handle_info(_message, socket), do: {:noreply, socket}

  @impl FlezhaConsoleWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.observability_sources(token) do
      {:ok, %{rows: sources}} = listed ->
        sinks = NodeManager.observability_sinks(token)

        assign(socket,
          sources: sources,
          sinks: NodeManager.ok_or(sinks, []),
          unreachable: NodeManager.unreachable([listed, sinks]),
          load_error: nil,
          disabled?: false
        )

      {:error, reason} ->
        socket = assign(socket, sources: [], sinks: [], unreachable: [])

        if NodeManager.error(reason).code == "observability.disabled",
          do: assign(socket, load_error: nil, disabled?: true),
          else: assign(socket, load_error: reason, disabled?: false)
    end
  end

  # The buffered history first, newest first, as the live lines will be.
  defp open_tail(socket, name) do
    token = socket.assigns.flezha_token

    {history, history_error} =
      case NodeManager.observability_query(%{source: name, limit: @history}, token) do
        {:ok, %{rows: signals}} ->
          {signals
           |> Enum.reverse()
           |> Enum.map(&(&1 |> unwrap_tail() |> Map.put(:history?, true))), nil}

        {:error, reason} ->
          {[], reason}
      end

    socket
    |> start_tail(&NodeManager.observability_tail(name, token, &1), name, seed: history)
    |> assign(
      history_error: history_error,
      tail_source: Enum.find(socket.assigns.sources, &(&1[:name] == name))
    )
  end

  @doc """
  A source's switch: `true` when every controller listing it runs it, `false`
  when none does and `:mixed` in between.
  """
  def switch_state(source) do
    case NodeManager.source_enabled(source) do
      {0, _of} -> false
      {on, on} -> true
      _part -> :mixed
    end
  end

  @doc ~S|"On 2 of 3 controllers" for a source on part of the cluster, else nil.|
  def enabled_words(source) do
    case NodeManager.source_enabled(source) do
      {on, of} when on > 0 and on < of -> "On #{on} of #{Words.count(of, "controller")}"
      _all_or_none -> nil
    end
  end

  @doc """
  The sinks once each by name, in the order listed, with `stopped`: the
  controllers on which it is not running.
  """
  def sink_groups(sinks) do
    for {sink, copies} <- NodeManager.copies(sinks, & &1[:name]) do
      %{
        name: sink[:name],
        sink: sink,
        stopped: for(copy <- copies, !NodeManager.sink_running?(copy), do: copy[:node])
      }
    end
  end

  @areas [
    relays: "Relays and runners",
    plugins: "Plugins",
    storage: "Storage",
    controller: "The controller",
    machine: "The machine and transports",
    other: "Other"
  ]

  @doc """
  The sources grouped by the area the controller declares, "Other" for none,
  each group with its sources whose title, name or description contains
  `filter` — those with a recent failure first, then those that spoke recently,
  each by title — and how many of all its sources are on.
  """
  def groups(sources, filter) do
    needle = filter |> String.trim() |> String.downcase()

    sources
    |> Enum.group_by(&area/1)
    |> Enum.map(fn {key, members} ->
      %{
        key: key,
        label: Keyword.fetch!(@areas, key),
        enabled: Enum.count(members, &(switch_state(&1) == true)),
        total: length(members),
        sources:
          members
          |> Enum.filter(&matches?(&1, needle))
          |> Enum.sort_by(&{band(activity(&1)), String.downcase(title(&1))})
      }
    end)
    |> Enum.sort_by(fn group -> Enum.find_index(Keyword.keys(@areas), &(&1 == group.key)) end)
  end

  defp area(source) do
    if Keyword.has_key?(@areas, source[:area]), do: source[:area], else: :other
  end

  defp matches?(source, needle) do
    Enum.any?([source[:title], source[:name], source[:description]], fn text ->
      text |> to_string() |> String.downcase() |> String.contains?(needle)
    end)
  end

  defp band(%{failures: failures}) when failures > 0, do: 0
  defp band(%{normal: [_ | _]}), do: 1
  defp band(_activity), do: 2

  @doc "A source's plain title, or its technical name when it declares none."
  def title(source), do: to_string(source[:title] || source[:name])

  @doc "A source's technical name, shown under its title, or `nil` when the title is the name."
  def tech_name(nil), do: nil
  def tech_name(source), do: if(source[:title], do: to_string(source[:name]))

  @doc """
  What a source said within the controller's history window, by outcome:
  `failures` and the age of the newest, whether it declares any failure signal,
  and its normal signals as `{label, count}`, most frequent first, with the age
  of the newest. `nil` when the controller does not say.
  """
  def activity(source) do
    case source[:recent] do
      %{signals: signals, window_ms: window} when is_map(signals) ->
        {failed, normal} =
          Enum.split_with(signals, fn {name, _} -> failure?(declared(source, name)) end)

        %{
          window: window,
          failure_signals?: Enum.any?(source[:signals] || [], &failure?/1),
          failures: failed |> Enum.map(fn {_, seen} -> seen.count end) |> Enum.sum(),
          failure_age: newest(failed),
          normal:
            normal
            |> Enum.map(fn {name, seen} -> {label(source, name), seen.count} end)
            |> Enum.sort_by(fn {label, count} -> {-count, label} end),
          normal_age: newest(normal)
        }

      _absent ->
        nil
    end
  end

  defp newest([]), do: nil
  defp newest(seen), do: seen |> Enum.map(fn {_, %{last_age_ms: age}} -> age end) |> Enum.min()

  @doc "A source's activity line: its failures, or that it had none, and its normal activity."
  attr :source, :map, required: true

  def activity_line(assigns) do
    assigns = assign(assigns, :activity, activity(assigns.source))

    ~H"""
    <span
      :if={@activity}
      class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm fcon-muted"
      data-testid={"source-activity-#{@source[:name]}"}
    >
      <span
        :if={@activity.failures > 0}
        class="fcon-badge fcon-badge--warning"
        data-testid={"source-failures-#{@source[:name]}"}
      >
        ⚠ {Words.count(@activity.failures, "failure")} in the last {ago(@activity.window)}, latest {ago(
          @activity.failure_age
        )} ago
      </span>
      <span
        :if={@activity.failures == 0 and @activity.failure_signals?}
        class="fcon-badge fcon-badge--positive"
        data-testid={"source-no-failures-#{@source[:name]}"}
      >
        ✓ No failures in the last {ago(@activity.window)}
      </span>
      <span :if={@activity.normal != []}>
        {Enum.map_join(Enum.take(@activity.normal, 3), " · ", fn {label, count} ->
          "#{Format.compact(count)} #{Words.in_sentence(label)}"
        end)}{if length(@activity.normal) > 3,
          do: " · #{length(@activity.normal) - 3} more"} · last {ago(@activity.normal_age)} ago
      </span>
      <span :if={
        @activity.normal == [] and @activity.failures == 0 and not @activity.failure_signals?
      }>
        Nothing in the last {ago(@activity.window)}
      </span>
    </span>
    """
  end

  @doc """
  Every signal a source declares, failures first, each with its label, an
  outcome badge, its meaning and its full technical name.
  """
  attr :source, :map, required: true

  def signal_meanings(assigns) do
    {failures, normal} =
      Enum.split_with(assigns.source[:signals] || [], &failure?/1)

    assigns =
      assign(assigns,
        catalogue: [
          {"When something goes wrong", :failure, failures},
          {"Normal activity", :normal, normal}
        ]
      )

    ~H"""
    <div class="space-y-4" data-testid="tail-meanings">
      <section
        :for={{heading, outcome, signals} <- @catalogue}
        :if={signals != []}
        class="space-y-2"
        data-testid={"tail-meanings-#{outcome}"}
      >
        <h3 class="fcon-eyebrow">{heading}</h3>
        <dl class="fcon-review">
          <div
            :for={signal <- signals}
            class="fcon-review-row"
            data-testid={"tail-meaning-#{signal[:name]}"}
          >
            <dt><span class="fcon-label">{signal[:label] || signal[:name]}</span></dt>
            <dd class="space-y-1">
              <span :if={outcome == :failure} class="fcon-badge fcon-badge--warning">⚠ Failure</span>
              <span :if={outcome == :normal and signal[:outcome]} class="fcon-badge">Normal</span>
              <span :if={signal[:description]} class="block fcon-hint">{signal[:description]}</span>
              <span class="block fcon-tech-name">{signal[:name]}</span>
            </dd>
          </div>
        </dl>
      </section>
    </div>
    """
  end

  @doc """
  One signal of a tail: when and on which controller, one sentence about its
  subject, a warning mark on a failure, and its labels and numbers behind a
  toggle. `source` is the tailed source's listing entry, which carries the
  declarations; `controllers` names the controllers' machines.
  """
  attr :signal, :map, required: true
  attr :source, :map, default: nil
  attr :controllers, :list, default: nil

  def tail_line(assigns) do
    assigns =
      assign(assigns,
        id: "tail-line-#{assigns.signal[:line_id]}",
        failure?: failure?(declared(assigns.source, assigns.signal[:name]))
      )

    ~H"""
    <li class="fcon-river-event" data-testid="tail-record" data-outcome={@failure? && "failure"}>
      <span class="fcon-river-time">{emitted_at(@signal)}</span>
      <span class="min-w-0">
        <span :if={@signal[:node]} class="block fcon-figures text-xs">
          <.controller_name node={@signal[:node]} controllers={@controllers} testid="tail-controller" />
        </span>
        <span
          class={["block", if(@failure?, do: "fcon-tone-warning", else: "fcon-strong")]}
          data-testid="tail-sentence"
        >
          <span :if={@failure?} aria-label="Failure" data-testid="tail-failure-mark">⚠</span>
          {sentence(@source, @signal)}
        </span>
      </span>
      <details id={@id} phx-mounted={JS.ignore_attributes(["open"])} data-testid="tail-details">
        <summary class="fcon-muted text-xs">Details</summary>
        <span class="flex flex-wrap gap-x-3 fcon-tech-name">
          <span :if={labels(@signal[:metadata])}>{labels(@signal[:metadata])}</span>
          <span>{measurements(@signal[:measurements])}</span>
        </span>
      </details>
    </li>
    """
  end

  @subjects [:relay, :relay_id, :plugin_id, :runner, :runner_id, :hub, :namespace]

  @doc """
  A signal as one sentence from its declared template, or, when it has none or
  the signal lacks a value the template names, its subject and its label.
  """
  def sentence(source, signal) do
    values = Map.merge(signal[:measurements] || %{}, signal[:metadata] || %{})

    with %{sentence: template} <- declared(source, signal[:name]),
         {:ok, filled} <- fill(template, values) do
      filled
    else
      _ ->
        label = label(source, signal[:name])

        case Enum.find_value(@subjects, &values[&1]) do
          nil -> label
          subject -> "#{word(subject)}: #{label}"
        end
    end
  end

  defp fill(template, values) do
    template
    |> String.split(~r/\{[^{}]*\}/, include_captures: true)
    |> Enum.reduce_while({:ok, ""}, fn piece, {:ok, acc} ->
      case placeholder(piece, values) do
        {:ok, text} -> {:cont, {:ok, acc <> text}}
        :missing -> {:halt, :missing}
      end
    end)
  end

  defp placeholder("{" <> rest, values) do
    {key, noun} =
      case rest |> String.trim_trailing("}") |> String.split(":", parts: 2) do
        [key, noun] -> {key, noun}
        [key] -> {key, nil}
      end

    case Enum.find(values, fn {name, _} -> to_string(name) == key end) do
      {_, value} when is_nil(noun) -> {:ok, word(value)}
      {_, 1} -> {:ok, Words.count(1, noun)}
      {_, count} when is_number(count) -> {:ok, Words.count(Format.compact(count), noun)}
      _missing -> :missing
    end
  end

  defp placeholder(text, _values), do: {:ok, text}

  # A value as a word in a sentence: a path by its last segment, a number as
  # the details show it, anything else as a label.
  defp word("/" <> _ = path), do: Path.basename(path)
  defp word(value) when is_number(value), do: figure(value)
  defp word(value), do: label_value(value)

  @doc "A span in milliseconds, to its largest unit: `3s`, `15m`."
  def ago(ms), do: Format.age(div(ms, 1_000))

  @sink_purposes %{
    Flezha.Observability.PubSubSink => "live tails",
    Flezha.Observability.RingBufferSink => "recent history",
    Flezha.Observability.AuditLog.Sink => "the audit log",
    Flezha.Observability.HookSink => "controller plugins",
    Flezha.Observability.Export.PrometheusSink => "Prometheus",
    Flezha.Observability.Export.OtlpSink => "an OTLP collector"
  }

  @doc "What a sink is for, from the module that implements it, or `nil` for one this screen does not know."
  def sink_purpose(sink), do: Map.get(@sink_purposes, sink[:module])

  @doc "What the source declares for a signal `name`, or `nil`."
  def declared(nil, _name), do: nil
  def declared(source, name), do: Enum.find(source[:signals] || [], &(&1[:name] == name))

  defp label(source, name) do
    case declared(source, name) do
      %{label: label} when is_binary(label) -> label
      _undeclared -> to_string(name)
    end
  end

  # A signal the source declares as reporting something that went wrong.
  defp failure?(%{outcome: :failure}), do: true
  defp failure?(_declared), do: false

  @doc "When a signal was emitted, by the wall-clock time its controller stamped on it."
  def emitted_at(%{at_us: at_us}) when is_integer(at_us) do
    case DateTime.from_unix(at_us, :microsecond) do
      {:ok, at} -> Format.time_of_day(at)
      {:error, _} -> "—"
    end
  end

  def emitted_at(_signal), do: "—"

  @doc "A signal's labels as sorted `key=value` pairs, each value cut to a readable length."
  def labels(metadata) when is_map(metadata) and map_size(metadata) > 0 do
    metadata
    |> Enum.map(fn {key, value} -> {label_value(key), label_value(value)} end)
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{value}" end)
  end

  def labels(_none), do: nil

  defp label_value(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp label_value(value) when is_binary(value), do: Format.printable(value, limit: 120)
  defp label_value(value), do: inspect(value, limit: 10, printable_limit: 120)

  @doc "A signal's measurements as `key value` pairs."
  def measurements(values) when is_map(values) do
    values
    |> Enum.sort()
    |> Enum.map_join("  ", fn {key, value} -> "#{key} #{figure(value)}" end)
  end

  def measurements(other), do: inspect(other)

  defp figure(value) when is_float(value), do: value |> Float.round(4) |> to_string()
  defp figure(value) when is_integer(value), do: Format.compact(value)
  defp figure(value), do: Format.printable(value)

  @doc "Whether a tail was refused because the controller's pubsub sink is off."
  def pubsub_disabled?(nil), do: false

  def pubsub_disabled?(error),
    do: NodeManager.error(error).code == "observability.pubsub_disabled"

  # The listing's own entry, found by the name a form sent. The source atom is
  # then the one the controller named — a form value is never converted.
  defp named_source(socket, name) do
    Enum.find(socket.assigns.sources, &(to_string(&1[:name]) == name))
  end

  # A source on everywhere is switched off; one off or on part of the cluster
  # is switched on everywhere.
  defp apply_toggle(socket, source) do
    token = socket.assigns.flezha_token
    on? = switch_state(source) == true

    result =
      if on?,
        do: NodeManager.disable_source(source[:name], token),
        else: NodeManager.enable_source(source[:name], token)

    case result do
      {:error, reason} ->
        assign(socket, toggle_error: reason, toggle_missed: nil)

      {:ok, %{unreachable: [_ | _] = missed}} ->
        assign(socket, toggle_error: nil, toggle_missed: {source, !on?, missed})

      _applied ->
        assign(socket, toggle_error: nil, toggle_missed: nil)
    end
  end
end
