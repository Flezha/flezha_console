defmodule FlezhaUiWeb.Topology do
  @moduledoc """
  The data plane, seen two ways: one operative's pipeline, and a namespace's
  health at a glance.

  flezha has no user-declared operative→operative wiring — a builder names a
  factory, not upstream peers — so the graph worth drawing is *one operative's
  own path*: transport ingest → its `on_input` plugins in position order → the
  operative core → its `on_output` plugins → the bound runner's stream channel
  → output, with failures parking into the dead-letter queue. Structure comes
  from the controller's own extension table, so the picture shows what is
  actually attached, in the order it runs.

  A namespace gets a summary rather than a canvas of every operative: flezha
  runs thousands, and the summary costs the same five controller calls whatever
  that number is.

  Three parts, in the order a host uses them:

    * the host seam — `use FlezhaUiWeb.Topology`, then `init/1` in mount and
      `load_pipeline/1` or `load_summary/2` inside the host's own `refresh/1`.
      Everything kept between ticks (the previous snapshot, rate history, the
      selection) lives in the `:topology_state` assign.
    * the view model — `pipeline/1`, `summary/1`, `rates/3`, `push_history/2`,
      `speed_bucket/1`. Pure, so the delta arithmetic and the joins are
      testable without a controller.
    * the rendering — `pipeline_graph/1` and `fleet_summary/1`, server-rendered
      SVG and HEEx whose flow animation is CSS keyed to a speed bucket.

  Rates are `Δcount / Δt` between this UI's own ticks, not controller-side
  timing, and only on the three edges the controller actually counts. The
  controller keeps no per-extension counter, so the chain between plugins
  carries no figure — a tap is how you measure a point the counters miss.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  # A vertical chain: it fits the column it is given at any length, and the
  # page already scrolls downward.
  @node_w 240
  @node_h 52
  @row_step 96
  @pad 20
  @branch_gap 44
  @branch_w 176

  @history_limit 60
  @stall_window_us 60_000_000
  @stall_query %{source: :flezha_data_plane, limit: 20}

  # The extension points that sit on the record path, and where.
  @inbound [:on_input]
  @outbound [:on_output]

  # Named exactly, not by prefix: a host owns `graph_*` events of its own — the
  # operative page's payload tap is one — and a prefix match would swallow them
  # before the host's own clauses were reached.
  @events ~w(graph_select graph_dismiss)

  @doc "The events this component handles; a host keeps the rest for itself."
  def events, do: @events

  @doc """
  Embeds the topology in a host LiveView: the components, and the delegation of
  the graph's own events.

  The import is scoped because an unqualified one would collide with the host's
  `handle_event/3`.
  """
  defmacro __using__(_opts) do
    events = @events

    quote do
      import FlezhaUiWeb.Topology, only: [pipeline_graph: 1, fleet_summary: 1]

      @impl Phoenix.LiveView
      def handle_event(event, params, socket) when event in unquote(events) do
        {:noreply, FlezhaUiWeb.Topology.handle_event(event, params, socket)}
      end
    end
  end

  # ---- Host seam ----

  @doc "Initial assigns for a host embedding the topology. Call before the first load."
  def init(socket) do
    assign(socket,
      topology: nil,
      topology_state: %{prev: nil, prev_at: nil, history: %{}, selected: nil}
    )
  end

  @doc """
  Reloads one operative's pipeline.

  Reads the overwatch facts the host already assigned, so a tick costs one
  liveness snapshot and the reads that are namespace-wide anyway — never a
  second overwatch call for the operative the host just fetched.
  """
  def load_pipeline(socket) do
    %{ns: namespace, operative_id: operative_id, overwatch: facts} = socket.assigns
    state = socket.assigns.topology_state
    token = socket.assigns[:flezha_token]

    if NodeManager.connected_node() do
      {snapshot, skew} = snapshot()
      {rates, state} = advance(state, snapshot, [operative_id])
      {verdicts, stall_notice} = stall(token)

      assign_topology(
        socket,
        state,
        pipeline(%{
          namespace: namespace,
          operative_id: operative_id,
          facts: facts,
          snapshot: snapshot,
          rate: Map.get(rates, operative_id),
          history: state.history |> Map.get(operative_id, []) |> Enum.reverse(),
          parked: parked_for(facts),
          verdicts: verdicts,
          stall_notice: stall_notice,
          skew: skew,
          selected: state.selected
        })
      )
    else
      disconnected(socket, state)
    end
  end

  @doc """
  Reloads a namespace's fleet summary.

  Deliberately issues no per-operative call: the liveness snapshot already
  carries every operative's counters, so the cost is flat in the size of the
  fleet. `prefetched_rows` lets a host that has already read
  `operative_rows/1` this tick avoid a second identical read.
  """
  def load_summary(socket, namespace, prefetched \\ nil) do
    state = socket.assigns.topology_state
    token = socket.assigns[:flezha_token]

    cond do
      is_nil(NodeManager.connected_node()) ->
        disconnected(socket, state)

      is_nil(namespace) ->
        assign_topology(socket, state, summary_view(%{state: :empty, namespace: nil}))

      true ->
        {snapshot, skew} = snapshot()

        # Health comes from the same registry dump the listings read, so the
        # summary can break its counts down rather than reporting liveness
        # alone — still one call for the namespace, whatever its size.
        # A host that already read the namespace's rows and groups hands them
        # over rather than paying for the same registry dump — and the same
        # per-group coverage check — twice on one tick.
        rows = (prefetched && prefetched.rows) || NodeManager.namespace_rows(namespace)
        groups = (prefetched && prefetched.groups) || NodeManager.partition_groups(rows)

        ids = Enum.map(rows, &to_string(&1.id))
        {rates, state} = advance(state, snapshot, ids)
        {verdicts, stall_notice} = stall(token)

        assign_topology(
          socket,
          state,
          summary(%{
            namespace: namespace,
            rows: rows,
            operative_ids: ids,
            faulted_groups: NodeManager.faulted_group_ids(groups),
            runners: runner_ids(namespace),
            snapshot: snapshot,
            rates: rates,
            dlq: NodeManager.ok_or(NodeManager.dlq_stats(), []),
            verdicts: verdicts,
            stall_notice: stall_notice,
            skew: skew
          })
        )
    end
  end

  @doc """
  The graph's own events. A host forwards `"graph_*"` events here.

  Selecting re-renders from what the last tick already fetched rather than
  re-reading the controller.
  """
  def handle_event("graph_select", %{"id" => id}, socket), do: select(socket, id)
  def handle_event("graph_dismiss", _params, socket), do: select(socket, nil)

  defp select(socket, id) do
    state = %{socket.assigns.topology_state | selected: id}

    socket
    |> assign(topology_state: state)
    |> assign(topology: reselect(socket.assigns.topology, id))
  end

  defp reselect(nil, _id), do: nil

  defp reselect(%{nodes: nodes} = topology, id) do
    %{topology | selected: Enum.find(nodes, &(&1.id == id && &1.selectable?))}
  end

  defp reselect(topology, _id), do: topology

  defp assign_topology(socket, state, topology) do
    socket |> assign(topology: topology) |> assign(topology_state: state)
  end

  # A stale baseline carried across a disconnect would produce one tick of
  # fictional rates on reconnect, so the graph starts from no baseline instead.
  defp disconnected(socket, state) do
    assign_topology(
      socket,
      %{state | prev: nil, prev_at: nil},
      %{kind: :disconnected, state: :disconnected}
    )
  end

  # One tick of the shared arithmetic: rates against the previous snapshot,
  # history advanced and pruned to the ids still present.
  defp advance(state, snapshot, ids) do
    now = System.monotonic_time(:millisecond)
    rates = rates(snapshot, state.prev, now - (state.prev_at || now))
    history = state.history |> push_history(rates) |> Map.take(ids)

    {rates,
     %{
       state
       | history: history,
         prev: snapshot || state.prev,
         prev_at: (snapshot && now) || state.prev_at
     }}
  end

  # `:api_missing` is the defined answer from a controller predating the
  # counters: the graph still draws structure, so it is carried through as a
  # notice rather than swallowed. Any other failure simply leaves no rates —
  # the host's own error banner already says the controller is unhappy.
  defp snapshot do
    case NodeManager.liveness_snapshot() do
      %{} = snapshot -> {snapshot, nil}
      {:error, {:api_missing, _module, _function, _arity} = reason} -> {nil, reason}
      _other -> {nil, nil}
    end
  end

  defp runner_ids(namespace) do
    namespace
    |> NodeManager.active_runners()
    |> NodeManager.ok_or([])
    |> Enum.map(&NodeManager.identifier_id/1)
  end

  defp parked_for(facts) do
    NodeManager.dlq_stats()
    |> NodeManager.ok_or([])
    |> Enum.filter(&(to_string(Map.get(&1, :operative_class)) == facts.operative_class))
    |> Enum.reduce(0, &(&2 + Map.get(&1, :entries, 0)))
  end

  @doc """
  Recent stall verdicts, and why there are none when there are none.

  Answers `{verdicts, notice}`. The notice is what separates "nothing is
  stalled" from "we were not allowed to look": a refusal and a switched-off
  subsystem are stated, and every other failure stays silent, because a
  transport blip is not news about the data plane.

  The controller's clock is only read when there is something to age, so a
  quiet ring buffer costs one call per tick rather than two.
  """
  def stall(token) do
    case NodeManager.observability_query(@stall_query, token) do
      {:ok, signals} when is_list(signals) -> {recent(signals), nil}
      {:error, {:forbidden, reason}} -> {[], {:refused, reason}}
      {:error, :observability_disabled} -> {[], :disabled}
      _other -> {[], nil}
    end
  end

  defp recent(signals) do
    with [_ | _] = stalls <- Enum.filter(signals, &(Map.get(&1, :name) == :stall_localized)),
         now when is_integer(now) <- NodeManager.controller_monotonic_us() do
      stalls
      |> Enum.filter(fn signal -> now - signal_ts(signal) < @stall_window_us end)
      |> Enum.sort_by(&signal_ts/1, :desc)
      |> Enum.map(&verdict/1)
    else
      _none -> []
    end
  end

  defp signal_ts(signal), do: Map.get(signal, :ts) || 0

  defp verdict(signal) do
    metadata = Map.get(signal, :metadata) || %{}

    %{layer: Map.get(metadata, :layer), entity: verdict_entity(metadata)}
  end

  # The classifier names whichever entity its verdict is about; the deepest
  # identifier present wins, and a driver-level verdict names no node.
  defp verdict_entity(%{operative_id: id}) when not is_nil(id), do: to_string(id)
  defp verdict_entity(%{runner_id: id}) when not is_nil(id), do: to_string(id)
  defp verdict_entity(%{channel: name}) when not is_nil(name), do: to_string(name)
  defp verdict_entity(_metadata), do: nil

  # ---- Pipeline view model ----

  @doc """
  One operative's pipeline, as nodes and edges.

  Pure: the overwatch facts (including the extension table), the liveness
  snapshot, the computed rate and its history, the parked count, and any recent
  stall verdicts all arrive in `input`.
  """
  def pipeline(input) do
    facts = input.facts
    channel = channel_for(input.snapshot, facts.runner_id)
    {inbound, outbound, satellites} = stages(facts.bindings)

    chain =
      [%{id: "ingest", kind: :ingest, label: "Ingest", sub: "transport"}] ++
        Enum.map(inbound, &stage_node/1) ++
        [core_node(input, facts)] ++
        Enum.map(outbound, &stage_node/1) ++
        [channel_node(input, facts, channel), sink_node()]

    nodes = position(chain)
    core = Enum.find(nodes, &(&1.kind == :core))
    branches = branch_nodes(input, satellites, core)
    all = nodes ++ branches

    %{
      kind: :pipeline,
      state: :ok,
      namespace: input.namespace,
      operative_id: input.operative_id,
      nodes: all,
      edges: chain_edges(nodes, input) ++ branch_edges(core, branches),
      width: @pad + @node_w + @branch_gap + @branch_w + @pad,
      height: canvas_height(all),
      selected: Enum.find(all, &(&1.id == input.selected && &1.selectable?)),
      stall: List.first(input.verdicts),
      stall_notice: Map.get(input, :stall_notice),
      skew: input.skew,
      plugin_count: length(facts.bindings)
    }
  end

  # `on_input` runs before the operative sees a record and `on_output` after it
  # forwards one; everything else fires off the record path, so it hangs off the
  # core rather than pretending to be a step.
  defp stages(bindings) do
    sorted = Enum.sort_by(bindings, &{&1.position || 0, &1.plugin_id})

    {Enum.filter(sorted, &on?(&1, @inbound)), Enum.filter(sorted, &on?(&1, @outbound)),
     Enum.reject(sorted, &(on?(&1, @inbound) or on?(&1, @outbound)))}
  end

  defp on?(entry, extensions), do: entry.extension in Enum.map(extensions, &Atom.to_string/1)

  defp stage_node(entry) do
    %{
      id: "plugin-#{entry.plugin_id}",
      kind: :plugin,
      label: entry.plugin_id,
      sub: "#{entry.extension}#{position_suffix(entry.position)} · #{entry.provider}",
      selectable?: true,
      plugin_id: entry.plugin_id,
      extension: entry.extension,
      provider: entry.provider,
      position: entry.position
    }
  end

  defp position_suffix(nil), do: ""
  defp position_suffix(position), do: " ##{position}"

  defp core_node(input, facts) do
    %{
      id: input.operative_id,
      kind: :core,
      label: input.operative_id,
      sub: to_string(facts.factory_id || "—"),
      selectable?: true,
      state: (facts.suspended && :suspended) || :running,
      facts: facts,
      counters: operative_counters(input.snapshot, input.operative_id),
      rate: input.rate,
      history: input.history,
      href: ~p"/namespaces/#{input.namespace}/operatives/#{input.operative_id}/stream"
    }
  end

  defp channel_node(_input, facts, channel) do
    %{
      id: "channel",
      kind: :channel,
      label: facts.runner_id || "unbound",
      sub: (channel && "stream channel") || "no channel counters",
      selectable?: true,
      state: channel_state(facts.runner_id),
      channel: channel,
      backpressure?: channel != nil and credit_exhausted?(channel),
      href: ~p"/cluster"
    }
  end

  defp channel_state(nil), do: :unbound
  defp channel_state(_runner_id), do: :bound

  defp sink_node, do: %{id: "output", kind: :sink, label: "Output", sub: "runner stream"}

  # Every chain node is one row down from the last.
  defp position(chain) do
    chain
    |> Enum.with_index()
    |> Enum.map(fn {node, row} ->
      node
      |> Map.put_new(:selectable?, false)
      |> Map.merge(%{x: @pad, y: @pad + row * @row_step})
    end)
  end

  # The dead-letter branch and the off-path extensions live in their own column
  # beside the core, so neither pretends to be a step on the record path.
  defp branch_nodes(input, satellites, core) do
    dlq =
      if input.parked > 0 do
        [
          %{
            id: "dead-letter",
            kind: :dead_letter,
            label: "Dead letter",
            sub: "#{input.parked} parked",
            selectable?: false,
            href: ~p"/dlq"
          }
        ]
      else
        []
      end

    (dlq ++ Enum.map(satellites, &stage_node/1))
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      Map.merge(node, %{
        x: @pad + @node_w + @branch_gap,
        y: core.y + index * @row_step
      })
    end)
  end

  # Rates land only where the controller counts: into the operative, out of it,
  # and out of the channel. Between plugins there is no counter, so no figure.
  defp chain_edges(nodes, input) do
    nodes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      %{
        id: "flow-#{from.id}-#{to.id}",
        kind: :flow,
        rate: edge_rate(from, to, input.rate),
        degraded?: to.kind == :channel and to.state == :unbound,
        x1: from.x + div(@node_w, 2),
        y1: from.y + @node_h,
        x2: to.x + div(@node_w, 2),
        y2: to.y
      }
      |> then(&Map.put(&1, :bucket, speed_bucket(&1.rate)))
    end)
  end

  defp edge_rate(_from, %{kind: :core}, rate), do: rate && rate.in
  defp edge_rate(%{kind: :core}, _to, rate), do: rate && rate.out
  defp edge_rate(%{kind: :channel}, _to, rate), do: rate && rate.out
  defp edge_rate(_from, _to, _rate), do: nil

  defp branch_edges(core, branches) do
    Enum.map(branches, fn branch ->
      %{
        id: "branch-#{branch.id}",
        kind: (branch.kind == :dead_letter && :dlq) || :satellite,
        rate: nil,
        bucket: :idle,
        degraded?: false,
        x1: core.x + @node_w,
        y1: core.y + div(@node_h, 2),
        x2: branch.x,
        y2: branch.y + div(@node_h, 2)
      }
    end)
  end

  defp canvas_height(nodes) do
    Enum.max(Enum.map(nodes, & &1.y)) + @node_h + @pad
  end

  # ---- Summary view model ----

  @doc """
  A namespace's data plane at a glance, from reads that do not grow with the
  size of the fleet.
  """
  def summary(input) do
    live = MapSet.new(input.operative_ids)
    channels = channels_by_runner(input.snapshot)

    busiest =
      input.rates
      |> Enum.filter(fn {id, _rate} -> MapSet.member?(live, id) end)
      |> Enum.map(fn {id, rate} ->
        %{
          id: id,
          in: rate.in,
          out: rate.out,
          href: ~p"/namespaces/#{input.namespace}/operatives/#{id}"
        }
      end)
      |> Enum.sort_by(&(-(&1.in + &1.out)))
      |> Enum.take(5)

    rows = Map.get(input, :rows, [])
    faulted = Map.get(input, :faulted_groups, [])

    # Surfaced whatever their throughput: an operative that is unhealthy,
    # unplaced, or owning a broken key range is exactly the one whose counters
    # have stopped moving, so a ranking by throughput would bury it.
    attention =
      rows
      |> Enum.filter(fn row ->
        NodeManager.row_health(row) != :healthy or is_nil(row[:node]) or
          (row[:partition] && row.partition.group in faulted)
      end)
      |> Enum.map(fn row ->
        %{
          id: to_string(row.id),
          health: NodeManager.row_health(row),
          unplaced?: is_nil(row[:node]),
          faulted_group: row[:partition] && row.partition.group in faulted && row.partition.group,
          href: ~p"/namespaces/#{input.namespace}/operatives/#{row.id}"
        }
      end)
      |> Enum.sort_by(& &1.id)

    summary_view(%{
      state: ((input.operative_ids == [] and input.runners == []) && :empty) || :ok,
      namespace: input.namespace,
      operative_count: length(input.operative_ids),
      health:
        Enum.map(NodeManager.health_counts(rows), fn {health, count} ->
          %{
            health: health,
            count: count,
            href: ~p"/operatives?#{[namespace: input.namespace, health: health]}"
          }
        end),
      attention: attention,
      stall_notice: Map.get(input, :stall_notice),
      runner_count: length(input.runners),
      backpressured:
        Enum.filter(input.runners, fn runner ->
          channels |> Map.get(runner, []) |> Enum.any?(&credit_exhausted?/1)
        end),
      parked: Enum.reduce(input.dlq, 0, &(&2 + Map.get(&1, :entries, 0))),
      stall: List.first(input.verdicts),
      busiest: busiest,
      skew: input.skew
    })
  end

  defp summary_view(fields) do
    Map.merge(
      %{
        kind: :summary,
        state: :ok,
        namespace: nil,
        operative_count: 0,
        runner_count: 0,
        backpressured: [],
        parked: 0,
        stall: nil,
        stall_notice: nil,
        health: [],
        attention: [],
        busiest: [],
        skew: nil
      },
      fields
    )
  end

  # ---- Shared arithmetic ----

  @doc """
  Per-operative in/out message rates from two snapshots and the milliseconds
  between them.

  Answers `%{operative_id => %{in: rate, out: rate}}`, and nothing at all
  without a baseline — a first tick has no elapsed time to divide by. A
  negative delta means the controller restarted and its counters reset; that
  clamps to zero for the one tick rather than rendering a nonsense figure.
  """
  def rates(snapshot, previous, elapsed_ms)
      when is_map(snapshot) and is_map(previous) and elapsed_ms > 0 do
    before = index_operatives(previous)
    seconds = elapsed_ms / 1_000

    snapshot
    |> Map.get(:operatives, [])
    |> Enum.reduce(%{}, fn entry, acc ->
      id = NodeManager.identifier_id(Map.get(entry, :operative_id))

      case Map.fetch(before, id) do
        {:ok, base} ->
          Map.put(acc, id, %{
            in: rate(entry, base, :io_in_received, seconds),
            out: rate(entry, base, :forwarded, seconds)
          })

        :error ->
          acc
      end
    end)
  end

  def rates(_snapshot, _previous, _elapsed_ms), do: %{}

  defp rate(entry, base, slot, seconds) do
    delta = max(Map.get(entry, slot, 0) - Map.get(base, slot, 0), 0)

    Float.round(delta / seconds, 1)
  end

  @doc """
  Appends this tick's rates to each operative's history, newest first.

  Capped at #{@history_limit} samples: the sparkline is a session-local view of
  the recent past, not a metrics store.
  """
  def push_history(history, rates) do
    Enum.reduce(rates, history, fn {id, rate}, acc ->
      Map.update(acc, id, [rate], &Enum.take([rate | &1], @history_limit))
    end)
  end

  @doc """
  The animation bucket for a rate. Zero — and no rate at all — is `:idle`, and
  an idle edge renders static rather than animating at an imperceptible speed.
  """
  def speed_bucket(nil), do: :idle
  def speed_bucket(rate) when rate <= 0, do: :idle
  def speed_bucket(rate) when rate < 10, do: :slow
  def speed_bucket(rate) when rate < 100, do: :medium
  def speed_bucket(_rate), do: :fast

  defp index_operatives(snapshot) do
    snapshot
    |> Map.get(:operatives, [])
    |> Map.new(&{NodeManager.identifier_id(Map.get(&1, :operative_id)), &1})
  end

  defp operative_counters(nil, _operative_id), do: nil

  defp operative_counters(snapshot, operative_id) do
    Map.get(index_operatives(snapshot), operative_id)
  end

  defp channel_for(nil, _runner_id), do: nil
  defp channel_for(_snapshot, nil), do: nil

  defp channel_for(snapshot, runner_id) do
    snapshot |> channels_by_runner() |> Map.get(runner_id, []) |> List.first()
  end

  # A channel is registered through the controller's process registry, so its
  # `name` arrives as the `:via` tuple rather than a plain id — the seam's
  # normaliser is what knows that.
  defp channels_by_runner(nil), do: %{}

  defp channels_by_runner(snapshot) do
    snapshot
    |> Map.get(:channels, [])
    |> Enum.map(&Map.put(&1, :name, NodeManager.identifier_id(Map.get(&1, :name))))
    |> Enum.group_by(&NodeManager.identifier_id(Map.get(&1, :runner_id)))
    |> Map.new(fn {runner, channels} -> {runner, Enum.sort_by(channels, & &1.name)} end)
  end

  # A credit-speaking sender whose ledger has run dry is the controller telling
  # us the runner cannot take more.
  defp credit_exhausted?(channel) do
    Map.get(channel, :credit_active, 0) > 0 and Map.get(channel, :credit_ledger_level, 0) <= 0
  end

  # ---- Pipeline rendering ----

  @doc """
  One operative's pipeline: the chain, its banners, the legend, and the detail
  panel for the selected node.

  The `:tap` slot is where the host puts its payload tap, beside the chain.
  """
  attr :topology, :any, required: true
  slot :tap

  def pipeline_graph(assigns) do
    ~H"""
    <.graph_frame
      topology={@topology}
      kind={:pipeline}
      testid="topology-graph"
      icon="hero-share"
      title="Pipeline"
    >
      <:header>
        <span :if={@topology && @topology.kind == :pipeline} class="text-xs text-th-muted">
          {@topology.plugin_count} plugin{if @topology.plugin_count == 1, do: "", else: "s"} attached
        </span>
      </:header>

      <div class="flex flex-col lg:flex-row gap-4">
        <.detail :if={@topology.selected} node={@topology.selected} />
        {render_slot(@tap)}

        <div class="flex-1 order-last">
          <svg
            viewBox={"0 0 #{@topology.width} #{@topology.height}"}
            width={@topology.width}
            height={@topology.height}
            class="max-w-full h-auto mx-auto"
            role="img"
            aria-label={"Pipeline of #{@topology.operative_id}"}
          >
            <g><.edge :for={edge <- @topology.edges} edge={edge} /></g>
            <g>
              <.graph_node :for={node <- @topology.nodes} node={node} selected={@topology.selected} />
            </g>
          </svg>

          <.legend />
        </div>
      </div>
    </.graph_frame>
    """
  end

  # Both graphs are the same frame around a different body: the panel chrome, an
  # honest word when the controller is unreachable, and the notices neither of
  # them may go without.
  attr :topology, :any, required: true
  attr :kind, :atom, required: true, doc: "the topology kind whose body this frame holds"
  attr :testid, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :header, doc: "controls at the right of the panel header"
  slot :inner_block, required: true

  defp graph_frame(assigns) do
    ~H"""
    <.panel testid={@testid} icon={@icon} class="overflow-hidden">
      <:title>{@title}</:title>
      <:actions :if={@header != []}>{render_slot(@header)}</:actions>

      <div
        :if={@topology && @topology.state == :disconnected}
        data-testid="topology-disconnected"
        class="p-5"
      >
        <.runtime_error error={:node_not_connected} />
      </div>

      <div :if={@topology && @topology.kind == @kind} class="p-5 space-y-4">
        <.graph_notices topology={@topology} />
        {render_slot(@inner_block)}
      </div>
    </.panel>
    """
  end

  defp legend(assigns) do
    ~H"""
    <dl
      data-testid="topology-legend"
      class="mt-4 pt-3 border-t border-brd-subtle grid grid-cols-2 gap-x-6 gap-y-1 text-[11px]"
    >
      <.legend_item swatch="topo-flow-medium">Records flowing; speed tracks the rate</.legend_item>
      <.legend_item swatch="topo-flow-idle">Idle — no records since the last tick</.legend_item>
      <.legend_item swatch="topo-edge-satellite">Runs off the record path</.legend_item>
      <.legend_item swatch="topo-edge-dlq">Failures parking into the dead-letter queue</.legend_item>
      <.legend_item swatch="topo-edge-degraded">Nothing bound at the far end</.legend_item>
      <.legend_item swatch="topo-flow-fast">Busy — over 100 records a second</.legend_item>
    </dl>
    """
  end

  attr :swatch, :string, required: true
  slot :inner_block, required: true

  defp legend_item(assigns) do
    ~H"""
    <div class="flex items-center gap-2">
      <svg width="26" height="8" class="shrink-0" aria-hidden="true">
        <line x1="0" y1="4" x2="26" y2="4" class={["topo-edge", @swatch]} />
      </svg>
      <dd class="text-th-muted">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  attr :edge, :map, required: true

  defp edge(assigns) do
    assigns = assign(assigns, :label, edge_label(assigns.edge))

    ~H"""
    <line
      data-testid={"topo-edge-#{@edge.id}"}
      x1={@edge.x1}
      y1={@edge.y1}
      x2={@edge.x2}
      y2={@edge.y2}
      class={edge_class(@edge)}
    />
    <text
      :if={@label}
      data-testid={"#{@label.name}-#{@edge.id}"}
      x={@edge.x1 + 10}
      y={div(@edge.y1 + @edge.y2, 2) + 4}
      class={[@label.name, @label.muted? && "is-muted"]}
    >
      {@label.text}
    </text>
    """
  end

  # Only the edges the controller counts carry a figure. An idle edge still
  # states its zero, but quietly: one busy operative should not read as a
  # column of identical numbers.
  defp edge_label(%{kind: :flow, rate: rate}) when is_number(rate),
    do: %{name: "topo-rate", text: "#{rate}/s", muted?: rate == 0}

  defp edge_label(_edge), do: nil

  defp edge_class(%{degraded?: true}), do: "topo-edge topo-edge-degraded"
  defp edge_class(%{kind: :flow} = edge), do: "topo-edge topo-flow-#{edge.bucket}"
  defp edge_class(%{kind: :dlq}), do: "topo-edge topo-edge-dlq"
  defp edge_class(%{kind: :satellite}), do: "topo-edge topo-edge-satellite"

  attr :node, :map, required: true
  attr :selected, :any, required: true

  defp graph_node(%{node: %{kind: :dead_letter}} = assigns) do
    ~H"""
    <.link navigate={@node.href} data-testid={"topo-node-#{@node.id}"}>
      <.node_body node={@node} selected={@selected} />
    </.link>
    """
  end

  defp graph_node(%{node: %{selectable?: false}} = assigns) do
    ~H"""
    <g data-testid={"topo-node-#{@node.id}"}>
      <.node_body node={@node} selected={@selected} />
    </g>
    """
  end

  defp graph_node(assigns) do
    ~H"""
    <g
      data-testid={"topo-node-#{@node.id}"}
      phx-click="graph_select"
      phx-value-id={@node.id}
      class="cursor-pointer"
    >
      <.node_body node={@node} selected={@selected} />
      <circle
        :if={@node.kind == :channel and @node.backpressure?}
        data-testid="topo-backpressure"
        cx={@node.x + node_w() - 14}
        cy={@node.y + 14}
        r="5"
        class="topo-backpressure"
      />
    </g>
    """
  end

  attr :node, :map, required: true
  attr :selected, :any, required: true

  defp node_body(assigns) do
    ~H"""
    <rect
      x={@node.x}
      y={@node.y}
      width={width_for(@node)}
      height={node_h()}
      rx="8"
      class={node_class(@node, @selected)}
    />
    <text x={@node.x + 12} y={@node.y + 21} class="topo-label">{@node.label}</text>
    <text x={@node.x + 12} y={@node.y + 38} class="topo-sub">{@node.sub}</text>
    """
  end

  defp node_w, do: @node_w
  defp node_h, do: @node_h
  defp width_for(%{x: x}) when x > @pad, do: @branch_w
  defp width_for(_node), do: @node_w

  defp node_class(node, selected) do
    [
      "topo-node",
      "topo-node-#{node.kind}",
      node[:state] == :suspended && "is-suspended",
      node[:state] == :unbound && "is-disconnected",
      selected && selected.id == node.id && "is-selected"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  # ---- Detail panel ----

  attr :node, :map, required: true

  defp detail(assigns) do
    ~H"""
    <aside
      data-testid="topology-detail"
      class="lg:w-80 shrink-0 bg-surface-input border border-brd rounded-xl p-4 space-y-3"
    >
      <div class="flex items-start justify-between gap-2">
        <div>
          <p class="flz-label">{@node.kind}</p>
          <p class="text-sm font-mono text-th-primary break-all">{@node.label}</p>
        </div>
        <button
          type="button"
          phx-click="graph_dismiss"
          data-testid="topology-detail-dismiss"
          class="text-th-muted hover:text-th-primary transition-colors"
          aria-label="Close detail"
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>

      <.core_detail :if={@node.kind == :core} node={@node} />
      <.channel_detail :if={@node.kind == :channel} node={@node} />
      <.plugin_detail :if={@node.kind == :plugin} node={@node} />

      <.link
        :if={@node[:href]}
        navigate={@node.href}
        data-testid="topology-detail-link"
        class="inline-flex items-center gap-1 text-xs font-medium text-accent-text hover:text-accent transition-colors"
      >
        {detail_link_label(@node.kind)}
        <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
      </.link>
    </aside>
    """
  end

  defp detail_link_label(:core), do: "Open live stream"
  defp detail_link_label(:channel), do: "Open cluster"
  defp detail_link_label(_kind), do: "Open"

  attr :node, :map, required: true

  defp core_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Factory">{@node.facts.factory_id || "—"}</.fact>
      <.fact label="Runner">{@node.facts.runner_id || "—"}</.fact>
      <.fact label="Kind">{@node.facts.kind || "—"}</.fact>
      <.fact label="Uptime">{Format.duration(@node.facts.uptime_ms)}</.fact>
      <.fact label="State">{@node.state}</.fact>
      <.fact label="In">{rate_text(@node.rate, :in)}</.fact>
      <.fact label="Out">{rate_text(@node.rate, :out)}</.fact>
      <.fact :if={@node.counters} label="Received">
        {Map.get(@node.counters, :io_in_received, 0)}
      </.fact>
      <.fact :if={@node.counters} label="Forwarded">
        {Map.get(@node.counters, :forwarded, 0)}
      </.fact>
      <.fact :if={@node.counters} label="Filtered nil">
        {Map.get(@node.counters, :filtered_nil, 0)}
      </.fact>
    </dl>

    <.sparkline :if={@node.history != []} samples={@node.history} />
    """
  end

  attr :node, :map, required: true

  defp channel_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="State">{@node.state}</.fact>
      <.fact label="Backpressure">{if @node.backpressure?, do: "yes", else: "no"}</.fact>
    </dl>

    <p :if={is_nil(@node.channel)} class="text-xs text-th-muted">
      No channel counters reported for this runner.
    </p>

    <dl :if={@node.channel} data-testid="topology-channel" class="space-y-1 text-xs">
      <.fact label="Channel">{@node.channel.name}</.fact>
      <.fact label="Received">{Map.get(@node.channel, :io_in_received, 0)}</.fact>
      <.fact label="Sends">{Map.get(@node.channel, :send_frame_calls, 0)}</.fact>
      <.fact label="Nil drops">{Map.get(@node.channel, :nil_drops, 0)}</.fact>
      <.fact label="Credit">
        {if Map.get(@node.channel, :credit_active, 0) > 0, do: "active", else: "off"} · {Format.bytes(
          Map.get(@node.channel, :credit_ledger_level, 0)
        )}
      </.fact>
      <.fact label="Overruns">{Map.get(@node.channel, :credit_overrun_total, 0)}</.fact>
      <.fact label="Heartbeats">
        {Map.get(@node.channel, :hb_count, 0)} · {Map.get(@node.channel, :hb_dispatches, 0)} dispatches
      </.fact>
    </dl>
    """
  end

  attr :node, :map, required: true

  defp plugin_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Plugin">{@node.plugin_id}</.fact>
      <.fact label="Provider">{@node.provider}</.fact>
      <.fact label="Extension">{@node.extension}</.fact>
      <.fact label="Position">{@node.position || "—"}</.fact>
    </dl>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex justify-between gap-3">
      <dt class="text-th-muted">{@label}</dt>
      <dd class="text-th-secondary font-mono text-right break-all">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp rate_text(nil, _key), do: "—"
  defp rate_text(rate, key), do: "#{Map.fetch!(rate, key)}/s"

  @sparkline_w 256
  @sparkline_h 40

  attr :samples, :list, required: true

  defp sparkline(assigns) do
    peak = Enum.max([0 | Enum.flat_map(assigns.samples, &[&1.in, &1.out])])

    assigns =
      assign(assigns,
        peak: peak,
        height: @sparkline_h,
        in_points: sparkline_points(assigns.samples, :in, peak),
        out_points: sparkline_points(assigns.samples, :out, peak)
      )

    ~H"""
    <div data-testid="topology-sparkline">
      <svg viewBox={"0 0 #{sparkline_w()} #{@height}"} width="100%" height={@height} role="img">
        <polyline points={@in_points} class="topo-spark-in" />
        <polyline points={@out_points} class="topo-spark-out" />
      </svg>
      <p class="text-[10px] text-th-muted text-right">peak {@peak}/s</p>
    </div>
    """
  end

  defp sparkline_w, do: @sparkline_w

  defp sparkline_points(samples, key, peak) do
    count = length(samples)
    step = if count > 1, do: @sparkline_w / (count - 1), else: 0
    scale = if peak > 0, do: (@sparkline_h - 2) / peak, else: 0

    samples
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {sample, index} ->
      "#{Float.round(index * step, 1)},#{Float.round(@sparkline_h - 1 - Map.fetch!(sample, key) * scale, 1)}"
    end)
  end

  # ---- Summary rendering ----

  @doc """
  A namespace's data plane at a glance. The `:controls` slot is where the
  dashboard puts its namespace selector; the namespace page leaves it empty.
  """
  attr :topology, :any, required: true
  slot :controls

  def fleet_summary(assigns) do
    ~H"""
    <.graph_frame
      topology={@topology}
      kind={:summary}
      testid="topology-summary"
      icon="hero-signal"
      title="Data plane"
    >
      <:header :if={@controls != []}>{render_slot(@controls)}</:header>

      <div :if={@topology.state == :empty} data-testid="topology-empty" class="py-8 text-center">
        <p class="text-sm text-th-muted">Nothing running in {@topology.namespace} yet.</p>
      </div>

      <div :if={@topology.state == :ok} class="space-y-4">
        <dl class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <.stat boxed testid="summary-operatives" label="Operatives">
            {@topology.operative_count}
          </.stat>
          <.stat boxed testid="summary-runners" label="Runners">{@topology.runner_count}</.stat>
          <.stat
            boxed
            testid="summary-backpressure"
            label="Backpressured"
            tone={alert_tone(@topology.backpressured != [])}
          >
            {length(@topology.backpressured)}
          </.stat>
          <.stat boxed testid="summary-parked" label="Parked" tone={alert_tone(@topology.parked > 0)}>
            {@topology.parked}
          </.stat>
        </dl>

        <div :if={@topology.health != []} data-testid="summary-health">
          <h3 class="flz-label mb-2">Health</h3>
          <div class="flex flex-wrap gap-2">
            <.link
              :for={bucket <- @topology.health}
              navigate={bucket.href}
              data-testid={"summary-health-#{bucket.health}"}
              class="hover:opacity-80 transition-opacity"
            >
              <.health_badge health={bucket.health} count={bucket.count} />
            </.link>
          </div>
        </div>

        <div :if={@topology.attention != []} data-testid="summary-attention">
          <h3 class="flz-label mb-2">
            Needs attention ({length(@topology.attention)})
          </h3>
          <ul class="divide-y divide-brd-subtle">
            <li
              :for={row <- @topology.attention}
              data-testid={"summary-attention-#{row.id}"}
              class="py-2 flex items-center gap-3 text-xs"
            >
              <.link
                navigate={row.href}
                class="font-mono text-accent-text hover:text-accent transition-colors truncate"
              >
                {row.id}
              </.link>
              <.health_badge health={row.health} />
              <span :if={row.unplaced?} class="text-warning">unplaced</span>
              <span :if={row.faulted_group} class="text-danger-text">
                group {row.faulted_group} coverage faulted
              </span>
            </li>
          </ul>
        </div>

        <div>
          <h3 class="flz-label mb-2">Busiest operatives</h3>
          <p
            :if={@topology.busiest == []}
            data-testid="summary-busiest-empty"
            class="text-xs text-th-muted"
          >
            No throughput measured yet — rates need two ticks.
          </p>
          <ul
            :if={@topology.busiest != []}
            data-testid="summary-busiest"
            class="divide-y divide-brd-subtle"
          >
            <li :for={row <- @topology.busiest} class="py-2 flex items-center gap-3 text-xs">
              <.link
                navigate={row.href}
                data-testid={"summary-operative-#{row.id}"}
                class="font-mono text-accent-text hover:text-accent transition-colors truncate"
              >
                {row.id}
              </.link>
              <span class="ml-auto font-mono text-th-secondary shrink-0">
                {row.in}/s in · {row.out}/s out
              </span>
            </li>
          </ul>
        </div>
      </div>
    </.graph_frame>
    """
  end

  # The notices both graphs carry: clock skew, a stall verdict, and — when
  # there is no verdict because nobody was allowed to look — why. One component
  # rather than one per graph, because a stall the pipeline explains and the
  # summary does not would be worse than either.
  attr :topology, :map, required: true

  defp graph_notices(assigns) do
    ~H"""
    <div :if={@topology.skew} data-testid="topology-skew">
      <.runtime_error error={@topology.skew} />
    </div>

    <.notice :if={@topology.stall} kind={:error} testid="topology-stall">
      Data-plane stall localized at
      <.mono>{Format.humanize(@topology.stall.layer)}</.mono>
      <span :if={@topology.stall.entity}>
        on
        <.mono>{@topology.stall.entity}</.mono>
      </span>
    </.notice>

    <%!-- Silence about stalls has to be explained when it is not the
          controller's silence but a refusal. --%>
    <.notice
      :if={match?({:refused, _}, Map.get(@topology, :stall_notice))}
      kind={:error}
      testid="topology-stall-refused"
    >
      Stall detection is unavailable: {forbidden_reason(elem(Map.get(@topology, :stall_notice), 1))}
    </.notice>

    <.notice
      :if={Map.get(@topology, :stall_notice) == :disabled}
      kind={:info}
      testid="topology-stall-disabled"
    >
      Stall detection is switched off on this controller — observability is disabled, so no
      verdicts are produced.
    </.notice>
    """
  end

  # A summary figure the operator should look at reads in the warning colour;
  # every other one keeps the stat's own ink.
  defp alert_tone(true), do: "text-warning"
  defp alert_tone(false), do: nil
end
