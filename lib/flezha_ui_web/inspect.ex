defmodule FlezhaUiWeb.Inspect do
  @moduledoc """
  Inspecting a relay, a runner, a plugin or a parked entry in a drawer on the
  current screen, without navigating away.

  The selection lives in the address bar as `?inspect=<kind>:<id>`, applied
  with a patch, so an inspected object is a link someone else can open and the
  back control closes the drawer. On a screen showing more than one namespace
  a relay or runner id carries its namespace: `relay:default/orders`.

      use FlezhaUiWeb.Inspect, kinds: ~w(relay runner)

      def handle_params(params, _uri, socket) do
        {:noreply, socket |> refresh() |> inspect_params(params)}
      end

  The host renders `inspector/1` with `@inspected`, and may answer
  `inspect_context/2` with what it already knows about the selection — the
  relay's row and measured rates — so opening it costs only its one on-demand
  read: a relay's overwatch state, a runner's principal, a plugin's provider,
  a parked entry's payload. A host names the kinds it inspects, and an address
  naming any other is ignored: each kind's actions are events only its hosts
  handle — the relay inspector's Stop is a host's `confirm_stop` with a
  `relay_id`, the parked entry's Replay and Drop a host's `confirm`.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  @kinds ~w(relay runner plugin entry)
  @events ~w(inspect inspect_close inspect_diagnose)

  @doc "What the host may already know about the selection, to show without a read."
  @callback inspect_context(Phoenix.LiveView.Socket.t(), {String.t(), String.t()}) :: map()

  defmacro __using__(opts) do
    events = @events
    kinds = Keyword.fetch!(opts, :kinds)

    quote do
      @behaviour FlezhaUiWeb.Inspect

      import FlezhaUiWeb.Inspect, only: [inspect_params: 2, inspect_path: 2, inspector: 1]

      @doc false
      def inspect_kinds, do: unquote(kinds)

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Inspect.handle_event(event, params, socket)}
      end

      @impl FlezhaUiWeb.Inspect
      def inspect_context(_socket, _selection), do: %{}

      defoverridable inspect_context: 2
    end
  end

  # ---- The address ----

  @doc """
  The selection a query names, as `{kind, id}`, or `nil`.

      iex> FlezhaUiWeb.Inspect.parse(%{"inspect" => "relay:orders"})
      {"relay", "orders"}
      iex> FlezhaUiWeb.Inspect.parse(%{"inspect" => "nonsense"})
      nil
  """
  def parse(params, kinds \\ @kinds)

  def parse(%{"inspect" => value}, kinds) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [kind, id] when id != "" -> if kind in kinds, do: {kind, id}
      _other -> nil
    end
  end

  def parse(_params, _kinds), do: nil

  @doc """
  The current screen's address with `selection` inspected, or with no
  selection for `nil`; every other query parameter is kept.
  """
  def inspect_path(socket, selection) do
    query =
      case selection do
        nil -> Map.delete(socket.assigns[:current_query] || %{}, "inspect")
        {kind, id} -> Map.put(socket.assigns[:current_query] || %{}, "inspect", "#{kind}:#{id}")
      end

    if query == %{},
      do: socket.assigns.current_path,
      else: socket.assigns.current_path <> "?" <> URI.encode_query(query)
  end

  @doc """
  Applies the selection a host's params name: loads it when it changed, keeps
  it when it did not, and clears it when the params name none. Only on a
  connected socket: the dead render would read it for nothing.
  """
  def inspect_params(socket, params) do
    selection =
      if Phoenix.LiveView.connected?(socket), do: parse(params, socket.view.inspect_kinds())

    case {selection, socket.assigns[:inspected]} do
      {nil, _open} -> assign(socket, inspected: nil)
      {{kind, id}, %{kind: kind, id: id}} -> socket
      {selection, _other} -> assign(socket, inspected: load(socket, selection))
    end
  end

  @doc false
  def handle_event("inspect", %{"kind" => kind, "id" => id}, socket) do
    if kind in socket.view.inspect_kinds(),
      do: Phoenix.LiveView.push_patch(socket, to: inspect_path(socket, {kind, id})),
      else: socket
  end

  def handle_event("inspect", _params, socket), do: socket

  def handle_event("inspect_close", _params, socket),
    do: Phoenix.LiveView.push_patch(socket, to: inspect_path(socket, nil))

  def handle_event(
        "inspect_diagnose",
        _params,
        %{assigns: %{inspected: %{kind: "relay"} = it}} = socket
      ) do
    answer =
      case NodeManager.diagnose_relay(it.namespace, it.relay, socket.assigns.flezha_token) do
        {:ok, diagnosis} -> %{diagnosis: diagnosis, error: nil}
        {:error, reason} -> %{diagnosis: nil, error: reason}
      end

    assign(socket, inspected: Map.put(it, :diagnosis, answer))
  end

  def handle_event("inspect_diagnose", _params, socket), do: socket

  # ---- Loading, once per selection ----

  defp load(socket, {kind, id} = selection) do
    token = socket.assigns.flezha_token
    context = socket.view.inspect_context(socket, selection)
    {namespace, name} = split_namespace(socket, kind, id)
    base = %{kind: kind, id: id, namespace: namespace, context: context, diagnosis: nil}

    Map.merge(base, read(kind, namespace, name, context, token))
  end

  # A scoped screen names its namespace in the path; any other names it in the id.
  defp split_namespace(socket, kind, id) when kind in ~w(relay runner) do
    case {socket.assigns[:scoped_namespace], String.split(id, "/", parts: 2)} do
      {scope, _parts} when is_binary(scope) -> {scope, id}
      {nil, [namespace, name]} -> {namespace, name}
      {nil, [name]} -> {nil, name}
    end
  end

  defp split_namespace(socket, _kind, id), do: {socket.assigns[:scoped_namespace], id}

  defp read("relay", namespace, relay, _context, token) do
    case namespace && NodeManager.overwatch_facts(namespace, relay, token) do
      {:ok, facts} -> %{relay: relay, facts: facts, error: nil}
      {:error, reason} -> %{relay: relay, facts: nil, error: reason}
      nil -> %{relay: relay, facts: nil, error: :not_found}
    end
  end

  defp read("runner", namespace, runner, _context, token) do
    %{runner: runner, principal: namespace && NodeManager.runner_principal(namespace, token)}
  end

  defp read("plugin", _namespace, name, context, token) do
    case context[:provider_id] && NodeManager.provider(context.provider_id, token) do
      {:ok, provider} -> %{plugin: name, provider: provider, error: nil}
      {:error, reason} -> %{plugin: name, provider: nil, error: reason}
      nil -> %{plugin: name, provider: nil, error: nil}
    end
  end

  defp read("entry", _namespace, ref, _context, token) do
    case NodeManager.dlq_get(ref, token) do
      {:ok, entry, payload} -> %{ref: ref, entry: entry, payload: payload, error: nil}
      {:error, reason} -> %{ref: ref, entry: nil, payload: nil, error: reason}
      _other -> %{ref: ref, entry: nil, payload: nil, error: :not_found}
    end
  end

  # ---- Rendering ----

  @doc """
  The open inspector, or nothing. `operations` gates its actions.
  """
  attr :inspected, :map, default: nil
  attr :operations, :any, required: true

  def inspector(%{inspected: nil} = assigns), do: ~H""

  def inspector(%{inspected: %{kind: "relay"}} = assigns) do
    it = assigns.inspected
    facts = it.facts
    row = it.context[:row]

    assigns =
      assign(assigns,
        it: it,
        facts: facts,
        row: row,
        rate: it.context[:rate],
        history: it.context[:history] || [],
        plugins: (facts && length(Enum.uniq_by(facts.bindings, & &1.plugin_id))) || 0
      )

    ~H"""
    <.drawer
      id="inspector"
      eyebrow="Relay"
      title={@it.relay}
      on_close="inspect_close"
      testid="inspector-relay"
    >
      <%= if @facts do %>
        <p class="fui-sentence" data-testid="inspector-sentence">
          {relay_sentence(@facts, @row)}
        </p>
        <FlezhaUiWeb.RelayState.summary
          state={FlezhaUiWeb.RelayState.of(@row, @facts.suspended)}
          factory={@facts.factory_id && to_string(@facts.factory_id)}
          runner={@facts.runner_id && to_string(@facts.runner_id)}
          serving={@it.context[:serving]}
          diagnosis={@it.diagnosis && @it.diagnosis.diagnosis}
          error={@it.diagnosis && @it.diagnosis.error}
          testid="inspector-state"
          diagnosis_testid="inspector-diagnosis"
        />

        <dl class="fui-facts">
          <.stat label="In" testid="inspector-rate-in">
            <span class="fui-rate">{rate_words(@rate, :in)}</span>
            <.sparkline samples={@history} key={:in} testid="inspector-sparkline" />
          </.stat>
          <.stat label="Out"><span class="fui-rate">{rate_words(@rate, :out)}</span></.stat>
          <.stat label="Factory" mono>{@facts.factory_id || "—"}</.stat>
          <.stat label="Run">{@facts.run || "—"}</.stat>
          <.stat label="Node" mono>{(@row && @row[:node]) || "unplaced"}</.stat>
          <.stat label="Uptime">{Format.duration(@facts.uptime_ms)}</.stat>
          <.stat label="Plugins bound" testid="inspector-plugins">{@plugins}</.stat>
        </dl>
        <p :if={@it.context[:factory_description]} class="fui-figures">
          {@facts.factory_id}: {@it.context.factory_description}
        </p>
      <% else %>
        <p class="fui-sentence" data-testid="inspector-missing">
          {@it.relay} is not running in {@it.namespace || "this namespace"}: it may have stopped
          or finished since the link was made.
        </p>
      <% end %>

      <:actions>
        <.button
          :if={@it.namespace}
          navigate={~p"/namespaces/#{@it.namespace}/relays/#{@it.relay}"}
          icon_right="hero-arrow-right"
          data-testid="inspector-open"
        >
          Open relay
        </.button>
        <.button
          :if={@facts && NodeManager.granted?(@operations, "Relay.diagnose")}
          variant="secondary"
          phx-click="inspect_diagnose"
          data-testid="inspector-diagnose"
        >
          Diagnose
        </.button>
        <.button
          :if={@facts && NodeManager.granted?(@operations, "Relay.stop")}
          variant="danger"
          phx-click="confirm_stop"
          phx-value-relay_id={@it.relay}
          phx-value-namespace={@it.namespace}
          data-testid="inspector-stop"
        >
          Stop
        </.button>
      </:actions>
    </.drawer>
    """
  end

  def inspector(%{inspected: %{kind: "runner"}} = assigns) do
    it = assigns.inspected
    assigns = assign(assigns, it: it, ctx: it.context)

    ~H"""
    <.drawer
      id="inspector"
      eyebrow="Runner"
      title={short(@it.runner)}
      on_close="inspect_close"
      testid="inspector-runner"
    >
      <p class="fui-sentence" data-testid="inspector-sentence">
        A runner serving {Words.count(length(@ctx[:factories] || []), "factory", "factories")} in {@it.namespace}, with {Words.count(
          length(@ctx[:relays] || []),
          "relay"
        )} bound to it.
      </p>
      <dl class="fui-facts">
        <.stat label="Runner"><.ident value={@it.runner} copy /></.stat>
        <.stat label="OS pid" mono testid="inspector-pid">{@ctx[:pid] || "—"}</.stat>
        <.stat label="Principal" mono testid="inspector-principal">{@it.principal || "—"}</.stat>
      </dl>
      <div :if={(@ctx[:factories] || []) != []} data-fui-filterable class="space-y-2">
        <h3 class="fui-eyebrow">Factories it serves</h3>
        <input
          type="search"
          class="fui-input--compact"
          placeholder="Filter factories"
          aria-label="Filter factories"
          data-fui-filter
        />
        <ul class="flex flex-wrap gap-2" data-testid="inspector-factories">
          <li :for={factory <- @ctx.factories} data-fui-item>
            <.chip mono>{factory}</.chip>
          </li>
        </ul>
      </div>
      <div class="space-y-2">
        <h3 class="fui-eyebrow">Relays bound to it</h3>
        <p :if={(@ctx[:relays] || []) == []} class="fui-figures">No relay is bound to it.</p>
        <ul class="flex flex-wrap gap-2" data-testid="inspector-relays">
          <li :for={relay <- @ctx[:relays] || []}>
            <.link navigate={~p"/namespaces/#{@it.namespace}/relays/#{relay}"}>{relay}</.link>
          </li>
        </ul>
      </div>
    </.drawer>
    """
  end

  def inspector(%{inspected: %{kind: "plugin"}} = assigns) do
    it = assigns.inspected
    assigns = assign(assigns, it: it, ctx: it.context, provider: it.provider)

    ~H"""
    <.drawer
      id="inspector"
      eyebrow="Plugin"
      title={@it.plugin}
      on_close="inspect_close"
      testid="inspector-plugin"
    >
      <p class="fui-sentence" data-testid="inspector-sentence">
        A plugin from the {(@ctx[:provider] && to_string(@ctx.provider)) || "unknown"} provider, bound to {Words.count(
          length(@ctx[:relays] || []),
          "relay"
        )}.
      </p>
      <.runtime_error error={@it.error} action="the provider description" />
      <p :if={@provider && @provider[:help]} data-testid="inspector-provider-help">
        {@provider.help}
      </p>
      <dl class="fui-facts">
        <.stat label="Hooks">
          <span class="flex flex-wrap gap-1">
            <.chip :for={hook <- @ctx[:hooks] || []} mono>{hook}</.chip>
          </span>
        </.stat>
        <.stat label="Runs on" mono>
          {Enum.join(@ctx[:controllers] || [], ", ") |> blank_dash()}
        </.stat>
        <.stat label="Namespace" mono>{@ctx[:namespace] || @it.namespace || "—"}</.stat>
      </dl>
      <div class="space-y-2">
        <h3 class="fui-eyebrow">Relays bound to it</h3>
        <p :if={(@ctx[:relays] || []) == []} class="fui-figures">No relay is bound to it.</p>
        <ul class="flex flex-wrap gap-2" data-testid="inspector-relays">
          <li :for={relay <- @ctx[:relays] || []}>
            <.chip mono>{relay}</.chip>
          </li>
        </ul>
      </div>
    </.drawer>
    """
  end

  def inspector(%{inspected: %{kind: "entry"}} = assigns) do
    it = assigns.inspected
    assigns = assign(assigns, it: it, entry: it.entry)

    ~H"""
    <.drawer
      id="inspector"
      eyebrow="Dead letter"
      title={short(@it.ref)}
      on_close="inspect_close"
      testid="inspector-entry"
    >
      <.runtime_error error={@it.error} action="the dead letter" />
      <%= if @entry do %>
        <p class="fui-sentence" data-testid="inspector-sentence">
          Left by tasklet {field(@entry, :tasklet_id) || "—"} of {field(@entry, :relay_class) || "—"}, generation {field(
            @entry,
            :generation
          ) || 1}.
        </p>
        <dl class="fui-facts" data-testid="inspector-entry-meta">
          <.stat :for={{key, value} <- entry_facts(@entry)} label={key} mono>{value}</.stat>
        </dl>
        <div class="space-y-2">
          <h3 class="fui-eyebrow">Payload</h3>
          <.code_block testid="inspector-payload">
            {Format.printable(@it.payload, limit: 4_000)}
          </.code_block>
        </div>
      <% end %>
      <:actions>
        <.button
          :if={@entry && NodeManager.granted?(@operations, "Dlq.replay")}
          variant="secondary"
          phx-click="confirm"
          phx-value-action="replay"
          phx-value-ref={@it.ref}
          data-testid="inspector-replay"
        >
          Replay
        </.button>
        <.button
          :if={@entry && NodeManager.granted?(@operations, "Dlq.drop")}
          variant="danger"
          phx-click="confirm"
          phx-value-action="drop"
          phx-value-ref={@it.ref}
          data-testid="inspector-drop"
        >
          Drop
        </.button>
      </:actions>
    </.drawer>
    """
  end

  defp relay_sentence(facts, row) do
    run = facts.run && "#{facts.run} "
    factory = facts.factory_id && " from #{facts.factory_id}"

    where =
      cond do
        is_nil(facts.runner_id) -> ", with no runner bound"
        row && row[:node] -> ", running on #{short(facts.runner_id)} at #{row.node}"
        true -> ", bound to #{short(facts.runner_id)}"
      end

    uptime = facts.uptime_ms && " for #{Format.duration(facts.uptime_ms)}"
    "A #{run}relay#{factory}#{where}#{uptime}."
  end

  defp rate_words(nil, _key), do: "not measured yet"
  defp rate_words(rate, key), do: FlezhaUiWeb.Topology.traffic_label(rate, key)

  defp short(id) do
    id = to_string(id)
    if String.length(id) > 16, do: "…" <> String.slice(id, -7, 7), else: id
  end

  defp blank_dash(""), do: "—"
  defp blank_dash(text), do: text

  # A parked entry's metadata arrives keyed by string from the store.
  defp field(entry, key), do: Map.get(entry, key) || Map.get(entry, Atom.to_string(key))

  defp entry_facts(entry) do
    for {key, value} <- Enum.sort_by(entry, fn {key, _} -> to_string(key) end),
        to_string(key) not in ~w(payload),
        not is_nil(value),
        do:
          {key |> to_string() |> String.replace("_", " ") |> String.capitalize(),
           Format.printable(value)}
  end
end
