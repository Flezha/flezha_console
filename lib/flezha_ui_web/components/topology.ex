defmodule FlezhaUiWeb.Topology do
  @moduledoc """
  The data plane, seen two ways: one relay's pipeline, and a namespace's
  health at a glance.

  flezha has no user-declared relay→relay wiring — a builder names a
  factory, not upstream peers — so the graph worth drawing is *one relay's
  own path*: transport ingest → its `on_input` plugins in position order → the
  relay core → its `on_output` plugins → the bound runner's stream channel
  → output, with lifecycle hooks above the core and the filtered and
  dead-letter ends below it. Structure comes from the controller's own hook
  table, so the picture shows what is actually attached, in the order it
  runs; listeners bound by core's `Flezha.Service.Listener` are counted on the
  point they watch rather than drawn as steps.

  A namespace gets a summary rather than a canvas of every relay: flezha
  runs thousands, and the summary costs the same five controller calls whatever
  that number is.

  Three parts, in the order a host uses them:

    * the host seam — `use FlezhaUiWeb.Topology`, then `init/1` in mount and
      `load_pipeline/1` or `load_summary/2` inside the host's own `refresh/1`.
      Everything kept between ticks (the previous snapshot, rate history, the
      selection, when each port last saw a record and each wire's state) lives
      in the `:topology_state` assign.
    * the view model — `pipeline/1`, `summary/1`, `rates/3`, `push_history/2`,
      `speed_bucket/1`. Pure, so the delta arithmetic and the joins are
      testable without a controller.
    * the rendering — `pipeline_graph/1` and `namespace_map/1`, server-rendered
      SVG and HEEx. The pipeline's records move through the `FlzPipeline`
      hook, from the counts `load_pipeline/1` pushes each tick and what the
      host's tap pushes.

  Rates are `Δcount / Δt` between this UI's own ticks, not controller-side
  timing, smoothed on the pipeline over its newest samples, and only where the
  controller actually counts: the IN and OUT ports and the wire out of the
  channel. The
  controller keeps no per-hook counter, so the chain between plugins
  carries no figure — a tap is how you measure a point the counters miss.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.NodeManager

  # Three left-to-right lanes: lifecycle chips over the core, the record path,
  # and the filtered and dead-letter ends under the core. The wires out of
  # Ingest and out of the core are wider than the rest, since each carries a
  # port.
  @pad 20
  @cap_w 88
  @node_w 168
  @node_h 52
  @gap 40
  @port_gap 140
  @chip_w 152
  @chip_h 36
  @chip_gap 12
  @end_w 152
  @end_h 44
  @lane_gap 64
  @life_y @pad
  @record_y @life_y + @chip_h + @lane_gap
  @fail_y @record_y + @node_h + @lane_gap

  # The pipeline shows the mean of the newest samples, so a relay moving one
  # record every few ticks does not flicker between a figure and zero.
  @smoothing 7
  # A wire streams from 5 records a second until it falls to 3, and trickles
  # while a record passed within the last 30 seconds.
  @stream_on 5
  @stream_off 3
  @trickle_ms 30_000

  @observer_provider inspect(Flezha.Plugin.Provider.MonitoredIOForward)

  # The relay counters the controller keeps, by the rate each one feeds.
  @counted [in: :io_in_received, out: :forwarded, filtered: :filtered_nil]
  @quiet %{in: :quiet, out: :quiet}

  @history_limit 60
  @stall_window_us 60_000_000
  @stall_query %{source: :flezha_health, limit: 20}

  # Named exactly, not by prefix: a host owns `graph_*` events of its own — the
  # relay page's payload tap is one — and a prefix match would swallow them
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
      import FlezhaUiWeb.Topology, only: [pipeline_graph: 1, payload_tap: 1, namespace_map: 1]

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
      topology_state: %{
        prev: nil,
        prev_at: nil,
        history: %{},
        rates: %{},
        selected: nil,
        prev_parked: nil,
        seen: %{in: nil, out: nil},
        modes: @quiet,
        opened_at: System.monotonic_time(:millisecond)
      }
    )
  end

  @doc """
  Reloads one relay's pipeline.

  Reads the overwatch facts the host already assigned, so a tick costs one
  liveness snapshot and the reads that are namespace-wide anyway — never a
  second overwatch call for the relay the host just fetched.

  Once a baseline exists, each tick also pushes `"pipeline_counts"` to the
  browser: how far the relay's counters advanced, which the graph replays as
  moving dots over the next tick.
  """
  def load_pipeline(socket) do
    %{ns: namespace, relay_id: relay_id, overwatch: facts} = socket.assigns
    state = socket.assigns.topology_state
    token = socket.assigns[:flezha_token]

    if NodeManager.connected_node() do
      {snapshot, skew} = snapshot(token)
      {_rates, ticked} = advance(state, snapshot, [relay_id])
      {verdicts, stall_notice} = stall(token)
      parked = parked_for(facts, token)
      {ticked, counts} = tick(state, ticked, relay_id, snapshot, parked)

      # A failed read measures nothing, so nothing is shown as moving.
      {history, modes} =
        if snapshot,
          do: {ticked.history |> Map.get(relay_id, []) |> Enum.reverse(), ticked.modes},
          else: {[], @quiet}

      socket
      |> assign_topology(
        ticked,
        pipeline(%{
          namespace: namespace,
          relay_id: relay_id,
          facts: facts,
          snapshot: snapshot,
          history: history,
          parked: parked,
          verdicts: verdicts,
          stall_notice: stall_notice,
          skew: skew,
          selected: ticked.selected,
          seen: ticked.seen,
          modes: modes,
          opened_at: ticked.opened_at,
          now: System.monotonic_time(:millisecond)
        })
      )
      |> push_counts(counts)
    else
      disconnected(socket, state)
    end
  end

  defp push_counts(socket, nil), do: socket

  defp push_counts(socket, counts),
    do: Phoenix.LiveView.push_event(socket, "pipeline_counts", counts)

  # What the pipeline keeps beyond the shared arithmetic: the parked sample
  # beside this tick's rates, when each counted point last moved, and each
  # wire's state. Answers the counts to replay, or nil without a baseline.
  defp tick(before, ticked, relay_id, snapshot, parked) do
    previous = relay_counters(before.prev, relay_id)
    current = relay_counters(snapshot, relay_id)
    parked_by = (before.prev_parked && advance_of(parked, before.prev_parked)) || 0
    ticked = %{ticked | prev_parked: parked}

    if previous && current && before.prev_at do
      now = ticked.prev_at
      interval = now - before.prev_at
      counts = advances(previous, current) |> Map.put(:parked, parked_by)
      seconds = max(interval, 1) / 1_000
      history = sample_parked(ticked.history, relay_id, Float.round(parked_by / seconds, 1))
      seen = Map.new(ticked.seen, fn {key, at} -> {key, (counts[key] > 0 && now) || at} end)
      newest = history |> Map.get(relay_id, []) |> Enum.reverse()

      modes =
        Map.new(ticked.modes, fn {key, mode} ->
          {key, wire_mode(mode, smoothed(newest, key), seen[key] && now - seen[key])}
        end)

      {%{ticked | history: history, seen: seen, modes: modes},
       Map.merge(counts, %{interval_ms: interval, modes: Map.put(modes, :chan, modes.out)})}
    else
      {ticked, nil}
    end
  end

  # `push_history/2` stores the shared rates; the parked rate is the
  # pipeline's own, added to the sample this tick just pushed.
  defp sample_parked(history, relay_id, rate) do
    case history do
      %{^relay_id => [newest | older]} ->
        %{history | relay_id => [Map.put(newest, :parked, rate) | older]}

      _none ->
        history
    end
  end

  @doc """
  Reloads a namespace's fleet summary.

  Deliberately issues no per-relay call: the liveness snapshot already
  carries every relay's counters, so the cost is flat in the size of the
  fleet. `prefetched` lets a host that has already read `relay_rows/2` and
  the partition groups this tick avoid a second identical read.
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
        {snapshot, skew} = snapshot(token)

        # Health comes from the same registry dump the listings read, so the
        # summary can break its counts down rather than reporting liveness
        # alone — still one call for the namespace, whatever its size.
        # A host that already read the namespace's rows and groups hands them
        # over rather than paying for the same registry dump — and the same
        # per-group coverage check — twice on one tick.
        rows =
          (prefetched && prefetched.rows) ||
            namespace |> NodeManager.relay_rows(token) |> NodeManager.ok_or([])

        groups = (prefetched && prefetched.groups) || NodeManager.partition_groups(rows, token)

        ids = Enum.map(rows, &to_string(&1.id))
        {rates, state} = advance(state, snapshot, ids)
        {verdicts, stall_notice} = stall(token)

        assign_topology(
          socket,
          state,
          summary(%{
            namespace: namespace,
            rows: rows,
            relay_ids: ids,
            faulted_groups: NodeManager.faulted_group_ids(groups),
            runners: runner_ids(namespace, token),
            snapshot: snapshot,
            rates: rates,
            dlq: parked_in(ids, token),
            verdicts: verdicts,
            stall_notice: stall_notice,
            skew: skew
          })
        )
    end
  end

  @doc """
  Measures the rates of `ids` from one liveness snapshot, for a host that
  shows rates without a graph: the rates and their history land in
  `:topology_state`, read the same way the map reads them.
  """
  def load_rates(socket, ids) do
    state = socket.assigns.topology_state

    if NodeManager.connected_node() do
      {snapshot, _skew} = snapshot(socket.assigns[:flezha_token])
      {_rates, state} = advance(state, snapshot, ids)
      assign(socket, topology_state: state)
    else
      assign(socket, topology_state: %{state | prev: nil, prev_at: nil, rates: %{}})
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
  # fictional rates on reconnect, and what was measured before it would read as
  # current, so the graph starts from nothing instead.
  defp disconnected(socket, state) do
    assign_topology(
      socket,
      %{
        state
        | prev: nil,
          prev_at: nil,
          rates: %{},
          history: %{},
          prev_parked: nil,
          seen: %{in: nil, out: nil},
          modes: @quiet
      },
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
         rates: rates,
         prev: snapshot || state.prev,
         prev_at: (snapshot && now) || state.prev_at
     }}
  end

  # `:api_missing` is the defined answer from a controller predating the
  # counters: the graph still draws structure, so it is carried through as a
  # notice rather than swallowed. Any other failure simply leaves no rates —
  # the host's own error banner already says the controller is unhappy.
  defp snapshot(token) do
    case NodeManager.liveness_snapshot(token) do
      {:ok, %{} = snapshot} -> {snapshot, nil}
      {:error, {:api_missing, _module, _function, _arity} = reason} -> {nil, reason}
      _other -> {nil, nil}
    end
  end

  defp runner_ids(namespace, token) do
    namespace
    |> NodeManager.runners(token)
    |> NodeManager.ok_or([])
    |> Enum.map(&NodeManager.identifier_id/1)
  end

  # The dead-letter statistics are kept per relay class across the cluster; a
  # namespace's share is its own relays' classes.
  defp parked_in(relay_ids, token) do
    classes = MapSet.new(relay_ids, &to_string/1)

    token
    |> NodeManager.dlq_stats()
    |> NodeManager.ok_or([])
    |> Enum.filter(&(to_string(Map.get(&1, :relay_class)) in classes))
  end

  defp parked_for(facts, token), do: [facts.relay_class] |> parked_in(token) |> entries()

  defp entries(stats), do: Enum.reduce(stats, 0, &(&2 + Map.get(&1, :entries, 0)))

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
      {:ok, signals} when is_list(signals) -> {recent(signals, token), nil}
      {:error, reason} -> {[], stall_notice(reason)}
      _other -> {[], nil}
    end
  end

  defp stall_notice(reason) do
    case NodeManager.error(reason) do
      %{class: :denied} -> {:refused, reason}
      %{code: "observability.disabled"} -> :disabled
      _other -> nil
    end
  end

  defp recent(signals, token) do
    with [_ | _] = stalls <- Enum.filter(signals, &(Map.get(&1, :name) == :stall_localized)),
         now when is_integer(now) <- NodeManager.controller_monotonic_us(token) do
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

    %{layer: Map.get(metadata, :layer), subject: verdict_subject(metadata)}
  end

  # The classifier names whichever relay, runner or channel its verdict is
  # about; the deepest identifier present wins, and a driver-level verdict
  # names no node.
  defp verdict_subject(%{relay_id: id}) when not is_nil(id), do: to_string(id)
  defp verdict_subject(%{runner_id: id}) when not is_nil(id), do: to_string(id)
  defp verdict_subject(%{channel: name}) when not is_nil(name), do: to_string(name)
  defp verdict_subject(_metadata), do: nil

  # ---- Pipeline view model ----

  @doc """
  One relay's pipeline, as lanes of nodes, the wires between them, and the IN
  and OUT ports.

  Pure: the overwatch facts (including the hook table), the liveness
  snapshot, the rate history (oldest first), the parked count and any recent
  stall verdicts all arrive in `input`, as do, when the host keeps them, when
  each port last saw a record (`seen`), each wire's state (`modes`), when the
  page opened (`opened_at`) and the clock to age them by (`now`).
  """
  def pipeline(input) do
    facts = input.facts
    history = Map.get(input, :history, [])
    channel = channel_for(input.snapshot, facts.runner_id)

    %{inbound: inbound, outbound: outbound, chips: chips, observers: observers} =
      stages(facts.bindings)

    stalled = stalled_subject(input, facts, channel)
    counters = relay_counters(input.snapshot, input.relay_id)
    rates = %{in: smoothed(history, :in), out: smoothed(history, :out)}

    nodes =
      layout(
        [%{id: "ingest", kind: :ingest, lane: :record, label: "Ingest", sub: "transport"}] ++
          Enum.map(inbound, &plugin_node(&1, :record)) ++
          [
            core_node(
              input,
              facts,
              if(history != [], do: rates),
              counters,
              observers.calls,
              stalled
            )
          ] ++
          Enum.map(outbound, &plugin_node(&1, :record)) ++
          [channel_node(facts, channel, stalled), output_node()] ++
          Enum.map(chips, &plugin_node(&1, :life)) ++
          [filtered_node(counters), dead_letter_node(input.parked)]
      )

    record = Enum.filter(nodes, &(&1.lane == :record))
    core = Enum.find(record, &(&1.kind == :core))
    modes = Map.get(input, :modes, @quiet)
    recency = recency(input, rates, modes)
    backpressure? = Enum.any?(record, &(&1[:backpressure?] == true))
    chain = chain_edges(record, core, rates, modes, recency, backpressure?)
    branches = for node <- nodes, node.lane != :record, do: branch(node, core)

    ports = ports(record, rates, recency, observers)
    nav = nav_order(nodes, ports)
    nodes = Enum.map(nodes, &Map.put(&1, :nav, nav[{:node, &1.id}]))
    word = state_word(history, modes, backpressure?)
    width = canvas_width(nodes)

    %{
      kind: :pipeline,
      state: :ok,
      namespace: input.namespace,
      relay_id: input.relay_id,
      nodes: nodes,
      edges: chain ++ branches,
      ports: Enum.map(ports, &Map.put(&1, :nav, nav[{:port, &1.id}])),
      routes: route_paths(record, core, branches),
      width: width,
      min_width: round(width * 0.75),
      height: @fail_y + @end_h + @pad,
      selected: Enum.find(nodes, &(&1.id == input.selected && &1.selectable?)),
      stall: List.first(input.verdicts),
      stall_notice: Map.get(input, :stall_notice),
      skew: input.skew,
      plugin_count: (inbound ++ outbound ++ chips) |> Enum.map(& &1.plugin_id) |> count_ids(),
      observer_count: observers |> Map.values() |> List.flatten() |> count_ids(),
      flow: %{word: word, sentence: sentence(word, history, rates, modes, input)},
      timeline: timeline(history)
    }
  end

  defp count_ids(ids), do: ids |> Enum.uniq() |> length()

  # Listeners leave the path first: every binding of the provider core's
  # `Flezha.Service.Listener` binds is an observer, counted once per plugin on
  # the point it watches. Then `on_input` runs before the relay sees a record
  # and `on_output` after it forwards one, and every other hook fires off the
  # record path, so a plugin bound only there is one lifecycle chip.
  defp stages(bindings) do
    {listeners, plugins} = Enum.split_with(bindings, &(&1.provider == @observer_provider))
    sorted = Enum.sort_by(plugins, &{&1.position || 0, &1.plugin_id})

    %{
      inbound: Enum.filter(sorted, &(&1.hook == "on_input")),
      outbound: Enum.filter(sorted, &(&1.hook == "on_output")),
      chips:
        sorted
        |> Enum.reject(&(&1.hook in ~w(on_input on_output)))
        |> Enum.group_by(& &1.plugin_id)
        |> Enum.sort_by(fn {plugin_id, _entries} -> plugin_id end)
        |> Enum.map(fn {plugin_id, entries} ->
          %{
            plugin_id: plugin_id,
            hook: Enum.map_join(entries, ", ", & &1.hook),
            sub: Enum.map_join(entries, " · ", & &1.hook),
            provider: hd(entries).provider,
            position: nil
          }
        end),
      observers: %{
        in: observing(listeners, ~w(on_input)),
        out: observing(listeners, ~w(on_output on_preview)),
        calls: observing(listeners, ~w(on_call))
      }
    }
  end

  defp observing(listeners, hooks) do
    for(entry <- listeners, entry.hook in hooks, do: entry.plugin_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # A step on the record lane is one binding, so its id names its hook; a
  # lifecycle chip is one plugin, listing every hook it is bound to.
  defp plugin_node(entry, lane) do
    %{
      id:
        if(lane == :record,
          do: "plugin-#{entry.plugin_id}-#{entry.hook}",
          else: "plugin-#{entry.plugin_id}"
        ),
      kind: :plugin,
      lane: lane,
      label: entry.plugin_id,
      sub:
        entry[:sub] ||
          "#{entry.hook}#{position_suffix(entry.position)} · #{short_provider(entry.provider)}",
      selectable?: true,
      plugin_id: entry.plugin_id,
      hook: entry.hook,
      provider: entry.provider,
      position: entry.position
    }
  end

  defp position_suffix(nil), do: ""
  defp position_suffix(position), do: " ##{position}"

  # A provider module's last segment: the full name is far wider than a node,
  # and stays in the node's tooltip and the selected plugin's panel.
  defp short_provider(provider), do: provider |> to_string() |> String.split(".") |> List.last()

  defp core_node(input, facts, rates, counters, callers, stalled) do
    %{
      id: input.relay_id,
      kind: :core,
      lane: :record,
      label: input.relay_id,
      sub: to_string(facts.factory_id || "—"),
      selectable?: true,
      state: (facts.suspended && :suspended) || :running,
      stalled?: stalled == :core,
      facts: facts,
      counters: counters,
      rate: rates,
      observers: callers,
      href: ~p"/namespaces/#{input.namespace}/relays/#{input.relay_id}/listen"
    }
  end

  defp channel_node(facts, channel, stalled) do
    %{
      id: "channel",
      kind: :channel,
      lane: :record,
      label: facts.runner_id || "unbound",
      sub: (channel && "stream channel") || "no channel counters",
      selectable?: true,
      state: channel_state(facts.runner_id),
      stalled?: stalled == :channel,
      channel: channel,
      backpressure?: channel != nil and credit_exhausted?(channel),
      href: ~p"/cluster"
    }
  end

  defp channel_state(nil), do: :unbound
  defp channel_state(_runner_id), do: :bound

  defp output_node,
    do: %{id: "output", kind: :output, lane: :record, label: "Output", sub: "runner stream"}

  # Both ends of the failures lane are drawn from the start, so the first
  # record to reach either does not move anything.
  defp filtered_node(counters) do
    filtered = (counters && Map.get(counters, :filtered_nil, 0)) || 0

    %{
      id: "filtered",
      kind: :filtered,
      lane: :fail,
      label: "Filtered",
      sub: "#{filtered} dropped as nil",
      muted?: filtered == 0
    }
  end

  defp dead_letter_node(parked) do
    %{
      id: "dead-letter",
      kind: :dead_letter,
      lane: :fail,
      label: "Dead letter",
      sub: "#{parked} parked",
      muted?: parked == 0,
      href: ~p"/dlq"
    }
  end

  # The newest verdict marks the node it names: the relay is its core, and its
  # runner or that runner's channel is its channel.
  defp stalled_subject(input, facts, channel) do
    case List.first(input.verdicts) do
      %{subject: nil} -> nil
      %{subject: subject} when subject == input.relay_id -> :core
      %{subject: subject} -> channel_subject(subject, facts.runner_id, channel)
      nil -> nil
    end
  end

  defp channel_subject(subject, runner_id, channel) do
    if subject == runner_id or (channel != nil and subject == to_string(channel.name)),
      do: :channel
  end

  @doc """
  Places the pipeline's nodes in their lanes, from the nodes alone: the record
  lane left to right with compact ends and wide port wires, lifecycle chips
  centred over the core, and the filtered and dead-letter ends under it.

  Pure, and fed only the relay's own plugins, so a listener coming or going
  moves nothing.
  """
  def layout(nodes) do
    {record, rest} = Enum.split_with(nodes, &(&1.lane == :record))

    {record, _x} =
      Enum.map_reduce(record, @pad, fn node, x ->
        w = if node.kind in [:ingest, :output], do: @cap_w, else: @node_w
        gap = if node.kind in [:ingest, :core], do: @port_gap, else: @gap
        {place(node, x, @record_y, w, @node_h), x + w + gap}
      end)

    core = Enum.find(record, &(&1.kind == :core))
    centre = core.x + div(core.w, 2)
    chips = Enum.filter(rest, &(&1.lane == :life))
    span = length(chips) * (@chip_w + @chip_gap) - @chip_gap
    # Clear of the lane's label when many chips push the row left.
    from = max(centre - div(span, 2), @pad + 104)

    life =
      chips
      |> Enum.with_index()
      |> Enum.map(fn {chip, i} ->
        place(chip, from + i * (@chip_w + @chip_gap), @life_y, @chip_w, @chip_h)
      end)

    fail =
      rest
      |> Enum.filter(&(&1.lane == :fail))
      |> Enum.map(fn node ->
        x = if node.kind == :filtered, do: centre - @end_w - 8, else: centre + 8
        place(node, x, @fail_y, @end_w, @end_h)
      end)

    record ++ life ++ fail
  end

  defp place(node, x, y, w, h) do
    node
    |> Map.put_new(:selectable?, false)
    |> Map.merge(%{x: x, y: y, w: w, h: h, routes: routes(node)})
  end

  # The routes a record can take through an element: on to the output, into
  # the filtered end, into the dead-letter queue, or the lifecycle hooks'.
  # Everything before the core is on every record's way.
  defp routes(%{lane: :life}), do: "life"
  defp routes(%{kind: :core}), do: "out filter dlq life"
  defp routes(%{kind: :filtered}), do: "filter"
  defp routes(%{kind: :dead_letter}), do: "dlq"
  defp routes(%{kind: kind}) when kind in [:channel, :output], do: "out"
  defp routes(%{kind: :plugin, hook: "on_output"}), do: "out"
  defp routes(_before_core), do: "out filter dlq"

  defp canvas_width(nodes) do
    Enum.max(Enum.map(nodes, &(&1.x + &1.w))) + @pad
  end

  defp middle(node), do: node.y + div(node.h, 2)

  # The record lane's wires join neighbours; the core reaches each chip and
  # each end of the failures lane on a branch. Only the wire out of Ingest,
  # the wire out of the core and the wire out of the channel are counted; the
  # rest say so.
  defp chain_edges(record, core, rates, modes, recency, backpressure?) do
    {start, finish} = {hd(record).x + hd(record).w, List.last(record).x}

    record
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [from, to] ->
      segment = segment(from, to, core)
      key = counter(segment)
      rate = rates[key]
      counted? = from.kind in [:ingest, :core, :channel]
      {x0, x1} = if key == :in, do: {start, core.x}, else: {core.x + core.w, finish}

      %{
        id: "flow-#{from.id}-#{to.id}",
        kind: :flow,
        d: "M#{from.x + from.w},#{middle(from)} L#{to.x},#{middle(to)}",
        x1: from.x + from.w,
        x2: to.x,
        y: middle(from),
        counted?: counted?,
        rate: if(counted?, do: rate),
        label: if(segment == :chan, do: rate_label(rate)),
        bucket: speed_bucket(rate),
        mode: modes[key],
        band: modes[key] == :streaming && band_width(rate),
        stopped?: backpressure? and key == :out,
        degraded?: to.kind == :channel and to.state == :unbound,
        flow: Atom.to_string(key),
        at: Float.round((from.x + from.w - x0) / max(x1 - x0, 1), 2),
        routes: if(from.kind == :core, do: to.routes, else: from.routes),
        title: wire_title(segment, counted?, rate, recency[key])
      }
    end)
  end

  # The wire out of the channel moves with the relay's forwarded count.
  defp counter(:chan), do: :out
  defp counter(segment), do: segment

  defp segment(from, to, core) do
    cond do
      from.kind == :channel -> :chan
      from.x < core.x or to.kind == :core -> :in
      true -> :out
    end
  end

  defp branch(node, core) do
    centre = core.x + div(core.w, 2)

    {kind, d, title} =
      case node.lane do
        :life ->
          {from_x, to_y} = {node.x + div(node.w, 2), node.y + node.h}
          mid = div(to_y + core.y, 2)

          {:satellite,
           "M#{from_x},#{to_y} C#{from_x},#{mid} #{centre},#{mid} #{centre},#{core.y}",
           "#{node.label} runs on #{node.sub}, off the record path"}

        :fail ->
          {x0, y0} =
            {if(node.kind == :filtered, do: centre - 24, else: centre + 24), core.y + core.h}

          {x1, y1} = {node.x + div(node.w, 2), node.y}
          mid = div(y0 + y1, 2)
          kind = if node.kind == :filtered, do: :filter, else: :dlq

          {kind, "M#{x0},#{y0} C#{x0},#{mid} #{x1},#{mid} #{x1},#{y1}", branch_title(kind)}
      end

    %{
      id: "branch-#{node.id}",
      kind: kind,
      d: d,
      rate: nil,
      bucket: :idle,
      mode: :quiet,
      band: false,
      degraded?: false,
      flow: Atom.to_string(kind),
      at: 0.0,
      routes: node.routes,
      title: title
    }
  end

  defp branch_title(:filter), do: "Records the relay dropped by returning nil"
  defp branch_title(:dlq), do: "Records that failed, parked in the dead-letter queue"

  defp wire_title(_segment, false, _rate, _recency),
    do: "Not counted: the controller keeps no counter between plugins"

  defp wire_title(segment, true, rate, recency) do
    what = %{in: "Into the relay", out: "Forwarded by the relay", chan: "Out to the runner"}

    "#{what[segment]}: #{rate_label(rate) || "measuring"}, #{recency}"
  end

  # The streaming band's width grows with the logarithm of the rate, so a
  # thousand records a second does not drown the graph.
  defp band_width(rate), do: Float.round(3 + 4 * :math.log10(1 + rate), 1)

  # The ports sit on the wire out of Ingest, where the input listener sees
  # records, and on the wire out of the core, where the output listener does.
  defp ports(record, rates, recency, observers) do
    for {key, after_kind, direction, routes} <- [
          {:in, :ingest, "input", "out filter dlq"},
          {:out, :core, "output", "out"}
        ] do
      index = Enum.find_index(record, &(&1.kind == after_kind))
      [from, to] = Enum.slice(record, index, 2)
      rate = rates[key]

      %{
        id: Atom.to_string(key),
        direction: direction,
        x: div(from.x + from.w + to.x, 2),
        y: middle(from),
        rate: rate,
        label: rate_label(rate),
        state: recency[key],
        observers: observers[key],
        routes: routes
      }
    end
  end

  # How each counted point states its recency: nothing before a baseline,
  # "continuous" while a stream is still arriving, and otherwise when a record
  # last passed, to the tick's resolution.
  defp recency(input, rates, modes) do
    seen = Map.get(input, :seen, %{in: nil, out: nil})
    now = Map.get(input, :now, 0)
    opened_at = Map.get(input, :opened_at, now)

    Map.new([:in, :out], &{&1, recency(rates[&1], modes[&1], seen[&1], now, opened_at)})
  end

  defp recency(nil, _mode, _seen, _now, _opened_at), do: "measuring"
  defp recency(_rate, :quiet, nil, now, opened_at), do: "quiet for #{ago(now - opened_at)}"
  defp recency(_rate, :quiet, seen, now, _opened_at), do: "quiet for #{ago(now - seen)}"
  defp recency(_rate, _mode, nil, _now, _opened_at), do: "none since opened"

  defp recency(_rate, :streaming, seen, now, _opened_at) when now - seen <= 3_000,
    do: "continuous"

  defp recency(_rate, _mode, seen, now, _opened_at), do: "last record #{ago(now - seen)} ago"

  defp ago(ms) when ms < 60_000, do: "~#{div(max(ms, 0), 1_000)} s"
  defp ago(ms), do: Format.duration(ms)

  # Focus walks each lane in path order and steps between lanes; the hook
  # reads the order from `data-lane` and `data-nav`.
  defp nav_order(nodes, ports) do
    (for(
       node <- nodes,
       node.selectable? or node.kind == :dead_letter,
       do: {{:node, node.id}, node.lane, node.x}
     ) ++
       for(port <- ports, do: {{:port, port.id}, :record, port.x}))
    |> Enum.group_by(&elem(&1, 1))
    |> Enum.flat_map(fn {_lane, members} ->
      members
      |> Enum.sort_by(&elem(&1, 2))
      |> Enum.with_index(fn {key, _lane, _x}, i -> {key, i} end)
    end)
    |> Map.new()
  end

  # The hidden paths dots ride: into the core, from it to the output, and from
  # it along each branch into the failures lane.
  defp route_paths(record, core, branches) do
    [ingest, output] = [hd(record), List.last(record)]
    y = middle(core)
    branch = &Enum.find_value(branches, fn edge -> edge.kind == &1 && edge.d end)

    %{
      in: "M#{ingest.x + ingest.w},#{y} L#{core.x},#{y}",
      out: "M#{core.x + core.w},#{y} L#{output.x},#{y}",
      filter: branch.(:filter),
      dlq: branch.(:dlq)
    }
  end

  @doc """
  The rate the pipeline shows for `key`: the mean of the newest
  #{@smoothing} samples of a history held oldest first, or nil before the
  first sample.
  """
  def smoothed([], _key), do: nil

  def smoothed(history, key) do
    samples = Enum.take(history, -@smoothing)
    Enum.sum(Enum.map(samples, &Map.get(&1, key, 0))) / length(samples)
  end

  @doc "A displayed rate as the pipeline labels it; a trickle under 0.05 reads `<0.1/s`."
  def rate_label(nil), do: nil
  def rate_label(rate) when rate > 0 and rate < 0.05, do: "<0.1/s"
  def rate_label(rate), do: "#{Float.round(rate / 1, 1)}/s"

  @doc """
  A counted wire's state: `:streaming` from #{@stream_on} records a second
  until its rate falls to #{@stream_off}, `:trickling` below that while a
  record passed within #{div(@trickle_ms, 1_000)} seconds (`ago_ms`), and
  `:quiet` otherwise.
  """
  def wire_mode(previous, rate, ago_ms) do
    rate = rate || 0

    cond do
      rate >= @stream_on -> :streaming
      previous == :streaming and rate > @stream_off -> :streaming
      ago_ms != nil and ago_ms <= @trickle_ms -> :trickling
      true -> :quiet
    end
  end

  # Stuck outranks Failing, which outranks how the input is moving.
  defp state_word(_history, _modes, true), do: :stuck

  defp state_word(history, modes, false) do
    if failing?(history) do
      :failing
    else
      %{streaming: :streaming, trickling: :trickle, quiet: :quiet}[modes.in]
    end
  end

  # More than a tenth of what the last two ticks took was parked.
  defp failing?(history) do
    {parked, taken} = parked_of_taken(history)
    parked > 0 and parked > taken / 10
  end

  defp parked_of_taken(history) do
    recent = Enum.take(history, -2)

    {recent |> Enum.map(&Map.get(&1, :parked, 0)) |> Enum.sum(),
     recent |> Enum.map(&Map.get(&1, :in, 0)) |> Enum.sum()}
  end

  # The one place the graph's state is put into words.
  defp sentence(:stuck, _history, _rates, _modes, _input),
    do: "The runner's channel has no credit left, so the relay cannot hand records on."

  defp sentence(:failing, history, _rates, _modes, _input) do
    {parked, taken} = parked_of_taken(history)
    share = if taken > 0, do: "#{round(min(parked / taken, 1) * 100)}% of", else: "records beyond"

    "#{share} what came in over the last two ticks was parked in the dead-letter queue."
  end

  defp sentence(:quiet, history, _rates, _modes, input) do
    seen = input |> Map.get(:seen, %{}) |> Map.get(:in)

    cond do
      history == [] -> "Measuring: rates appear after the second reading."
      is_nil(seen) -> "No record has come in since this page opened."
      true -> "No record has come in for #{ago(Map.get(input, :now, seen) - seen)}."
    end
  end

  defp sentence(_moving, history, rates, _modes, _input) do
    filtered = smoothed(history, :filtered) || 0
    taken = rates.in || 0

    "#{rate_label(taken)} in, #{rate_label(rates.out || 0)} delivered" <>
      if(filtered > 0 and taken > 0,
        do: ", #{round(min(filtered / taken, 1) * 100)}% filtered.",
        else: "."
      )
  end

  @timeline_rows [in: "In", out: "Delivered", filtered: "Filtered", parked: "Parked"]
  @timeline_w 600
  @timeline_row_h 18

  # One bar per tick on each row, newest at the right, on a shared log scale
  # so a trickle still shows beside a stream.
  defp timeline(history) do
    peak =
      history
      |> Enum.flat_map(&Enum.map(@timeline_rows, fn {key, _} -> Map.get(&1, key, 0) end))
      |> Enum.max(fn -> 0 end)

    step = @timeline_w / @history_limit
    offset = @history_limit - length(history)

    %{
      samples: length(history),
      width: @timeline_w,
      row_h: @timeline_row_h,
      rows:
        Enum.map(@timeline_rows, fn {key, label} ->
          %{
            key: key,
            label: label,
            bars:
              for {sample, i} <- Enum.with_index(history),
                  value = Map.get(sample, key, 0),
                  value > 0 do
                %{
                  x: Float.round((offset + i) * step, 1),
                  w: Float.round(step - 1, 1),
                  h:
                    Float.round(
                      max(:math.log10(1 + value) / :math.log10(1 + peak), 0.1) * @timeline_row_h,
                      1
                    )
                }
              end
          }
        end)
    }
  end

  # ---- Summary view model ----

  @doc """
  A namespace's data plane at a glance, from reads that do not grow with the
  size of the fleet.
  """
  def summary(input) do
    live = MapSet.new(input.relay_ids)
    channels = channels_by_runner(input.snapshot)

    busiest =
      input.rates
      |> Enum.filter(fn {id, _rate} -> MapSet.member?(live, id) end)
      |> Enum.map(fn {id, rate} ->
        %{
          id: id,
          in: rate.in,
          out: rate.out,
          href: ~p"/namespaces/#{input.namespace}/relays/#{id}"
        }
      end)
      |> Enum.sort_by(&(-(&1.in + &1.out)))
      |> Enum.take(5)

    rows = Map.get(input, :rows, [])
    faulted = Map.get(input, :faulted_groups, [])
    attention = FlezhaUiWeb.Attention.relay_items(input.namespace, rows, faulted)

    summary_view(%{
      state: ((input.relay_ids == [] and input.runners == []) && :empty) || :ok,
      namespace: input.namespace,
      relay_count: length(input.relay_ids),
      health:
        Enum.map(NodeManager.health_counts(rows), fn {health, count} ->
          %{
            health: health,
            count: count,
            href: ~p"/relays?#{[namespace: input.namespace, health: health]}"
          }
        end),
      attention: attention,
      stall_notice: Map.get(input, :stall_notice),
      runner_count: length(input.runners),
      backpressured:
        Enum.filter(input.runners, fn runner ->
          channels |> Map.get(runner, []) |> Enum.any?(&credit_exhausted?/1)
        end),
      parked: entries(input.dlq),
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
        relay_count: 0,
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
  Per-relay message rates from two snapshots and the milliseconds between
  them: in, out, and the records the relay filtered by returning nil.

  Answers `%{relay_id => %{in: rate, out: rate, filtered: rate}}`, and nothing at all
  without a baseline — a first tick has no elapsed time to divide by. A
  negative delta means the controller restarted and its counters reset; that
  clamps to zero for the one tick rather than rendering a nonsense figure.
  """
  def rates(snapshot, previous, elapsed_ms)
      when is_map(snapshot) and is_map(previous) and elapsed_ms > 0 do
    before = index_relays(previous)
    seconds = elapsed_ms / 1_000

    snapshot
    |> Map.get(:relays, [])
    |> Enum.reduce(%{}, fn entry, acc ->
      id = NodeManager.identifier_id(Map.get(entry, :relay_id))

      case Map.fetch(before, id) do
        {:ok, base} ->
          Map.put(
            acc,
            id,
            Map.new(advances(base, entry), fn {key, delta} ->
              {key, Float.round(delta / seconds, 1)}
            end)
          )

        :error ->
          acc
      end
    end)
  end

  def rates(_snapshot, _previous, _elapsed_ms), do: %{}

  # How far each counted slot moved since `base`. A counter that went
  # backwards was reset by a controller restart, and moved nothing.
  defp advances(base, entry) do
    Map.new(@counted, fn {key, slot} ->
      {key, advance_of(Map.get(entry, slot, 0), Map.get(base, slot, 0))}
    end)
  end

  defp advance_of(now, before), do: max(now - before, 0)

  @doc """
  Appends this tick's rates to each relay's history, newest first.

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

  defp index_relays(snapshot) do
    snapshot
    |> Map.get(:relays, [])
    |> Map.new(&{NodeManager.identifier_id(Map.get(&1, :relay_id)), &1})
  end

  defp relay_counters(nil, _relay_id), do: nil

  defp relay_counters(snapshot, relay_id) do
    Map.get(index_relays(snapshot), relay_id)
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
  One relay's pipeline: the lanes, the ports, a sentence and a timeline of
  what the relay is doing, and a dock below them holding the selected node's
  inspector and the host's payload tap.

  `tapped` is the direction of the host's open tap, which marks its port; the
  `:tap` slot is where the host puts the tap itself. Nothing opened in the dock
  moves the canvas.
  """
  attr :topology, :any, required: true
  attr :tapped, :string, default: nil, doc: "the direction of the open tap, if any"
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
        <span :if={@topology && @topology.kind == :pipeline} class="text-xs topo-muted">
          {Words.count(@topology.plugin_count, "plugin")} attached<span
            :if={@topology.observer_count > 0}
            data-testid="topology-observer-count"
          > · {@topology.observer_count} listening</span>
        </span>
        <.legend :if={@topology && @topology.kind == :pipeline} />
      </:header>

      <div
        id="topology-canvas"
        phx-hook="FlzPipeline"
        phx-mounted={
          JS.ignore_attributes(
            ~w(data-trace data-trace-out data-trace-filter data-trace-dlq data-trace-life)
          )
        }
        phx-window-keydown={@topology.selected && "graph_dismiss"}
        phx-key="Escape"
        data-testid="topology-canvas"
        data-tapped={@tapped}
        class="topo-canvas overflow-x-auto"
      >
        <svg
          viewBox={"0 0 #{@topology.width} #{@topology.height}"}
          width={@topology.width}
          height={@topology.height}
          style={"min-width: #{@topology.min_width}px"}
          class="w-full h-auto"
          role="group"
          aria-label={"Pipeline of #{@topology.relay_id}"}
        >
          <g class="topo-lane-label" aria-hidden="true">
            <text :for={{name, y} <- lane_labels()} x="20" y={y}>{name}</text>
          </g>
          <g>
            <path
              :for={edge <- @topology.edges}
              :if={edge[:band]}
              d={edge.d}
              stroke-width={edge.band}
              class={["topo-band", edge[:stopped?] && "is-stopped"]}
              data-testid={"topo-band-#{edge.id}"}
              data-routes={edge.routes}
            />
          </g>
          <g><.wire :for={edge <- @topology.edges} edge={edge} /></g>
          <g>
            <.graph_node :for={node <- @topology.nodes} node={node} selected={@topology.selected} />
          </g>
          <g>
            <.port :for={port <- @topology.ports} port={port} tapped={@tapped == port.direction} />
          </g>
          <g class="topo-routes" aria-hidden="true">
            <path :for={{route, d} <- @topology.routes} id={"route-#{route}"} d={d} />
          </g>
          <g id="topology-dots" phx-update="ignore" data-testid="topo-dots"></g>
        </svg>
      </div>

      <.flow_state flow={@topology.flow} timeline={@topology.timeline} />

      <div data-testid="topology-dock" class="grid gap-4 md:grid-cols-2">
        <.detail :if={@topology.selected} node={@topology.selected} />
        {render_slot(@tap)}
        <p :if={!@topology.selected and is_nil(@tapped)} class="text-xs topo-muted md:col-span-2">
          Select a node to inspect it, or a port to tap the records passing it.
        </p>
      </div>
    </.graph_frame>
    """
  end

  defp lane_labels,
    do: [
      {"Lifecycle", @life_y + 4},
      {"Records", @record_y - 12},
      {"Failures and drops", @fail_y + 4}
    ]

  @doc """
  The relay page's payload tap, in the graph's dock: what a listen on the
  relay's input or output has heard since its port opened it.
  """
  attr :tap, :any, required: true

  def payload_tap(assigns) do
    ~H"""
    <.dock_panel
      :if={@tap}
      testid="topology-tap"
      on_close="graph_tap_close"
      close_testid="tap-close"
      close_label="Close tap"
    >
      <:head>
        <p class="flz-label">Tapping <span class="font-mono">{@tap.direction}</span></p>
      </:head>

      <div :if={@tap.error} data-testid="tap-error">
        <.runtime_error error={@tap.error} action="the payload tap" />
      </div>

      <dl data-testid="tap-figures" class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
        <dt class="topo-muted">Messages</dt>
        <dd class="topo-secondary font-mono text-right">{@tap.count}</dd>
        <dt class="topo-muted">Total</dt>
        <dd class="topo-secondary font-mono text-right">{Format.bytes(@tap.bytes)}</dd>
        <dt class="topo-muted">Rate</dt>
        <dd data-testid="tap-msg-rate" class="topo-primary font-mono text-right">
          {FlezhaUiWeb.RelayLive.tap_rate(@tap, :count)}/s
        </dd>
        <dt class="topo-muted">Throughput</dt>
        <dd data-testid="tap-byte-rate" class="topo-primary font-mono text-right">
          {Format.bytes(round(FlezhaUiWeb.RelayLive.tap_rate(@tap, :bytes)))}/s
        </dd>
        <dt class="topo-muted">Dead letters</dt>
        <dd data-testid="tap-dead-letters" class="topo-secondary font-mono text-right">
          {@tap.dead_letters}
        </dd>
      </dl>

      <ul :if={@tap.recent != []} data-testid="tap-recent" class="space-y-1">
        <li :for={msg <- @tap.recent} class="flz-chip block truncate">
          {String.slice(msg.message, 0, 60)}
        </li>
      </ul>

      <p :if={@tap.ended?} data-testid="tap-ended" class="text-xs topo-muted">
        The tap ended: the relay stopped or the controller let it go.
      </p>

      <p
        :if={@tap.recent == [] and is_nil(@tap.error) and not @tap.ended?}
        class="text-xs topo-muted"
      >
        Listening while open, and stops when closed. Waiting for a record to pass.
      </p>
    </.dock_panel>
    """
  end

  # A panel of the graph's dock, beneath the canvas: a head, a control that
  # closes it, and its body.
  attr :testid, :string, required: true
  attr :on_close, :string, required: true
  attr :close_testid, :string, required: true
  attr :close_label, :string, required: true
  slot :head, required: true
  slot :inner_block, required: true

  defp dock_panel(assigns) do
    ~H"""
    <aside data-testid={@testid} class="flz-panel p-4 space-y-3">
      <div class="flex items-start justify-between gap-2">
        <div>{render_slot(@head)}</div>
        <button
          type="button"
          phx-click={@on_close}
          data-testid={@close_testid}
          class="flz-button flz-button--sm flz-button--ghost"
          aria-label={@close_label}
        >
          <.icon name="hero-x-mark" class="w-4 h-4" />
        </button>
      </div>
      {render_slot(@inner_block)}
    </aside>
    """
  end

  # The pipeline's frame, in the stylebook's panel recipe: an honest word when
  # the controller is unreachable, and the notices the graph may not go
  # without.
  attr :topology, :any, required: true
  attr :kind, :atom, required: true, doc: "the topology kind whose body this frame holds"
  attr :testid, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :header, doc: "controls at the right of the panel header"
  slot :inner_block, required: true

  defp graph_frame(assigns) do
    ~H"""
    <div data-testid={@testid} class="flz-panel overflow-hidden">
      <div class="flz-panel-head">
        <h2 class="flz-panel-title"><.icon name={@icon} class="w-4 h-4" />{@title}</h2>
        <div :if={@header != []} class="flex items-center gap-3">{render_slot(@header)}</div>
      </div>

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
    </div>
    """
  end

  defp legend(assigns) do
    ~H"""
    <.popover
      id="topology-legend-menu"
      testid="topology-legend-toggle"
      label="Legend"
      align="end"
      role="dialog"
      trigger_class="fui-btn fui-btn--sm fui-btn--ghost"
    >
      <:trigger>Legend</:trigger>
      <ul data-testid="topology-legend" class="flz-graph-legend topo-legend">
        <li><span class="flz-graph-legend-plugin" aria-hidden="true"></span>A plugin</li>
        <li><span class="flz-graph-legend-tasklet" aria-hidden="true"></span>The relay's own code</li>
        <.legend_node role="runner">The runner's channel</.legend_node>
        <.legend_node role="state">Where records enter, leave, or end</.legend_node>
        <.legend_node role="runner flz-graph-node--recovering">Suspended</.legend_node>
        <.legend_node role="runner flz-graph-node--dead">Unbound — no runner</.legend_node>
        <.legend_item swatch="topo-flow-medium">Records flowing; speed tracks the rate</.legend_item>
        <.legend_item swatch="topo-flow-fast">Busy — over 100 records a second</.legend_item>
        <.legend_item swatch="topo-flow-idle">Idle, or one record at a time</.legend_item>
        <li>
          <svg width="26" height="10" class="shrink-0" aria-hidden="true">
            <line x1="0" y1="5" x2="26" y2="5" class="topo-band" stroke-width="7" />
          </svg>
          A stream — five or more records a second
        </li>
        <.legend_item swatch="flz-graph-wire--state">Runs off the record path</.legend_item>
        <.legend_item swatch="flz-graph-wire--state topo-edge-dlq">
          Where failures park, in the dead-letter queue
        </.legend_item>
        <.legend_item swatch="flz-graph-wire--fail">Nothing bound at the far end</.legend_item>
        <li>
          <svg width="26" height="14" class="shrink-0" aria-hidden="true">
            <g class="topo-port"><circle cx="13" cy="7" r="5.5" class="topo-port-ring" /></g>
          </svg>
          A port — select it to tap the records passing
        </li>
        <li>
          <span class="topo-legend-badge" aria-hidden="true">2</span> Listeners watching that point
        </li>
        <li>
          <svg width="26" height="10" class="shrink-0" aria-hidden="true">
            <circle cx="7" cy="5" r="3.5" class="flz-graph-dot topo-dot topo-dot--counted" />
            <circle cx="19" cy="5" r="3.5" class="flz-graph-dot topo-dot" />
          </svg>
          A record — hollow from the counters, a tick behind; filled from a tap
        </li>
        <li><span class="flz-graph-legend-fail" aria-hidden="true"></span>A dead letter</li>
      </ul>
    </.popover>
    """
  end

  attr :swatch, :string, required: true
  slot :inner_block, required: true

  defp legend_item(assigns) do
    ~H"""
    <li>
      <svg width="26" height="8" class="shrink-0" aria-hidden="true">
        <line x1="0" y1="4" x2="26" y2="4" class={["flz-graph-wire", @swatch]} />
      </svg>
      {render_slot(@inner_block)}
    </li>
    """
  end

  attr :role, :string,
    required: true,
    doc: "the node role and state classes after `flz-graph-node--`"

  slot :inner_block, required: true

  defp legend_node(assigns) do
    ~H"""
    <li>
      <svg width="26" height="14" class="shrink-0" aria-hidden="true">
        <g class={"flz-graph-node flz-graph-node--#{@role}"}>
          <rect x="1" y="1" width="24" height="12" rx="3" />
        </g>
      </svg>
      {render_slot(@inner_block)}
    </li>
    """
  end

  attr :edge, :map, required: true

  defp wire(assigns) do
    ~H"""
    <path
      data-testid={"topo-edge-#{@edge.id}"}
      d={@edge.d}
      class={wire_class(@edge)}
      data-flow={@edge.flow}
      data-at={@edge.at}
      data-mode={@edge.mode}
      data-routes={@edge.routes}
    >
      <title>{@edge.title}</title>
    </path>
    <text
      :if={@edge[:label]}
      data-testid={"topo-rate-#{@edge.id}"}
      x={div(@edge.x1 + @edge.x2, 2)}
      y={@edge.y - 8}
      text-anchor="middle"
      class={["topo-rate", @edge.rate == 0 && "is-muted"]}
    >
      {@edge.label}
    </text>
    """
  end

  defp wire_class(%{degraded?: true}), do: "flz-graph-wire flz-graph-wire--fail topo-wire"
  defp wire_class(%{kind: :flow} = edge), do: "flz-graph-wire topo-wire topo-flow-#{edge.bucket}"

  defp wire_class(%{kind: :dlq}),
    do: "flz-graph-wire flz-graph-wire--state topo-wire topo-edge-dlq"

  defp wire_class(_off_path), do: "flz-graph-wire flz-graph-wire--state topo-wire"

  attr :port, :map, required: true
  attr :tapped, :boolean, required: true

  defp port(assigns) do
    assigns =
      assign(assigns,
        event: (assigns.tapped && "graph_tap_close") || "graph_tap",
        name: port_name(assigns.port, assigns.tapped),
        state: (assigns.tapped && "tapping") || assigns.port.state
      )

    ~H"""
    <g
      data-testid={"topo-port-#{@port.id}"}
      class={["topo-port", @tapped && "is-tapped"]}
      role="button"
      tabindex="0"
      aria-pressed={to_string(@tapped)}
      aria-label={@name}
      phx-click={@event}
      phx-keydown={@event}
      phx-key="Enter"
      phx-value-direction={@port.direction}
      data-lane="record"
      data-nav={@port.nav}
      data-routes={@port.routes}
    >
      <title>{@name}</title>
      <rect class="topo-port-hit" x={@port.x - 46} y={@port.y - 30} width="92" height="78" rx="6" />
      <circle class="topo-port-ring" cx={@port.x} cy={@port.y} r="9" />
      <circle class="topo-port-core" cx={@port.x} cy={@port.y} r="3.5" />
      <text x={@port.x} y={@port.y - 16} text-anchor="middle" class="topo-port-state">
        {String.upcase(@port.id)}<tspan
          :if={@port.label}
          data-testid={"topo-rate-#{@port.id}"}
          class={["topo-rate", @port.rate == 0 && "is-muted"]}
        > {@port.label}</tspan>
      </text>
      <text
        data-testid={"topo-port-state-#{@port.id}"}
        x={@port.x}
        y={@port.y + 26}
        text-anchor="middle"
        class="topo-port-state"
      >
        {@state}
      </text>
      <text
        :if={@port.observers != []}
        data-testid={"topo-observers-#{@port.id}"}
        x={@port.x}
        y={@port.y + 40}
        text-anchor="middle"
        class="topo-observers"
      >
        {length(@port.observers)} listening
      </text>
      <text class="topo-observer-ids" x={@port.x} y={@port.y + 54} text-anchor="middle">
        <tspan
          :for={{id, i} <- Enum.with_index(@port.observers)}
          x={@port.x}
          dy={if i > 0, do: 12, else: 0}
        >
          {id}
        </tspan>
      </text>
    </g>
    """
  end

  defp port_name(port, tapped) do
    [
      "#{String.upcase(port.id)} port, #{port.label || "no rate yet"}, #{port.state}",
      tapped && "your tap is open here",
      port.observers != [] && "listening: #{Enum.join(port.observers, ", ")}",
      if(tapped, do: "select to close the tap", else: "select to tap the #{port.direction}")
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  attr :node, :map, required: true
  attr :selected, :any, required: true

  defp graph_node(%{node: %{kind: :dead_letter}} = assigns) do
    ~H"""
    <.link
      navigate={@node.href}
      data-testid={"topo-node-#{@node.id}"}
      aria-label={"Dead letter: #{@node.sub}"}
      data-lane={@node.lane}
      data-nav={@node.nav}
      data-routes={@node.routes}
    >
      <.node_body node={@node} selected={@selected} />
    </.link>
    """
  end

  defp graph_node(%{node: %{selectable?: false}} = assigns) do
    ~H"""
    <g data-testid={"topo-node-#{@node.id}"} data-routes={@node.routes}>
      <.node_body node={@node} selected={@selected} />
    </g>
    """
  end

  defp graph_node(assigns) do
    ~H"""
    <g
      data-testid={"topo-node-#{@node.id}"}
      role="button"
      tabindex="0"
      aria-label={"#{@node.label}, #{@node.sub}"}
      aria-pressed={to_string(@selected != nil and @selected.id == @node.id)}
      phx-click="graph_select"
      phx-keydown="graph_select"
      phx-key="Enter"
      phx-value-id={@node.id}
      data-lane={@node.lane}
      data-nav={@node.nav}
      data-routes={@node.routes}
      class="cursor-pointer"
    >
      <.node_body node={@node} selected={@selected} />
      <rect
        :if={@node[:stalled?]}
        data-testid="topo-stall-marker"
        x={@node.x - 5}
        y={@node.y - 5}
        width={@node.w + 10}
        height={@node.h + 10}
        rx="11"
        class="topo-stall"
      />
      <circle
        :if={@node.kind == :channel and @node.backpressure?}
        data-testid="topo-backpressure"
        cx={@node.x + @node.w - 14}
        cy={@node.y + 14}
        r="5"
        class="topo-backpressure"
      />
      <text
        :if={@node[:observers] not in [nil, []]}
        data-testid="topo-observers-calls"
        x={@node.x + @node.w}
        y={@node.y - 6}
        text-anchor="end"
        class="topo-observers"
      >
        <title>Listening to calls: {Enum.join(@node.observers, ", ")}</title>
        {length(@node.observers)} on calls
      </text>
    </g>
    """
  end

  attr :node, :map, required: true
  attr :selected, :any, required: true

  defp node_body(assigns) do
    ~H"""
    <g class={node_class(@node, @selected)}>
      <title>{@node.label} — {@node.sub}</title>
      <rect x={@node.x} y={@node.y} width={@node.w} height={@node.h} rx="8" />
      <%!-- SVG text never wraps, so the box clips it rather than letting a long
           identifier run out past its own edge. --%>
      <svg x={@node.x} y={@node.y} width={@node.w - 8} height={@node.h} overflow="hidden">
        <text x="12" y={div(@node.h, 2) - 4} class="topo-label">{@node.label}</text>
        <text x="12" y={div(@node.h, 2) + 12} class="topo-sub">{@node.sub}</text>
      </svg>
    </g>
    """
  end

  defp node_class(node, selected) do
    [
      "flz-graph-node",
      "flz-graph-node--#{graph_role(node.kind)}",
      "topo-node-#{node.kind}",
      node[:state] == :suspended && "flz-graph-node--recovering",
      node[:state] == :unbound && "flz-graph-node--dead",
      node[:muted?] && "is-muted",
      selected && selected.id == node.id && "is-selected"
    ]
    |> Enum.filter(&is_binary/1)
    |> Enum.join(" ")
  end

  # The shared relay-graph roles: the relay's own code is a tasklet, the
  # runner's channel a runner, and the ends of the record path are state.
  defp graph_role(:plugin), do: "plugin"
  defp graph_role(:core), do: "tasklet"
  defp graph_role(:channel), do: "runner"
  defp graph_role(_kind), do: "state"

  attr :flow, :map, required: true
  attr :timeline, :map, required: true

  # The state word, the sentence that explains it, and the timeline beneath.
  defp flow_state(assigns) do
    ~H"""
    <div data-testid="topology-state" class="space-y-2">
      <p class="text-sm topo-secondary">
        <span data-testid="topology-state-word" class={"topo-state-word is-#{@flow.word}"}>
          {flow_word(@flow.word)}
        </span>
        {@flow.sentence}
      </p>

      <div data-testid="topology-timeline" data-samples={@timeline.samples} class="topo-timeline">
        <div :for={row <- @timeline.rows} class="topo-timeline-row">
          <span class="topo-timeline-label">{row.label}</span>
          <svg
            data-testid={"timeline-row-#{row.key}"}
            viewBox={"0 0 #{@timeline.width} #{@timeline.row_h}"}
            preserveAspectRatio="none"
            height={@timeline.row_h}
            class={"topo-timeline-bars is-#{row.key}"}
            role="img"
            aria-label={"#{row.label}, #{length(row.bars)} of the last #{@timeline.samples} ticks"}
          >
            <rect
              :for={bar <- row.bars}
              x={bar.x}
              y={@timeline.row_h - bar.h}
              width={bar.w}
              height={bar.h}
            />
          </svg>
        </div>
        <p class="topo-timeline-axis text-xs topo-muted">
          <span>2 min ago</span><span>now</span>
        </p>
      </div>
    </div>
    """
  end

  defp flow_word(:stuck), do: "Stuck"
  defp flow_word(:failing), do: "Failing"
  defp flow_word(:streaming), do: "Streaming"
  defp flow_word(:trickle), do: "Trickle"
  defp flow_word(:quiet), do: "Quiet"

  # ---- Detail panel ----

  attr :node, :map, required: true

  defp detail(assigns) do
    ~H"""
    <.dock_panel
      testid="topology-detail"
      on_close="graph_dismiss"
      close_testid="topology-detail-dismiss"
      close_label="Close detail"
    >
      <:head>
        <p class="flz-label">{@node.kind}</p>
        <p class="text-sm font-mono topo-primary break-all">{@node.label}</p>
      </:head>

      <.core_detail :if={@node.kind == :core} node={@node} />
      <.channel_detail :if={@node.kind == :channel} node={@node} />
      <.plugin_detail :if={@node.kind == :plugin} node={@node} />

      <.link
        :if={@node[:href]}
        navigate={@node.href}
        data-testid="topology-detail-link"
        class="flz-button flz-button--sm flz-button--ghost"
      >
        {detail_link_label(@node.kind)}
        <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
      </.link>
    </.dock_panel>
    """
  end

  defp detail_link_label(:core), do: "Listen"
  defp detail_link_label(:channel), do: "Open cluster"
  defp detail_link_label(_kind), do: "Open"

  attr :node, :map, required: true

  defp core_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Factory">{@node.facts.factory_id || "—"}</.fact>
      <.fact label="Runner">{@node.facts.runner_id || "—"}</.fact>
      <.fact label="Run">{@node.facts.run || "—"}</.fact>
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
      <.fact :if={@node.observers != []} label="Listening to calls">
        {Enum.join(@node.observers, ", ")}
      </.fact>
    </dl>
    """
  end

  attr :node, :map, required: true

  defp channel_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="State">{@node.state}</.fact>
      <.fact label="Backpressure">{if @node.backpressure?, do: "yes", else: "no"}</.fact>
    </dl>

    <p :if={is_nil(@node.channel)} class="text-xs topo-muted">
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
      <.fact label="Hook">{@node.hook}</.fact>
      <.fact label="Position">{@node.position || "—"}</.fact>
    </dl>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true

  defp fact(assigns) do
    ~H"""
    <div class="flex justify-between gap-3">
      <dt class="topo-muted">{@label}</dt>
      <dd class="topo-secondary font-mono text-right break-all">{render_slot(@inner_block)}</dd>
    </div>
    """
  end

  defp rate_text(nil, _key), do: "—"
  defp rate_text(rate, key), do: rate |> Map.fetch!(key) |> rate_label()

  # ---- Namespace map ----

  @map_w 900
  @map_src_w 176
  @map_band_x 236
  @map_band_w 428
  @map_out_x 724
  @map_out_w 176
  @map_top 34
  @map_node_h 40
  @map_node_gap 12
  @map_band_head 40
  @map_lane_h 40
  @map_lane_gap 8
  @map_band_gap 18
  @map_lane_cap 12
  @map_stack_min 4
  @map_spark_w 72
  @map_spark_h 18

  @doc """
  A namespace's data plane as a map, drawn by the console rather than by the
  relay graph: sources, one band per runner holding the lanes of the relays
  bound to it, a zone for relays with no runner, outputs, and a dead-letter
  drain.

  Pure: built from the summary's reads plus one `relay_plugins/2`, so it
  costs no call per relay. `input` holds `:namespace`, `:rows`
  (`relay_rows/2`), `:runners` (`[%{id:, pid:}]`), `:plugins` (the
  `relay_plugins/2` pairs), `:runs` (`%{id => run}`), `:rates` and `:history`
  (the topology state's), `:parked`, and optionally `:faulted_groups`,
  `:expanded` (the stack keys opened) and `:selected` (`{kind, id}`).

  Within a band, lanes needing attention come first, then by measured
  throughput, then by id; more than three relays of one factory collapse into
  a stack lane, and a band draws at most twelve lanes and then "+N more".
  Wires animate at their lane's speed bucket, and not at all before two
  snapshots exist.
  """
  def map(input) do
    rows = Map.get(input, :rows, [])
    runners = Map.get(input, :runners, [])
    plugins = Map.get(input, :plugins, [])
    rates = Map.get(input, :rates, %{})
    selected = Map.get(input, :selected)
    faulted = Map.get(input, :faulted_groups, [])
    expanded = Map.get(input, :expanded, MapSet.new())

    bindings = Map.new(rows, &{to_string(&1.id), relay_bindings(plugins, to_string(&1.id))})
    runner_ids = MapSet.new(runners, &to_string(&1.id))

    {bound, unbound} =
      Enum.split_with(rows, &(&1[:runner] && MapSet.member?(runner_ids, to_string(&1.runner))))

    by_runner = Enum.group_by(bound, &to_string(&1.runner))
    lane = &map_lane(&1, input, rates, faulted, bindings)

    sources = map_sources(bindings, selected)
    outputs = map_outputs(bindings, selected)

    {bands, y} =
      runners
      |> Enum.sort_by(&to_string(&1.id))
      |> Enum.map_reduce(@map_top, fn runner, y ->
        id = to_string(runner.id)

        lanes =
          by_runner
          |> Map.get(id, [])
          |> Enum.map(lane)
          |> stack(id, expanded)
          |> order_lanes()

        {shown, more} = Enum.split(lanes, @map_lane_cap)
        band = map_band(input.namespace, runner, shown, more, y, selected)
        {band, y + band.h + @map_band_gap}
      end)

    zone =
      case unbound |> Enum.map(lane) |> order_lanes() do
        [] -> nil
        lanes -> map_zone(lanes, y)
      end

    bands_bottom = if zone, do: zone.y + zone.h, else: y - @map_band_gap
    drain = map_drain(Map.get(input, :parked, 0), length(outputs))
    all_lanes = Enum.flat_map(bands, & &1.lanes) ++ ((zone && zone.lanes) || [])
    lanes = Enum.map(all_lanes, &mark_selected(&1, selected))

    height =
      Enum.max([
        bands_bottom,
        column_bottom(sources),
        column_bottom(outputs ++ List.wrap(drain))
      ]) + @map_node_gap

    %{
      namespace: input.namespace,
      width: @map_w,
      height: max(height, @map_top + @map_node_h + @map_node_gap),
      animated?: rates != %{},
      sources: sources,
      outputs: outputs,
      drain: drain,
      bands:
        Enum.map(bands, fn band ->
          %{band | lanes: Enum.map(band.lanes, &mark_selected(&1, selected))}
        end),
      zone: zone && %{zone | lanes: Enum.map(zone.lanes, &mark_selected(&1, selected))},
      wires: map_wires(lanes, sources, outputs, rates)
    }
  end

  # A relay's declared plugin bindings, as `{plugin_id, [hook]}`.
  defp relay_bindings(pairs, relay_id) do
    for row <- NodeManager.declared_bindings(pairs, relay_id), do: {row.plugin_id, row.hooks}
  end

  defp bound_on(bindings, hook) do
    for {plugin_id, hooks} <- bindings, hook in hooks, do: plugin_id
  end

  defp map_sources(bindings, selected) do
    plugins =
      bindings
      |> Map.values()
      |> Enum.flat_map(&bound_on(&1, "on_input"))
      |> Enum.uniq()
      |> Enum.sort()

    ([%{id: "calls", kind: :calls, label: "Calls and sends", sub: "from clients", inspect: nil}] ++
       Enum.map(
         plugins,
         &%{id: "in-#{&1}", kind: :plugin, label: &1, sub: "on_input", inspect: {:plugin, &1}}
       ))
    |> place_column(0, @map_src_w, selected)
  end

  defp map_outputs(bindings, selected) do
    plugins =
      bindings
      |> Map.values()
      |> Enum.flat_map(&bound_on(&1, "on_output"))
      |> Enum.uniq()
      |> Enum.sort()

    (Enum.map(
       plugins,
       &%{id: "out-#{&1}", kind: :plugin, label: &1, sub: "on_output", inspect: {:plugin, &1}}
     ) ++
       [
         %{
           id: "stream",
           kind: :runner_stream,
           label: "Runner stream",
           sub: "to its clients",
           inspect: nil
         }
       ])
    |> place_column(@map_out_x, @map_out_w, selected)
  end

  defp place_column(nodes, x, w, selected) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      Map.merge(node, %{
        x: x,
        y: @map_top + index * (@map_node_h + @map_node_gap),
        w: w,
        h: @map_node_h,
        selected?: node.inspect != nil and node.inspect == selected
      })
    end)
  end

  defp column_bottom([]), do: @map_top
  defp column_bottom(nodes), do: nodes |> Enum.map(&(&1.y + &1.h)) |> Enum.max()

  defp map_drain(parked, _outputs) when parked in [nil, 0], do: nil

  defp map_drain(parked, outputs) do
    %{
      id: "drain",
      kind: :drain,
      label: "Dead letter",
      sub: "#{parked} parked",
      parked: parked,
      x: @map_out_x,
      y: @map_top + outputs * (@map_node_h + @map_node_gap) + @map_node_gap,
      w: @map_out_w,
      h: @map_node_h,
      href: ~p"/dlq"
    }
  end

  defp map_lane(row, input, rates, faulted, bindings) do
    id = to_string(row.id)
    health = NodeManager.row_health(row)
    said = FlezhaUiWeb.Words.say(:health, health)
    rate = Map.get(rates, id)
    unplaced? = is_nil(row[:node])
    group_faulted? = row[:partition] && row.partition.group in faulted
    runner = row[:runner] && to_string(row.runner)
    run = input |> Map.get(:runs, %{}) |> Map.get(id)

    history =
      input |> Map.get(:history, %{}) |> Map.get(id, []) |> Enum.reverse() |> Enum.map(& &1.in)

    %{
      key: "relay-#{id}",
      kind: :relay,
      id: id,
      factory: row[:factory] && to_string(row.factory),
      label: id,
      state:
        [
          (is_nil(runner) or input_runner_missing?(input, runner)) && "waiting for a runner",
          String.downcase(said.text),
          unplaced? && "unplaced",
          group_faulted? && "coverage faulted"
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" · "),
      sub:
        [run && to_string(run), row[:factory] && to_string(row.factory)]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" · "),
      health: health,
      tone: if(unplaced? or group_faulted?, do: worse_tone(said.tone), else: said.tone),
      shape: said.shape,
      attention?: health != :healthy or unplaced? or group_faulted? == true,
      rate: rate,
      throughput: (rate && rate.in + rate.out) || 0,
      spark: if(length(history) >= 2, do: spark_points(history, @map_spark_w, @map_spark_h)),
      inputs: bound_on(Map.get(bindings, id, []), "on_input"),
      outputs: bound_on(Map.get(bindings, id, []), "on_output"),
      bound?: runner != nil and not input_runner_missing?(input, runner),
      inspect: {:relay, id},
      members: []
    }
  end

  defp input_runner_missing?(input, runner),
    do: not Enum.any?(Map.get(input, :runners, []), &(to_string(&1.id) == runner))

  defp worse_tone(:positive), do: :warning
  defp worse_tone(tone), do: tone

  # More than three relays of one factory share one lane, until opened.
  defp stack(lanes, runner, expanded) do
    lanes
    |> Enum.group_by(& &1.factory)
    |> Enum.flat_map(fn
      {factory, members} when length(members) >= @map_stack_min and not is_nil(factory) ->
        key = "#{runner}/#{factory}"

        if MapSet.member?(expanded, key), do: members, else: [stack_lane(key, factory, members)]

      {_factory, members} ->
        members
    end)
  end

  defp stack_lane(key, factory, members) do
    counts = members |> Enum.map(& &1.health) |> Enum.frequencies()
    worst = members |> Enum.map(& &1.tone) |> FlezhaUiWeb.Words.worst()
    rate_in = members |> Enum.map(&((&1.rate && &1.rate.in) || 0)) |> Enum.sum()
    rate_out = members |> Enum.map(&((&1.rate && &1.rate.out) || 0)) |> Enum.sum()
    any_rate? = Enum.any?(members, & &1.rate)

    %{
      key: "stack-#{key}",
      kind: :stack,
      id: key,
      factory: factory,
      label: "#{factory} ×#{length(members)}",
      state: "stack, open to show its relays",
      sub:
        counts
        |> Enum.sort_by(fn {health, _} -> health end)
        |> Enum.map_join(" · ", fn {health, count} ->
          "#{count} #{String.downcase(FlezhaUiWeb.Words.text(:health, health))}"
        end),
      health: if(worst == :positive, do: :healthy, else: nil),
      tone: worst,
      shape: if(worst == :positive, do: "dot", else: "triangle"),
      attention?: Enum.any?(members, & &1.attention?),
      rate:
        if(any_rate?, do: %{in: Float.round(rate_in / 1, 1), out: Float.round(rate_out / 1, 1)}),
      throughput: rate_in + rate_out,
      spark: nil,
      inputs: members |> Enum.flat_map(& &1.inputs) |> Enum.uniq(),
      outputs: members |> Enum.flat_map(& &1.outputs) |> Enum.uniq(),
      bound?: true,
      inspect: nil,
      members: Enum.map(members, & &1.id)
    }
  end

  defp order_lanes(lanes) do
    Enum.sort_by(lanes, &{if(&1.attention?, do: 0, else: 1), -&1.throughput, &1.id})
  end

  defp map_band(namespace, runner, lanes, more, y, selected) do
    id = to_string(runner.id)
    head = y + @map_band_head

    placed =
      lanes
      |> Enum.with_index()
      |> Enum.map(fn {lane, index} ->
        Map.merge(lane, %{
          x: @map_band_x + 12,
          y: head + index * (@map_lane_h + @map_lane_gap),
          w: @map_band_w - 24,
          h: @map_lane_h
        })
      end)

    rows = length(placed) + if(more == [], do: 0, else: 1)

    %{
      id: id,
      short: short_id(id),
      pid: Map.get(runner, :pid),
      x: @map_band_x,
      y: y,
      w: @map_band_w,
      h: @map_band_head + max(rows, 1) * (@map_lane_h + @map_lane_gap) + 4,
      lanes: placed,
      more:
        if more != [] do
          %{
            count: Enum.reduce(more, 0, &(&2 + max(length(&1.members), 1))),
            href: ~p"/namespaces/#{namespace}/relays?#{[runner: id]}",
            y: head + length(placed) * (@map_lane_h + @map_lane_gap) + 24
          }
        end,
      selected?: selected == {:runner, id}
    }
  end

  defp map_zone(lanes, y) do
    head = y + 30

    placed =
      lanes
      |> Enum.with_index()
      |> Enum.map(fn {lane, index} ->
        Map.merge(lane, %{
          x: @map_band_x + 12,
          y: head + index * (@map_lane_h + @map_lane_gap),
          w: @map_band_w - 24,
          h: @map_lane_h
        })
      end)

    %{
      x: @map_band_x,
      y: y,
      w: @map_band_w,
      h: 30 + length(placed) * (@map_lane_h + @map_lane_gap) + 4,
      lanes: placed
    }
  end

  defp mark_selected(lane, selected),
    do: Map.put(lane, :selected?, lane.inspect != nil and lane.inspect == selected)

  # Each lane is wired from the sources it is bound to — calls and sends when
  # no input plugin feeds it — and to its outputs, the runner stream when no
  # output plugin carries it. A lane with no runner has no stream to reach.
  defp map_wires(lanes, sources, outputs, rates) do
    source = Map.new(sources, &{&1.id, &1})
    output = Map.new(outputs, &{&1.id, &1})

    Enum.flat_map(lanes, fn lane ->
      ins = if lane.inputs == [], do: ["calls"], else: Enum.map(lane.inputs, &"in-#{&1}")

      outs =
        if lane.outputs == [],
          do: if(lane.bound?, do: ["stream"], else: []),
          else: Enum.map(lane.outputs, &"out-#{&1}")

      in_bucket = if rates == %{}, do: :idle, else: speed_bucket(lane.rate && lane.rate.in)
      out_bucket = if rates == %{}, do: :idle, else: speed_bucket(lane.rate && lane.rate.out)

      Enum.map(ins, fn id ->
        node = Map.fetch!(source, id)

        wire(
          "#{id}->#{lane.key}",
          node.x + node.w,
          node.y + div(node.h, 2),
          lane.x,
          lane.y + div(lane.h, 2),
          in_bucket
        )
      end) ++
        Enum.map(outs, fn id ->
          node = Map.fetch!(output, id)

          wire(
            "#{lane.key}->#{id}",
            lane.x + lane.w,
            lane.y + div(lane.h, 2),
            node.x,
            node.y + div(node.h, 2),
            out_bucket
          )
        end)
    end)
  end

  defp wire(id, x1, y1, x2, y2, bucket) do
    mid = div(x1 + x2, 2)
    %{id: id, d: "M#{x1},#{y1} C#{mid},#{y1} #{mid},#{y2} #{x2},#{y2}", bucket: bucket}
  end

  # A runner id reads by its last seven characters past sixteen, as every
  # identifier does.
  defp short_id(id) do
    if String.length(id) > 16, do: "…" <> String.slice(id, -7, 7), else: id
  end

  # ---- Namespace map rendering ----

  @doc """
  The namespace map, server-rendered as SVG on the `fui-map-*` recipes. Every
  lane, runner band heading and plugin node is a control: activating one
  sends `inspect` with its kind and id, and a stack lane sends `map_expand`.
  """
  attr :map, :map, required: true

  def namespace_map(assigns) do
    ~H"""
    <div class="fui-map" data-testid="namespace-map">
      <div class="fui-map-head">
        <p class="fui-eyebrow">Data plane</p>
        <p class="fui-map-legend">
          <span>Lanes needing attention come first</span>
          <span>
            {if @map.animated?,
              do: "Dots move at the measured rate",
              else: "Rates appear after the second reading"}
          </span>
          <span :if={@map.animated?} class="fui-live">Live</span>
        </p>
      </div>
      <div class="fui-map-scroll">
        <svg
          class="fui-map-svg"
          viewBox={"0 0 #{@map.width} #{@map.height}"}
          role="group"
          aria-label={"Data plane of #{@map.namespace}"}
        >
          <text class="fui-map-col" x="0" y="14">Sources</text>
          <text class="fui-map-col" x={band_x()} y="14">Runners and their relays</text>
          <text class="fui-map-col" x={out_x()} y="14">Outputs</text>

          <g>
            <path
              :for={wire <- @map.wires}
              d={wire.d}
              class={["fui-map-wire", wire.bucket != :idle && "topo-flow-#{wire.bucket}"]}
              data-testid={"map-wire-#{wire.id}"}
              data-bucket={wire.bucket}
            />
          </g>

          <.map_node :for={node <- @map.sources ++ @map.outputs} node={node} />

          <.link
            :if={@map.drain}
            navigate={@map.drain.href}
            class="fui-map-drain"
            data-testid="map-drain"
            aria-label={"Dead letter: #{@map.drain.sub}"}
          >
            <rect x={@map.drain.x} y={@map.drain.y} width={@map.drain.w} height={@map.drain.h} rx="8" />
            <text x={@map.drain.x + 12} y={@map.drain.y + 17}>{@map.drain.label}</text>
            <text class="fui-map-sub" x={@map.drain.x + 12} y={@map.drain.y + 32}>
              {@map.drain.sub}
            </text>
          </.link>

          <g :for={band <- @map.bands} class="fui-map-band" data-testid={"map-band-#{band.id}"}>
            <rect
              class="fui-map-band-box"
              x={band.x}
              y={band.y}
              width={band.w}
              height={band.h}
              rx="10"
            />
            <g
              class="fui-map-band-head fui-map-hit"
              role="button"
              tabindex="0"
              aria-pressed={to_string(band.selected?)}
              aria-label={"Runner #{band.id}, pid #{band.pid || "unknown"}"}
              phx-click="inspect"
              phx-value-kind="runner"
              phx-value-id={band.id}
              phx-keydown="inspect"
              phx-key="Enter"
              data-testid={"map-runner-#{band.id}"}
            >
              <rect
                class="fui-map-hitbox"
                x={band.x + 6}
                y={band.y + 5}
                width={band.w - 12}
                height="28"
                rx="6"
              />
              <text class="fui-map-band-title" x={band.x + 14} y={band.y + 24}>{band.short}</text>
              <text class="fui-map-sub" x={band.x + 140} y={band.y + 24}>
                {if band.pid, do: "pid #{band.pid} · ", else: ""}{FlezhaUiWeb.Words.count(
                  length(band.lanes),
                  "lane"
                )}
              </text>
            </g>
            <.map_lane :for={lane <- band.lanes} lane={lane} />
            <.link
              :if={band.more}
              navigate={band.more.href}
              class="fui-map-more"
              data-testid={"map-more-#{band.id}"}
            >
              <text x={band.x + 14} y={band.more.y}>+{band.more.count} more</text>
            </.link>
          </g>

          <g :if={@map.zone} class="fui-map-unbound" data-testid="map-unbound">
            <rect x={@map.zone.x} y={@map.zone.y} width={@map.zone.w} height={@map.zone.h} rx="10" />
            <text class="fui-map-zone-label" x={@map.zone.x + 14} y={@map.zone.y + 20}>
              Waiting for a runner
            </text>
            <.map_lane :for={lane <- @map.zone.lanes} lane={lane} />
          </g>
        </svg>
      </div>
    </div>
    """
  end

  defp band_x, do: @map_band_x
  defp out_x, do: @map_out_x

  attr :node, :map, required: true

  defp map_node(%{node: %{inspect: {kind, id}}} = assigns) do
    assigns = assign(assigns, kind: kind, id: id)

    ~H"""
    <g
      class="fui-map-node fui-map-hit"
      role="button"
      tabindex="0"
      aria-pressed={to_string(@node.selected?)}
      aria-label={"Plugin #{@node.label}, #{@node.sub}"}
      phx-click="inspect"
      phx-value-kind={@kind}
      phx-value-id={@id}
      phx-keydown="inspect"
      phx-key="Enter"
      data-testid={"map-node-#{@node.id}"}
    >
      <.map_node_body node={@node} />
    </g>
    """
  end

  defp map_node(assigns) do
    ~H"""
    <g class="fui-map-node" data-testid={"map-node-#{@node.id}"}>
      <.map_node_body node={@node} />
    </g>
    """
  end

  attr :node, :map, required: true

  defp map_node_body(assigns) do
    ~H"""
    <rect x={@node.x} y={@node.y} width={@node.w} height={@node.h} rx="8" />
    <svg x={@node.x} y={@node.y} width={@node.w - 6} height={@node.h} overflow="hidden">
      <text class={@node.kind == :plugin && "fui-map-mono"} x="12" y="17">{@node.label}</text>
      <text class="fui-map-sub" x="12" y="32">{@node.sub}</text>
    </svg>
    """
  end

  attr :lane, :map, required: true

  defp map_lane(assigns) do
    ~H"""
    <g
      class="fui-map-lane fui-map-hit"
      role="button"
      tabindex="0"
      data-tone={@lane.tone}
      data-kind={@lane.kind}
      aria-pressed={to_string(@lane.selected?)}
      aria-label={lane_name(@lane)}
      phx-click={if @lane.kind == :stack, do: "map_expand", else: "inspect"}
      phx-value-kind="relay"
      phx-value-id={@lane.id}
      phx-keydown={if @lane.kind == :stack, do: "map_expand", else: "inspect"}
      phx-key="Enter"
      data-testid={"map-lane-#{@lane.id}"}
    >
      <rect class="fui-map-lane-box" x={@lane.x} y={@lane.y} width={@lane.w} height={@lane.h} rx="7" />
      <.map_glyph shape={@lane.shape} cx={@lane.x + 14} cy={@lane.y + 13} />
      <title>{lane_name(@lane)}</title>
      <svg x={@lane.x} y={@lane.y} width="226" height={@lane.h} overflow="hidden">
        <text class="fui-map-mono" x="26" y="17">{@lane.label}</text>
        <text class="fui-map-sub" x="26" y="32">
          <tspan class="fui-map-health">{@lane.state}</tspan>{if @lane.sub != "",
            do: " · " <> @lane.sub}
        </text>
      </svg>
      <polyline
        :if={@lane.spark}
        class="fui-map-spark"
        transform={"translate(#{@lane.x + 236}, #{@lane.y + 11})"}
        points={@lane.spark}
        data-testid={"map-spark-#{@lane.id}"}
      />
      <text
        :if={@lane.rate}
        class="fui-map-rate"
        x={@lane.x + @lane.w - 12}
        y={@lane.y + 24}
        text-anchor="end"
        data-testid={"map-rate-#{@lane.id}"}
      >
        {@lane.rate.in}/s
      </text>
    </g>
    """
  end

  defp lane_name(%{kind: :stack} = lane),
    do: "#{lane.label}: #{lane.sub}. Expand to show its relays"

  defp lane_name(lane),
    do:
      "Relay #{lane.id}, #{lane.state}, #{lane.sub}" <>
        if(lane.rate, do: ", #{lane.rate.in} per second in", else: "")

  attr :shape, :string, required: true
  attr :cx, :integer, required: true
  attr :cy, :integer, required: true

  # The same shapes the state badges use, drawn in SVG.
  defp map_glyph(%{shape: "dot"} = assigns),
    do: ~H|<circle class="fui-map-glyph" cx={@cx} cy={@cy} r="4" />|

  defp map_glyph(%{shape: "ring"} = assigns),
    do: ~H|<circle class="fui-map-glyph-ring" cx={@cx} cy={@cy} r="3.5" />|

  defp map_glyph(%{shape: "triangle"} = assigns),
    do: ~H|<path
  class="fui-map-glyph"
  d={"M#{@cx},#{@cy - 5} L#{@cx + 5},#{@cy + 4} L#{@cx - 5},#{@cy + 4} Z"}
/>|

  defp map_glyph(%{shape: "diamond"} = assigns),
    do: ~H|<path
  class="fui-map-glyph"
  d={"M#{@cx},#{@cy - 5} L#{@cx + 5},#{@cy} L#{@cx},#{@cy + 5} L#{@cx - 5},#{@cy} Z"}
/>|

  defp map_glyph(%{shape: "square"} = assigns),
    do: ~H|<rect class="fui-map-glyph" x={@cx - 4} y={@cy - 4} width="8" height="8" rx="1" />|

  defp map_glyph(%{shape: "cross"} = assigns),
    do: ~H|<path
  class="fui-map-glyph-ring"
  d={"M#{@cx - 4},#{@cy - 4} L#{@cx + 4},#{@cy + 4} M#{@cx + 4},#{@cy - 4} L#{@cx - 4},#{@cy + 4}"}
  stroke-width="2.5"
/>|

  defp map_glyph(%{shape: "bars"} = assigns) do
    ~H"""
    <rect class="fui-map-glyph" x={@cx - 4} y={@cy - 4} width="3" height="8" />
    <rect class="fui-map-glyph" x={@cx + 1} y={@cy - 4} width="3" height="8" />
    """
  end

  defp map_glyph(%{shape: "half"} = assigns) do
    ~H"""
    <circle class="fui-map-glyph-ring" cx={@cx} cy={@cy} r="4" />
    <path class="fui-map-glyph" d={"M#{@cx},#{@cy - 4} A4,4 0 0 0 #{@cx},#{@cy + 4} Z"} />
    """
  end

  defp map_glyph(assigns), do: ~H|<circle class="fui-map-glyph" cx={@cx} cy={@cy} r="4" />|

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
      <span class="font-mono">{Format.humanize(@topology.stall.layer)}</span>
      <span :if={@topology.stall.subject}>
        on <span class="font-mono">{@topology.stall.subject}</span>
      </span>
    </.notice>

    <%!-- Silence about stalls has to be explained when it is not the
          controller's silence but a refusal. --%>
    <.notice
      :if={match?({:refused, _}, Map.get(@topology, :stall_notice))}
      kind={:error}
      testid="topology-stall-refused"
    >
      Stall detection is unavailable: {error_message(elem(Map.get(@topology, :stall_notice), 1))}
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
end
