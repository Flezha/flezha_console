defmodule FlezhaUiWeb.ObservabilityLive do
  @moduledoc """
  What each part of the controller reports about itself, what it reported
  recently, and a live view of it.

  The controller describes every source and signal and counts what its ring
  buffer holds, so this screen explains and summarises without a table of its
  own. The tail rides `FlezhaUi.Service.EventFeed`, the same feed the runtime
  events use, and opens with the source's buffered history.
  """

  use FlezhaUiWeb, :live_view

  use FlezhaUiWeb.Live.Refresh, every: 5_000
  use FlezhaUiWeb.Live.Tail, tag: :observability_tail, max: 200

  alias FlezhaUi.Format
  alias FlezhaUi.Service.NodeManager

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
       history_error: nil,
       clock_offset_us: nil,
       tail_source: nil
     )
     |> refresh()}
  end

  @doc """
  A forwarded signal, as a plain map. The controller sends its
  `%Flezha.Observability.Signal{}` struct, which this node has no module for
  and which `Access` cannot read.
  """
  @impl FlezhaUiWeb.Live.Tail
  def unwrap_tail(signal) when is_map(signal), do: Map.delete(signal, :__struct__)

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

  @impl FlezhaUiWeb.Live.Refresh
  def refresh(socket) do
    token = socket.assigns.flezha_token

    case NodeManager.observability_sources(token) do
      {:ok, sources} ->
        assign(socket,
          sources: sources,
          sinks: NodeManager.ok_or(NodeManager.observability_sinks(token), []),
          load_error: nil,
          disabled?: false
        )

      {:error, reason} ->
        if NodeManager.error(reason).code == "observability.disabled",
          do: assign(socket, sources: [], sinks: [], load_error: nil, disabled?: true),
          else: assign(socket, sources: [], sinks: [], load_error: reason, disabled?: false)
    end
  end

  # The buffered history first, under one reading of the controller's clock
  # that every signal's time is then placed against, live ones included.
  defp open_tail(socket, name) do
    token = socket.assigns.flezha_token

    {history, history_error} =
      case NodeManager.observability_query(%{source: name, limit: @history}, token) do
        {:ok, signals} when is_list(signals) ->
          {signals
           |> Enum.reverse()
           |> Enum.map(&(&1 |> unwrap_tail() |> Map.put(:history?, true))), nil}

        {:error, reason} ->
          {[], reason}

        _other ->
          {[], nil}
      end

    offset =
      case NodeManager.controller_monotonic_us(token) do
        now when is_integer(now) -> System.os_time(:microsecond) - now
        _unknown -> nil
      end

    socket
    |> start_tail(&NodeManager.observability_tail(name, token, &1), name, seed: history)
    |> assign(
      history_error: history_error,
      clock_offset_us: offset,
      tail_source: Enum.find(socket.assigns.sources, &(&1[:name] == name))
    )
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
  each group with its sources whose name or description contains `filter` —
  those that spoke recently first — and how many of all its sources are on.
  """
  def groups(sources, filter) do
    needle = filter |> String.trim() |> String.downcase()

    sources
    |> Enum.group_by(&area/1)
    |> Enum.map(fn {key, members} ->
      %{
        key: key,
        label: Keyword.fetch!(@areas, key),
        enabled: Enum.count(members, &NodeManager.source_enabled?/1),
        total: length(members),
        sources:
          members
          |> Enum.filter(&matches?(&1, needle))
          |> Enum.sort_by(&{quiet?(&1), to_string(&1[:name])})
      }
    end)
    |> Enum.sort_by(fn group -> Enum.find_index(Keyword.keys(@areas), &(&1 == group.key)) end)
  end

  defp area(source) do
    if Keyword.has_key?(@areas, source[:area]), do: source[:area], else: :other
  end

  defp matches?(source, needle) do
    Enum.any?([source[:name], source[:description]], fn text ->
      text |> to_string() |> String.downcase() |> String.contains?(needle)
    end)
  end

  defp quiet?(source), do: activity(source) |> elem(0) != :active

  @doc """
  What a source said within the controller's history window:
  `{:active, [{name, count}], newest_age_ms}`, most frequent first;
  `{:quiet, window_ms}`; or `{:unknown, nil}` when the controller does not say.
  """
  def activity(source) do
    case source[:recent] do
      %{signals: signals, window_ms: window} when map_size(signals) == 0 ->
        {:quiet, window}

      %{signals: signals} when is_map(signals) ->
        counts =
          signals
          |> Enum.map(fn {name, %{count: count}} -> {name, count} end)
          |> Enum.sort_by(fn {name, count} -> {-count, to_string(name)} end)

        newest = signals |> Map.values() |> Enum.map(& &1.last_age_ms) |> Enum.min()
        {:active, counts, newest}

      _absent ->
        {:unknown, nil}
    end
  end

  @doc "A source's activity line: what it said in the history window, or that it said nothing."
  attr :source, :map, required: true

  def activity_line(%{source: source} = assigns) do
    assigns = assign(assigns, :activity, activity(source))

    ~H"""
    <span class="block fui-figures" data-testid={"source-activity-#{@source[:name]}"}>
      <%= case @activity do %>
        <% {:active, counts, newest} -> %>
          {Enum.map_join(Enum.take(counts, 3), " · ", fn {name, count} ->
            "#{name} ×#{Format.compact(count)}"
          end)}{if length(counts) > 3, do: " · #{length(counts) - 3} more"} · last {ago(newest)} ago
        <% {:quiet, window} -> %>
          Nothing in the last {ago(window)}
        <% {:unknown, nil} -> %>
      <% end %>
    </span>
    """
  end

  @doc "Every signal a source declares, with what it says."
  attr :source, :map, required: true

  def signal_meanings(assigns) do
    ~H"""
    <dl
      class="fui-figures grid grid-cols-[minmax(0,10rem)_1fr] gap-x-3 gap-y-1"
      data-testid="tail-meanings"
    >
      <%= for signal <- @source[:signals] || [] do %>
        <dt class="fui-num truncate">{signal[:name]}</dt>
        <dd>{signal[:description]}</dd>
      <% end %>
    </dl>
    """
  end

  @doc """
  One signal of a tail: when, what, what it means, about whom and how much.
  `source` is the tailed source's listing entry, which carries the meanings.
  """
  attr :signal, :map, required: true
  attr :source, :map, default: nil
  attr :offset_us, :integer, default: nil

  def tail_line(assigns) do
    ~H"""
    <li class="fui-river-event" data-testid="tail-record">
      <span class="fui-river-time">{emitted_at(@signal, @offset_us)}</span>
      <span class="fui-river-object">{@signal[:name]}</span>
      <span class="min-w-0">
        <span :if={meaning(@source, @signal[:name])} class="block">
          {meaning(@source, @signal[:name])}
        </span>
        <span class="flex flex-wrap gap-x-3 fui-num text-xs break-all">
          <span :if={labels(@signal[:metadata])}>{labels(@signal[:metadata])}</span>
          <span>{measurements(@signal[:measurements])}</span>
        </span>
      </span>
    </li>
    """
  end

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

  @doc "The meaning the source declares for a signal `name`, or `nil`."
  def meaning(nil, _name), do: nil

  def meaning(source, name) do
    Enum.find_value(source[:signals] || [], fn signal ->
      if signal[:name] == name, do: signal[:description]
    end)
  end

  @doc "When a signal was emitted, placed on this node's clock through `offset_us`."
  def emitted_at(%{ts: ts}, offset_us) when is_integer(ts) and is_integer(offset_us) do
    case DateTime.from_unix(ts + offset_us, :microsecond) do
      {:ok, at} -> Format.time_of_day(at)
      {:error, _} -> "—"
    end
  end

  def emitted_at(_signal, _offset_us), do: "—"

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

  @doc """
  A signal's measurements as `key value` pairs. Its own timestamp is the
  emitting node's monotonic clock, which says nothing to a reader, so it is
  not shown as a number.
  """
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

  defp apply_toggle(socket, source) do
    token = socket.assigns.flezha_token

    result =
      if NodeManager.source_enabled?(source) do
        NodeManager.disable_source(source[:name], token)
      else
        NodeManager.enable_source(source[:name], token)
      end

    case result do
      {:error, reason} -> assign(socket, toggle_error: reason)
      _ok -> assign(socket, toggle_error: nil)
    end
  end
end
