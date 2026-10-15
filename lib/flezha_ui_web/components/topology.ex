defmodule FlezhaUiWeb.Topology do
  @moduledoc """
  The data plane, seen two ways: one relay's pipeline, and a namespace's
  health at a glance.

  flezha has no user-declared relay→relay wiring — a builder names a
  factory, not upstream peers — so the graph worth drawing is *one relay's
  own path*: the sources that feed it and the input filters they pass, the
  relay's own graph of entry channels, tasklets and output channels as its
  runners announce it, and the plugins, called relays and dead-letter end its
  records leave for. Structure comes from the controller's hook table, the
  provider listing and the announced graph; listeners bound by core's
  `Flezha.Service.Listener` are counted at the edge they watch rather than
  drawn.

  A namespace gets a summary rather than a canvas of every relay: flezha
  runs thousands, and the summary costs the same five controller calls whatever
  that number is.

  Three parts, in the order a host uses them:

    * the host seam — `use FlezhaUiWeb.Topology`, then `init/1` in mount and
      `load_pipeline/1` or `load_summary/2` inside the host's own `refresh/1`.
      Everything kept between ticks (the previous readings, rate history, the
      selection, the viewer's direction, the open Cell sheet, the tally and the
      placed layouts) lives in the `:topology_state` assign.
    * the view model — `pipeline/1`, `summary/1`, `rates/3`, `push_history/2`,
      `speed_bucket/1`. Pure, so the delta arithmetic, the layout and the
      joins are testable without a controller. The pipeline is placed on
      abstract ranks and orders, routed as nets with lanes and coloured, and
      only then mapped to x and y for the drawn direction.
    * the rendering — `pipeline_graph/1` and `namespace_map/1`, server-rendered
      SVG and HEEx. The `FlzPipeline` hook owns the view box, zoom, pan and
      full screen, and draws records moving on a canvas laid over the SVG,
      from the counts `load_pipeline/1` pushes each tick.

  Rates are `Δcount / Δt` between readings, smoothed over the newest samples,
  and shown only where something counts: the relay's IN and OUT, each
  tasklet's admitted total, and each output channel's tally while the page
  watches.
  """

  use FlezhaUiWeb, :html

  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  # The pipeline shows the mean of the newest samples, so a relay moving one
  # record every few ticks does not flicker between a figure and zero.
  @smoothing 7
  # A wire streams from 12 records a second until it falls to 9, and trickles
  # while a record passed within the last 30 seconds.
  @stream_on 12
  @stream_off 9
  @trickle_ms 30_000

  @observer_provider inspect(Flezha.Plugin.Provider.MonitoredIOForward)

  # The relay counters the controller keeps, by the rate each one feeds.
  @counted [in: :io_in_received, out: :forwarded, filtered: :filtered_nil]
  # The bytes behind `in` and `out`, read only where the controller reports
  # them, so an older one reads as unmeasured rather than as zero bytes.
  @counted_bytes [bytes_in: :bytes_in, bytes_out: :bytes_forwarded]
  @bytes_of %{in: :bytes_in, out: :bytes_out}

  @history_limit 60
  @stale_baseline_ms 10_000
  @stall_window_us 60_000_000
  @stall_query %{source: :flezha_health, limit: 20}
  @cells_limit 50

  # Named exactly, not by prefix: a host owns `graph_*` events of its own — the
  # relay page's payload tap is one — and a prefix match would swallow them
  # before the host's own clauses were reached.
  @events ~w(graph_select graph_dismiss graph_view graph_fold graph_cells_close graph_cells_sort)

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
        seen: %{},
        modes: %{},
        opened_at: System.monotonic_time(:millisecond),
        graph: nil,
        graph_for: nil,
        activity: nil,
        view: %{direction: "auto", width: nil, height: nil},
        expanded: MapSet.new(),
        cells_of: nil,
        cells_sort: "rate",
        prev_cells: nil,
        tally: nil,
        prev_tally: nil,
        placed: %{},
        input: nil
      }
    )
  end

  @doc """
  Reloads one relay's pipeline.

  Reads the overwatch facts the host already assigned, so a tick costs one
  liveness snapshot and the reads that are namespace-wide anyway — never a
  second overwatch call for the relay the host just fetched.

  Once a baseline exists, each tick also pushes `"pipeline_counts"` to the
  browser: how many records each counted node took since the last tick, which
  the graph replays as marks moving through the relay over the next tick.
  """
  def load_pipeline(socket) do
    %{ns: namespace, relay_id: relay_id, overwatch: facts} = socket.assigns
    state = forget_stale(socket.assigns.topology_state)
    token = socket.assigns[:flezha_token]

    if NodeManager.connected_node() do
      {snapshot, skew} = snapshot(token)
      {_rates, ticked} = advance(state, snapshot, [relay_id])
      {verdicts, stall_notice} = stall(token)
      {parked, parked_by} = parked_for(facts, token)
      {graph, graph_for, activity} = inside_reads(socket, state, facts, token)

      ticked =
        %{ticked | graph: graph, graph_for: graph_for, activity: activity}
        |> keep_tally(socket, announced(graph))

      input = %{
        namespace: namespace,
        relay_id: relay_id,
        facts: facts,
        snapshot: snapshot,
        parked: parked,
        parked_by: parked_by,
        verdicts: verdicts,
        stall_notice: stall_notice,
        skew: skew,
        graph: graph,
        activity: activity,
        prev_activity: state.activity,
        prev_cells: state.prev_cells
      }

      {ticked, counts} = tick(state, ticked, input)

      # A failed read measures nothing, so nothing is shown as moving.
      {history, modes} =
        if snapshot,
          do: {ticked.history |> Map.get(relay_id, []) |> Enum.reverse(), ticked.modes},
          else: {[], %{}}

      input = Map.merge(input, %{history: history, modes: modes, seen: ticked.seen})

      socket
      |> render_pipeline(%{ticked | input: input, prev_cells: cells_of_read(activity)})
      |> push_counts(counts)
    else
      disconnected(socket, state)
    end
  end

  # The model from the last tick's readings and the viewer's own choices, so a
  # selection, an expanded run or a direction re-renders without reading the
  # controller again. Placing is kept per shape and direction, since nothing
  # but the shape moves a node.
  defp render_pipeline(socket, %{input: input} = state) do
    model =
      input
      |> Map.merge(%{
        selected: state.selected,
        now: System.monotonic_time(:millisecond),
        opened_at: state.opened_at,
        view: state.view,
        expanded: state.expanded,
        cells_of: state.cells_of,
        cells_sort: state.cells_sort,
        placed: state.placed
      })
      |> pipeline()

    assign_topology(socket, %{state | placed: model.placed}, Map.delete(model, :placed))
  end

  # A baseline older than a few ticks, as after a hidden tab or a pause, would
  # replay all it missed as one tick, so the next reading starts afresh.
  defp forget_stale(%{prev_at: at} = state) when is_integer(at) do
    if System.monotonic_time(:millisecond) - at > @stale_baseline_ms,
      do: drop_baseline(state),
      else: state
  end

  defp forget_stale(state), do: state

  # What the next reading is measured against.
  defp drop_baseline(state),
    do: %{state | prev: nil, prev_at: nil, prev_parked: nil, activity: nil, prev_tally: nil}

  # The graph is the factory's announcement, so it is read once the page is
  # connected and again only when the relay is bound anew, a runner of its
  # namespace comes or goes, or its runner started another instance, or after
  # a read that failed for a reason that may pass. Activity is read only for a
  # relay whose inside is drawn, with the open Cell sheet's rows, and the dead
  # render reads neither.
  defp inside_reads(socket, state, facts, token) do
    %{ns: namespace, relay_id: relay_id} = socket.assigns
    key = {facts.runner_id, Map.get(facts, :bound_at), socket.assigns[:runner_epoch]}
    read_graph = fn -> NodeManager.relay_graph(namespace, relay_id, token) end

    if Phoenix.LiveView.connected?(socket) do
      fresh? = state.graph_for != key or not settled?(state.graph)
      graph = if fresh?, do: read_graph.(), else: state.graph
      activity = activity(graph, namespace, relay_id, token, state.cells_of)

      if not fresh? and restarted?(state.activity, activity),
        do: {read_graph.(), key, activity},
        else: {graph, key, activity}
    else
      {nil, nil, nil}
    end
  end

  # The runner answering now started again since the last reading.
  defp restarted?(%{} = before, %{} = now), do: instance(before) != instance(now)
  defp restarted?(_before, _now), do: false

  defp settled?({:ok, _read}), do: true
  defp settled?({:error, {:api_missing, _module, _function, _arity}}), do: true
  defp settled?({:error, reason}), do: NodeManager.error(reason).class in [:denied, :not_found]
  defp settled?(_unread), do: false

  # A refused Cell read falls back to the plain one, so the sheet says its
  # runner reports no Cells rather than losing the tasklet figures.
  defp activity({:ok, %{graph: %{}}}, namespace, relay_id, token, nil) do
    namespace |> NodeManager.relay_activity(relay_id, token) |> NodeManager.ok_or(nil)
  end

  defp activity({:ok, %{graph: %{}}} = graph, namespace, relay_id, token, tasklet) do
    case NodeManager.relay_activity(namespace, relay_id, token,
           cells_of: tasklet,
           limit: @cells_limit
         ) do
      {:ok, read} -> Map.put(read, :cells_asked, tasklet)
      {:error, _reason} -> activity(graph, namespace, relay_id, token, nil)
    end
  end

  defp activity(_graph, _namespace, _relay_id, _token, _cells_of), do: nil

  defp cells_of_read(%{cells: %{tasklet: _} = cells} = read),
    do: Map.merge(cells, %{read_at_ms: read.read_at_ms, instance: instance(read)})

  defp cells_of_read(_read), do: nil

  defp push_counts(socket, nil), do: socket

  defp push_counts(socket, counts),
    do: Phoenix.LiveView.push_event(socket, "pipeline_counts", counts)

  # ---- The tally ----
  #
  # A count-only listen on the relay's output channels, held by a feed linked
  # to the page while the relay has two or more of them and the page is
  # visible: one output channel's rate is the relay's forwarded count, and a
  # hidden page counts nothing. Its plugin is an observer the page made, so it
  # is never counted as one.

  defp keep_tally(state, socket, graph) do
    wanted? =
      Phoenix.LiveView.connected?(socket) and not (socket.assigns[:refresh_hidden] || false) and
        length(output_channels(graph)) >= 2

    case {wanted?, state.tally} do
      {true, nil} ->
        %{ns: ns, relay_id: id} = socket.assigns
        feed = EventFeed.listen(ns, id, :tally, socket.assigns[:flezha_token], :pipeline_tally)
        %{state | tally: %{feed: feed, totals: nil, epochs: nil, read_at_ms: nil}}

      {false, %{}} ->
        close_tally(state)

      _same ->
        state
    end
  end

  @doc """
  Ends the page's tally listen, as when the page is hidden: the listener
  leaves the relay, and the next visible tick opens another.
  """
  def stop_tally(socket) do
    assign(socket, topology_state: close_tally(socket.assigns.topology_state))
  end

  defp close_tally(%{tally: %{feed: feed}} = state) do
    EventFeed.stop(feed, :pipeline_tally)
    %{state | tally: nil, prev_tally: nil}
  end

  defp close_tally(state), do: state

  @doc """
  What the page's tally feed heard: a report of the frames counted per output
  channel, the attach, or that the listen ended. A report under new epochs
  counts from zero again, so the rates take it as a new baseline.
  """
  def tally(socket, :feed_event, {:tally, totals, %{epochs: epochs} = meta})
      when is_map(totals) do
    update_tally(socket, fn tally ->
      %{tally | totals: totals, epochs: epochs, read_at_ms: meta[:read_at_ms]}
    end)
  end

  # A tally that ended, or failed for a while — the controller unreachable, the
  # relay restarting — is opened again on the next tick; one the controller
  # refused stays refused for this visit, lighting the exits from OUT.
  def tally(socket, :feed_ended, _answer), do: update_tally(socket, fn _tally -> nil end)

  def tally(socket, :feed_error, reason) do
    next =
      if NodeManager.error(reason).class in [:unavailable, :not_found, :conflict],
        do: nil,
        else: :refused

    update_tally(socket, fn _tally -> next end)
  end

  def tally(socket, _kind, _event), do: socket

  defp update_tally(%{assigns: %{topology_state: %{tally: %{} = tally} = state}} = socket, fun) do
    assign(socket, topology_state: %{state | tally: fun.(tally)})
  end

  defp update_tally(socket, _fun), do: socket

  # ---- Ticks ----

  # What the pipeline keeps beyond the shared arithmetic: how far each counted
  # node advanced this tick, its rate in the history, when it last moved and
  # each wire's state. Answers the counts to replay, or nil without a baseline.
  defp tick(before, ticked, input) do
    relay_id = input.relay_id
    previous = relay_counters(before.prev, relay_id)
    current = relay_counters(input.snapshot, relay_id)
    parked_by = (before.prev_parked && advance_of(input.parked, before.prev_parked)) || 0
    {tally_by, ticked} = tally_advance(before, ticked)
    ticked = %{ticked | prev_parked: input.parked}

    if previous && current && before.prev_at do
      now = ticked.prev_at
      interval = now - before.prev_at
      seconds = max(interval, 1) / 1_000
      relay = advances(previous, current)
      tasklets = tasklet_advances(input.activity, before.activity)
      counts = budgets(shape(input), relay, tasklets, tally_by)

      rates =
        input.activity
        |> tasklet_rates(before.activity)
        |> Map.merge(Map.new(counts, fn {id, n} -> {id, per_second(n, seconds)} end))
        |> Map.put(:parked, per_second(parked_by, seconds))

      history = sample_more(ticked.history, relay_id, rates)

      moved = Map.merge(counts, %{in: relay.in, out: relay.out})

      seen =
        Enum.reduce(moved, ticked.seen, fn {key, n}, seen ->
          if n > 0, do: Map.put(seen, key, now), else: Map.put_new(seen, key, nil)
        end)

      newest = history |> Map.get(relay_id, []) |> Enum.reverse()

      modes =
        Map.new(seen, fn {key, at} ->
          {key, wire_mode(ticked.modes[key], smoothed(newest, key), at && now - at)}
        end)

      {%{ticked | history: history, seen: seen, modes: modes},
       %{
         interval_ms: interval,
         budgets: Map.new(counts, fn {id, n} -> {id, Float.round(n / 1, 2)} end),
         skipped: relay.filtered,
         parked: parked_by
       }}
    else
      {ticked, nil}
    end
  end

  # How far each output channel's tally advanced since the last tick, or nil
  # when there is no tally or no baseline under the same epochs.
  defp tally_advance(before, %{tally: %{totals: %{} = totals, epochs: epochs}} = ticked) do
    by =
      case before.prev_tally do
        {^epochs, base} -> Map.new(totals, fn {ch, n} -> {ch, advance_of(n, base[ch] || 0)} end)
        _other -> nil
      end

    {by, %{ticked | prev_tally: {epochs, totals}}}
  end

  defp tally_advance(_before, ticked), do: {nil, %{ticked | prev_tally: nil}}

  # Each tasklet's admitted advance between two reads of the same instance.
  defp tasklet_advances(%{tasklets: rows} = current, previous) do
    base = same_instance_rows(current, previous)

    for %{tasklet: name, admitted_total: total} <- rows,
        is_integer(total) and is_integer(base[name][:admitted_total]),
        into: %{},
        do: {name, advance_of(total, base[name].admitted_total)}
  end

  defp tasklet_advances(_current, _previous), do: %{}

  # `push_history/2` stores the shared rates; the node and tasklet rates are
  # the pipeline's own, added to the sample this tick just pushed.
  defp sample_more(history, relay_id, rates) do
    case history do
      %{^relay_id => [newest | older]} ->
        %{history | relay_id => [Map.merge(newest, rates) | older]}

      _none ->
        history
    end
  end

  @doc """
  Each tasklet's input rate between two activity reads, keyed `{:tasklet,
  name}`: the advance of its `admitted_total` over the advance of the runner's
  `read_at_ms`. A total that went backwards clamps to zero, and reads of two
  different instances, whose totals started again, give no rate.
  """
  def tasklet_rates(%{read_at_ms: now} = current, %{read_at_ms: before} = previous)
      when is_integer(now) and is_integer(before) and now > before do
    seconds = (now - before) / 1_000

    Map.new(tasklet_advances(current, previous), fn {name, n} ->
      {{:tasklet, name}, per_second(n, seconds)}
    end)
  end

  def tasklet_rates(_current, _previous), do: %{}

  defp instance(read), do: {read[:runner], read[:instance_seq]}

  # The previous read's rows by tasklet, when the same instance answered both
  # reads; totals of another instance started again and compare to nothing.
  defp same_instance_rows(current, previous) do
    if previous && instance(previous) == instance(current),
      do: Map.new(previous.tasklets, &{&1.tasklet, &1}),
      else: %{}
  end

  defp per_second(count, seconds), do: Float.round(count / seconds, 1)

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
      assign(socket, topology_state: %{drop_baseline(state) | rates: %{}})
    end
  end

  @doc """
  The graph's own events. A host forwards them here.

  Each re-renders from what the last tick already read, never reading the
  controller again, except that opening a tasklet's Cells reads them at once
  rather than leaving the sheet empty until the next tick.
  """
  def handle_event("graph_select", %{"id" => "tasklet-" <> name = id}, socket) do
    if announced_tasklet?(socket, name),
      do:
        socket
        |> update_state(&%{&1 | selected: id, cells_of: name, expanded: unfold(&1, name)})
        |> read_cells()
        |> rerender(),
      else: socket
  end

  def handle_event("graph_select", %{"id" => "run-" <> _first = id}, socket) do
    socket
    |> update_state(&%{&1 | selected: nil, expanded: MapSet.put(&1.expanded, id)})
    |> rerender()
  end

  def handle_event("graph_select", %{"id" => id}, socket) when is_binary(id) do
    socket |> update_state(&%{&1 | selected: id, cells_of: nil}) |> rerender()
  end

  def handle_event("graph_dismiss", _params, socket) do
    socket |> update_state(&%{&1 | selected: nil, cells_of: nil}) |> rerender()
  end

  def handle_event("graph_cells_close", _params, socket) do
    socket |> update_state(&%{&1 | cells_of: nil}) |> rerender()
  end

  def handle_event("graph_cells_sort", %{"by" => by}, socket)
      when by in ~w(key rate queued blocked dropped ago) do
    socket |> update_state(&%{&1 | cells_sort: by}) |> rerender()
  end

  def handle_event("graph_fold", _params, socket) do
    socket |> update_state(&%{&1 | expanded: MapSet.new(), cells_of: nil}) |> rerender()
  end

  # The viewer's direction and the panel the graph fits, from the hook. Only
  # the direction moves anything, so a size alone is kept for Auto's choice.
  def handle_event("graph_view", %{"direction" => direction} = params, socket)
      when direction in ~w(auto LR TB) do
    view = %{
      direction: direction,
      width: positive(params["width"]),
      height: positive(params["height"])
    }

    socket |> update_state(&%{&1 | view: view}) |> rerender()
  end

  def handle_event(_event, _params, socket), do: socket

  defp announced_tasklet?(socket, name) do
    with %{graph: read} <- socket.assigns.topology_state.input,
         %{tasklets: tasklets} <- announced(read) do
      Enum.any?(tasklets, &(&1.name == name))
    else
      _unread -> false
    end
  end

  # A tasklet folded into a run is shown by opening its run.
  defp unfold(%{input: %{graph: read}, expanded: expanded}, name) do
    case Enum.find(runs(announced(read)), &(name in &1.seq)) do
      %{id: run} -> MapSet.put(expanded, run)
      nil -> expanded
    end
  end

  defp positive(n) when is_number(n) and n > 0, do: n
  defp positive(_n), do: nil

  defp update_state(socket, fun),
    do: assign(socket, topology_state: fun.(socket.assigns.topology_state))

  defp rerender(%{assigns: %{topology_state: %{input: %{}} = state}} = socket),
    do: render_pipeline(socket, state)

  defp rerender(socket), do: socket

  # The open sheet's rows at once, against the previous read of the same
  # tasklet, so the first rates come with the next tick.
  defp read_cells(%{assigns: %{topology_state: %{input: %{} = input} = state}} = socket) do
    token = socket.assigns[:flezha_token]
    activity = activity(input.graph, input.namespace, input.relay_id, token, state.cells_of)

    if activity,
      do:
        update_state(
          socket,
          &%{&1 | input: Map.put(input, :activity, activity), prev_cells: cells_of_read(activity)}
        ),
      else: socket
  end

  defp read_cells(socket), do: socket

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
        close_tally(drop_baseline(state))
        | rates: %{},
          history: %{},
          seen: %{},
          modes: %{},
          graph: nil,
          graph_for: nil,
          input: nil,
          tally: nil
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

  # The relay class's parked entries, and each tasklet's share of them.
  defp parked_for(facts, token) do
    stats = parked_in([facts.relay_class], token)

    by_tasklet =
      stats
      |> Enum.group_by(&to_string(Map.get(&1, :tasklet_id)))
      |> Map.new(fn {tasklet, rows} -> {tasklet, entries(rows)} end)

    {entries(stats), by_tasklet}
  end

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
  One relay's pipeline: every node placed for the drawn direction, the wires
  between them as nets, the figures of this tick and the open inspector or
  Cell sheet.

  Pure: the overwatch facts (the hook table and the sources), the announced
  graph, the liveness snapshot, the rate history (oldest first), the activity
  reads, the parked count and any recent stall verdicts all arrive
  in `input`, as do the viewer's choices (`view`, `expanded`, `selected`,
  `cells_of`, `cells_sort`) and, when the host keeps them, when each counted
  node last moved (`seen`), each wire's state (`modes`), when the page opened
  (`opened_at`) and the clock to age them by (`now`).

  `placed` is the host's cache of layouts by shape and direction; the answer
  carries it back under `:placed`, since positions depend on nothing a tick
  changes.
  """
  def pipeline(input) do
    facts = input.facts
    history = Map.get(input, :history, [])
    selected_id = Map.get(input, :selected)
    expanded = Map.get(input, :expanded, MapSet.new())
    shape = shape(input)

    model =
      shape
      |> model(expanded)
      |> Map.put(:title, {to_string(input.relay_id), to_string(facts.factory_id || "—")})

    key = :erlang.phash2(model)
    view = Map.get(input, :view) || %{direction: "auto", width: nil, height: nil}
    {dir, layout, placed} = place(model, key, view, Map.get(input, :placed, %{}))

    channel = channel_for(input.snapshot, facts.runner_id)
    skipped = skipped_total(input)
    modes = Map.get(input, :modes, %{})
    figures = figures(input, history)
    rates = relay_rates(history)
    seen = Map.get(input, :seen, %{})
    stalled? = stalled?(input, channel)
    backpressure? = channel != nil and credit_exhausted?(channel)
    clock = %{now: Map.get(input, :now, 0), opened_at: Map.get(input, :opened_at, 0)}

    reading = %{
      history: history,
      modes: modes,
      seen: seen,
      clock: clock,
      figures: figures,
      skipped: skipped
    }

    word = state_word(history, modes, backpressure?)
    selected = selected(selected_id, shape, layout, input, channel, skipped)

    %{
      kind: :pipeline,
      state: :ok,
      namespace: input.namespace,
      relay_id: input.relay_id,
      factory: facts.factory_id,
      direction: dir,
      view: view,
      layout_key: "#{dir}-#{key}",
      bounds: layout.bounds,
      box: layout.box,
      head: layout.head,
      nodes: Enum.map(layout.nodes, &decorate(&1, reading, selected_id)),
      nets: Enum.map(layout.nets, &net_view(&1, reading)),
      labels: Enum.map(layout.labels, &label_view(&1, reading)),
      dlq: dlq_view(layout.dlq, Map.get(input, :parked, 0)),
      edges: edges_view(layout, shape.observers, backpressure?),
      inside: inside_note(Map.get(input, :graph), shape.graph),
      selected: selected,
      selected_id: selected_id,
      cells: cells(Map.get(input, :cells_of), shape, input, figures),
      stalled?: stalled?,
      backpressure?: backpressure?,
      stall: List.first(input.verdicts),
      stall_notice: Map.get(input, :stall_notice),
      skew: input.skew,
      plugin_count: shape.plugin_ids |> count_ids(),
      observer_count: shape.observers |> Map.values() |> List.flatten() |> count_ids(),
      expanded?: MapSet.size(expanded) > 0,
      flow: %{word: word, sentence: sentence(word, history, rates, input)},
      timeline: timeline(history),
      placed: placed
    }
  end

  defp count_ids(ids), do: ids |> Enum.uniq() |> length()

  defp relay_rates(history) do
    %{
      in: smoothed(history, :in),
      out: smoothed(history, :out),
      bytes_in: smoothed_bytes(history, :bytes_in),
      bytes_out: smoothed_bytes(history, :bytes_out)
    }
  end

  # ---- The shape: what feeds the relay, what it is, what drains it ----

  # An announcement with neither a channel nor a tasklet has no inside to draw.
  defp announced({:ok, %{graph: %{channels: [], tasklets: []}}}), do: nil

  defp announced({:ok, %{graph: %{channels: channels, tasklets: tasklets} = graph}})
       when is_list(channels) and is_list(tasklets),
       do: graph

  defp announced(_none), do: nil

  # A channel that leaves the relay for a plugin output or a call.
  defp exit?(%{kind: "entry"}), do: false
  defp exit?(channel), do: channel.kind == "plugin_bound" or channel.plugin_end in ~w(output call)

  defp output_channels(graph),
    do: for(c <- channels_of(graph), exit?(c) and c.plugin_end != "call", do: c.name)

  # Listeners leave the path first: every binding of the provider core's
  # `Flezha.Service.Listener` binds is an observer, counted once per plugin on
  # the edge it watches; a tally hears no record, so it is no observer. Of the
  # rest, a source feeds an entry, an `on_input` plugin filters the entries it
  # names before the relay sees a record, an `on_output` plugin takes the
  # output channels it names, and a plugin bound only off the record path is
  # listed with the relay rather than drawn.
  defp shape(input) do
    facts = input.facts
    graph = announced(Map.get(input, :graph))
    {listeners, plugins} = Enum.split_with(facts.bindings, &(&1.provider == @observer_provider))
    sources = Map.get(facts, :sources, [])
    source_ids = MapSet.new(sources, & &1.plugin_id)
    by_plugin = Enum.group_by(plugins, & &1.plugin_id)
    own = Map.drop(by_plugin, MapSet.to_list(source_ids))

    entries = for %{kind: "entry", name: name} <- channels_of(graph), do: name
    exits = for c <- channels_of(graph), exit?(c), do: c.name
    known = graph && MapSet.new(graph.channels, & &1.name)

    # A call's answers come back from the runner, past the input filters.
    answers = for c <- channels_of(graph), c.plugin_end == "call", do: "#{c.name}.response"
    filters = sided(own, "on_input", entries -- answers, known, :near)
    outputs = sided(own, "on_output", exits, known, :far)

    lifecycle =
      for {id, rows} <- own,
          not Enum.any?(rows, &(&1.hook in ~w(on_input on_output))),
          do: %{plugin_id: id, provider: hd(rows).provider, hooks: Enum.map(rows, & &1.hook)}

    %{
      graph: graph,
      entries: entries,
      exits: exits,
      answers: answers,
      sources: Enum.map(sources, &source(&1, graph, entries, by_plugin)),
      filters: filters,
      outputs: outputs,
      lifecycle: Enum.sort_by(lifecycle, & &1.plugin_id),
      skipped?: filters != [] or skipped_total(input) > 0,
      runs: runs(graph),
      observers: observers(listeners),
      plugin_ids: Map.keys(by_plugin)
    }
  end

  defp channels_of(nil), do: []
  defp channels_of(graph), do: graph.channels

  # A source naming no channel feeds the first entry channel, as the runner
  # routes it; one naming an entry the relay lacks attaches to the relay.
  defp source(source, graph, entries, by_plugin) do
    named = List.first(source.channel)

    entry =
      cond do
        is_nil(graph) -> nil
        is_nil(named) -> List.first(entries)
        named in entries -> named
        true -> nil
      end

    %{
      plugin_id: source.plugin_id,
      provider: source.provider,
      entry: entry,
      unnamed?: is_nil(named),
      missing: if(graph && named && named not in entries, do: [named], else: []),
      attached: if(graph && is_nil(entry), do: :near),
      hooks: by_plugin |> Map.get(source.plugin_id, []) |> Enum.map(& &1.hook)
    }
  end

  # The plugins bound on `hook`, one per plugin, in position order, with the
  # channels of `names` they act on. An input filter naming no channel acts on
  # every entry; an output plugin naming none, or a filter or output naming
  # only channels the relay lacks, attaches to the relay as a whole.
  defp sided(by_plugin, hook, names, known, edge) do
    for {id, rows} <- by_plugin, row = Enum.find(rows, &(&1.hook == hook)) do
      named = row.channel

      channels =
        cond do
          is_nil(named) and hook == "on_input" -> names
          is_nil(named) -> []
          true -> Enum.filter(named, &(&1 in names))
        end

      %{
        plugin_id: id,
        provider: row.provider,
        position: row.position,
        hook: hook,
        channels: if(known, do: channels, else: []),
        missing: if(known && named, do: Enum.reject(named, &MapSet.member?(known, &1)), else: []),
        every?: is_nil(named) and hook == "on_output",
        attached: if(known && channels == [], do: edge),
        hooks: Enum.map(rows, & &1.hook)
      }
    end
    |> Enum.sort_by(&{&1.position || 0, &1.plugin_id})
  end

  defp observers(listeners) do
    counted = Enum.reject(listeners, &Map.get(&1, :tally?, false))

    %{
      in: observing(counted, ~w(on_input)),
      out: observing(counted, ~w(on_output on_preview)),
      calls: observing(counted, ~w(on_call))
    }
  end

  defp observing(listeners, hooks) do
    for(entry <- listeners, entry.hook in hooks, do: entry.plugin_id)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Straight runs of four or more tasklets, each reading only the one before
  # it over a channel nothing else reads and that does not leave the relay.
  defp runs(nil), do: []

  defp runs(graph) do
    names = Enum.map(graph.tasklets, & &1.name)
    inputs = Map.new(names, &{&1, for(c <- graph.channels, &1 in c.consumers, do: c)})
    outs = Map.new(names, &{&1, for(c <- graph.channels, c.producer == &1, do: c)})

    next = fn name ->
      with [%{consumers: [consumer]} = c] <- outs[name],
           false <- exit?(c),
           [_one] <- inputs[consumer] || [] do
        consumer
      else
        _ -> nil
      end
    end

    linked = names |> Enum.map(next) |> MapSet.new()

    for name <- names,
        not MapSet.member?(linked, name),
        seq = follow(name, next, [name]),
        length(seq) >= 4,
        do: %{id: "run-#{name}", seq: seq}
  end

  defp follow(name, next, seq) do
    case next.(name) do
      nil ->
        Enum.reverse(seq)

      after_it ->
        if after_it in seq, do: Enum.reverse(seq), else: follow(after_it, next, [after_it | seq])
    end
  end

  # ---- The model: nodes and the edges between them ----
  #
  # Everything the layout places, in the order it first meets them, and only
  # what the shape and the folded runs decide, so it keys the layout cache.

  defp model(shape, expanded) do
    graph = shape.graph

    folded =
      for run <- shape.runs,
          run.id not in expanded,
          name <- run.seq,
          into: %{},
          do: {name, run.id}

    tid = &Map.get(folded, &1, "tasklet-#{&1}")
    acc = %{nodes: [], seen: MapSet.new(), edges: []}

    acc =
      if graph,
        do: inside_model(acc, shape, folded, tid),
        else: add(acc, %{id: "inside", type: :hollow, label: "inside not shown", sub: nil})

    acc
    |> filters_model(shape)
    |> sources_model(shape)
    |> ends_model(shape)
    |> then(&%{nodes: Enum.reverse(&1.nodes), edges: Enum.reverse(&1.edges)})
  end

  defp add(acc, node) do
    if MapSet.member?(acc.seen, node.id),
      do: acc,
      else: %{acc | nodes: [node | acc.nodes], seen: MapSet.put(acc.seen, node.id)}
  end

  @edge %{ch: nil, kind: :inner, side: false, label: nil, meter: false, entry: nil}

  defp link(acc, from, to, fields) do
    edge = Map.merge(@edge, Map.merge(fields, %{from: from, to: to}))

    if Enum.any?(acc.edges, &(&1.from == from and &1.to == to and &1.ch == edge.ch)),
      do: acc,
      else: %{acc | edges: [edge | acc.edges]}
  end

  defp inside_model(acc, shape, folded, tid) do
    graph = shape.graph
    tasklets = Map.new(graph.tasklets, &{&1.name, &1})

    acc =
      Enum.reduce(graph.tasklets, acc, fn t, acc ->
        if Map.has_key?(folded, t.name), do: acc, else: add(acc, tasklet_node(t))
      end)

    acc =
      Enum.reduce(shape.runs, acc, fn run, acc ->
        if Map.get(folded, hd(run.seq)) == run.id, do: add(acc, run_node(run)), else: acc
      end)

    acc =
      Enum.reduce(graph.channels, acc, fn
        %{kind: "entry"} = c, acc -> add(acc, port_node(c, :entry))
        _c, acc -> acc
      end)

    acc =
      Enum.reduce(graph.channels, acc, fn c, acc ->
        if exit?(c), do: add(acc, port_node(c, :exit)), else: acc
      end)

    Enum.reduce(graph.channels, acc, fn c, acc ->
      from =
        cond do
          c.kind == "entry" -> "entry-#{c.name}"
          Map.has_key?(tasklets, c.producer) -> tid.(c.producer)
          true -> nil
        end

      acc =
        for consumer <- c.consumers,
            from && Map.has_key?(tasklets, consumer),
            to = tid.(consumer),
            to != from,
            reduce: acc do
          acc -> link(acc, from, to, %{ch: c.name, label: c.kind != "entry" && c.name})
        end

      if exit?(c) and from,
        do: link(acc, from, "exit-#{c.name}", %{ch: c.name, label: c.consumers != [] && c.name}),
        else: acc
    end)
  end

  defp tasklet_node(tasklet) do
    %{
      id: "tasklet-#{tasklet.name}",
      type: :tasklet,
      label: shorten(tasklet.name),
      full: tasklet.name,
      sub: caption_sample(tasklet),
      tasklet: tasklet
    }
  end

  defp run_node(run) do
    %{
      id: run.id,
      type: :run,
      label: "#{length(run.seq)} tasklets",
      full: Enum.join(run.seq, " → "),
      sub: "#{shorten(hd(run.seq))} → #{shorten(List.last(run.seq))}",
      seq: run.seq
    }
  end

  defp port_node(channel, role) do
    %{
      id: "#{role}-#{channel.name}",
      type: role,
      label: channel.name,
      full: channel.name,
      sub: nil,
      channel: channel
    }
  end

  # Each entry's input filters stand in position order between its sources
  # and it; a filter acting on several entries is one node. Its skipped end
  # hangs off the filter nearest the relay, and with no filter bound but
  # records skipped all the same, off the relay itself.
  defp filters_model(acc, shape) do
    acc =
      Enum.reduce(shape.filters, acc, fn f, acc ->
        add(acc, %{
          id: "filter-#{f.plugin_id}",
          type: :filter,
          label: f.plugin_id,
          full: f.plugin_id,
          sub: "#{short_provider(f.provider)} · on_input",
          plugin: f,
          attached: f.attached
        })
      end)

    acc =
      for entry <- targets(shape), chain = chain(shape, entry), chain != [], reduce: acc do
        acc ->
          ids = Enum.map(chain, &"filter-#{&1.plugin_id}") ++ [entry_id(entry)]
          last = length(ids) - 2

          ids
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.with_index()
          |> Enum.reduce(acc, fn {[from, to], i}, acc ->
            link(acc, from, to, %{
              kind: :pass,
              ch: entry,
              entry: entry,
              meter: i == last and entry != nil
            })
          end)
      end

    if shape.skipped? do
      last =
        for(f <- shape.filters, f.attached == nil, do: "filter-#{f.plugin_id}") |> List.last()

      acc =
        add(acc, %{
          id: "skipped",
          type: :skip,
          label: "Skipped by filter",
          sub: "0,000,000 records",
          bin_for: last,
          attached: if(is_nil(last), do: :near)
        })

      for f <- shape.filters, f.attached == nil, reduce: acc do
        acc -> link(acc, "filter-#{f.plugin_id}", "skipped", %{kind: :skip, side: true})
      end
    else
      acc
    end
  end

  # The points records enter through: the entries, or the relay as one box.
  defp targets(%{graph: nil}), do: [nil]
  defp targets(shape), do: shape.entries

  defp entry_id(nil), do: "inside"
  defp entry_id(entry), do: "entry-#{entry}"

  defp chain(%{graph: nil} = shape, nil), do: Enum.filter(shape.filters, &(&1.attached == nil))
  defp chain(shape, entry), do: Enum.filter(shape.filters, &(entry in &1.channels))

  defp sources_model(acc, shape) do
    Enum.reduce(shape.sources, acc, fn s, acc ->
      acc =
        add(acc, %{
          id: "source-#{s.plugin_id}",
          type: :source,
          label: s.plugin_id,
          full: s.plugin_id,
          sub: short_provider(s.provider),
          source: s,
          attached: s.attached
        })

      case {s.attached, chain(shape, s.entry)} do
        {:near, _chain} ->
          acc

        {nil, [first | _]} ->
          link(acc, "source-#{s.plugin_id}", "filter-#{first.plugin_id}", %{
            kind: :feed,
            ch: s.entry,
            entry: s.entry
          })

        {nil, []} ->
          link(acc, "source-#{s.plugin_id}", entry_id(s.entry), %{
            kind: :feed,
            ch: s.entry,
            entry: s.entry,
            meter: s.entry != nil
          })
      end
    end)
  end

  # Where records leave: each output channel's plugins, or the muted end
  # that says none is bound; each call channel's called relay, drawn again
  # where its answer comes back in; and the plugins attached to the relay as
  # a whole.
  defp ends_model(acc, %{graph: nil} = shape), do: ends_hollow(acc, shape)

  defp ends_model(acc, shape) do
    channels = Map.new(shape.graph.channels, &{&1.name, &1})

    acc =
      Enum.reduce(shape.exits, acc, fn name, acc ->
        exit_ends(acc, channels[name], shape)
      end)

    Enum.reduce(shape.outputs, acc, fn
      %{attached: :far} = p, acc -> add(acc, plugin_node(p))
      _p, acc -> acc
    end)
  end

  defp exit_ends(acc, %{plugin_end: "call"} = c, shape) do
    {kind, target} = call_target(c.call_target)
    answer = "#{c.name}.response"

    acc =
      acc
      |> add(%{
        id: "call-#{c.name}",
        type: :call,
        label: target,
        full: target,
        sub: "#{kind}, called",
        channel: c
      })
      |> link("exit-#{c.name}", "call-#{c.name}", %{kind: :out, ch: c.name})

    if answer in shape.entries do
      acc
      |> add(%{
        id: "answer-#{c.name}",
        type: :answer,
        label: target,
        full: target,
        sub: "answers the call",
        channel: c
      })
      |> link("answer-#{c.name}", "entry-#{answer}", %{kind: :answer, ch: answer})
    else
      acc
    end
  end

  defp exit_ends(acc, c, shape) do
    case Enum.filter(shape.outputs, &(c.name in &1.channels)) do
      [] ->
        acc
        |> add(%{
          id: "unbound-#{c.name}",
          type: :unbound,
          label: "no plugin bound",
          sub: "reaches listeners only",
          channel: c
        })
        |> link("exit-#{c.name}", "unbound-#{c.name}", %{kind: :out, ch: c.name, meter: true})

      bound ->
        bound
        |> Enum.with_index()
        |> Enum.reduce(acc, fn {p, i}, acc ->
          acc
          |> add(plugin_node(p))
          |> link("exit-#{c.name}", "plugin-#{p.plugin_id}", %{
            kind: :out,
            ch: c.name,
            meter: i == 0
          })
        end)
    end
  end

  defp ends_hollow(acc, shape) do
    Enum.reduce(shape.outputs, acc, fn p, acc ->
      acc |> add(plugin_node(p)) |> link("inside", "plugin-#{p.plugin_id}", %{kind: :out})
    end)
  end

  defp plugin_node(p) do
    %{
      id: "plugin-#{p.plugin_id}",
      type: :plugin,
      label: p.plugin_id,
      full: p.plugin_id,
      sub: "#{short_provider(p.provider)} · on_output#{position_suffix(p.position)}",
      plugin: p,
      attached: p.attached
    }
  end

  defp call_target("factory:" <> target), do: {"factory", target}
  defp call_target("relay:" <> target), do: {"relay", target}
  defp call_target(target), do: {"relay", to_string(target)}

  defp position_suffix(nil), do: ""
  defp position_suffix(position), do: " ##{position}"

  # A provider module's last segment: the full name is far wider than a node,
  # and stays in the inspector.
  defp short_provider(provider), do: provider |> to_string() |> String.split(".") |> List.last()

  # Monospace text is measured by its advance, and a name longer than a node
  # can carry is shortened in the middle, where it is least telling.
  @advance 7.2
  @sub_advance 6.6
  @chan_advance 6.3
  @max_name 34
  # The widest rate a tasklet's slot holds, so a figure never resizes it.
  @rate_slot " 000.0/s"

  defp shorten(name) do
    if String.length(name) <= @max_name,
      do: name,
      else: String.slice(name, 0, 16) <> "…" <> String.slice(name, -(@max_name - 17), @max_name)
  end

  defp text_w(text, advance \\ @advance), do: String.length(text || "") * advance

  # A dynamic tasklet's caption carries its live Cell count, so its width is
  # taken from the widest the count can read.
  defp caption_sample(%{mode: "dynamic"}), do: "dynamic · 00,000 Cells"

  defp caption_sample(%{mode: "static", cell_keys: keys}) do
    named = Enum.join(keys, ", ")
    if String.length(named) <= 24, do: "static · #{named}", else: "static · #{length(keys)} keys"
  end

  defp caption_sample(%{mode: mode}), do: "#{mode} · 1 Cell"

  defp stacked?(%{type: :tasklet, tasklet: %{mode: mode}}), do: mode != "single"
  defp stacked?(_node), do: false

  # ---- Layout ----
  #
  # Every node is placed on two abstract axes: `main`, the way records travel,
  # and `cross`. Only the last step maps them onto x and y, so left to right
  # and top to bottom share every rule.

  @gap_cross 16
  @lane 12

  # The layout for the viewer's direction, from the cache when this shape was
  # placed before. Auto draws whichever direction fits the panel larger.
  defp place(model, key, view, cache) do
    get = fn cache, dir -> Map.get_lazy(cache, {key, dir}, fn -> layout(model, dir) end) end

    {dir, cache} =
      case view.direction do
        dir when dir in ~w(LR TB) ->
          {dir, Map.put(cache, {key, dir}, get.(cache, dir))}

        _auto ->
          lr = get.(cache, "LR")
          tb = get.(cache, "TB")
          w = view.width || 1200
          h = view.height || 640
          fit = &min(1, min(w / &1.bounds.w, h / &1.bounds.h))
          dir = if fit.(tb) > fit.(lr) * 1.08, do: "TB", else: "LR"
          {dir, %{{key, "LR"} => lr, {key, "TB"} => tb}}
      end

    cache = Map.take(cache, [{key, "LR"}, {key, "TB"}])
    {dir, cache[{key, dir}], cache}
  end

  defp size(node, dir) do
    {w, h} =
      case node.type do
        type when type in [:entry, :exit] ->
          {14, 14}

        :dummy ->
          {0, 0}

        :hollow ->
          {220, 64}

        type ->
          inner? = type in [:tasklet, :run]
          slot = if inner?, do: @rate_slot, else: ""
          text = max(text_w(node.label <> slot), text_w(node.sub, @sub_advance))
          w = max(if(inner?, do: 140, else: 120), 26 + text)
          if stacked?(node), do: {w + 6, 52}, else: {w, 46}
      end

    label_w = if node.type in [:entry, :exit], do: text_w(node.label, @chan_advance) + 12, else: 0

    {main, cross} =
      cond do
        node.type == :dummy -> {0, 10}
        node.type in [:entry, :exit] -> {0, if(dir == "TB", do: 14 + 2 * label_w, else: 28)}
        dir == "LR" -> {w, h}
        true -> {h, w}
      end

    Map.merge(node, %{w: w, h: h, label_w: label_w, main_size: main, cross_size: cross})
  end

  defp layout(model, dir) do
    nodes = Map.new(model.nodes, &{&1.id, size(&1, dir)})
    order = Enum.map(model.nodes, & &1.id)
    edges = model.edges
    real = Enum.reject(edges, & &1.side)
    preds = Enum.group_by(real, & &1.to, & &1.from)

    depth = depths(nodes, preds)
    {e_rank, x_rank, rank_of} = ranks(nodes, edges, depth)
    nodes = Map.new(nodes, fn {id, n} -> {id, Map.put(n, :rank, rank_of.(n))} end)

    {nodes, order, wires} = dummies(nodes, order, edges, dir)
    {up, down} = adjacency(wires)

    min_rank = nodes |> Map.values() |> Enum.map(& &1.rank) |> Enum.min()
    max_rank = nodes |> Map.values() |> Enum.map(& &1.rank) |> Enum.max()

    rows =
      for r <- min_rank..max_rank//1,
          do: Enum.filter(order, &(nodes[&1].rank == r))

    rows = sweep_orders(rows, nodes, up, down)
    cross = cross_positions(rows, nodes, up, down)

    routed = route(nodes, wires, cross, min_rank)
    finish(routed, nodes, rows, model, dir, e_rank, x_rank, min_rank)
  end

  # Each tasklet's longest distance from the entries, its first rank being 1.
  # A cycle counts its closing edge as a first step rather than looping.
  defp depths(nodes, preds) do
    inner = for {id, %{type: t}} <- nodes, t in [:tasklet, :run], do: id

    Enum.reduce(Enum.sort(inner), %{}, fn id, memo ->
      {_d, memo} = depth_of(id, memo, MapSet.new(), nodes, preds)
      memo
    end)
  end

  defp depth_of(id, memo, seen, nodes, preds) do
    cond do
      Map.has_key?(memo, id) ->
        {memo[id], memo}

      MapSet.member?(seen, id) ->
        {1, memo}

      true ->
        {deepest, memo} =
          Enum.reduce(Map.get(preds, id, []), {0, memo}, fn p, {d, memo} ->
            if nodes[p].type in [:tasklet, :run] do
              {pd, memo} = depth_of(p, memo, MapSet.put(seen, id), nodes, preds)
              {max(d, pd), memo}
            else
              {d, memo}
            end
          end)

        {deepest + 1, Map.put(memo, id, deepest + 1)}
    end
  end

  # Sources, filters and call answers before the entries; the entries; the
  # tasklets by depth; the exits; then everything records leave for.
  defp ranks(nodes, edges, depth) do
    filters = for {id, %{type: :filter, attached: nil}} <- nodes, do: id
    reach = Map.new(filters, &{&1, filter_depth(&1, edges, nodes)})
    e_rank = 1 + Enum.max([0 | Map.values(reach)])
    deepest = Enum.max([1 | Map.values(depth)])
    hollow? = Map.has_key?(nodes, "inside")
    x_rank = if hollow?, do: e_rank, else: e_rank + deepest + 1

    first_hop = fn id ->
      Enum.find_value(edges, fn e -> e.from == id and not e.side and e.to end)
    end

    rank_of = fn n ->
      case n.type do
        :filter when n.attached == nil -> e_rank - reach[n.id]
        :source when n.attached == nil -> source_rank(first_hop.(n.id), reach, e_rank)
        type when type in [:source, :filter, :skip, :answer] -> e_rank - 1
        type when type in [:entry, :hollow] -> e_rank
        type when type in [:tasklet, :run] -> e_rank + depth[n.id]
        :exit -> x_rank
        _end -> x_rank + 1
      end
    end

    {e_rank, x_rank, rank_of}
  end

  defp source_rank("filter-" <> _ = filter, reach, e_rank), do: e_rank - reach[filter] - 1
  defp source_rank(_entry, _reach, e_rank), do: e_rank - 1

  # How many filters a record still passes from this one to its entry.
  defp filter_depth(id, edges, nodes, seen \\ MapSet.new()) do
    nexts = for e <- edges, e.from == id, not e.side, nodes[e.to].type == :filter, do: e.to

    if MapSet.member?(seen, id),
      do: 1,
      else:
        1 + Enum.max([0 | Enum.map(nexts, &filter_depth(&1, edges, nodes, MapSet.put(seen, id)))])
  end

  # A wire skipping ranks passes one point per rank it crosses, so the rank's
  # ordering and packing keep its line clear of the nodes there.
  defp dummies(nodes, order, edges, dir) do
    {wires, {nodes, order}} =
      Enum.map_reduce(edges, {nodes, order}, fn e, {nodes, order} ->
        a = nodes[e.from].rank
        b = nodes[e.to].rank

        points =
          if e.side,
            do: [],
            else: for(r <- (a + 1)..(b - 1)//1, do: {"d:#{e.from}>#{e.to}>#{e.ch}:#{r}", r})

        nodes =
          Enum.reduce(points, nodes, fn {id, r}, nodes ->
            Map.put(nodes, id, size(%{id: id, type: :dummy, label: "", sub: nil, rank: r}, dir))
          end)

        ids = Enum.map(points, &elem(&1, 0))
        {Map.put(e, :chain, [e.from] ++ ids ++ [e.to]), {nodes, order ++ ids}}
      end)

    {nodes, order, wires}
  end

  defp adjacency(wires) do
    pairs =
      for w <- wires, not w.side, [a, b] <- Enum.chunk_every(w.chain, 2, 1, :discard), do: {a, b}

    {Enum.group_by(pairs, &elem(&1, 1), &elem(&1, 0)),
     Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))}
  end

  # Order within each rank by barycentre sweeps down and back; a filter's
  # skipped end follows its filter.
  defp sweep_orders(rows, nodes, up, down) do
    last = length(rows) - 1

    resort = fn rows, r, neighbours ->
      List.update_at(rows, r, fn row -> sort_row(row, rows, neighbours, nodes) end)
    end

    Enum.reduce(1..10, rows, fn _round, rows ->
      rows = Enum.reduce(1..last//1, rows, fn r, rows -> resort.(rows, r, up) end)
      Enum.reduce((last - 1)..0//-1, rows, fn r, rows -> resort.(rows, r, down) end)
    end)
  end

  defp sort_row(row, rows, neighbours, nodes) do
    idx = index(rows)
    {bins, rest} = Enum.split_with(row, &(nodes[&1].type == :skip))

    sorted = Enum.sort_by(rest, &barycentre(idx, &1, neighbours))

    Enum.reduce(bins, sorted, fn bin, sorted ->
      at = (Enum.find_index(sorted, &(&1 == nodes[bin].bin_for)) || -1) + 1
      List.insert_at(sorted, at, bin)
    end)
  end

  defp index(rows),
    do: for(row <- rows, {id, i} <- Enum.with_index(row), into: %{}, do: {id, i})

  # The mean of a node's neighbours' positions, or its own without any.
  defp barycentre(pos, id, neighbours) do
    case Map.get(neighbours, id, []) do
      [] -> pos[id]
      list -> Enum.sum(Enum.map(list, &pos[&1])) / length(list)
    end
  end

  # Cross positions: a node sits at the mean of its neighbours, a dummy keeps
  # its wire's line, each row is packed apart, and a node lined up with its
  # one neighbour snaps onto that line when the row has room.
  defp cross_positions(rows, nodes, up, down) do
    cs = &nodes[&1].cross_size
    last = length(rows) - 1

    cross =
      for row <- rows, reduce: %{} do
        cross ->
          {cross, _c} =
            Enum.reduce(row, {cross, 0}, fn id, {cross, c} ->
              {Map.put(cross, id, c + cs.(id) / 2), c + cs.(id) + @gap_cross}
            end)

          cross
      end

    dummy? = &(nodes[&1].type == :dummy)

    cross =
      Enum.reduce(1..8, cross, fn _round, cross ->
        cross =
          Enum.reduce(1..last//1, cross, fn r, cross ->
            pack(Enum.at(rows, r), cross, nodes, &barycentre(&2, &1, up))
          end)

        Enum.reduce((last - 1)..0//-1, cross, fn r, cross ->
          pack(Enum.at(rows, r), cross, nodes, fn id, cross ->
            if dummy?.(id), do: barycentre(cross, id, up), else: barycentre(cross, id, down)
          end)
        end)
      end)

    cross =
      Enum.reduce(1..last//1, cross, fn r, cross ->
        pack(Enum.at(rows, r), cross, nodes, fn id, cross ->
          if dummy?.(id),
            do: barycentre(cross, id, up),
            else: (barycentre(cross, id, up) + barycentre(cross, id, down)) / 2
        end)
      end)

    Enum.reduce(rows, cross, &snap_row(&1, &2, nodes, up, down))
  end

  defp pack(row, cross, nodes, want) do
    cs = &nodes[&1].cross_size

    wanted =
      Enum.map(row, fn id ->
        case nodes[id] do
          %{type: :skip, bin_for: bin} when is_binary(bin) ->
            cross[bin] + cs.(bin) / 2 + 24 + cs.(id) / 2

          _node ->
            want.(id, cross)
        end
      end)

    pairs = Enum.zip(row, wanted)

    {forward, _prev} =
      Enum.map_reduce(pairs, nil, fn {id, pos}, prev ->
        pos =
          case prev do
            nil -> pos
            {pid, ppos} -> max(pos, ppos + cs.(pid) / 2 + @gap_cross + cs.(id) / 2)
          end

        {{id, pos}, {id, pos}}
      end)

    {backward, _next} =
      forward
      |> Enum.reverse()
      |> Enum.map_reduce(nil, fn {id, pos}, next ->
        pos =
          case next do
            nil -> pos
            {nid, npos} -> min(pos, npos - cs.(nid) / 2 - @gap_cross - cs.(id) / 2)
          end

        {{id, pos}, {id, pos}}
      end)

    Enum.reduce(backward, cross, fn {id, pos}, cross -> Map.put(cross, id, pos) end)
  end

  defp snap_row(row, cross, nodes, up, down) do
    cs = &nodes[&1].cross_size
    indexed = row |> Enum.with_index() |> Map.new(fn {id, i} -> {i, id} end)

    row
    |> Enum.with_index()
    |> Enum.reduce(cross, fn {id, i}, cross ->
      u = Map.get(up, id, [])
      d = Map.get(down, id, [])

      to =
        case {u, d} do
          {[one], _} -> one
          {[], [one]} -> one
          _ -> nil
        end

      with to when is_binary(to) <- to,
           true <- abs(cross[to] - cross[id]) < 6,
           c = cross[to],
           prev = indexed[i - 1],
           next = indexed[i + 1],
           false <- prev && c - cs.(id) / 2 < cross[prev] + cs.(prev) / 2 + @gap_cross,
           false <- next && c + cs.(id) / 2 > cross[next] - cs.(next) / 2 - @gap_cross do
        Map.put(cross, id, c)
      else
        _held -> cross
      end
    end)
  end

  # Nets, lanes and the cross coordinate of each wire's ends: every wire
  # leaving one point on one channel is one net, a trunk in the first gap; nets
  # meeting one node meet it at spread points; a dummy close to its wire's line
  # moves onto it; and each bending net takes its own lane in each gap,
  # ordered to cross as few others as it can.
  defp route(nodes, wires, cross, min_rank) do
    wires =
      Enum.map(wires, fn w ->
        net = if w.side, do: "side:#{w.from}", else: "#{w.from}|#{w.ch || "#{w.kind}>#{w.to}"}"
        Map.put(w, :net, net)
      end)

    segs =
      for {w, wi} <- Enum.with_index(wires),
          not w.side,
          {[a, b], i} <- w.chain |> Enum.chunk_every(2, 1, :discard) |> Enum.with_index() do
        %{a: a, b: b, ri: nodes[a].rank - min_rank, group: if(i == 0, do: w.net, else: a), wi: wi}
      end

    arriving = meetings(segs, :b, &cross[&1.a], fn _old, new -> new end)
    leaving = meetings(segs, :a, &cross[&1.b], &min/2)
    offsets = Map.merge(spread(arriving, nodes, :in), spread(leaving, nodes, :out))

    src_c = fn eff, s ->
      Map.get(eff, s.a, cross[s.a]) + Map.get(offsets, {:out, s.a, s.group}, 0)
    end

    tgt_c = fn eff, s ->
      case Map.fetch(eff, s.b) do
        {:ok, c} -> c
        :error -> cross[s.b] + Map.get(offsets, {:in, s.b, s.group}, 0)
      end
    end

    eff =
      Enum.reduce(segs, %{}, fn s, eff ->
        if nodes[s.b].type == :dummy and abs(cross[s.b] - src_c.(eff, s)) < 8,
          do: Map.put(eff, s.b, src_c.(eff, s)),
          else: eff
      end)

    segs = Enum.map(segs, &Map.merge(&1, %{src: src_c.(eff, &1), tgt: tgt_c.(eff, &1)}))

    groups =
      segs
      |> ordered_groups(&{&1.ri, &1.group})
      |> Enum.map(fn {key, [s | _] = members} ->
        tgts = Enum.map(members, & &1.tgt)

        %{
          key: key,
          net: Enum.at(wires, s.wi).net,
          src: s.src,
          tgts: tgts,
          bends: Enum.any?(tgts, &(abs(&1 - s.src) >= 1))
        }
      end)
      |> Enum.group_by(&elem(&1.key, 0))

    lanes =
      Map.new(groups, fn {ri, list} -> {ri, order_by_crossings(Enum.filter(list, & &1.bends))} end)

    %{
      cross: cross,
      wires: wires,
      segs: segs,
      groups: groups,
      lanes: lanes,
      arriving: arriving
    }
  end

  # For each node at one end of segments, the groups meeting it, in the order
  # first met, each with where its other end sits.
  defp meetings(segs, side, value, merge) do
    segs
    |> Enum.group_by(&Map.fetch!(&1, side))
    |> Map.new(fn {node, list} ->
      {node,
       for {group, [s | more]} <- ordered_groups(list, & &1.group) do
         {group, Enum.reduce(more, value.(s), &merge.(&2, value.(&1)))}
       end}
    end)
  end

  # `Enum.group_by/2` as a list, in the order each key first appears.
  defp ordered_groups(items, key) do
    groups = Enum.group_by(items, key)
    items |> Enum.map(key) |> Enum.uniq() |> Enum.map(&{&1, groups[&1]})
  end

  defp spread(meetings, nodes, side) do
    for {id, list} <- meetings,
        length(list) >= 2,
        nodes[id].type not in [:dummy, :entry, :exit],
        n = length(list),
        step = min(@lane, (nodes[id].cross_size - 14) / (n - 1)),
        {{group, _at}, i} <- list |> Enum.sort_by(&elem(&1, 1)) |> Enum.with_index(),
        into: %{},
        do: {{side, id, group}, (i - (n - 1) / 2) * step}
  end

  # Neighbouring lanes swap while that crosses fewer nets: A left of B costs
  # B's source inside A's span, and each of A's targets inside B's span.
  defp order_by_crossings(list) do
    list = Enum.sort_by(list, & &1.src)
    n = length(list)

    Enum.reduce(0..max(n - 1, 0)//1, list, fn _pass, list ->
      Enum.reduce(0..(n - 2)//1, list, fn i, list ->
        [a, b] = Enum.slice(list, i, 2)

        if lane_cost(b, a) < lane_cost(a, b),
          do: list |> List.replace_at(i, b) |> List.replace_at(i + 1, a),
          else: list
      end)
    end)
  end

  defp span(g), do: {Enum.min([g.src | g.tgts]), Enum.max([g.src | g.tgts])}
  defp within?(v, {lo, hi}), do: v > lo + 0.5 and v < hi - 0.5

  defp lane_cost(a, b) do
    if(within?(b.src, span(a)), do: 1, else: 0) + Enum.count(a.tgts, &within?(&1, span(b)))
  end

  # Main positions, the boundary, the lanes in their gaps, and every point,
  # mapped to x and y.
  defp finish(routed, nodes, rows, model, dir, e_rank, x_rank, min_rank) do
    %{cross: cross, groups: groups, lanes: lanes, segs: segs, wires: wires} = routed
    lr? = dir == "LR"

    thick = Enum.map(rows, fn row -> Enum.max([14 | Enum.map(row, &nodes[&1].main_size)]) end)

    {main, gaps, _at} =
      rows
      |> Enum.with_index()
      |> Enum.reduce({%{}, %{}, 0}, fn {row, ri}, {main, gaps, at} ->
        t = Enum.at(thick, ri)
        main = Enum.reduce(row, main, &Map.put(&2, &1, at + t / 2))
        g = gap_after(ri, rows, nodes, wires, lanes, lr?)
        {main, Map.put(gaps, ri, {at + t, at + t + g}), at + t + g}
      end)

    hollow = nodes["inside"]

    inside =
      for {id, n} <- nodes, n.rank >= e_rank and n.rank <= x_rank, do: {id, n}

    c_min = Enum.min(for({id, n} <- inside, do: cross[id] - n.cross_size / 2), fn -> 0 end)
    c_max = Enum.max(for({id, n} <- inside, do: cross[id] + n.cross_size / 2), fn -> 60 end)
    head = if lr?, do: 40, else: 0
    mains = for {id, _n} <- inside, do: main[id]

    rank_main = fn r, fallback ->
      case Enum.at(rows, r - min_rank) do
        [id | _] -> main[id]
        _empty -> fallback.(mains, fn -> 0 end)
      end
    end

    {m0, m1} =
      if hollow,
        do:
          {main["inside"] - hollow.main_size / 2 - 24, main["inside"] + hollow.main_size / 2 + 24},
        else: {rank_main.(e_rank, &Enum.min/2), rank_main.(x_rank, &Enum.max/2)}

    box = %{m0: m0, m1: m1, c0: c_min - 20 - head, c1: c_max + 20}

    lane_at =
      for {ri, list} <- lanes, list != [], into: %{} do
        {start, stop} = gaps[ri]
        r = ri + min_rank

        centre =
          cond do
            r == e_rank - 1 -> start + (stop - start) * 0.3
            r == x_rank -> start + (stop - start) * 0.7
            lr? -> stop - max(24, (length(list) - 1) * @lane / 2 + 20)
            true -> (start + stop) / 2
          end

        # The whole block of lanes stays inside its gap, which is wide
        # enough for it, so no two lanes are pressed onto one line.
        width = (length(list) - 1) * @lane
        centre = centre |> max(start + 14 + width / 2) |> min(stop - 14 - width / 2)

        {ri,
         list
         |> Enum.with_index()
         |> Map.new(fn {g, i} -> {g.key, centre - width / 2 + i * @lane} end)}
      end

    anchor = fn id, side ->
      n = nodes[id]
      if side == :out, do: main[id] + n.main_size / 2, else: main[id] - n.main_size / 2
    end

    wires =
      wires
      |> Enum.with_index()
      |> Enum.map(fn {w, wi} ->
        pts =
          if w.side do
            a = nodes[w.from]
            b = nodes[w.to]

            [
              {main[w.from], cross[w.from] + a.cross_size / 2},
              {main[w.to], cross[w.to] - b.cross_size / 2}
            ]
          else
            segs
            |> Enum.filter(&(&1.wi == wi))
            |> Enum.flat_map(fn s ->
              p = {anchor.(s.a, :out), s.src}
              q = {anchor.(s.b, :in), s.tgt}

              if abs(s.src - s.tgt) >= 1 do
                lane = lane_at[s.ri][{s.ri, s.group}]
                [p, {lane, s.src}, {lane, s.tgt}, q]
              else
                [p, q]
              end
            end)
            |> tidy()
          end

        Map.put(w, :pts, pts)
      end)

    junctions =
      for {ri, list} <- groups,
          g <- list,
          g.bends,
          {lo, hi} = span(g),
          marks = junction_marks(g, {lo, hi}),
          v <- marks,
          do: {lane_at[ri][g.key], v, g.net}

    attached = attached_wires(nodes, cross, main, box)
    dlq = %{m: (box.m0 + box.m1) / 2, c: box.c1 + 56, w: 150, h: 44}

    xy = fn {m, c} -> if lr?, do: {m, c}, else: {c, m} end

    placed_nodes =
      for id <- Enum.map(model.nodes, & &1.id) do
        n = nodes[id]

        {x, y} =
          case n.type do
            :entry -> xy.({box.m0, cross[id]})
            :exit -> xy.({box.m1, cross[id]})
            _ -> xy.({main[id], cross[id]})
          end

        Map.merge(n, %{x: x, y: y, tag: port_tag(n.type, x, y, lr?)})
      end

    bxy =
      if lr?,
        do: %{x: box.m0, y: box.c0, w: box.m1 - box.m0, h: box.c1 - box.c0},
        else: %{x: box.c0, y: box.m0, w: box.c1 - box.c0, h: box.m1 - box.m0}

    {dx, dy} = xy.({dlq.m, dlq.c})
    dx = if lr?, do: dx, else: bxy.x + bxy.w + 34 + dlq.w / 2
    dlq_edge = if lr?, do: {dx, bxy.y + bxy.h}, else: {bxy.x + bxy.w, dy}
    dlq_view = %{x: dx, y: dy, w: dlq.w, h: dlq.h, edge: dlq_edge}

    wire_list =
      (wires ++ attached)
      |> Enum.map(fn w -> Map.put(w, :xy, Enum.map(w.pts, xy)) end)

    head =
      if lr?,
        do: %{x: bxy.x + 16, y: bxy.y + 22, anchor: "start"},
        else: %{x: bxy.x - 12, y: bxy.y + 16, anchor: "end"}

    {relay, factory} = Map.get(model, :title, {"", ""})
    title_w = max(text_w(relay, 7.8), text_w("factory #{factory}", @sub_advance)) + 16
    {x0, y0, x1, y1} = bounds(placed_nodes, wire_list, bxy, dlq_view, dir, title_w)
    colours = colours(wire_list, groups, routed.arriving)
    idx = index(rows)

    # The graph starts at the origin, whatever its packing drifted to.
    {sx, sy} = {20 - x0, 20 - y0}
    at = fn {x, y} -> {x + sx, y + sy} end
    moved = &Map.merge(&1, %{x: &1.x + sx, y: &1.y + sy})
    wire_list = Enum.map(wire_list, &Map.update!(&1, :xy, fn pts -> Enum.map(pts, at) end))
    placed_entries = for %{type: :entry} = n <- placed_nodes, do: moved.(n)

    %{
      direction: dir,
      nodes:
        Enum.map(placed_nodes, fn n ->
          n
          |> moved.()
          |> Map.update(:tag, nil, &(&1 && moved.(&1)))
          |> nav(idx, model.edges, nodes)
        end),
      nets: nets(wire_list, colours, junctions, &at.(xy.(&1))),
      labels: labels(wire_list, placed_entries, dir),
      box: moved.(bxy),
      head: moved.(head),
      dlq: dlq_view |> moved.() |> Map.update!(:edge, at),
      bounds: %{x: 0, y: 0, w: x1 - x0 + 40, h: y1 - y0 + 40}
    }
  end

  # Where a port writes its channel's name: inside the boundary beside it.
  defp port_tag(:entry, x, y, true), do: %{x: x + 12, y: y - 9, anchor: "start"}
  defp port_tag(:exit, x, y, true), do: %{x: x - 12, y: y - 9, anchor: "end"}
  defp port_tag(:entry, x, y, false), do: %{x: x + 12, y: y + 14, anchor: "start"}
  defp port_tag(:exit, x, y, false), do: %{x: x + 12, y: y - 6, anchor: "start"}
  defp port_tag(_type, _x, _y, _lr?), do: nil

  defp gap_after(ri, rows, nodes, wires, lanes, lr?) do
    row = Enum.at(rows, ri)
    next = Enum.at(rows, ri + 1) || []
    in_row = MapSet.new(row)
    lane_count = length(Map.get(lanes, ri, []))
    port? = &(nodes[&1].type in [:entry, :exit])

    need =
      if lr? do
        need =
          Enum.reduce(wires, 64, fn w, need ->
            cond do
              w.side or not MapSet.member?(in_row, hd(w.chain)) -> need
              w.meter -> max(need, 168)
              w.label -> max(need, text_w(w.label, @chan_advance) + 30 + lane_count * @lane)
              true -> need
            end
          end)

        ports =
          Enum.filter(row, &(nodes[&1].type == :entry)) ++
            Enum.filter(next, &(nodes[&1].type == :exit))

        Enum.reduce(ports, need, &max(&2, nodes[&1].label_w + 56))
      else
        if Enum.any?(row ++ next, port?), do: 72, else: 64
      end

    max(need, (lane_count - 1) * @lane + 48)
  end

  # Repeated points go, and so does a point in the middle of a straight run.
  defp tidy(pts) do
    pts =
      Enum.dedup_by(pts, fn {a, b} -> {Float.round(a / 1, 2), Float.round(b / 1, 2)} end)

    case pts do
      [first | _] = all when length(all) > 2 ->
        middle =
          all
          |> Enum.chunk_every(3, 1, :discard)
          |> Enum.reject(fn [{ax, ay}, {px, py}, {bx, by}] ->
            (abs(ax - px) < 0.01 and abs(px - bx) < 0.01) or
              (abs(ay - py) < 0.01 and abs(py - by) < 0.01)
          end)
          |> Enum.map(fn [_a, p, _b] -> p end)

        [first] ++ middle ++ [List.last(all)]

      short ->
        short
    end
  end

  defp junction_marks(g, span) do
    inner = Enum.filter([g.src | g.tgts], &within?(&1, span))
    split? = length(g.tgts) > 1 and Enum.any?(g.tgts, &(abs(&1 - g.src) < 1))
    Enum.uniq(if(split?, do: [g.src | inner], else: inner))
  end

  # A plugin, filter, source or skipped end attached to the relay as a whole
  # meets the boundary's edge at its own cross position, bending where it is
  # clear of the edge.
  defp attached_wires(nodes, cross, main, box) do
    for {id, %{attached: side} = n} <- nodes, side in [:near, :far] do
      c = cross[id]
      at = min(max(c, box.c0 + 12), box.c1 - 12)

      {from, to} =
        if side == :far,
          do: {{box.m1, at}, {main[id] - n.main_size / 2, c}},
          else: {{main[id] + n.main_size / 2, c}, {box.m0, at}}

      {fm, fc} = from
      {tm, tc} = to
      mid = (fm + tm) / 2
      pts = if abs(fc - tc) < 1, do: [from, to], else: [from, {mid, fc}, {mid, tc}, to]

      Map.merge(@edge, %{
        from: if(side == :far, do: "relay", else: id),
        to: if(side == :far, do: id, else: "relay"),
        kind: :edge,
        net: "edge:#{id}",
        chain: [],
        pts: pts
      })
    end
    |> Enum.sort_by(& &1.net)
  end

  defp bounds(nodes, wires, box, dlq, dir, title_w) do
    lr? = dir == "LR"
    xs0 = [box.x - if(lr?, do: 0, else: title_w + 12) | Enum.map(nodes, &(&1.x - &1.w / 2))]
    ys0 = [box.y | Enum.map(nodes, &(&1.y - &1.h / 2))]

    xs1 =
      [box.x + box.w, dlq.x + dlq.w / 2] ++
        Enum.map(
          nodes,
          &(&1.x + &1.w / 2 + if(not lr? and &1.label_w > 0, do: &1.label_w, else: 0))
        ) ++
        Enum.flat_map(wires, fn w ->
          Enum.map(w.xy, fn {x, _y} -> x + if(w.meter, do: 110, else: 0) end)
        end)

    ys1 = [box.y + box.h + 24, dlq.y + dlq.h / 2] ++ Enum.map(nodes, &(&1.y + &1.h / 2))

    {Enum.min(xs0), Enum.min(ys0) - 18, Enum.max(xs1), Enum.max(ys1)}
  end

  # Six hues, given greedily to the nets with the most neighbours first. Nets
  # running side by side in a gap, or into one node, never share one; nets
  # merely sharing a gap avoid it while a hue is left, since a gap can hold
  # more nets than there are hues.
  defp colours(wires, groups, arriving) do
    group_net = for {_ri, list} <- groups, g <- list, into: %{}, do: {elem(g.key, 1), g.net}

    side_by_side =
      Enum.flat_map(groups, fn {_ri, list} ->
        list
        |> Enum.sort_by(& &1.src)
        |> Enum.map(& &1.net)
        |> Enum.dedup()
        |> Enum.chunk_every(2, 1, :discard)
      end)

    into_one =
      Enum.map(arriving, fn {_id, list} ->
        list |> Enum.map(fn {group, _at} -> group_net[group] end) |> Enum.uniq()
      end)

    hard = clash_map(side_by_side ++ into_one)

    soft =
      clash_map(Enum.map(groups, fn {_ri, list} -> list |> Enum.map(& &1.net) |> Enum.uniq() end))

    near = &Map.get(&1, &2, MapSet.new())

    order =
      wires
      |> Enum.map(& &1.net)
      |> Enum.uniq()
      |> Enum.reject(&String.starts_with?(&1, ["side:", "edge:"]))
      |> Enum.sort_by(&{-MapSet.size(near.(hard, &1)), -MapSet.size(near.(soft, &1))})

    Enum.reduce(order, %{}, fn net, colour ->
      taken = &(near.(&1, net) |> Enum.map(fn other -> colour[other] end) |> MapSet.new())
      {hard_taken, soft_taken} = {taken.(hard), taken.(soft)}

      c =
        Enum.find(0..5, fn c -> c not in hard_taken and c not in soft_taken end) ||
          Enum.find(0..5, 5, &(&1 not in hard_taken))

      Map.put(colour, net, c)
    end)
  end

  defp clash_map(lists) do
    Enum.reduce(lists, %{}, fn list, clash ->
      for a <- list, b <- list, a && b && a != b, reduce: clash do
        clash -> Map.update(clash, a, MapSet.new([b]), &MapSet.put(&1, b))
      end
    end)
  end

  # Each net as one group: its wires, its colour, where it splits and the
  # nodes it touches.
  defp nets(wires, colours, junctions, xy) do
    wires
    |> ordered_groups(& &1.net)
    |> Enum.map(fn {net, ws} ->
      %{
        id: net,
        colour: colours[net],
        kind: hd(ws).kind,
        ch: hd(ws).ch,
        ends: ws |> Enum.flat_map(&[&1.from, &1.to]) |> Enum.uniq(),
        junctions: for({m, c, ^net} <- junctions, do: xy.({m, c})),
        wires:
          Enum.map(
            ws,
            &Map.take(&1, [:from, :to, :ch, :kind, :side, :meter, :entry, :xy, :label])
          )
      }
    end)
  end

  # Where each channel's name and each counted wire's figure is written.
  defp labels(wires, nodes, dir) do
    lr? = dir == "LR"

    names =
      wires
      |> Enum.filter(& &1.label)
      |> Enum.uniq_by(&{&1.from, &1.label})
      |> Enum.map(fn w ->
        {x, y} = hd(w.xy)
        {lx, ly} = if lr?, do: {x + 8, y - 6}, else: {x + 6, y + 15}
        %{kind: :channel, text: w.label, x: lx, y: ly, anchor: "start"}
      end)

    meters =
      for w <- wires, w.meter do
        if w.kind == :out do
          {x, y} = hd(w.xy)
          {lx, ly} = if lr?, do: {x + 14, y - 7}, else: {x + 8, y + 26}
          %{kind: :out, ch: w.ch, key: "exit-#{w.ch}", x: lx, y: ly, anchor: "start"}
        else
          in_label(List.last(w.xy), w.entry, "entry-#{w.entry}", lr?)
        end
      end

    names ++ meters ++ unfed(wires, nodes, lr?)
  end

  # An entry nothing drawn feeds, its records sent to the relay directly,
  # states its IN beside its port.
  defp unfed(wires, nodes, lr?) do
    fed = MapSet.new(wires, & &1.to)

    for %{type: :entry, id: id} = n <- nodes,
        not MapSet.member?(fed, id),
        do: in_label({n.x, n.y}, n.label, id, lr?)
  end

  # An entry's IN figure, written where its wire meets the port; top to
  # bottom it takes two lines, so neighbouring entries keep apart.
  defp in_label({x, y}, ch, key, lr?) do
    {lx, ly, anchor} = if lr?, do: {x - 14, y - 7, "end"}, else: {x + 8, y - 24, "start"}
    %{kind: :in, ch: ch, key: key, x: lx, y: ly, anchor: anchor, stacked?: not lr?}
  end

  # The keyboard's map: what a record reaches next and came from, and the
  # node's place in its rank.
  defp nav(node, idx, edges, nodes) do
    along = fn ids -> ids |> Enum.uniq() |> Enum.sort_by(&{nodes[&1].rank, idx[&1]}) end

    Map.merge(node, %{
      order: idx[node.id],
      next: along.(for e <- edges, e.from == node.id, not e.side, do: e.to),
      prev: along.(for e <- edges, e.to == node.id, not e.side, do: e.from)
    })
  end

  # ---- What each tick counted ----

  # How many records each counted node took this tick: the relay's IN split
  # over its entries and their sources, each tasklet's admitted advance, each
  # output channel's tally, or its share of OUT without one, and what the
  # input filters skipped. A node absent here is not counted and hands on
  # whatever reaches it.
  defp budgets(shape, relay, tasklets, tally_by) do
    entries = entry_counts(shape, relay.in, tasklets)
    outputs = output_channels(shape.graph)
    fed = Enum.filter(shape.sources, &is_nil(&1.attached))
    filtered = Enum.filter(fed, &(chain(shape, &1.entry) != []))
    skip_share = if filtered == [], do: 0, else: relay.filtered / length(filtered)

    sources =
      for s <- fed, into: %{} do
        alike = Enum.count(fed, &(&1.entry == s.entry))
        base = if shape.graph, do: Map.get(entries, s.entry, 0), else: relay.in
        share = if s in filtered, do: skip_share, else: 0
        {"source-#{s.plugin_id}", base / alike + share}
      end

    exits =
      for ch <- outputs, into: %{} do
        {"exit-#{ch}",
         if(tally_by, do: Map.get(tally_by, ch, 0), else: relay.out / length(outputs))}
      end

    runs =
      for run <- shape.runs, n = tasklets[hd(run.seq)], into: %{}, do: {run.id, n}

    [
      sources,
      Map.new(entries, fn {e, n} -> {"entry-#{e}", n} end),
      Map.new(tasklets, fn {name, n} -> {"tasklet-#{name}", n} end),
      runs,
      exits,
      if(shape.skipped?, do: %{"skipped" => relay.filtered}, else: %{})
    ]
    |> Enum.reduce(&Map.merge(&2, &1))
  end

  # IN per entry: the admitted advance of the one tasklet that reads only that
  # entry, where there is one, and the rest of IN shared evenly over the other
  # entries. An entry a call's answers come back on is fed by the call.
  defp entry_counts(%{graph: nil}, _taken, _tasklets), do: %{}

  defp entry_counts(shape, taken, tasklets) do
    graph = shape.graph
    reads = fn name -> for c <- graph.channels, name in c.consumers, do: c.name end

    known =
      for %{kind: "entry", name: e, consumers: [consumer]} <- graph.channels,
          reads.(consumer) == [e],
          n = tasklets[consumer],
          into: %{},
          do: {e, n}

    rest = Enum.reject(shape.entries, &(Map.has_key?(known, &1) or &1 in shape.answers))
    left = max(taken - Enum.sum(Map.values(known)), 0)
    share = if rest == [], do: 0, else: left / length(rest)

    Map.merge(known, Map.new(rest, &{&1, share}))
  end

  # What each tasklet is doing, from this tick's activity read beside the
  # previous one: its smoothed input rate, its backlog once its deepest Cell
  # has held a queue for two reads, what it shed since the last read, and the
  # dead letters of its own in the queue. Nothing from the runner at all when
  # this tick's read failed.
  defp figures(input, history) do
    parked = Map.get(input, :parked_by, %{})

    case Map.get(input, :activity) do
      %{tasklets: rows} = current ->
        before = same_instance_rows(current, Map.get(input, :prev_activity))

        figures =
          Map.new(rows, &{&1.tasklet, tasklet_figure(&1, before[&1.tasklet], history, parked)})

        deepest =
          figures
          |> Enum.filter(fn {_name, figure} -> figure.backlog end)
          |> Enum.max_by(fn {_name, figure} -> figure.row[:queued_max] end, fn -> nil end)

        figures =
          case deepest do
            {name, figure} -> Map.put(figures, name, %{figure | deepest?: true})
            nil -> figures
          end

        Map.merge(parked_only(parked), figures)

      _unread ->
        parked_only(parked)
    end
  end

  # A tasklet the runner reported nothing for still carries its dead letters.
  defp parked_only(parked) do
    Map.new(parked, fn {name, n} ->
      {name, %{row: nil, rate: nil, backlog: nil, shed: 0, parked: n, deepest?: false}}
    end)
  end

  defp tasklet_figure(row, previous, history, parked) do
    key = {:tasklet, row.tasklet}
    samples = history |> Enum.take(-@smoothing) |> Enum.filter(&Map.has_key?(&1, key))
    queued? = &(is_integer(&1[:queued_max]) and &1[:queued_max] > 0)

    %{
      row: row,
      rate: if(samples != [], do: smoothed(samples, key)),
      backlog: if(previous && queued?.(row) && queued?.(previous), do: row.queued_max),
      shed: if(previous, do: advance_of(dropped(row), dropped(previous)), else: 0),
      parked: Map.get(parked, row.tasklet, 0),
      deepest?: false
    }
  end

  defp dropped(row) do
    [:dropped_newest_total, :dropped_oldest_total, :dropped_capped_total]
    |> Enum.map(&(row[&1] || 0))
    |> Enum.sum()
  end

  # ---- Decoration: this tick's figures on the placed graph ----

  defp decorate(node, reading, selected) do
    figure = tasklet_figure_of(node, reading.figures)

    node
    |> Map.take([
      :id,
      :type,
      :label,
      :full,
      :x,
      :y,
      :w,
      :h,
      :label_w,
      :rank,
      :order,
      :next,
      :prev
    ])
    |> Map.merge(%{
      tag: node[:tag],
      attached: node[:attached],
      sub: if(node.type == :skip, do: skipped_sub(reading), else: node_sub(node, figure)),
      rate: figure_rate(figure),
      badges: badges(figure),
      stacked?: stacked?(node),
      unbound?: node.type == :exit and Enum.any?(node.next, &String.starts_with?(&1, "unbound-")),
      call?: node.type == :exit and node.channel.plugin_end == "call",
      mark: node_mark(node),
      selected?: selected == node.id
    })
  end

  defp tasklet_figure_of(%{type: :tasklet, tasklet: t}, figures), do: figures[t.name]
  defp tasklet_figure_of(%{type: :run, seq: [first | _]}, figures), do: figures[first]
  defp tasklet_figure_of(_node, _figures), do: nil

  defp figure_rate(%{rate: rate}) when is_number(rate), do: rate_label(rate, "/s")
  defp figure_rate(_figure), do: nil

  defp node_sub(%{type: :tasklet, tasklet: %{mode: "dynamic"}}, %{row: %{cells: n}})
       when is_integer(n),
       do: "dynamic · #{Words.count(n, "Cell")}"

  defp node_sub(%{type: :tasklet, tasklet: %{mode: "dynamic"}}, _figure), do: "dynamic · Cells"
  defp node_sub(node, _figure), do: node.sub

  defp skipped_sub(reading), do: Words.count(reading.skipped, "record")

  defp badges(nil), do: []

  defp badges(figure) do
    Enum.filter(
      [
        figure.parked > 0 && {:parked, Words.count(figure.parked, "dead letter")},
        figure.backlog && {:backlog, "#{figure.backlog} queued"},
        figure.shed > 0 && {:shed, "#{figure.shed} shed"}
      ],
      & &1
    )
  end

  # What sets a node apart in words, beside its name.
  defp node_mark(%{attached: :far, plugin: %{every?: true}}), do: "every channel"
  defp node_mark(%{attached: _side, plugin: %{missing: [_ | _]}}), do: "no such channel"
  defp node_mark(%{attached: :near, source: %{missing: [_ | _]}}), do: "no such entry"
  defp node_mark(%{type: :skip, attached: :near}), do: "no filter bound"
  defp node_mark(_node), do: nil

  # Each wire of a net, with what the hook needs to move records along it and
  # what its tooltip says.
  defp net_view(net, reading) do
    wires =
      for w <- net.wires do
        key = count_key(w)
        rate = if key, do: smoothed(reading.history, key)

        %{
          id: wire_id(w),
          from: w.from,
          to: w.to,
          entry: w.entry,
          kind: w.kind,
          d: rounded_path(w.xy),
          pts: pts_attr(w.xy),
          key: key && to_string_key(key),
          mode: (key && Map.get(reading.modes, key)) || :quiet,
          rate: rate,
          title: wire_title(w, key, rate, reading)
        }
      end

    %{
      id: net.id,
      colour: net.colour,
      kind: net.kind,
      ends: net.ends,
      junctions: Enum.map(net.junctions, fn {x, y} -> %{x: r1(x), y: r1(y)} end),
      d: Enum.map_join(wires, " ", & &1.d),
      wires: wires,
      idle?: Enum.all?(wires, &(&1.mode == :quiet))
    }
  end

  defp wire_id(w), do: "#{w.from}>#{w.to}>#{w.ch}"

  # The counter a wire's rate and state come from: the node it reaches when
  # that node is counted, else the node it leaves.
  defp count_key(%{kind: kind}) when kind in [:edge, :skip], do: nil

  defp count_key(w) do
    cond do
      counted?(w.to) -> w.to
      counted?(w.from) -> w.from
      w.kind == :out and is_nil(w.ch) -> :out
      true -> nil
    end
  end

  defp counted?(id),
    do: String.starts_with?(id, ~w(entry- tasklet- run- exit- source-)) or id == "skipped"

  defp to_string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp to_string_key(key), do: key

  defp wire_title(%{kind: :edge}, _key, _rate, _reading),
    do: "Attached to the relay as a whole, naming no channel it has"

  defp wire_title(%{kind: :skip}, _key, _rate, _reading),
    do: "Records an input filter skipped; they never reach a tasklet"

  defp wire_title(w, nil, _rate, _reading),
    do: "#{w.ch || "To the relay"}: not counted"

  defp wire_title(w, key, rate, reading) do
    "#{w.ch || "Through the relay"}: #{rate_label(rate, "/s") || "measuring"}, " <>
      last_record(key, reading)
  end

  defp last_record(key, %{seen: seen, clock: clock}) do
    case Map.fetch(seen, key) do
      {:ok, at} when is_integer(at) -> "last record #{ago(clock.now - at)} ago"
      {:ok, nil} -> "none since opened"
      :error -> "measuring"
    end
  end

  defp label_view(%{kind: :channel} = label, _reading), do: label

  defp label_view(%{key: key} = label, reading) when label.kind in [:in, :out] do
    key = label_key(label, key)
    rate = smoothed(reading.history, key)
    word = if label.kind == :in, do: "IN", else: "OUT"

    text = if rate, do: "#{word} #{rate_label(rate, "/s")}", else: word
    more = if label.kind == :in and rate, do: recency(key, rate, reading)

    Map.merge(label, %{
      text: text,
      more: more,
      rate: rate,
      testid: "topo-rate-#{label.kind}-#{label.ch || "relay"}"
    })
  end

  defp label_key(%{kind: :in, ch: nil}, _key), do: :in
  defp label_key(%{kind: :out, ch: nil}, _key), do: :out
  defp label_key(_label, key), do: key

  # How a counted point states its recency: "continuous" while a stream is
  # still arriving, and otherwise when a record last passed, to the tick's
  # resolution.
  defp recency(key, rate, %{seen: seen, modes: modes, clock: clock}) do
    at = Map.get(seen, key)
    mode = Map.get(modes, key, :quiet)
    now = clock.now

    cond do
      is_nil(rate) -> "measuring"
      mode == :quiet and is_nil(at) -> "quiet for #{ago(now - clock.opened_at)}"
      mode == :quiet -> "quiet for #{ago(now - at)}"
      is_nil(at) -> "none since opened"
      mode == :streaming and now - at <= 3_000 -> "continuous"
      true -> "#{ago(now - at)} ago"
    end
  end

  defp ago(ms) when ms < 60_000, do: "~#{div(max(ms, 0), 1_000)} s"
  defp ago(ms), do: Format.duration(ms)

  defp dlq_view(dlq, parked) do
    {ex, ey} = dlq.edge

    {x0, y0} =
      if dlq.x - dlq.w / 2 > ex, do: {dlq.x - dlq.w / 2, dlq.y}, else: {dlq.x, dlq.y - dlq.h / 2}

    %{
      x: r1(dlq.x - dlq.w / 2),
      y: r1(dlq.y - dlq.h / 2),
      w: dlq.w,
      h: dlq.h,
      parked: parked,
      d: rounded_path([{ex, ey}, {x0, y0}]),
      pts: pts_attr([{ex, ey}, {x0, y0}])
    }
  end

  # Where the boundary says who listens at each edge, and that the runner's
  # channel has no credit left.
  defp edges_view(layout, observers, backpressure?) do
    box = layout.box
    lr? = layout.direction == "LR"

    %{
      in: %{ids: observers.in, x: box.x + 4, y: if(lr?, do: box.y + box.h + 16, else: box.y - 8)},
      out: %{ids: observers.out, x: box.x + box.w - 4, y: box.y + box.h + 16},
      calls: %{ids: observers.calls, x: layout.head.x, y: layout.head.y + 30},
      backpressure: backpressure? && %{x: box.x + box.w, y: box.y + 14}
    }
  end

  defp r1(v), do: Float.round(v / 1, 1)

  defp pts_attr(xy), do: Enum.map_join(xy, " ", fn {x, y} -> "#{r1(x)},#{r1(y)}" end)

  # An orthogonal polyline with rounded corners.
  defp rounded_path([{x, y} | _] = pts) do
    corners =
      pts
      |> Enum.chunk_every(3, 1, :discard)
      |> Enum.map(fn [{ax, ay}, {px, py}, {bx, by}] ->
        la = :math.sqrt((px - ax) ** 2 + (py - ay) ** 2)
        lb = :math.sqrt((bx - px) ** 2 + (by - py) ** 2)
        rr = Enum.min([8, la / 2, lb / 2])
        {sx, sy} = {px - (px - ax) / max(la, 0.001) * rr, py - (py - ay) / max(la, 0.001) * rr}
        {ex, ey} = {px + (bx - px) / max(lb, 0.001) * rr, py + (by - py) / max(lb, 0.001) * rr}
        " L#{r1(sx)},#{r1(sy)} Q#{r1(px)},#{r1(py)} #{r1(ex)},#{r1(ey)}"
      end)

    {lx, ly} = List.last(pts)
    "M#{r1(x)},#{r1(y)}" <> Enum.join(corners) <> " L#{r1(lx)},#{r1(ly)}"
  end

  # ---- The inspector ----

  defp selected(nil, _shape, _layout, _input, _channel, _skipped), do: nil

  defp selected("relay", shape, _layout, input, channel, _skipped),
    do: relay_view(shape, input, channel)

  defp selected(id, shape, layout, _input, _channel, skipped),
    do: layout.nodes |> Enum.find(&(&1.id == id)) |> node_detail(shape, skipped)

  defp relay_view(shape, input, channel) do
    facts = input.facts

    %{
      id: "relay",
      type: :relay,
      label: input.relay_id,
      facts: facts,
      counters: relay_counters(input.snapshot, input.relay_id),
      rates: if(Map.get(input, :history, []) != [], do: relay_rates(input.history)),
      channel: channel,
      lifecycle: shape.lifecycle,
      calls: shape.observers.calls,
      listen: ~p"/namespaces/#{input.namespace}/relays/#{input.relay_id}/listen",
      runner: ~p"/cluster"
    }
  end

  defp node_detail(%{type: :source} = node, _shape, _skipped),
    do: %{id: node.id, type: :source, label: node.label, source: node.source}

  defp node_detail(%{type: :filter} = node, _shape, skipped),
    do: %{id: node.id, type: :filter, label: node.label, plugin: node.plugin, skipped: skipped}

  defp node_detail(%{type: :skip} = node, _shape, skipped),
    do: %{id: node.id, type: :skip, label: node.label, skipped: skipped}

  defp node_detail(%{type: type} = node, shape, _skipped) when type in [:entry, :exit] do
    c = node.channel

    %{
      id: node.id,
      type: type,
      label: node.label,
      channel: c,
      bound: for(p <- shape.outputs, c.name in p.channels, do: p)
    }
  end

  defp node_detail(%{type: :plugin} = node, _shape, _skipped),
    do: %{id: node.id, type: :plugin, label: node.label, plugin: node.plugin}

  defp node_detail(%{type: type} = node, _shape, _skipped)
       when type in [:unbound, :call, :answer],
       do: %{id: node.id, type: type, label: node.label, channel: node.channel}

  defp node_detail(_node, _shape, _skipped), do: nil

  # ---- The Cell sheet ----

  defp cells(nil, _shape, _input, _figures), do: nil
  defp cells(_name, %{graph: nil}, _input, _figures), do: nil

  defp cells(name, shape, input, figures) do
    with %{} = tasklet <- Enum.find(shape.graph.tasklets, &(&1.name == name)) do
      read = Map.get(input, :activity)
      figure = figures[name]
      sort = Map.get(input, :cells_sort, "rate")

      {rows, total, note} =
        case read do
          %{cells_asked: ^name, cells: %{tasklet: ^name, rows: rows, cells_total: total}} ->
            {cell_rows(rows, read, Map.get(input, :prev_cells), name), total, nil}

          _none ->
            {[], 0, cells_note(read)}
        end

      %{
        tasklet: name,
        caption:
          node_sub(%{type: :tasklet, tasklet: tasklet, sub: caption_sample(tasklet)}, figure),
        rate: figure_rate(figure),
        parked: (figure && figure.parked) || 0,
        rows: sort_cells(rows, sort),
        sort: sort,
        total: total,
        note: note,
        hops: hops(shape.graph, name)
      }
    end
  end

  defp cells_note(nil), do: :unread
  defp cells_note(_read), do: :not_reported

  # Each Cell's intake between this read and the last of the same tasklet and
  # instance, how long since it last took a record on the runner's clock, and
  # whether it took one since that read.
  defp cell_rows(rows, read, previous, name) do
    base =
      if previous && previous.tasklet == name && previous.instance == instance(read),
        do: Map.new(previous.rows, &{&1.key, &1}),
        else: %{}

    seconds = previous && max(read.read_at_ms - previous.read_at_ms, 1) / 1_000

    for row <- rows do
      before = base[row.key]
      admitted = row[:admitted_total] || 0
      advanced = before && advance_of(admitted, before[:admitted_total] || 0)
      last = row[:last_admitted_ms]

      %{
        key: to_string(row.key),
        rate: if(advanced && seconds, do: per_second(advanced, seconds)),
        queued: row[:queued] || 0,
        blocked: row[:blocked_total] || 0,
        dropped: (row[:dropped_newest_total] || 0) + (row[:dropped_oldest_total] || 0),
        ago_ms: if(is_integer(last) and last > 0, do: max(read.read_at_ms - last, 0)),
        fresh?: (advanced || 0) > 0
      }
    end
  end

  defp sort_cells(rows, "key"), do: Enum.sort_by(rows, & &1.key)
  defp sort_cells(rows, "ago"), do: Enum.sort_by(rows, &(&1.ago_ms || :infinity))

  defp sort_cells(rows, by) do
    field = String.to_existing_atom(by)
    Enum.sort_by(rows, &{-(Map.get(&1, field) || 0), &1.key})
  end

  # The tasklets a record comes from and goes to, each with the channel
  # between them.
  defp hops(graph, name) do
    up =
      for c <- graph.channels,
          name in c.consumers,
          c.producer,
          do: %{label: "← #{c.producer} via #{c.name}", tasklet: c.producer}

    down =
      for c <- graph.channels,
          c.producer == name,
          consumer <- c.consumers,
          do: %{label: "#{c.name} → #{consumer}", tasklet: consumer}

    up ++ down
  end

  # Why the relay is drawn as one box, when it is.
  defp inside_note(nil, _announced), do: nil
  defp inside_note({:ok, %{disagree: true}}, %{}), do: :disagree
  defp inside_note(_read, %{}), do: nil
  defp inside_note({:ok, %{factory: factory}}, nil), do: {:not_announced, factory}
  defp inside_note({:error, {:api_missing, _m, _f, _a}}, nil), do: :not_supported
  defp inside_note({:error, reason}, nil), do: {:unreadable, reason}

  # The newest verdict marks the relay when it names the relay, its runner or
  # its runner's channel.
  defp stalled?(%{verdicts: [%{subject: subject} | _]} = input, channel) when subject != nil do
    subject == input.relay_id or subject == input.facts.runner_id or
      (channel != nil and subject == to_string(channel.name))
  end

  defp stalled?(_input, _channel), do: false

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

  # Bytes are smoothed like messages, but only once the controller has
  # reported them; before that they are unmeasured, not zero.
  defp smoothed_bytes(history, key) do
    if Enum.any?(history, &Map.has_key?(&1, key)), do: smoothed(history, key)
  end

  @doc """
  A displayed message rate; a trickle under 0.05 reads `<0.1 msgs/s`. Inside
  a relay boundary, where wires are short, the unit is `/s`.
  """
  def rate_label(rate, unit \\ " msgs/s")
  def rate_label(nil, _unit), do: nil
  def rate_label(rate, unit) when rate > 0 and rate < 0.05, do: "<0.1" <> unit
  def rate_label(rate, unit), do: "#{Float.round(rate / 1, 1)}" <> unit

  @doc "A displayed byte rate, `2.3 KB/s`, or nil while the bytes are unmeasured."
  def byte_rate_label(nil), do: nil
  def byte_rate_label(bytes), do: Format.bytes(round(bytes)) <> "/s"

  @doc """
  A relay's traffic one way (`:in` or `:out`) from its rates: messages a
  second and, where the controller counts them, bytes — `4.0 msgs/s · 2.3 KB/s`.
  """
  def traffic_label(rate, way) do
    [rate_label(Map.fetch!(rate, way)), byte_rate_label(Map.get(rate, @bytes_of[way]))]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

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
      %{streaming: :streaming, trickling: :trickle, quiet: :quiet}[Map.get(modes, :in, :quiet)]
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
  defp sentence(:stuck, _history, _rates, _input),
    do: "The runner's channel has no credit left, so the relay cannot hand records on."

  defp sentence(:failing, history, _rates, _input) do
    {parked, taken} = parked_of_taken(history)
    share = if taken > 0, do: "#{round(min(parked / taken, 1) * 100)}% of", else: "records beyond"

    "#{share} what came in over the last two ticks was parked in the dead-letter queue."
  end

  defp sentence(:quiet, history, _rates, input) do
    seen = input |> Map.get(:seen, %{}) |> Map.get(:in)

    cond do
      history == [] -> "Measuring: rates appear after the second reading."
      is_nil(seen) -> "No record has come in since this page opened."
      true -> "No record has come in for #{ago(Map.get(input, :now, seen) - seen)}."
    end
  end

  defp sentence(_moving, history, rates, _input) do
    filtered = smoothed(history, :filtered) || 0
    taken = rates.in || 0

    "#{traffic_label(%{rates | in: taken}, :in)} in; " <>
      "#{traffic_label(%{rates | out: rates.out || 0}, :out)} delivered" <>
      if(filtered > 0 and taken > 0,
        do: ", #{round(min(filtered / taken, 1) * 100)}% skipped by its input filters.",
        else: "."
      )
  end

  @timeline_rows [in: "In", out: "Delivered", filtered: "Skipped", parked: "Parked"]
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
              {key, per_second(delta, seconds)}
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
    bytes = Enum.filter(@counted_bytes, fn {_key, slot} -> Map.has_key?(entry, slot) end)

    Map.new(@counted ++ bytes, fn {key, slot} ->
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

  # What the relay's input filters have skipped since its counters started.
  defp skipped_total(input) do
    case relay_counters(input.snapshot, input.relay_id) do
      %{} = counters -> Map.get(counters, :filtered_nil, 0)
      nil -> 0
    end
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
  One relay's pipeline: its controls, the graph fitted to its panel with the
  Cell sheet over its right side, a sentence and a timeline of what the relay
  is doing, and a dock below them holding the selected node's inspector and
  the host's payload tap.

  `tapped` is the id of the port the host's tap is open on, which marks it;
  the `:tap` slot is where the host puts the tap itself. Nothing opened in the
  dock or the sheet moves a node.
  """
  attr :topology, :any, required: true
  attr :tapped, :string, default: nil, doc: "the node id of the port the open tap listens at"
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
        <span :if={pipeline?(@topology)} class="text-xs topo-muted" data-testid="topology-attached">
          {Words.count(@topology.plugin_count, "plugin")} attached<span
            :if={@topology.observer_count > 0}
            data-testid="topology-observer-count"
          > · {@topology.observer_count} listening</span>
        </span>
        <.view_controls :if={pipeline?(@topology)} topology={@topology} />
        <.legend :if={pipeline?(@topology)} />
      </:header>

      <.inside_line inside={@topology.inside} drawn?={@topology.inside in [nil, :disagree]} />

      <div
        id="topology-canvas"
        phx-hook="FlzPipeline"
        phx-mounted={JS.ignore_attributes(~w(data-focus style))}
        data-testid="topology-canvas"
        data-layout={@topology.layout_key}
        data-direction={@topology.direction}
        data-bounds={bounds_attr(@topology.bounds)}
        data-selected={@topology.selected_id}
        data-cells={@topology.cells && "tasklet-#{@topology.cells.tasklet}"}
        class="topo-canvas"
      >
        <svg
          id="topology-svg"
          viewBox={bounds_attr(@topology.bounds)}
          phx-mounted={JS.ignore_attributes(~w(viewBox))}
          preserveAspectRatio="xMinYMin meet"
          class="topo-svg"
          role="group"
          aria-label={"Pipeline of #{@topology.relay_id}, drawn #{direction_words(@topology.direction)}: sources feed its entry channels, tasklets hand records on, output channels end at plugins."}
        >
          <.boundary topology={@topology} />
          <g class="topo-nets">
            <.net :for={net <- @topology.nets} net={net} />
            <.dead_letter_wire dlq={@topology.dlq} />
          </g>
          <g class="topo-labels" aria-hidden="true">
            <text
              :for={label <- @topology.labels}
              x={label.x}
              y={label.y}
              text-anchor={label.anchor}
              data-testid={label[:testid]}
              class={[
                "topo-halo",
                if(label.kind == :channel, do: "topo-chan", else: "topo-rate"),
                label[:rate] == 0 && "is-muted"
              ]}
            >
              {label.text}<tspan :if={label[:more] && !label[:stacked?]}> · {label.more}</tspan>
              <tspan
                :if={label[:more] && label[:stacked?]}
                x={label.x}
                dy="12"
              >
                {label.more}
              </tspan>
            </text>
          </g>
          <g class="topo-nodes">
            <.graph_node :for={node <- @topology.nodes} node={node} tapped={@tapped} />
            <.dead_letter dlq={@topology.dlq} />
          </g>
          <.edge_marks topology={@topology} />
        </svg>
        <div id="topology-motion" class="topo-motion" phx-update="ignore" aria-hidden="true">
          <canvas></canvas>
          <style>
          </style>
        </div>
        <.cell_sheet :if={@topology.cells} cells={@topology.cells} />
      </div>

      <.flow_state flow={@topology.flow} timeline={@topology.timeline} />

      <div data-testid="topology-dock" class="grid gap-4 md:grid-cols-2">
        <.detail :if={@topology.selected} node={@topology.selected} expanded?={@topology.expanded?} />
        {render_slot(@tap)}
        <p :if={!@topology.selected and is_nil(@tapped)} class="text-xs topo-muted md:col-span-2">
          Select a node to inspect it, a tasklet to see its Cells, or a channel port to tap the
          records passing it.
        </p>
      </div>
    </.graph_frame>
    """
  end

  defp pipeline?(topology), do: topology && topology.kind == :pipeline

  defp bounds_attr(%{x: x, y: y, w: w, h: h}), do: "#{r1(x)} #{r1(y)} #{r1(w)} #{r1(h)}"

  defp direction_words("TB"), do: "top to bottom"
  defp direction_words(_lr), do: "left to right"

  attr :topology, :map, required: true

  # The viewer's own controls: they change the view, never the layout, and
  # only the direction reaches the server.
  defp view_controls(assigns) do
    ~H"""
    <div class="topo-tools">
      <span class="text-xs topo-muted font-mono" data-testid="topology-direction">
        {direction_words(@topology.direction)}{if @topology.view.direction == "auto", do: " (auto)"}
      </span>
      <div
        class="topo-seg"
        role="group"
        aria-label="Direction"
        data-testid="topology-direction-control"
      >
        <button
          :for={
            {value, label} <- [{"auto", "Auto"}, {"LR", "Left to right"}, {"TB", "Top to bottom"}]
          }
          type="button"
          data-dir={value}
          data-testid={"topology-dir-#{value}"}
          aria-pressed={to_string(@topology.view.direction == value)}
        >
          {label}
        </button>
      </div>
      <div class="topo-seg" role="group" aria-label="Zoom">
        <button type="button" data-zoom="out" aria-label="Zoom out" data-testid="topology-zoom-out">
          −
        </button>
        <span id="topology-zoom" phx-update="ignore" class="topo-zoom" data-testid="topology-zoom">
          100%
        </span>
        <button type="button" data-zoom="in" aria-label="Zoom in" data-testid="topology-zoom-in">
          +
        </button>
        <button type="button" data-zoom="fit" data-testid="topology-fit">Fit</button>
        <button type="button" data-zoom="one" data-testid="topology-one">100%</button>
      </div>
      <button
        type="button"
        class="topo-seg-button"
        data-zoom="full"
        data-testid="topology-full"
        aria-pressed="false"
        phx-mounted={JS.ignore_attributes(~w(aria-pressed))}
      >
        Full screen
      </button>
    </div>
    """
  end

  attr :topology, :map, required: true

  # The relay's edge, and its header: the one place it is selected.
  defp boundary(assigns) do
    ~H"""
    <rect
      x={r1(@topology.box.x)}
      y={r1(@topology.box.y)}
      width={r1(@topology.box.w)}
      height={r1(@topology.box.h)}
      rx="10"
      class={["topo-boundary-outline", @topology.stalled? && "is-stalled"]}
      data-testid={@topology.stalled? && "topo-stall-marker"}
    />
    <g
      data-testid="topo-node-relay"
      data-node="relay"
      role="button"
      tabindex="0"
      aria-label={"Relay #{@topology.relay_id}, factory #{@topology.factory || "—"}, details"}
      aria-pressed={to_string(@topology.selected_id == "relay")}
      phx-click="graph_select"
      phx-keydown="graph_select"
      phx-key="Enter"
      phx-value-id="relay"
      class={["topo-head", @topology.selected_id == "relay" && "is-selected"]}
    >
      <text
        x={r1(@topology.head.x)}
        y={r1(@topology.head.y)}
        text-anchor={@topology.head.anchor}
        class="topo-title"
      >
        {@topology.relay_id}
      </text>
      <text
        x={r1(@topology.head.x)}
        y={r1(@topology.head.y + 15)}
        text-anchor={@topology.head.anchor}
        class="topo-sub"
      >
        factory {@topology.factory || "—"}
      </text>
    </g>
    """
  end

  attr :net, :map, required: true

  # One net: a halo in the canvas colour first, so where a later net crosses
  # an earlier one the earlier line is visibly cut, then the line, the dots
  # where it splits, and a wide hit path per wire that carries its geometry
  # for the motion layer and its tooltip.
  defp net(assigns) do
    ~H"""
    <g
      class={["topo-net", @net.idle? && "is-idle"]}
      data-net={@net.id}
      data-ends={Enum.join(@net.ends, " ")}
      data-c={@net.colour}
      data-testid={"topo-net-#{@net.id}"}
    >
      <path d={@net.d} class="topo-wire-halo" />
      <path d={@net.d} class={["flz-graph-wire", "topo-wire", wire_style(@net.kind)]} />
      <circle :for={j <- @net.junctions} cx={j.x} cy={j.y} r="2.8" class="topo-junction" />
      <path
        :for={w <- @net.wires}
        d={w.d}
        class="topo-hit"
        data-testid={"topo-wire-#{w.id}"}
        data-wire={w.id}
        data-from={w.from}
        data-to={w.to}
        data-entry={w.entry}
        data-kind={w.kind}
        data-key={w.key}
        data-mode={w.mode}
        data-rate={w.rate}
        data-pts={w.pts}
      >
        <title>{w.title}</title>
      </path>
    </g>
    """
  end

  defp wire_style(:skip), do: "topo-wire--skip"
  defp wire_style(:edge), do: "flz-graph-wire--state"
  defp wire_style(_kind), do: nil

  attr :dlq, :map, required: true

  defp dead_letter_wire(assigns) do
    ~H"""
    <g class="topo-net" data-net="dead-letter" data-ends="relay dead-letter">
      <path
        d={@dlq.d}
        class={["flz-graph-wire", "topo-wire", "topo-wire--dlq", @dlq.parked == 0 && "is-idle"]}
      />
      <path
        d={@dlq.d}
        class="topo-hit"
        data-wire="relay>dead-letter"
        data-from="relay"
        data-to="dead-letter"
        data-kind="dlq"
        data-mode="quiet"
        data-pts={@dlq.pts}
      >
        <title>Records a tasklet failed on, parked in the dead-letter queue</title>
      </path>
    </g>
    """
  end

  attr :dlq, :map, required: true

  defp dead_letter(assigns) do
    ~H"""
    <.link
      navigate={~p"/dlq"}
      data-testid="topo-node-dead-letter"
      data-node="dead-letter"
      data-next=""
      data-prev=""
      aria-label={"Dead letter: #{@dlq.parked} parked, open the dead-letter queue"}
      class={["topo-n", "topo-n-bin", @dlq.parked > 0 && "is-hot"]}
    >
      <g class={["flz-graph-node", "flz-graph-node--state", @dlq.parked == 0 && "is-muted"]}>
        <rect x={@dlq.x} y={@dlq.y} width={@dlq.w} height={@dlq.h} rx="4" />
        <text x={r1(@dlq.x + 12)} y={r1(@dlq.y + 19)} class="topo-label">Dead letter</text>
        <text x={r1(@dlq.x + 12)} y={r1(@dlq.y + 34)} class="topo-sub">{@dlq.parked} parked</text>
      </g>
    </.link>
    """
  end

  attr :node, :map, required: true
  attr :tapped, :string, required: true

  # A port taps the records passing it; every other node is selected.
  defp graph_node(%{node: %{type: type}} = assigns) when type in [:entry, :exit] do
    tapped? = assigns.tapped == assigns.node.id

    assigns =
      assign(assigns,
        tapped?: tapped?,
        event: if(tapped?, do: "graph_tap_close", else: "graph_tap"),
        direction: if(type == :entry, do: "input", else: "output")
      )

    ~H"""
    <g
      data-testid={"topo-node-#{@node.id}"}
      role="button"
      tabindex="0"
      aria-pressed={to_string(@tapped?)}
      aria-label={port_name(@node, @tapped?)}
      phx-click={@event}
      phx-keydown={@event}
      phx-key="Enter"
      phx-value-port={@node.id}
      phx-value-direction={@direction}
      {nav_attrs(@node)}
      class={[
        "topo-n",
        "topo-port",
        "topo-n-#{@node.type}",
        @node.unbound? && "is-unbound",
        @tapped? && "is-tapped",
        @node.selected? && "is-selected"
      ]}
    >
      <title>{port_name(@node, @tapped?)}</title>
      <circle class="topo-port-hit" cx={r1(@node.x)} cy={r1(@node.y)} r="14" />
      <circle class="topo-port-ring" cx={r1(@node.x)} cy={r1(@node.y)} r="6.5" />
      <circle class="topo-port-core" cx={r1(@node.x)} cy={r1(@node.y)} r="2.6" />
      <text
        x={r1(@node.tag.x)}
        y={r1(@node.tag.y)}
        text-anchor={@node.tag.anchor}
        class="topo-chan topo-halo"
      >
        {@node.label}
      </text>
      <text
        :if={@tapped?}
        data-testid={"topo-tapping-#{@node.id}"}
        x={r1(@node.tag.x)}
        y={r1(@node.tag.y + 13)}
        text-anchor={@node.tag.anchor}
        class="topo-tapping topo-halo"
      >
        tapping
      </text>
    </g>
    """
  end

  defp graph_node(assigns) do
    ~H"""
    <g
      data-testid={"topo-node-#{@node.id}"}
      role="button"
      tabindex="0"
      aria-label={node_name(@node)}
      aria-pressed={to_string(@node.selected?)}
      phx-click="graph_select"
      phx-keydown="graph_select"
      phx-key="Enter"
      phx-value-id={@node.id}
      {nav_attrs(@node)}
      class={["topo-n", "topo-n-#{@node.type}", @node.selected? && "is-selected"]}
    >
      <title>{node_name(@node)}</title>
      <g class={node_class(@node)}>
        <rect
          :for={offset <- if(@node.stacked?, do: [6, 3], else: [])}
          x={r1(@node.x - @node.w / 2 + offset)}
          y={r1(text_y(@node) - offset)}
          width={r1(@node.w - 6)}
          height={r1(@node.h - 6)}
          rx="4"
          class="topo-card"
        />
        <rect
          x={r1(@node.x - @node.w / 2)}
          y={r1(text_y(@node))}
          width={r1(@node.w - if(@node.stacked?, do: 6, else: 0))}
          height={r1(@node.h - if(@node.stacked?, do: 6, else: 0))}
          rx="4"
        />
        <text x={r1(text_x(@node))} y={r1(text_y(@node) + 19)} class="topo-label">{@node.label}</text>
        <text
          :if={@node.rate}
          data-testid={"topo-rate-#{@node.id}"}
          x={r1(@node.x + @node.w / 2 - 10 - if(@node.stacked?, do: 6, else: 0))}
          y={r1(text_y(@node) + 19)}
          text-anchor="end"
          class="topo-rate"
        >
          {@node.rate}
        </text>
        <text x={r1(text_x(@node))} y={r1(text_y(@node) + 34)} class="topo-sub">{@node.sub}</text>
      </g>
      <text
        :if={@node.mark}
        data-testid={"topo-mark-#{@node.id}"}
        x={r1(@node.x - @node.w / 2)}
        y={r1(@node.y - @node.h / 2 - 6)}
        class="topo-mark"
      >
        {@node.mark}
      </text>
      <.node_badges node={@node} />
    </g>
    """
  end

  defp text_x(node), do: node.x - node.w / 2 + 12
  # A stack's front card is centred on the node's line, the cards behind it
  # stepping up and to the right.
  defp text_y(%{stacked?: true} = node), do: node.y - (node.h - 6) / 2
  defp text_y(node), do: node.y - node.h / 2

  attr :node, :map, required: true

  # Badges ride the card's lower edge, so a tick that brings one moves
  # nothing.
  defp node_badges(assigns) do
    assigns =
      assign(assigns,
        placed:
          assigns.node.badges
          |> Enum.map_reduce(assigns.node.x - assigns.node.w / 2 + 12, fn {kind, text}, x ->
            w = String.length(text) * 6.2 + 12
            {%{kind: kind, text: text, x: x, w: w}, x + w + 6}
          end)
          |> elem(0)
      )

    ~H"""
    <g
      :for={badge <- @placed}
      class={["topo-badge", "is-#{badge.kind}"]}
      data-testid={"topo-#{badge.kind}-#{@node.label}"}
    >
      <rect
        x={r1(badge.x)}
        y={r1(@node.y + @node.h / 2 - 8)}
        width={r1(badge.w)}
        height="15"
        rx="7.5"
      />
      <text x={r1(badge.x + badge.w / 2)} y={r1(@node.y + @node.h / 2 + 3)} text-anchor="middle">
        {badge.text}
      </text>
    </g>
    """
  end

  defp nav_attrs(node) do
    %{
      "data-node" => node.id,
      "data-rank" => node.rank,
      "data-order" => node.order,
      "data-next" => Enum.join(node.next, " "),
      "data-prev" => Enum.join(node.prev, " ")
    }
  end

  defp port_name(node, tapped?) do
    kind = if node.type == :entry, do: "Entry channel", else: "Output channel"

    [
      "#{kind} #{node.label}",
      node.unbound? && "no plugin bound",
      node.call? && "a call",
      if(tapped?,
        do: "your tap is open here, select to close it",
        else: "select to tap its records"
      )
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp node_name(node) do
    kind =
      %{
        tasklet: "Tasklet",
        run: "Folded run of",
        source: "Source",
        filter: "Input filter",
        skip: "End",
        plugin: "Output plugin",
        unbound: "Output channel end,",
        call: "Called relay",
        answer: "Answer from",
        hollow: "Relay"
      }[node.type]

    action =
      case node.type do
        :tasklet -> "open its Cells"
        :run -> "expand it"
        _other -> "inspect it"
      end

    [
      kind,
      node[:full] || node.label,
      node.sub,
      node.rate,
      node.mark | Enum.map(node.badges, &elem(&1, 1))
    ]
    |> Enum.concat([action])
    |> Enum.filter(&(&1 not in [nil, false, ""]))
    |> Enum.join(", ")
  end

  # The stylebook's relay-graph roles: a plugin, a tasklet, and the ends a
  # record path drains into.
  defp node_class(node) do
    role =
      case node.type do
        type when type in [:tasklet, :run] -> "tasklet"
        type when type in [:source, :filter, :plugin, :call, :answer] -> "plugin"
        _end -> "state"
      end

    ["flz-graph-node", "flz-graph-node--#{role}", "topo-node-#{node.type}"]
  end

  attr :topology, :map, required: true

  # Who listens at the boundary's edges, and its backpressure mark.
  defp edge_marks(assigns) do
    ~H"""
    <text
      :for={{edge, mark} <- listened(@topology.edges)}
      data-testid={"topo-observers-#{edge}"}
      data-count={length(mark.ids)}
      x={r1(mark.x)}
      y={r1(mark.y)}
      text-anchor={if edge == :out, do: "end", else: "start"}
      class="topo-observers"
      tabindex="0"
      aria-label={"#{length(mark.ids)} listening #{observer_edge(edge)}: #{Enum.join(mark.ids, ", ")}"}
    >
      <title>Listening {observer_edge(edge)}: {Enum.join(mark.ids, ", ")}</title>
      {length(mark.ids)} listening {observer_edge(edge)}
    </text>
    <circle
      :if={@topology.edges.backpressure}
      data-testid="topo-backpressure"
      cx={r1(@topology.edges.backpressure.x)}
      cy={r1(@topology.edges.backpressure.y)}
      r="6"
      class="topo-backpressure"
    >
      <title>The runner's channel has no credit left: records wait to leave the relay</title>
    </circle>
    """
  end

  defp listened(edges),
    do:
      for(
        {edge, %{ids: [_ | _]} = mark} <- [in: edges.in, out: edges.out, calls: edges.calls],
        do: {edge, mark}
      )

  defp observer_edge(:in), do: "to inputs"
  defp observer_edge(:out), do: "to outputs"
  defp observer_edge(:calls), do: "to calls"

  attr :cells, :map, required: true

  # A tasklet's Cells, read from the runner only while this sheet is open.
  defp cell_sheet(assigns) do
    ~H"""
    <aside
      id="topology-cells"
      data-testid="topology-cells"
      class="topo-cells"
      aria-label={"Cells of #{@cells.tasklet}"}
    >
      <div class="topo-cells-head">
        <div class="flex items-start justify-between gap-3">
          <h3 class="font-mono text-sm topo-primary break-all">{@cells.tasklet}</h3>
          <.close_button
            on_close="graph_cells_close"
            close_testid="cells-close"
            close_label="Close Cells"
          />
        </div>
        <p class="text-xs font-mono topo-muted" data-testid="cells-meta">
          {@cells.caption}{if @cells.rate, do: " · takes in #{@cells.rate}"}{if @cells.parked > 0,
            do: " · #{Words.count(@cells.parked, "dead letter")}"}
        </p>
        <div :if={@cells.hops != []} class="topo-hops">
          <button
            :for={hop <- @cells.hops}
            type="button"
            class="topo-hop"
            data-testid={"cells-hop-#{hop.tasklet}"}
            phx-click="graph_select"
            phx-value-id={"tasklet-#{hop.tasklet}"}
          >
            {hop.label}
          </button>
        </div>
      </div>
      <div class="topo-cells-body">
        <table :if={@cells.rows != []} class="topo-cells-table">
          <thead>
            <tr>
              <th
                :for={{by, label} <- cell_columns()}
                scope="col"
                aria-sort={if @cells.sort == by, do: sort_word(by)}
              >
                <button
                  type="button"
                  phx-click="graph_cells_sort"
                  phx-value-by={by}
                  data-testid={"cells-sort-#{by}"}
                >
                  {label}
                </button>
              </th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @cells.rows}
              class={row.fresh? && "is-fresh"}
              data-testid={"cell-#{row.key}"}
            >
              <td class="topo-cell-key" title={row.key}>{row.key}</td>
              <td>{rate_label(row.rate, "/s") || "—"}</td>
              <td class={figure_class(row.queued)}>{row.queued}</td>
              <td class={figure_class(row.blocked)}>{row.blocked}</td>
              <td class={figure_class(row.dropped)}>{row.dropped}</td>
              <td>{cell_ago(row.ago_ms)}</td>
            </tr>
          </tbody>
        </table>
        <p
          :if={@cells.note == :not_reported}
          data-testid="cells-not-reported"
          class="p-4 text-sm topo-muted"
        >
          This runner does not report its Cells. The tasklet's own figures still show on the graph.
        </p>
        <p :if={@cells.note == :unread} class="p-4 text-sm topo-muted">
          Its Cells could not be read this tick; the next one tries again.
        </p>
      </div>
      <p class="topo-cells-foot text-xs topo-muted" data-testid="cells-foot">
        <span :if={@cells.total > length(@cells.rows)}>
          Showing the {length(@cells.rows)} most recently active of {@cells.total} Cells.
        </span>
        The runner reads these from counters each Cell already keeps, only while this table is open.
      </p>
    </aside>
    """
  end

  defp cell_columns,
    do: [
      {"key", "Key"},
      {"rate", "In"},
      {"queued", "Queued"},
      {"blocked", "Blocked"},
      {"dropped", "Dropped"},
      {"ago", "Last in"}
    ]

  defp sort_word(by) when by in ~w(key ago), do: "ascending"
  defp sort_word(_by), do: "descending"

  defp figure_class(0), do: "is-zero"
  defp figure_class(_n), do: "is-hot"

  defp cell_ago(nil), do: "never"
  defp cell_ago(ms) when ms < 1_000, do: "now"
  defp cell_ago(ms) when ms < 60_000, do: "#{div(ms, 1_000)} s ago"
  defp cell_ago(ms), do: "#{Format.duration(ms)} ago"

  attr :inside, :any, required: true
  attr :drawn?, :boolean, required: true

  # The words for what the graph draws, where it first uses them, or why the
  # relay's inside is empty.
  defp inside_line(assigns) do
    ~H"""
    <p :if={@drawn?} data-testid="topology-inside" class="text-sm topo-secondary">
      Records come from its <.term key="source plugin">sources</.term>, pass any <.term key="input filter">input filters</.term>, enter on its <.term key="entry channel">entry channels</.term>, pass its
      <.term key="tasklet">tasklets</.term>
      and leave on its
      <.term key="output channel">output channels</.term>
      for the plugins bound to them. Select a tasklet to see its <.term key="cell">Cells</.term>.
      <span :if={@inside == :disagree} data-testid="topology-inside-disagree">
        Its runners announce different graphs; the latest is drawn.
      </span>
    </p>
    <p :if={not @drawn?} data-testid="topology-inside-note" class="text-sm topo-muted">
      The relay's inside is not shown: {code_names(inside_reason(@inside))}
    </p>
    """
  end

  defp inside_reason({:not_announced, factory}),
    do: "the runners of factory #{factory || "—"} announced no graph."

  defp inside_reason(:not_supported), do: "this controller does not report relay graphs."

  defp inside_reason({:unreadable, reason}),
    do: "its graph could not be read. #{NodeManager.error(reason).message}"

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
        <p class="flz-label">
          Tapping
          <span class="font-mono">{@tap.direction}</span><span
            :if={@tap.channel}
            class="font-mono"
          > · {if @tap.all?, do: "every channel", else: @tap.channel}</span>
        </p>
      </:head>

      <button
        :if={@tap.channel && not @tap.all?}
        type="button"
        phx-click="graph_tap_all"
        data-testid="tap-all"
        class="flz-button flz-button--sm flz-button--ghost"
      >
        Show every channel
      </button>

      <div :if={@tap.error} data-testid="tap-error">
        <.runtime_error error={@tap.error} action="the payload tap" />
      </div>

      <dl data-testid="tap-figures" class="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
        <dt class="topo-muted">Messages</dt>
        <dd data-testid="tap-msg-count" class="topo-secondary font-mono text-right">
          {@tap.count}
        </dd>
        <dt class="topo-muted">Total</dt>
        <dd class="topo-secondary font-mono text-right">{Format.bytes(@tap.bytes)}</dd>
        <dt class="topo-muted">Rate</dt>
        <dd data-testid="tap-msg-rate" class="topo-primary font-mono text-right">
          {tap_rate(@tap, :count)} msgs/s
        </dd>
        <dt class="topo-muted">Throughput</dt>
        <dd data-testid="tap-byte-rate" class="topo-primary font-mono text-right">
          {byte_rate_label(tap_rate(@tap, :bytes))}
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

  # A tap's `field` per second over the tap's own window: nothing counts bytes
  # on the data plane, so this is what the listener delivered while attached.
  defp tap_rate(tap, field) do
    elapsed = max(System.monotonic_time(:millisecond) - tap.started_at, 1) / 1_000

    Float.round(Map.fetch!(tap, field) / elapsed, 1)
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
        <.close_button on_close={@on_close} close_testid={@close_testid} close_label={@close_label} />
      </div>
      {render_slot(@inner_block)}
    </aside>
    """
  end

  attr :on_close, :string, required: true
  attr :close_testid, :string, required: true
  attr :close_label, :string, required: true

  defp close_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click={@on_close}
      data-testid={@close_testid}
      class="flz-button flz-button--sm flz-button--ghost"
      aria-label={@close_label}
    >
      <.icon name="hero-x-mark" class="w-4 h-4" />
    </button>
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
    <div
      id={"#{@testid}-frame"}
      data-testid={@testid}
      class="flz-panel topo-frame overflow-hidden"
      phx-mounted={JS.ignore_attributes(~w(data-full))}
    >
      <div class="flz-panel-head">
        <h2 class="flz-panel-title"><.icon name={@icon} class="w-4 h-4" />{@title}</h2>
        <div :if={@header != []} class="flex flex-wrap items-center gap-3">
          {render_slot(@header)}
        </div>
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

  # Every role, port, wire style, mark and motion form the graph draws.
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
        <li>
          <svg width="26" height="14" class="shrink-0" aria-hidden="true">
            <rect x="1" y="1" width="24" height="12" class="topo-boundary-outline" />
          </svg>
          The relay: everything inside its dashed edge runs on its runner
        </li>
        <li>
          <span class="flz-graph-legend-tasklet" aria-hidden="true"></span>A tasklet with one Cell
        </li>
        <li>
          <svg width="28" height="18" class="shrink-0" aria-hidden="true">
            <g class="flz-graph-node flz-graph-node--tasklet">
              <rect x="7" y="1" width="20" height="12" rx="2" class="topo-card" />
              <rect x="1" y="5" width="20" height="12" rx="2" />
            </g>
          </svg>
          A tasklet with several Cells; select it for its Cell table
        </li>
        <li>
          <svg width="26" height="14" class="shrink-0" aria-hidden="true">
            <g class="flz-graph-node flz-graph-node--tasklet topo-node-run">
              <rect x="1" y="1" width="24" height="12" rx="2" />
            </g>
          </svg>
          A folded run of four or more tasklets in a row; select it to expand
        </li>
        <li>
          <span class="flz-graph-legend-plugin" aria-hidden="true"></span>A plugin: a source feeding the
          relay, an input filter, or an output plugin
        </li>
        <li>
          <svg width="26" height="14" class="shrink-0" aria-hidden="true">
            <g class="flz-graph-node flz-graph-node--state">
              <rect x="1" y="1" width="24" height="12" rx="2" />
            </g>
          </svg>
          An end: skipped by an input filter, no plugin bound, or the dead letters
        </li>
        <li>
          <svg width="26" height="14" class="shrink-0" aria-hidden="true">
            <g class="topo-port">
              <circle cx="13" cy="7" r="5.5" class="topo-port-ring" /><circle
                cx="13"
                cy="7"
                r="2.2"
                class="topo-port-core"
              />
            </g>
          </svg>
          A channel port on the relay's edge; select it to tap the records passing
        </li>
        <li>
          <svg width="26" height="10" class="shrink-0" aria-hidden="true">
            <line x1="0" y1="5" x2="26" y2="5" class="flz-graph-wire topo-wire" />
            <circle cx="13" cy="5" r="2.8" class="topo-junction" />
          </svg>
          A wire, coloured apart from its neighbours; a dot where a channel splits
        </li>
        <li>
          <svg width="26" height="10" class="shrink-0" aria-hidden="true">
            <circle cx="13" cy="5" r="3.5" class="topo-legend-mark" />
          </svg>
          A record passing; its speed is not the record's, which crosses in microseconds
        </li>
        <li>
          <svg width="26" height="10" class="shrink-0" aria-hidden="true">
            <line x1="0" y1="5" x2="26" y2="5" class="topo-legend-flow" />
          </svg>
          A busy wire, twelve or more records a second, flowing continuously
        </li>
        <li>
          <span class="topo-legend-badge is-parked" aria-hidden="true">3</span> Dead letters a
          tasklet parked
        </li>
        <li>
          <span class="topo-legend-badge is-backlog" aria-hidden="true">40</span> A backlog: inputs
          waiting at a tasklet
        </li>
        <li>
          <span class="topo-legend-badge is-shed" aria-hidden="true">3</span> Inputs a tasklet
          dropped since the last reading
        </li>
        <li>
          <span class="topo-observers" aria-hidden="true">1 listening</span>
          Listeners watching an edge of
          the relay
        </li>
      </ul>
    </.popover>
    """
  end

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

  # ---- The inspector ----

  attr :node, :map, required: true
  attr :expanded?, :boolean, required: true

  defp detail(assigns) do
    ~H"""
    <.dock_panel
      testid="topology-detail"
      on_close="graph_dismiss"
      close_testid="topology-detail-dismiss"
      close_label="Close detail"
    >
      <:head>
        <p class="flz-label">{kind_label(@node.type)}</p>
        <p class="text-sm font-mono topo-primary break-all">{@node.label}</p>
      </:head>

      <.relay_detail :if={@node.type == :relay} node={@node} expanded?={@expanded?} />
      <.source_detail :if={@node.type == :source} node={@node} />
      <.plugin_detail :if={@node.type in [:filter, :plugin]} node={@node} />
      <.port_detail :if={@node.type in [:entry, :exit]} node={@node} />
      <.end_detail :if={@node.type in [:skip, :unbound, :call, :answer]} node={@node} />
    </.dock_panel>
    """
  end

  defp kind_label(:relay), do: "relay"
  defp kind_label(:source), do: "source"
  defp kind_label(:filter), do: "input filter"
  defp kind_label(:skip), do: "skipped by filter"
  defp kind_label(:entry), do: "entry channel"
  defp kind_label(:exit), do: "output channel"
  defp kind_label(:plugin), do: "output plugin"
  defp kind_label(:unbound), do: "no plugin bound"
  defp kind_label(type) when type in [:call, :answer], do: "called relay"

  attr :node, :map, required: true
  attr :expanded?, :boolean, required: true

  defp relay_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Factory">{@node.facts.factory_id || "—"}</.fact>
      <.fact label="Runner">{@node.facts.runner_id || "—"}</.fact>
      <.fact label="Run">{@node.facts.run || "—"}</.fact>
      <.fact label="Uptime">{Format.duration(@node.facts.uptime_ms)}</.fact>
      <.fact label="State">{if @node.facts.suspended, do: "suspended", else: "running"}</.fact>
      <.fact label="In">{rate_text(@node.rates, :in)}</.fact>
      <.fact label="Out">{rate_text(@node.rates, :out)}</.fact>
      <.fact :if={@node.counters} label="Received">
        {Map.get(@node.counters, :io_in_received, 0)}
      </.fact>
      <.fact :if={@node.counters} label="Forwarded">{Map.get(@node.counters, :forwarded, 0)}</.fact>
      <.fact :if={@node.counters} label="Skipped by filters">
        {Map.get(@node.counters, :filtered_nil, 0)}
      </.fact>
      <.fact :if={@node.calls != []} label="Listening to calls">{Enum.join(@node.calls, ", ")}</.fact>
    </dl>

    <dl :if={@node.channel} data-testid="topology-channel" class="space-y-1 text-xs">
      <.fact label="Runner channel">{@node.channel.name}</.fact>
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
    <p :if={is_nil(@node.channel)} class="text-xs topo-muted">
      No channel counters reported for this relay's runner.
    </p>

    <div :if={@node.lifecycle != []} data-testid="topology-lifecycle" class="space-y-1">
      <p class="text-xs topo-muted">Bound off the record path:</p>
      <dl class="space-y-1 text-xs">
        <.fact :for={l <- @node.lifecycle} label={l.plugin_id}>
          {Enum.join(l.hooks, ", ")} · {short_provider(l.provider)}
        </.fact>
      </dl>
    </div>

    <div class="flex flex-wrap gap-2">
      <.link
        navigate={@node.listen}
        data-testid="topology-detail-link"
        class="flz-button flz-button--sm flz-button--ghost"
      >
        Listen <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
      </.link>
      <.link
        navigate={@node.runner}
        data-testid="topology-runner-link"
        class="flz-button flz-button--sm flz-button--ghost"
      >
        Open cluster <.icon name="hero-arrow-top-right-on-square" class="w-3 h-3" />
      </.link>
      <button
        :if={@expanded?}
        type="button"
        phx-click="graph_fold"
        data-testid="topology-fold"
        class="flz-button flz-button--sm flz-button--ghost"
      >
        Fold the expanded runs again
      </button>
    </div>
    """
  end

  attr :node, :map, required: true

  defp source_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Provider">{@node.source.provider}</.fact>
      <.fact label="Feeds">{@node.source.entry || "—"}</.fact>
      <.fact :if={@node.source.hooks != []} label="Also bound to">
        {Enum.join(@node.source.hooks, ", ")}
      </.fact>
    </dl>
    <p class="text-xs topo-muted" data-testid="topology-source-note">
      A source feeds the relay on its own.{if @node.source.unnamed? and @node.source.entry,
        do:
          " Its options name no channel, so it feeds the relay's first entry channel, #{@node.source.entry}."}{if @node.source.missing !=
                                                                                                                    [],
                                                                                                                  do:
                                                                                                                    " The relay has no entry channel #{Enum.join(@node.source.missing, ", ")}, so it is drawn on the relay as a whole."}
    </p>
    """
  end

  attr :node, :map, required: true

  defp plugin_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Provider">{@node.plugin.provider}</.fact>
      <.fact label="Hook">{@node.plugin.hook}</.fact>
      <.fact label="Position">{@node.plugin.position || "—"}</.fact>
      <.fact label="Channels">{plugin_channels(@node.plugin)}</.fact>
      <.fact :if={@node.type == :filter} label="Skipped">{@node.skipped}</.fact>
      <.fact :if={length(@node.plugin.hooks) > 1} label="Also bound to">
        {@node.plugin.hooks |> Enum.reject(&(&1 == @node.plugin.hook)) |> Enum.join(", ")}
      </.fact>
    </dl>

    <p :if={@node.plugin.missing != []} data-testid="topology-plugin-missing" class="text-xs">
      The relay has no channel named <span class="font-mono">{Enum.join(@node.plugin.missing, ", ")}</span>{if @node.plugin.attached,
        do: ", so this plugin is drawn on the relay as a whole",
        else: ""}.
    </p>

    <p :if={@node.type == :filter} class="text-xs topo-muted">
      The controller runs every on_input plugin before a record enters the relay. A record it
      skips never reaches a tasklet and is counted as skipped.
    </p>

    <p :if={@node.type == :plugin} data-testid="topology-plugin-order" class="text-xs topo-muted">
      The controller runs every on_output plugin in position order, and each acts only on the
      channels it names.
    </p>
    """
  end

  defp plugin_channels(%{every?: true}), do: "every channel"
  defp plugin_channels(plugin), do: listed(plugin.channels)

  attr :node, :map, required: true

  defp port_detail(assigns) do
    ~H"""
    <dl class="space-y-1 text-xs">
      <.fact label="Kind">{@node.channel.kind}</.fact>
      <.fact :if={@node.type == :exit} label="Written by">{@node.channel.producer || "—"}</.fact>
      <.fact label="Read by">{listed(@node.channel.consumers)}</.fact>
      <.fact :if={@node.type == :exit} label="Plugins">
        {listed(Enum.map(@node.bound, &"##{&1.position || 0} #{&1.plugin_id}"))}
      </.fact>
      <.fact label="Overflow">{@node.channel.overflow || "—"}</.fact>
    </dl>
    <p :if={@node.type == :exit and @node.channel.plugin_end == "call"} class="text-xs topo-muted">
      A call channel: each record is a call to {@node.channel.call_target}, whose answer comes
      back on an entry channel.
    </p>
    <p
      :if={@node.type == :exit and @node.channel.plugin_end != "call" and @node.bound == []}
      data-testid="topology-port-unbound"
      class="text-xs topo-muted"
    >
      No plugin is bound to it, so only a listener, such as the tap, sees its records.
    </p>
    """
  end

  attr :node, :map, required: true

  defp end_detail(assigns) do
    ~H"""
    <p :if={@node.type == :skip} class="text-xs topo-secondary">
      {@node.skipped} records skipped by the relay's input filters. They never reached a tasklet.
    </p>
    <p :if={@node.type == :unbound} class="text-xs topo-secondary">
      Nothing takes the records of <span class="font-mono">{@node.channel.name}</span>
      off the relay. Bind a plugin whose channel option names it to keep them.
    </p>
    <p :if={@node.type in [:call, :answer]} class="text-xs topo-secondary">
      The relay this one calls on <span class="font-mono">{@node.channel.name}</span>. It is
      drawn twice: where the call leaves, and where its answer comes back in.
    </p>
    """
  end

  defp listed([]), do: "—"
  defp listed(names), do: Enum.join(names, ", ")

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
  defp rate_text(rate, key), do: traffic_label(rate, key)

  # ---- Namespace map ----

  @map_w 1000
  @map_src_w 176
  @map_band_x 276
  @map_band_w 380
  @map_out_x 824
  @map_out_w 176
  @map_top 34
  @map_node_h 40
  @map_node_gap 12
  @map_band_head 40
  @map_lane_h 40
  @map_lane_gap 8
  @map_band_gap 18
  @map_lane_cap 12
  @map_band_cap 4
  @map_column_cap 8
  @map_stack_min 4
  @map_spark_w 56
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
  a stack lane, and a band or the zone draws at most #{@map_lane_cap} lanes
  and then "+N more". The runners with relays needing attention, then the
  busiest, get the first #{@map_band_cap} bands; the rest fold into one row. A
  partition group's copies of a plugin are one node, and each side column
  draws its #{@map_column_cap} most-wired plugins and then "+N more", so the
  map's height is bounded however many relays the namespace runs.
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
    namespace = input.namespace

    bindings = Map.new(rows, &{to_string(&1.id), relay_bindings(plugins, to_string(&1.id))})
    keys = plugin_keys(rows, bindings)

    keyed =
      Map.new(bindings, fn {id, list} ->
        {id, for({plugin_id, hooks} <- list, do: {keys[plugin_id], hooks})}
      end)

    runner_ids = MapSet.new(runners, &to_string(&1.id))

    {bound, unbound} =
      Enum.split_with(rows, &(&1[:runner] && MapSet.member?(runner_ids, to_string(&1.runner))))

    by_runner = Enum.group_by(bound, &to_string(&1.runner))
    lane = &map_lane(&1, input, rates, faulted, keyed)

    {bands, more_runners, y} =
      runner_bands(runners, by_runner, lane, expanded, namespace, selected)

    zone =
      case unbound |> Enum.map(lane) |> order_lanes() do
        [] -> nil
        lanes -> map_zone(lanes, ~p"/namespaces/#{namespace}/relays", y)
      end

    bands_bottom = if zone, do: zone.y + zone.h, else: y - @map_band_gap
    parked = Map.get(input, :parked, 0)
    drawn = drawn_lanes(bands, zone)
    plugins_href = ~p"/namespaces/#{namespace}/plugins"

    {source_nodes, source_ids} =
      [%{id: "calls", kind: :calls, label: "Calls and sends", sub: "from clients", inspect: nil}]
      |> Kernel.++(plugin_nodes(bindings, keys, "on_input", "in", plugins_href))
      |> cap_column(drawn, &source_ids/1, "more-in", "on_input", plugins_href)

    {output_nodes, output_ids} =
      bindings
      |> plugin_nodes(keys, "on_output", "out", plugins_href)
      |> Kernel.++([
        %{
          id: "stream",
          kind: :runner_stream,
          label: "Runner stream",
          sub: "to its clients",
          inspect: nil
        }
      ])
      |> cap_column(drawn, &output_ids/1, "more-out", "on_output", plugins_href)

    # Every column is centred on the tallest, so a short one sits level with
    # what it feeds instead of hanging from the top edge.
    bands_h = bands_bottom - @map_top
    src_h = column_height(length(source_nodes))
    out_h = column_height(length(output_nodes)) + drain_height(parked)
    content_h = Enum.max([bands_h, src_h, out_h])
    dy = div(content_h - bands_h, 2)

    bands = Enum.map(bands, &shift_block(&1, dy))
    zone = zone && shift_block(zone, dy)
    more_runners = more_runners && %{more_runners | y: more_runners.y + dy}
    lanes = bands |> drawn_lanes(zone) |> Enum.map(&mark_selected(&1, selected))

    # Each side node sits level with the lanes it is wired to, so wires run
    # across rather than diagonally over each other.
    sources =
      source_nodes
      |> order_by_lanes(lanes, source_ids)
      |> place_column(0, @map_src_w, @map_top + div(content_h - src_h, 2), selected)

    outputs =
      output_nodes
      |> order_by_lanes(lanes, output_ids)
      |> place_column(@map_out_x, @map_out_w, @map_top + div(content_h - out_h, 2), selected)

    drain = map_drain(parked, outputs)
    height = @map_top + content_h + @map_node_gap

    %{
      namespace: namespace,
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
      more_runners: more_runners,
      zone: zone && %{zone | lanes: Enum.map(zone.lanes, &mark_selected(&1, selected))},
      wires: map_wires(lanes, sources, outputs, rates, source_ids, output_ids)
    }
  end

  # A relay's declared plugin bindings, as `{plugin_id, [hook]}`.
  defp relay_bindings(pairs, relay_id) do
    for row <- NodeManager.declared_bindings(pairs, relay_id), do: {row.plugin_id, row.hooks}
  end

  defp bound_on(bindings, hook) do
    for {plugin_id, hooks} <- bindings, hook in hooks, do: plugin_id
  end

  # A partition group's members each bind their own copy of a plugin, named
  # with the member's suffix (`demo#p0` binds `ohlc#p0`): the map draws a
  # plugin's copies as one node, keyed by the name without that suffix.
  defp plugin_keys(rows, bindings) do
    for row <- rows, {plugin_id, _hooks} <- Map.get(bindings, to_string(row.id), []), into: %{} do
      {plugin_id, plugin_key(row, plugin_id)}
    end
  end

  defp plugin_key(%{id: id, partition: %{group: group}}, plugin_id) do
    suffix = String.replace_prefix(to_string(id), to_string(group), "")

    if suffix != "" and byte_size(plugin_id) > byte_size(suffix) and
         String.ends_with?(plugin_id, suffix),
       do: String.replace_suffix(plugin_id, suffix, ""),
       else: plugin_id
  end

  defp plugin_key(_row, plugin_id), do: plugin_id

  # One node per plugin bound on `hook`, or per set of a group's copies, which
  # opens the plugins screen rather than one copy.
  defp plugin_nodes(bindings, keys, hook, prefix, href) do
    bindings
    |> Map.values()
    |> Enum.flat_map(&bound_on(&1, hook))
    |> Enum.uniq()
    |> Enum.group_by(&keys[&1])
    |> Enum.sort()
    |> Enum.map(fn
      {key, [plugin_id]} ->
        %{
          id: "#{prefix}-#{key}",
          kind: :plugin,
          label: plugin_id,
          sub: hook,
          inspect: {:plugin, plugin_id}
        }

      {key, copies} ->
        %{
          id: "#{prefix}-#{key}",
          kind: :plugin,
          label: "#{key} ×#{length(copies)}",
          sub: "#{hook} · one per partition",
          inspect: nil,
          link: %{navigate: href}
        }
    end)
  end

  # A column draws its most-wired plugins, up to the cap, and folds the rest
  # into one "+N more" node that opens the plugins screen. Answers the nodes
  # and how a lane's ends resolve to them: a folded plugin's to that node.
  defp cap_column(nodes, lanes, ids_of, more_id, hook, href) do
    {plugins, fixed} = Enum.split_with(nodes, &(&1.kind == :plugin))
    wired = lanes |> Enum.flat_map(ids_of) |> Enum.frequencies()

    {kept, folded} =
      plugins
      |> Enum.sort_by(&{-Map.get(wired, &1.id, 0), &1.id})
      |> Enum.split(@map_column_cap)

    shown = MapSet.new(fixed ++ kept, & &1.id)

    more =
      if folded == [],
        do: [],
        else: [
          %{
            id: more_id,
            kind: :more,
            label: "+#{length(folded)} more",
            sub: hook,
            inspect: nil,
            link: %{navigate: href}
          }
        ]

    resolve = fn lane ->
      lane
      |> ids_of.()
      |> Enum.map(&if(MapSet.member?(shown, &1), do: &1, else: more_id))
      |> Enum.uniq()
    end

    {Enum.filter(nodes, &MapSet.member?(shown, &1.id)) ++ more, resolve}
  end

  # One band per runner, those with relays needing attention and then the
  # busiest first, down to the band cap; the rest fold into one row under them.
  # Answers the bands, that row (or nil) and where the next block starts.
  defp runner_bands(runners, by_runner, lane, expanded, namespace, selected) do
    {shown, folded} =
      runners
      |> Enum.map(fn runner ->
        id = to_string(runner.id)

        lanes =
          by_runner
          |> Map.get(id, [])
          |> Enum.map(lane)
          |> stack(id, expanded)
          |> order_lanes()

        {runner, lanes}
      end)
      |> Enum.sort_by(fn {runner, lanes} ->
        {if(Enum.any?(lanes, & &1.attention?), do: 0, else: 1), -length(lanes),
         to_string(runner.id)}
      end)
      |> Enum.split(@map_band_cap)

    {bands, y} =
      Enum.map_reduce(shown, @map_top, fn {runner, lanes}, y ->
        id = to_string(runner.id)
        {lanes, more} = Enum.split(lanes, @map_lane_cap)
        href = ~p"/namespaces/#{namespace}/relays?#{[runner: id]}"
        band = map_band(runner, lanes, more, href, y, selected)
        {band, y + band.h + @map_band_gap}
      end)

    {more_runners, y} = more_runners(folded, by_runner, y)
    {bands, more_runners, y}
  end

  defp drawn_lanes(bands, zone),
    do: Enum.flat_map(bands, & &1.lanes) ++ ((zone && zone.lanes) || [])

  # Runners past the band cap fold into one row under the bands,
  # counting their relays and pointing at the runners table below the map.
  defp more_runners([], _by_runner, y), do: {nil, y}

  defp more_runners(folded, by_runner, y) do
    relays =
      folded |> Enum.map(&length(Map.get(by_runner, to_string(elem(&1, 0).id), []))) |> Enum.sum()

    block = %{
      id: "more-runners",
      kind: :more,
      label: "+" <> FlezhaUiWeb.Words.count(length(folded), "more runner"),
      sub: FlezhaUiWeb.Words.count(relays, "relay") <> ", listed under Runners",
      x: @map_band_x,
      y: y,
      w: @map_band_w,
      h: @map_node_h,
      link: %{href: "#runners"},
      class: "fui-map-more-runners",
      testid: "map-more-runners"
    }

    {block, y + block.h + @map_band_gap}
  end

  defp place_column(nodes, x, w, top, selected) do
    nodes
    |> Enum.with_index()
    |> Enum.map(fn {node, index} ->
      Map.merge(node, %{
        x: x,
        y: top + index * (@map_node_h + @map_node_gap),
        w: w,
        h: @map_node_h,
        selected?: node.inspect != nil and node.inspect == selected
      })
    end)
  end

  defp column_bottom(nodes), do: nodes |> Enum.map(&(&1.y + &1.h)) |> Enum.max(fn -> @map_top end)

  defp column_height(0), do: 0
  defp column_height(count), do: count * (@map_node_h + @map_node_gap) - @map_node_gap

  defp drain_height(parked) when parked in [nil, 0], do: 0
  defp drain_height(_parked), do: 2 * @map_node_gap + @map_node_h

  # A band or the no-runner zone moved down by `dy`, with everything in it.
  defp shift_block(block, dy) do
    block = %{block | y: block.y + dy, lanes: Enum.map(block.lanes, &%{&1 | y: &1.y + dy})}

    case block do
      %{more: %{y: y} = more} -> %{block | more: %{more | y: y + dy}}
      _no_more -> block
    end
  end

  # The side nodes a lane is wired to: calls and sends when no input plugin
  # feeds it, the runner stream when no output plugin carries it.
  defp source_ids(%{inputs: []}), do: ["calls"]
  defp source_ids(lane), do: Enum.map(lane.inputs, &"in-#{&1}")

  defp output_ids(%{outputs: [], bound?: true}), do: ["stream"]
  defp output_ids(%{outputs: []}), do: []
  defp output_ids(lane), do: Enum.map(lane.outputs, &"out-#{&1}")

  # Nodes by the mean height of the lanes they are wired to, those wired to
  # none last, each group keeping its own order.
  defp order_by_lanes(nodes, lanes, ids_of) do
    centre = fn node ->
      ys = for lane <- lanes, node.id in ids_of.(lane), do: lane.y + div(lane.h, 2)
      if ys == [], do: :infinity, else: Enum.sum(ys) / length(ys)
    end

    nodes
    |> Enum.with_index()
    |> Enum.sort_by(fn {node, index} -> {centre.(node), index} end)
    |> Enum.map(&elem(&1, 0))
  end

  defp map_drain(parked, _outputs) when parked in [nil, 0], do: nil

  defp map_drain(parked, outputs) do
    %{
      id: "drain",
      kind: :drain,
      label: "Dead letter",
      sub: "#{parked} parked",
      parked: parked,
      x: @map_out_x,
      y: column_bottom(outputs) + 2 * @map_node_gap,
      w: @map_out_w,
      h: @map_node_h,
      link: %{navigate: ~p"/dlq"},
      class: "fui-map-drain",
      testid: "map-drain"
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
    rates = members |> Enum.map(& &1.rate) |> Enum.reject(&is_nil/1)
    sum = fn key -> rates |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum() end
    {rate_in, rate_out} = {sum.(:in), sum.(:out)}
    bytes? = Enum.any?(rates, &Map.has_key?(&1, :bytes_in))
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
        if(any_rate?,
          do:
            Map.merge(
              %{in: Float.round(rate_in / 1, 1), out: Float.round(rate_out / 1, 1)},
              if(bytes?, do: %{bytes_in: sum.(:bytes_in), bytes_out: sum.(:bytes_out)}, else: %{})
            )
        ),
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

  defp map_band(runner, lanes, more, href, y, selected) do
    id = to_string(runner.id)

    Map.merge(
      %{
        id: id,
        short: short_id(id),
        pid: Map.get(runner, :pid),
        selected?: selected == {:runner, id}
      },
      lane_block(lanes, more, href, y, @map_band_head)
    )
  end

  defp map_zone(lanes, href, y) do
    {shown, more} = Enum.split(lanes, @map_lane_cap)
    lane_block(shown, more, href, y, 30)
  end

  # A band's or the zone's lanes stacked under a heading `head` tall, with a
  # "+N more" row for those past the cap.
  defp lane_block(lanes, more, href, y, head) do
    top = y + head

    placed =
      lanes
      |> Enum.with_index()
      |> Enum.map(fn {lane, index} ->
        Map.merge(lane, %{
          x: @map_band_x + 12,
          y: top + index * (@map_lane_h + @map_lane_gap),
          w: @map_band_w - 24,
          h: @map_lane_h
        })
      end)

    rows = length(placed) + if(more == [], do: 0, else: 1)

    %{
      x: @map_band_x,
      y: y,
      w: @map_band_w,
      h: head + max(rows, 1) * (@map_lane_h + @map_lane_gap) + 4,
      lanes: placed,
      more:
        if more != [] do
          %{
            count: Enum.reduce(more, 0, &(&2 + max(length(&1.members), 1))),
            href: href,
            y: top + length(placed) * (@map_lane_h + @map_lane_gap) + 24
          }
        end
    }
  end

  defp mark_selected(lane, selected),
    do: Map.put(lane, :selected?, lane.inspect != nil and lane.inspect == selected)

  # Each lane is wired from the sources it is bound to and to its outputs (see
  # `source_ids/1` and `output_ids/1`). Where several wires meet one edge,
  # their ends are spread along it in the order of what they lead to, so no two
  # converge on one point and none cross at the edge.
  defp map_wires(lanes, sources, outputs, rates, source_ids, output_ids) do
    source = Map.new(sources, &{&1.id, &1})
    output = Map.new(outputs, &{&1.id, &1})

    ins =
      for lane <- lanes,
          id <- source_ids.(lane),
          node <- List.wrap(source[id]),
          do: {node, lane, :in}

    outs =
      for lane <- lanes,
          id <- output_ids.(lane),
          node <- List.wrap(output[id]),
          do: {node, lane, :out}

    node_port = ports(ins ++ outs, &edge_node/1, &lane_mid/1)
    lane_port = ports(ins, &edge_lane/1, &node_mid/1)
    lane_out_port = ports(outs, &edge_lane/1, &node_mid/1)

    Enum.map(ins, fn {node, lane, _side} = edge ->
      wire(
        "#{node.id}->#{lane.key}",
        node.x + node.w,
        node.y + Map.fetch!(node_port, edge),
        lane.x,
        lane.y + Map.fetch!(lane_port, edge),
        speed(rates, lane, :in)
      )
    end) ++
      Enum.map(outs, fn {node, lane, _side} = edge ->
        wire(
          "#{lane.key}->#{node.id}",
          lane.x + lane.w,
          lane.y + Map.fetch!(lane_out_port, edge),
          node.x,
          node.y + Map.fetch!(node_port, edge),
          speed(rates, lane, :out)
        )
      end)
  end

  # Where along a box's edge each wire ends: the wires sharing a box are
  # ordered by how high their other end sits and spaced evenly over its height.
  defp ports(edges, box_of, other_mid) do
    edges
    |> Enum.group_by(box_of)
    |> Enum.flat_map(fn {box, group} ->
      count = length(group)

      group
      |> Enum.sort_by(other_mid)
      |> Enum.with_index(1)
      |> Enum.map(fn {edge, index} -> {edge, div(box.h * index, count + 1)} end)
    end)
    |> Map.new()
  end

  defp edge_node({node, _lane, _side}), do: node
  defp edge_lane({_node, lane, _side}), do: lane

  defp lane_mid({_node, lane, _side}), do: lane.y + div(lane.h, 2)
  defp node_mid({node, _lane, _side}), do: node.y + div(node.h, 2)

  defp speed(rates, _lane, _key) when rates == %{}, do: :idle
  defp speed(_rates, lane, key), do: speed_bucket(lane.rate && Map.get(lane.rate, key))

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
          <span>Rates are messages a second, then bytes</span>
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

          <.map_node
            :for={node <- @map.sources ++ @map.outputs ++ List.wrap(@map.drain)}
            node={node}
          />

          <g :for={band <- @map.bands} class="fui-map-band" data-testid={"map-band-#{band.id}"}>
            <rect
              class="fui-map-band-box"
              x={band.x}
              y={band.y}
              width={band.w}
              height={band.h}
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
            <.map_more block={band} testid={"map-more-#{band.id}"} />
          </g>

          <.map_node :if={@map.more_runners} node={@map.more_runners} />

          <g :if={@map.zone} class="fui-map-unbound" data-testid="map-unbound">
            <rect x={@map.zone.x} y={@map.zone.y} width={@map.zone.w} height={@map.zone.h} />
            <text class="fui-map-zone-label" x={@map.zone.x + 14} y={@map.zone.y + 20}>
              Waiting for a runner
            </text>
            <.map_lane :for={lane <- @map.zone.lanes} lane={lane} />
            <.map_more block={@map.zone} testid="map-more-unbound" />
          </g>
        </svg>
      </div>
    </div>
    """
  end

  attr :block, :map, required: true, doc: "a band or the zone"
  attr :testid, :string, required: true

  defp map_more(assigns) do
    ~H"""
    <.link :if={@block.more} navigate={@block.more.href} class="fui-map-more" data-testid={@testid}>
      <text x={@block.x + 14} y={@block.more.y}>+{@block.more.count} more</text>
    </.link>
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

  # A box that opens a screen (`navigate`) or a place on this one (`href`).
  defp map_node(%{node: %{link: link}} = assigns) do
    assigns = assign(assigns, :link, link)

    ~H"""
    <.link
      {@link}
      class={["fui-map-node fui-map-hit", @node[:class]]}
      aria-label={"#{@node.label}: #{@node.sub}"}
      data-testid={@node[:testid] || "map-node-#{@node.id}"}
    >
      <.map_node_body node={@node} />
    </.link>
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
    <rect x={@node.x} y={@node.y} width={@node.w} height={@node.h} />
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
      <rect class="fui-map-lane-box" x={@lane.x} y={@lane.y} width={@lane.w} height={@lane.h} />
      <.map_glyph shape={@lane.shape} cx={@lane.x + 14} cy={@lane.y + 13} />
      <title>{lane_name(@lane)}</title>
      <svg x={@lane.x} y={@lane.y} width="190" height={@lane.h} overflow="hidden">
        <text class="fui-map-mono" x="26" y="17">{@lane.label}</text>
        <text class="fui-map-sub" x="26" y="32">
          <tspan class="fui-map-health">{@lane.state}</tspan>{if @lane.sub != "",
            do: " · " <> @lane.sub}
        </text>
      </svg>
      <polyline
        :if={@lane.spark}
        class="fui-map-spark"
        transform={"translate(#{@lane.x + 196}, #{@lane.y + 11})"}
        points={@lane.spark}
        data-testid={"map-spark-#{@lane.id}"}
      />
      <g :if={@lane.rate} data-testid={"map-rate-#{@lane.id}"}>
        <text class="fui-map-rate" x={@lane.x + @lane.w - 12} y={@lane.y + 17} text-anchor="end">
          {rate_label(@lane.rate.in)}
        </text>
        <text
          :if={@lane.rate[:bytes_in]}
          class="fui-map-sub"
          x={@lane.x + @lane.w - 12}
          y={@lane.y + 32}
          text-anchor="end"
        >
          {byte_rate_label(@lane.rate.bytes_in)}
        </text>
      </g>
    </g>
    """
  end

  defp lane_name(%{kind: :stack} = lane),
    do: "#{lane.label}: #{lane.sub}. Expand to show its relays"

  defp lane_name(lane),
    do:
      "Relay #{lane.id}, #{lane.state}, #{lane.sub}" <>
        if(lane.rate, do: ", #{traffic_label(lane.rate, :in)} in", else: "")

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
      Stall detection is unavailable: {code_names(
        error_message(elem(Map.get(@topology, :stall_notice), 1))
      )}
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
