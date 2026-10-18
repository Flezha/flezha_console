defmodule FlezhaUiWeb.TopologyLiveTest do
  @moduledoc """
  The pipeline graph and the fleet summary on their hosts, driven through the
  real erpc transport against a stand-in controller.

  What earns its keep here is everything a live stack will not produce to
  order: two snapshots with a known delta between them, a stall verdict of a
  chosen age, an observability subsystem that refuses, a controller that
  predates the liveness counters, the Cell rows or the provider flag, a tally
  report, and a listen the controller turns down.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Dlq
  alias Flezha.Service.Fleet
  alias Flezha.Service.Observability
  alias Flezha.Service.Relay
  alias FlezhaUi.TestEnv

  @relay "/namespaces/default/relays/relay_a"
  @listen {Relay, :listen}
  @websocket Flezha.Plugin.Provider.Websocket

  # The relay's overwatch state: its hook table and its plugin table, every
  # plugin of which is bound on the hooks `subs` gives it.
  defp overwatch(subs \\ %{}, plugins \\ %{}) do
    %{
      id: "relay_a",
      factory_id: "static_cell",
      runner_id: "runner-a",
      builder: %{run: :flow, opts: []},
      suspended: false,
      started_at: nil,
      extensions: %{subs: subs, plugins: plugins}
    }
  end

  # `testnet_chain`'s shape, fed by a websocket naming no channel and bound
  # only to tear down.
  defp chain_overwatch do
    overwatch(
      %{on_terminate: [%{plugin_id: "ws_chain", provider: @websocket, position: nil}]},
      %{"ws_chain" => %{provider: @websocket, opts: %{entry_channel: nil}}}
    )
  end

  defp chain_graph do
    graph([
      FakeController.graph_channel("input", "entry", nil, ["static_entry_tasklet"]),
      FakeController.graph_channel(
        "hop",
        "inter_tasklet",
        "static_entry_tasklet",
        ["static_downstream_tasklet"]
      ),
      FakeController.graph_channel(
        "kafka",
        "plugin_bound",
        "static_downstream_tasklet",
        [],
        "output"
      )
    ])
  end

  defp graph(channels, factory \\ "static_cell"),
    do:
      FakeController.graph_answer(channels,
        factory: factory,
        cell_keys: %{"static_entry_tasklet" => ~w(a b c d)}
      )

  # One tasklet writing two output channels.
  defp two_outputs_graph do
    graph([
      FakeController.graph_channel("input", "entry", nil, ["t"]),
      FakeController.graph_channel("alerts", "plugin_bound", "t", [], "output"),
      FakeController.graph_channel("orders", "plugin_bound", "t", [], "output")
    ])
  end

  defp summary_row(id, overrides \\ %{}), do: FakeController.relay_row(id, overrides)

  defp stack(node, opts \\ []) do
    relays = Keyword.get(opts, :relays, ["relay_a"])
    rows = Keyword.get(opts, :rows, Enum.map(relays, &summary_row/1))
    namespaces = Keyword.get(opts, :namespaces, ["staging", "default"])

    # The summary reads health from the relay rows, not from an id list.
    FakeController.set_fleet(node,
      namespaces: namespaces,
      rows: Map.new(namespaces, &{&1, rows})
    )

    FakeController.set(
      node,
      {Fleet, :runners},
      {:ok, Enum.map(Keyword.get(opts, :runners, ["runner-a"]), &%{id: &1, pid: nil})}
    )

    FakeController.set(
      node,
      {Relay, :overwatch_state},
      {:ok, Keyword.get(opts, :overwatch, chain_overwatch())}
    )

    FakeController.set(node, {Relay, :graph}, {:ok, Keyword.get(opts, :graph, chain_graph())})

    FakeController.set(
      node,
      {Fleet, :providers},
      {:ok,
       %{
         providers: [
           FakeController.provider_entry(
             "relay_websocket",
             "Flezha.Plugin.Provider.Websocket",
             true
           ),
           FakeController.provider_entry("relay_stdout", "Flezha.Plugin.Provider.StdOut")
         ],
         refused: 0
       }}
    )
  end

  defp snapshot(node, relays, channels \\ []) do
    FakeController.set(
      node,
      {Controller, :liveness_counters},
      {:ok,
       %{
         channels: channels,
         relays:
           Enum.map(relays, fn
             {id, received, forwarded} ->
               %{relay_id: id, io_in_received: received, forwarded: forwarded, filtered_nil: 0}

             {id, received, forwarded, filtered} ->
               %{
                 relay_id: id,
                 io_in_received: received,
                 forwarded: forwarded,
                 filtered_nil: filtered
               }
           end)
       }}
    )
  end

  defp activity(node, read_at, rows, cells \\ nil) do
    answer =
      {:ok,
       %{
         relay: "relay_a",
         runner: "runner-a",
         read_at_ms: read_at,
         instance_seq: 1,
         tasklets: rows,
         cells: cells
       }}

    FakeController.set(node, {Relay, :activity}, answer)
  end

  # Asked with `cells_of`, the activity read answers its rows too.
  defp cells(node, read_at, rows, total \\ nil) do
    activity(
      node,
      read_at,
      [FakeController.activity_row("static_entry_tasklet", %{cells: 4})],
      %{tasklet: "static_entry_tasklet", cells_total: total || length(rows), rows: rows}
    )
  end

  # The activity reads that asked for a tasklet's Cells.
  defp cell_reads(node),
    do:
      for(
        [_ns, _id, [_ | _], _ctx] = call <- FakeController.calls(node, {Relay, :activity}),
        do: call
      )

  # Aged against the controller's own clock, which `Controller.status/1`
  # reports and the stand-in reads from the peer.
  defp stall_signal(node, layer, metadata, age_us) do
    now = :erpc.call(node, :erlang, :monotonic_time, [:microsecond])

    FakeController.set(
      node,
      {Observability, :query},
      {:ok,
       [
         %{
           kind: :event,
           source: :flezha_health,
           name: :stall_localized,
           measurements: %{count: 1},
           metadata: Map.put(metadata, :layer, layer),
           ts: now - age_us
         }
       ]}
    )
  end

  # How often the page has read the relay's graph or its activity.
  defp reads(node, function), do: length(FakeController.calls(node, {Relay, function}))

  defp listens(node, direction),
    do: for([_ns, _id, ^direction | _] = call <- FakeController.calls(node, @listen), do: call)

  describe "relay pipeline" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "a source feeds the first entry by the provider listing's flag, and no plumbing is drawn",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)
      html = render(view)

      assert has_element?(view, ~s([data-testid="topo-node-source-ws_chain"]))
      assert html =~ ~s(data-wire="source-ws_chain&gt;entry-input&gt;input")

      for gone <- ~w(ingest channel output filtered),
          do: refute(has_element?(view, ~s([data-testid="topo-node-#{gone}"])))

      refute html =~ "Lifecycle"
      refute html =~ "on_terminate ·"
    end

    test "an older listing without the flag draws only a source naming its entry", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :providers},
        {:ok, %{providers: [%{id: "relay_websocket", module: "x", type: :relay}], refused: 0}}
      )

      {:ok, view, _html} = live(conn, @relay)

      refute has_element?(view, ~s([data-testid="topo-node-source-ws_chain"]))
      assert has_element?(view, ~s([data-testid="topo-node-entry-input"]))
    end

    test "rates appear on the entry and output wires once a baseline exists, keyed by relay id",
         %{conn: conn, node: node} do
      snapshot(node, [{"relay_a", 100, 90}])
      {:ok, view, _html} = live(conn, @relay)

      assert view |> element(~s([data-testid="topo-rate-in-input"])) |> render() =~ ~r/>\s*IN\s*</

      snapshot(node, [{"relay_a", 1_000, 900}])
      tick(view)

      assert view |> element(~s([data-testid="topo-rate-in-input"])) |> render() =~
               ~r"IN \d+\.\d/s"

      assert view |> element(~s([data-testid="topo-rate-out-kafka"])) |> render() =~
               ~r"OUT \d+\.\d/s"

      assert has_element?(
               view,
               ~s([data-wire="source-ws_chain>entry-input>input"][data-mode="streaming"])
             )
    end

    test "each tick pushes what every counted node took, for the graph to replay, from the second on",
         %{conn: conn, node: node} do
      snapshot(node, [{"relay_a", 100, 90, 1}])

      activity(node, 1_000, [
        FakeController.activity_row("static_entry_tasklet", %{admitted_total: 10})
      ])

      {:ok, view, _html} = live(conn, @relay)

      refute_push_event(view, "pipeline_counts", %{}, 50)

      snapshot(node, [{"relay_a", 103, 92, 2}])

      activity(node, 2_000, [
        FakeController.activity_row("static_entry_tasklet", %{admitted_total: 13})
      ])

      tick(view)

      assert_push_event(view, "pipeline_counts", %{
        budgets: budgets,
        skipped: 1,
        parked: 0,
        interval_ms: interval
      })

      assert budgets["tasklet-static_entry_tasklet"] == 3.0
      # The entry's only reader admitted three, so the entry and its source took three.
      assert budgets["entry-input"] == 3.0
      assert budgets["source-ws_chain"] == 3.0
      assert budgets["exit-kafka"] == 2.0
      assert interval > 0
    end

    test "a liveness read that fails leaves no rate standing and pushes nothing", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 100, 90}])
      {:ok, view, _html} = live(conn, @relay)
      snapshot(node, [{"relay_a", 1_000, 900}])
      assert tick(view) =~ ~r"IN \d+\.\d/s"
      assert_push_event(view, "pipeline_counts", %{budgets: _})

      FakeController.set(node, {Controller, :liveness_counters}, {:error, :timeout})
      html = tick(view)

      refute html =~ ~r"IN \d+\.\d/s"
      refute_push_event(view, "pipeline_counts", %{budgets: _}, 50)
    end

    test "a controller without the liveness read still draws structure", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Controller, :liveness_counters},
        {:error, {:api_missing, Controller, :liveness_counters, 1}}
      )

      {:ok, view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-skew")
      assert html =~ "have diverged"
      assert has_element?(view, ~s([data-testid="topo-node-relay"]))
    end

    test "a recent stall verdict naming the relay banners and rings it, and a stale one does not",
         %{conn: conn, node: node} do
      stall_signal(node, :relay_not_forwarding, %{relay_id: "relay_a"}, 5_000_000)
      {:ok, view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-stall")
      assert html =~ "Relay Not Forwarding"
      assert has_element?(view, ~s([data-testid="topo-stall-marker"]))

      stall_signal(node, :relay_not_forwarding, %{relay_id: "relay_a"}, 120_000_000)
      {:ok, _view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="topology-stall")
    end

    test "selecting the relay shows its facts, its channel's credit, its off-path bindings and links",
         %{conn: conn, node: node} do
      snapshot(node, [{"relay_a", 1, 1}], [
        %{
          runner_id: "runner-a",
          name: :chan_a,
          io_in_received: 10,
          credit_active: 1,
          credit_ledger_level: 0,
          credit_overrun_total: 2,
          hb_count: 40,
          hb_dispatches: 12
        }
      ])

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok,
         overwatch(
           %{on_interval: [%{plugin_id: "ticker", provider: Some.Ticker, position: nil}]},
           %{}
         )}
      )

      {:ok, view, html} = live(conn, @relay)
      assert html =~ ~s(data-testid="topo-backpressure")

      html = view |> element(~s([data-testid="topo-node-relay"])) |> render_click()

      assert html =~ ~s(data-testid="topology-detail")
      assert html =~ "static_cell"
      assert view |> element(~s([data-testid="topology-channel"])) |> render() =~ "chan_a"
      assert view |> element(~s([data-testid="topology-lifecycle"])) |> render() =~ "on_interval"

      assert has_element?(
               view,
               ~s(a[data-testid="topology-detail-link"][href="/namespaces/default/relays/relay_a/listen"])
             )

      assert has_element?(view, ~s(a[data-testid="topology-runner-link"][href="/cluster"]))

      view |> element(~s([data-testid="topology-detail-dismiss"])) |> render_click()
      refute has_element?(view, ~s([data-testid="topology-detail"]))
    end

    test "Enter selects a focused node, and its inspector says what it is", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      html =
        view
        |> element(~s([data-testid="topo-node-source-ws_chain"]))
        |> render_keydown(%{"key" => "Enter"})

      assert html =~ ~s(data-testid="topology-detail")

      assert view |> element(~s([data-testid="topology-source-note"])) |> render() =~
               "feeds the relay&#39;s first entry channel, input"
    end

    test "an output channel with no plugin bound ends at its muted end, and says why", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-node-unbound-kafka"])) |> render_click()

      assert view |> element(~s([data-testid="topology-detail"])) |> render() =~
               "Nothing takes the records"
    end

    test "parked entries of the relay's class draw the dead-letter end and the tasklet's badge",
         %{
           conn: conn,
           node: node
         } do
      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok,
         [%{relay_class: "relay_a", tasklet_id: "static_entry_tasklet", entries: 4, bytes: 128}]}
      )

      {:ok, view, html} = live(conn, @relay)

      assert html =~ "4 waiting"
      assert has_element?(view, ~s(a[data-testid="topo-node-dead-letter"][href="/dlq"]))

      assert view |> element(~s([data-testid="topo-parked-static_entry_tasklet"])) |> render() =~
               "4 dead letters"
    end

    test "the viewer's direction re-draws the graph, and Auto names what it chose", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      render_hook(view, "graph_view", %{"direction" => "TB", "width" => 1200, "height" => 600})
      assert has_element?(view, ~s([data-testid="topology-canvas"][data-direction="TB"]))
      assert has_element?(view, ~s([data-testid="topology-dir-TB"][aria-pressed="true"]))

      render_hook(view, "graph_view", %{"direction" => "auto", "width" => 380, "height" => 600})

      assert view |> element(~s([data-testid="topology-direction"])) |> render() =~
               "top to bottom (auto)"

      render_hook(view, "graph_view", %{"direction" => "sideways"})
      assert has_element?(view, ~s([data-testid="topology-dir-auto"][aria-pressed="true"]))
    end

    test "the page's own tally is not a listener; another caller's listener is", %{
      conn: conn,
      node: node
    } do
      listener = %{
        plugin_id: "io_listener_x",
        provider: Flezha.Plugin.Provider.MonitoredIOForward,
        position: nil
      }

      tally = %{listener | plugin_id: "io_listener_tally"}

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok,
         overwatch(%{on_output: [tally]}, %{
           "io_listener_tally" => %{
             provider: Flezha.Plugin.Provider.MonitoredIOForward,
             opts: %{mode: "tally"}
           }
         })}
      )

      {:ok, view, html} = live(conn, @relay)
      refute html =~ ~s(data-testid="topology-observer-count")
      refute has_element?(view, ~s([data-testid="topo-observers-out"]))

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok,
         overwatch(%{on_output: [tally, listener]}, %{
           "io_listener_tally" => %{
             provider: Flezha.Plugin.Provider.MonitoredIOForward,
             opts: %{mode: "tally"}
           }
         })}
      )

      tick(view)
      assert view |> element(~s([data-testid="topo-observers-out"])) |> render() =~ "1 listening"
    end
  end

  describe "the Cell sheet" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "opens on a tasklet, read with its Cells, and the graph keeps every node in place", %{
      conn: conn,
      node: node
    } do
      cells(node, 1_000, [
        FakeController.cell_row("a", %{admitted_total: 5, last_admitted_ms: 900}),
        FakeController.cell_row("b", %{queued: 3})
      ])

      {:ok, view, _html} = live(conn, @relay)

      before =
        view
        |> element(~s([data-testid="topo-node-tasklet-static_downstream_tasklet"]))
        |> render()

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_click()

      assert [["default", "relay_a", opts, _ctx] | _] = cell_reads(node)

      assert opts == [cells_of: "static_entry_tasklet", limit: 50]
      sheet = view |> element(~s([data-testid="topology-cells"])) |> render()
      assert sheet =~ ~s(data-testid="cell-a")
      assert sheet =~ ~s(data-testid="cell-b")
      assert sheet =~ "now"
      assert has_element?(view, ~s([data-testid="cells-hop-static_downstream_tasklet"]))

      assert has_element?(
               view,
               ~s([data-testid="topology-canvas"][data-cells="tasklet-static_entry_tasklet"])
             )

      assert view
             |> element(~s([data-testid="topo-node-tasklet-static_downstream_tasklet"]))
             |> render() ==
               before
    end

    test "sorts by any column, and closing it stops reading the Cells", %{conn: conn, node: node} do
      cells(node, 1_000, [
        FakeController.cell_row("a", %{queued: 1}),
        FakeController.cell_row("b", %{queued: 7})
      ])

      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_click()

      view |> element(~s([data-testid="cells-sort-queued"])) |> render_click()
      keys = fn -> view |> render() |> attrs(~s([data-testid^="cell-"]), "data-testid") end
      assert keys.() == ["cell-b", "cell-a"]

      view |> element(~s([data-testid="cells-sort-key"])) |> render_click()
      assert keys.() == ["cell-a", "cell-b"]

      view |> element(~s([data-testid="cells-close"])) |> render_click()
      refute has_element?(view, ~s([data-testid="topology-cells"]))

      with_cells = length(cell_reads(node))

      tick(view)

      assert length(cell_reads(node)) == with_cells

      assert [_ns, _id, [], _ctx] = List.last(FakeController.calls(node, {Relay, :activity}))
    end

    test "a hop opens the neighbouring tasklet's Cells", %{conn: conn, node: node} do
      cells(node, 1_000, [])
      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_click()

      view |> element(~s([data-testid="cells-hop-static_downstream_tasklet"])) |> render_click()

      assert [["default", "relay_a", [cells_of: "static_downstream_tasklet", limit: 50], _] | _] =
               node |> cell_reads() |> Enum.reverse()
    end

    test "Enter on a focused tasklet opens its Cells, and a runner that keeps none says so", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_keydown(%{"key" => "Enter"})

      assert has_element?(view, ~s([data-testid="cells-not-reported"]))
    end

    test "a refused Cell read keeps the tasklet figures and says its runner reports none",
         %{conn: conn, node: node} do
      plain =
        {:ok,
         %{
           relay: "relay_a",
           runner: "runner-a",
           read_at_ms: 1_000,
           instance_seq: 1,
           tasklets: [FakeController.activity_row("static_entry_tasklet", %{cells: 4})]
         }}

      FakeController.set(
        node,
        {Relay, :activity},
        {:per_arg, 2,
         %{
           [cells_of: "static_entry_tasklet", limit: 50] =>
             FakeController.error("authz.role_insufficient")
         }, plain}
      )

      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_click()

      assert has_element?(view, ~s([data-testid="cells-not-reported"]))
      assert view |> element(~s([data-testid="cells-meta"])) |> render() =~ "static · a, b, c, d"
    end

    test "forged: a tasklet the graph does not announce opens no sheet and reads no Cells", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)

      render_hook(view, "graph_select", %{"id" => "tasklet-not_announced"})

      refute has_element?(view, ~s([data-testid="topology-cells"]))
      assert cell_reads(node) == []
    end

    test "says how many it shows of how many", %{conn: conn, node: node} do
      cells(node, 1_000, Enum.map(1..3, &FakeController.cell_row("k#{&1}")), 342)
      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-tasklet-static_entry_tasklet"]))
      |> render_click()

      assert view |> element(~s([data-testid="cells-foot"])) |> render() =~
               "Showing the 3 most recently active of 342 Cells."
    end
  end

  describe "folded runs" do
    setup %{node: node} do
      chain = fn from, to ->
        FakeController.graph_channel("#{from}_out", "inter_tasklet", from, [to])
      end

      stack(node,
        overwatch: overwatch(),
        graph:
          graph([
            FakeController.graph_channel("in", "entry", nil, ["t1"]),
            chain.("t1", "t2"),
            chain.("t2", "t3"),
            chain.("t3", "t4"),
            FakeController.graph_channel("out", "plugin_bound", "t4", [], "output")
          ])
      )

      :ok
    end

    test "a straight run of four folds, expands when selected, and folds again", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      assert view |> element(~s([data-testid="topo-node-run-t1"])) |> render() =~ "4 tasklets"
      refute has_element?(view, ~s([data-testid="topo-node-tasklet-t2"]))

      view |> element(~s([data-testid="topo-node-run-t1"])) |> render_click()
      assert has_element?(view, ~s([data-testid="topo-node-tasklet-t2"]))
      refute has_element?(view, ~s([data-testid="topo-node-run-t1"]))

      view |> element(~s([data-testid="topo-node-tasklet-t2"])) |> render_click()
      assert has_element?(view, ~s([data-testid="topology-cells"]))
      view |> element(~s([data-testid="topo-node-relay"])) |> render_click()
      view |> element(~s([data-testid="topology-fold"])) |> render_click()
      assert has_element?(view, ~s([data-testid="topo-node-run-t1"]))
      refute has_element?(view, ~s([data-testid="topology-cells"]))
    end

    test "selecting a folded tasklet, as a Cell sheet hop does, opens its run", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      render_hook(view, "graph_select", %{"id" => "tasklet-t3"})

      refute has_element?(view, ~s([data-testid="topo-node-run-t1"]))
      assert has_element?(view, ~s([data-testid="topo-node-tasklet-t3"].is-selected))
      assert has_element?(view, ~s([data-testid="topology-cells"]))
    end
  end

  describe "the tally" do
    setup %{node: node} do
      stack(node, graph: two_outputs_graph())

      snapshot(node, [{"relay_a", 0, 0}])
      :ok
    end

    # A tally report, heard by the page before the test goes on.
    defp report(node, view, totals, epoch) do
      FakeController.emit(
        node,
        @listen,
        {:tally, totals, %{read_at_ms: 1, epochs: %{"m" => epoch}}}
      )

      assert PeerNode.eventually(fn ->
               match?(
                 %{totals: ^totals},
                 :sys.get_state(view.pid).socket.assigns.topology_state.tally
               )
             end)
    end

    test "listens while the relay has two outputs and the page shows, and rates each channel", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)
      assert [["default", "relay_a", :tally, [], _ctx]] = listens(node, :tally)

      report(node, view, %{"alerts" => 10, "orders" => 2}, 1)
      tick(view)
      report(node, view, %{"alerts" => 20, "orders" => 4}, 1)
      tick(view)

      # A channel no tasklet reads carries what its tally counted.
      assert_push_event(view, "pipeline_counts", %{
        budgets: %{"exit-alerts" => 10.0, "exit-orders" => 2.0, "chan-alerts" => 10.0}
      })

      # A new epoch counts from zero again: no advance is drawn from it.
      report(node, view, %{"alerts" => 3, "orders" => 0}, 2)
      tick(view)
      refute_push_event(view, "pipeline_counts", %{budgets: %{"exit-alerts" => 3.0}}, 50)
    end

    test "ends when the page is hidden and starts again when it shows", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      render_hook(view, "refresh_visibility", %{"hidden" => true})
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) == [] end)

      render_hook(view, "refresh_visibility", %{"hidden" => false})
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)
      assert length(listens(node, :tally)) == 2
    end

    test "without a tally each exit is lit from its share of OUT", %{conn: conn, node: node} do
      FakeController.set(node, @listen, FakeController.error("authz.role_insufficient"))
      {:ok, view, _html} = live(conn, @relay)

      snapshot(node, [{"relay_a", 10, 6}])
      tick(view)

      assert_push_event(view, "pipeline_counts", %{
        budgets: %{"exit-alerts" => 3.0, "exit-orders" => 3.0}
      })

      # A refusal is an answer: the tally is not asked for again every tick.
      tick(view)
      tick(view)
      assert length(listens(node, :tally)) == 1
    end

    test "a tally that failed for a while is opened again on the next tick", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, @listen, FakeController.error("relay.not_found"))
      {:ok, view, _html} = live(conn, @relay)

      # Unlike a refusal, the failure is not an answer: the next tick asks again.
      assert PeerNode.eventually(fn ->
               tick(view)
               length(listens(node, :tally)) >= 2
             end)
    end

    test "a relay with one output channel needs no tally", %{conn: conn, node: node} do
      stack(node)
      {:ok, view, _html} = live(conn, @relay)
      tick(view)

      assert listens(node, :tally) == []
    end
  end

  describe "the relay's inside" do
    setup %{node: node} do
      stack(node,
        overwatch:
          overwatch(
            %{on_output: [%{plugin_id: "kafka", provider: Some.Producer, position: 0}]},
            %{
              "kafka" => %{provider: Some.Producer, opts: %{filter_channel: ["ohlc_out"]}},
              "trade_ws" => %{provider: @websocket, opts: %{entry_channel: "trades_in"}}
            }
          ),
        graph: inside_graph()
      )

      snapshot(node, [{"relay_a", 0, 0}])
      :ok
    end

    defp inside_graph do
      graph(
        [
          FakeController.graph_channel("trades_in", "entry", nil, ["ohlc"], "none"),
          FakeController.graph_channel("ohlc_out", "inter_tasklet", "ohlc", ["atr"], "output"),
          FakeController.graph_channel("atr_out", "plugin_bound", "atr", [], "output")
        ],
        "market"
      )
    end

    defp tasklet_activity(node, read_at, ohlc) do
      activity(node, read_at, [
        FakeController.activity_row("ohlc", ohlc),
        FakeController.activity_row("atr")
      ])
    end

    test "a tasklet's rate comes from its activity, in its own slot", %{conn: conn, node: node} do
      tasklet_activity(node, 10_000, %{admitted_total: 100})
      {:ok, view, _html} = live(conn, @relay)

      tasklet_activity(node, 20_000, %{admitted_total: 150})
      snapshot(node, [{"relay_a", 1, 1}])
      tick(view)

      assert view |> element(~s([data-testid="topo-rate-tasklet-ohlc"])) |> render() =~ "5.0/s"
      assert has_element?(view, ~s([data-testid="topo-node-source-trade_ws"]))
    end

    test "a queue held over two reads is marked as a backlog", %{conn: conn, node: node} do
      tasklet_activity(node, 1_000, %{queued_max: 40, queued: 40})
      {:ok, view, html} = live(conn, @relay)
      refute html =~ ~s(data-testid="topo-backlog-ohlc")

      tasklet_activity(node, 3_000, %{queued_max: 40, queued: 40})
      tick(view)

      assert view |> element(~s([data-testid="topo-backlog-ohlc"])) |> render() =~ "40 queued"
    end

    test "an output plugin's inspector names its channel and the order outputs run in", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-node-plugin-kafka"])) |> render_click()
      detail = view |> element(~s([data-testid="topology-detail"])) |> render()

      assert detail =~ "ohlc_out"
      assert detail =~ "runs every on_output plugin in position order"
    end

    test "the graph is read once while the relay stays bound, and again when it is bound anew",
         %{conn: conn, node: node} do
      tasklet_activity(node, 1_000, %{})
      {:ok, view, _html} = live(conn, @relay)

      # The dead render reads neither; the connected mount reads each once.
      assert reads(node, :graph) == 1
      assert reads(node, :activity) == 1
      for _tick <- 1..10, do: tick(view)

      assert reads(node, :graph) == 1
      assert reads(node, :activity) == 11

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, Map.put(overwatch(), :bound_at, 1_760_000_000_000)}
      )

      tick(view)
      assert reads(node, :graph) == 2

      # A runner that started another instance announced again.
      FakeController.set(
        node,
        {Relay, :activity},
        {:ok,
         %{relay: "relay_a", runner: "runner-a", read_at_ms: 9_000, instance_seq: 2, tasklets: []}}
      )

      tick(view)
      tick(view)
      assert reads(node, :graph) == 3
    end

    test "a runner of the namespace coming back makes the graph be read again", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      reads = reads(node, :graph)

      send(view.pid, {:flezha_event, :runner_connected, {"default", "runner-a"}})
      render(view)
      assert reads(node, :graph) == reads + 1

      send(view.pid, {:flezha_event, :runner_connected, {"elsewhere", "runner-z"}})
      render(view)
      assert reads(node, :graph) == reads + 1
    end

    test "a baseline older than a few ticks is dropped rather than replayed", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      snapshot(node, [{"relay_a", 5, 5}])
      tick(view)
      assert_push_event(view, "pipeline_counts", %{budgets: %{"entry-trades_in" => 5.0}})

      # As after a tab hidden for a minute: the last reading is long past.
      :sys.replace_state(view.pid, fn %{socket: socket} = channel ->
        state = socket.assigns.topology_state
        aged = %{state | prev_at: state.prev_at - 60_000}
        %{channel | socket: Phoenix.Component.assign(socket, :topology_state, aged)}
      end)

      snapshot(node, [{"relay_a", 500, 500}])
      tick(view)
      refute_push_event(view, "pipeline_counts", %{budgets: %{"entry-trades_in" => 495.0}})
    end

    test "a refused graph read is an answer, not read again every tick", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :graph}, FakeController.error("relay.not_found"))
      {:ok, view, html} = live(conn, @relay)
      for _tick <- 1..3, do: tick(view)

      assert html =~ "its graph could not be read"
      assert reads(node, :graph) == 1
    end

    test "nothing is read while the tab is hidden, and reading resumes when it shows", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      render_hook(view, "refresh_visibility", %{"hidden" => true})
      reads = reads(node, :activity)

      for _tick <- 1..3, do: tick(view)
      assert reads(node, :activity) == reads

      render_hook(view, "refresh_visibility", %{"hidden" => false})
      assert reads(node, :activity) == reads + 1
    end

    test "a refused activity read keeps the structure and drops the figures", %{
      conn: conn,
      node: node
    } do
      rate = ~s([data-testid="topo-rate-tasklet-ohlc"])
      tasklet_activity(node, 10_000, %{admitted_total: 100})
      {:ok, view, _html} = live(conn, @relay)
      tasklet_activity(node, 20_000, %{admitted_total: 150})
      snapshot(node, [{"relay_a", 1, 1}])
      tick(view)
      assert has_element?(view, rate)

      FakeController.set(node, {Relay, :activity}, FakeController.error("relay.not_found"))
      snapshot(node, [{"relay_a", 2, 2}])
      tick(view)

      assert has_element?(view, ~s([data-testid="topo-node-tasklet-ohlc"]))
      refute has_element?(view, rate)
    end

    test "a runner that announced no graph, or a controller without one, says why", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :graph},
        {:ok, %{inside_graph() | graph: nil, reason: "not_announced"}}
      )

      {:ok, view, html} = live(conn, @relay)
      assert html =~ "the runners of factory market announced no graph"
      refute has_element?(view, ~s([data-testid="topo-node-tasklet-ohlc"]))
      assert has_element?(view, ~s([data-testid="topo-node-inside"]))
      assert FakeController.calls(node, {Relay, :activity}) == []

      FakeController.set(node, {Relay, :graph}, {:error, {:api_missing, Relay, :graph, 3}})

      {:ok, _view, html} = live(conn, @relay)
      assert html =~ "this controller does not report relay graphs"
    end
  end

  describe "channel rates" do
    # The market's fan-in: `volume_signal` reads `ohlc_out` and `config_out`,
    # `route_latest` reads `trades_in` beside `config_in`.
    setup %{node: node} do
      stack(node,
        graph:
          graph(
            [
              FakeController.graph_channel("trades_in", "entry", nil, ~w(ohlc route_latest)),
              FakeController.graph_channel("config_in", "entry", nil, ["route_latest"]),
              FakeController.graph_channel(
                "ohlc_out",
                "inter_tasklet",
                "ohlc",
                ~w(adr volume_signal),
                "output"
              ),
              FakeController.graph_channel(
                "config_out",
                "inter_tasklet",
                "route_latest",
                ["volume_signal"]
              ),
              FakeController.graph_channel("adr_out", "plugin_bound", "adr", [], "output"),
              FakeController.graph_channel(
                "signal_out",
                "plugin_bound",
                "volume_signal",
                [],
                "output"
              )
            ],
            "market"
          )
      )

      snapshot(node, [{"relay_a", 0, 0}])
      :ok
    end

    defp market_activity(node, read_at, n) do
      rows =
        for {name, k} <- [ohlc: 1, route_latest: 1, adr: 7, volume_signal: 7],
            do: FakeController.activity_row("#{name}", %{admitted_total: n * k})

      activity(node, read_at, rows)
    end

    test "a wire into a tasklet reading several channels carries only its own channel's share",
         %{conn: conn, node: node} do
      market_activity(node, 1_000, 0)
      {:ok, view, _html} = live(conn, @relay)

      market_activity(node, 3_000, 4)
      snapshot(node, [{"relay_a", 1, 1}])
      tick(view)

      assert_push_event(view, "pipeline_counts", %{budgets: budgets})

      # Each channel: from a reader of it alone, else what a reader's intake
      # leaves beside its known inputs.
      assert budgets["chan-trades_in"] == 4.0
      assert budgets["chan-ohlc_out"] == 28.0
      assert budgets["chan-config_in"] == 0.0
      assert budgets["chan-config_out"] == 0.0
      assert budgets["feed-volume_signal>ohlc_out"] == 28.0
      assert budgets["feed-volume_signal>config_out"] == 0.0
      assert budgets["feed-route_latest>trades_in"] == 4.0
      # IN goes to the entries that carried anything, not to a quiet one.
      assert budgets["entry-config_in"] == 0
      assert budgets["entry-trades_in"] == 1.0

      config = ~s([data-wire="tasklet-route_latest>tasklet-volume_signal>config_out"])
      ohlc = ~s([data-wire="tasklet-ohlc>tasklet-volume_signal>ohlc_out"])
      assert has_element?(view, config <> ~s([data-key="feed-volume_signal>config_out"]))
      refute has_element?(view, config <> ~s([data-mode="streaming"]))
      assert has_element?(view, ohlc <> ~s([data-mode="streaming"]))
      # A reader of one channel keeps its own intake as the wire's.
      assert has_element?(
               view,
               ~s([data-wire="tasklet-ohlc>tasklet-adr>ohlc_out"][data-key="tasklet-adr"])
             )
    end

    test "a channel's name carries its rate, so a tasklet's fan-out reads along the graph",
         %{conn: conn, node: node} do
      market_activity(node, 1_000, 0)
      {:ok, view, html} = live(conn, @relay)
      refute view |> element(~s([data-testid="topo-chan-ohlc_out"])) |> render() =~ "/s"
      wires = attrs(html, ".topo-net path", "d")
      assert wires != []

      market_activity(node, 3_000, 4)
      snapshot(node, [{"relay_a", 1, 1}])
      html = tick(view)

      assert text_of(html, ~s([data-testid="topo-chan-ohlc_out"])) =~ ~r"^ohlc_out (· )?[\d.]+/s$"

      assert text_of(html, ~s([data-testid="topo-chan-trades_in"])) =~
               ~r"^trades_in (· )?[\d.]+/s$"

      assert_in_delta figure(html, "topo-chan-ohlc_out") / figure(html, "topo-chan-trades_in"),
                      7,
                      0.1

      assert attrs(html, ".topo-net path", "d") == wires
    end

    test "a channel's label takes its tally when that is larger, while its marks keep its readers' count",
         %{conn: conn, node: node} do
      market_activity(node, 1_000, 0)
      {:ok, view, _html} = live(conn, @relay)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)
      report(node, view, %{"ohlc_out" => 0}, 1)
      tick(view)

      market_activity(node, 3_000, 4)
      report(node, view, %{"ohlc_out" => 40}, 1)
      html = tick(view)

      assert_push_event(view, "pipeline_counts", %{
        budgets: %{"chan-ohlc_out" => 28.0, "exit-ohlc_out" => 40.0}
      })

      assert figure(html, "topo-chan-ohlc_out") == figure(html, "topo-rate-out-ohlc_out")
      assert figure(html, "topo-chan-ohlc_out") > figure(html, "topo-rate-tasklet-adr")
    end
  end

  describe "payload tap" do
    setup %{node: node} do
      stack(node, graph: two_outputs_graph())

      :ok
    end

    defp payload_listens(node), do: listens(node, :output) ++ listens(node, :input)

    defp payload_streams(node) do
      tally = for [_ns, _id, :tally | _] <- FakeController.calls(node, @listen), do: :tally
      # The tally holds a stream of its own while this relay has two outputs.
      length(FakeController.streams(node, @listen)) - min(length(tally), 1)
    end

    test "opening a tap listens and selects its port, and closing it ends the listen", %{
      conn: conn,
      node: node
    } do
      {:ok, view, html} = live(conn, @relay)
      refute html =~ ~s(data-testid="tap-figures")
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      html = view |> element(~s([data-testid="topo-node-exit-alerts"])) |> render_click()

      assert html =~ ~s(data-testid="tap-figures")
      assert has_element?(view, ~s([data-testid="topo-node-exit-alerts"].is-tapped))
      assert has_element?(view, ~s([data-testid="topo-tapping-exit-alerts"]))
      assert view |> element(~s([data-testid="topology-detail"])) |> render() =~ "output channel"
      assert PeerNode.eventually(fn -> payload_streams(node) == 1 end)

      html = view |> element(~s([data-testid="tap-close"])) |> render_click()
      refute html =~ ~s(data-testid="tap-figures")

      assert PeerNode.eventually(fn -> payload_streams(node) == 0 end),
             "the listen must not be left open on the controller"
    end

    test "a tap opens from an entry port, and from it with Enter", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-entry-input"]))
      |> render_keydown(%{"key" => "Enter"})

      assert has_element?(view, ~s([data-testid="topo-node-entry-input"].is-tapped))
      assert PeerNode.eventually(fn -> listens(node, :input) != [] end)

      # Selecting the tapped port again closes its tap.
      view |> element(~s([data-testid="topo-node-entry-input"])) |> render_click()
      refute has_element?(view, ~s([data-testid="topology-tap"]))
    end

    test "switching ports ends the first listen", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-node-exit-alerts"])) |> render_click()
      assert PeerNode.eventually(fn -> payload_streams(node) == 1 end)

      view |> element(~s([data-testid="topo-node-entry-input"])) |> render_click()

      assert PeerNode.eventually(fn ->
               payload_streams(node) == 1 and listens(node, :input) != []
             end)

      assert length(payload_listens(node)) == 2
    end

    test "an output tap shows its own channel first, and every channel on request", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-node-exit-alerts"])) |> render_click()
      assert PeerNode.eventually(fn -> payload_streams(node) == 1 end)

      FakeController.emit(node, @listen, {:output, "an order", %{"channel" => "orders"}})
      FakeController.emit(node, @listen, {:output, "an alert", %{"channel" => "alerts"}})
      assert PeerNode.eventually(fn -> render(view) =~ "an alert" end)
      refute render(view) =~ "an order"
      assert view |> element(~s([data-testid="tap-msg-count"])) |> render() =~ ~r/>\s*1\s*</

      view |> element(~s([data-testid="tap-all"])) |> render_click()
      FakeController.emit(node, @listen, {:output, "another order", %{"channel" => "orders"}})
      assert PeerNode.eventually(fn -> render(view) =~ "another order" end)
    end

    test "what the tap hears reaches the graph coalesced, previews cut to 40 characters", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-node-entry-input"])) |> render_click()
      assert PeerNode.eventually(fn -> listens(node, :input) != [] end)

      long = String.duplicate("x", 50)
      {:error, failure} = FakeController.error("internal.uncatalogued")
      FakeController.emit(node, @listen, {:input, long, %{}})
      FakeController.emit(node, @listen, {:input, "short", %{}})
      FakeController.emit(node, @listen, {:dead_lettered, failure, %{}})

      assert_push_event(
        view,
        "pipeline_records",
        %{port: "entry-input", records: 2, previews: [preview, "short"]},
        1_000
      )

      assert preview == String.duplicate("x", 40)
      assert view |> element(~s([data-testid="tap-dead-letters"])) |> render() =~ "1"
    end

    test "closing the tap drops what it had not yet pushed", %{conn: conn, node: node} do
      # Held until the test delivers it, so the close lands before the flush.
      TestEnv.put_app(:tap_flush_ms, :timer.hours(1))

      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-node-entry-input"])) |> render_click()
      assert PeerNode.eventually(fn -> listens(node, :input) != [] end)

      FakeController.emit(node, @listen, {:input, "late", %{}})
      assert PeerNode.eventually(fn -> render(view) =~ "late" end)
      %{socket: %{assigns: %{tap: %{flush: {ref, _timer}}}}} = :sys.get_state(view.pid)

      view |> element(~s([data-testid="tap-close"])) |> render_click()
      send(view.pid, {:tap_flush, ref})
      render(view)

      refute_push_event(view, "pipeline_records", %{}, 0)
    end

    test "payloads are counted and sized as they arrive", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-entry-input"][phx-click="graph_tap"]))
      |> render_click()

      assert PeerNode.eventually(fn -> listens(node, :input) != [] end)

      FakeController.emit(node, @listen, {:input, "hello", %{}})
      FakeController.emit(node, @listen, {:input, "world!", %{}})

      assert PeerNode.eventually(fn -> render(view) =~ "world!" end)
      html = render(view)

      assert html =~ ~s(data-testid="tap-recent")
      # Two payloads, eleven bytes — both figures come from the payloads
      # themselves, because nothing on the data plane counts bytes.
      assert html =~ "11 B"
      assert html =~ ~s(data-testid="tap-msg-rate")
    end

    test "forged: a port the graph does not draw, or tapped the wrong way, opens nothing", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)

      render_hook(view, "graph_tap", %{"port" => "exit-alerts", "direction" => "input"})
      render_hook(view, "graph_tap", %{"port" => 7, "direction" => "output"})

      refute has_element?(view, ~s([data-testid="topology-tap"]))
      assert payload_listens(node) == []
    end

    test "a listen the controller refuses is reported rather than silently dead", %{
      conn: conn,
      node: node
    } do
      stack(node)
      FakeController.set(node, @listen, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, @relay)

      view
      |> element(~s([data-testid="topo-node-entry-input"][phx-click="graph_tap"]))
      |> render_click()

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tap-error") end)
      # A tap that is not listening does not claim its port.
      refute has_element?(view, ~s([data-testid="topo-node-entry-input"].is-tapped))
    end
  end

  describe "Home's headline" do
    test "every relay healthy and moving reads as flowing, with its figures", %{
      conn: conn,
      node: node
    } do
      stack(node, relays: ["relay_a", "relay_b"])
      snapshot(node, [{"relay_a", 100, 100}, {"relay_b", 10, 10}])

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      # The first snapshot has nothing to divide by, so no rate is stated.
      assert headline(html) == {"healthy", "Every relay in default is healthy."}
      refute figures(html) =~ "records/s"

      snapshot(node, [{"relay_a", 5_000, 5_000}, {"relay_b", 20, 20}])
      html = tick(view)

      assert {"flowing", _text} = headline(html)
      assert figures(html) =~ "2 of 2 relays healthy"
      assert figures(html) =~ "1 runner"
      assert figures(html) =~ "records/s in"
    end

    test "healthy and still reads as quiet", %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 1, 1}])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert {"quiet", _text} = view |> tick() |> headline()
    end

    test "one still reading after a burst keeps reading as flowing", %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 1, 1}])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      snapshot(node, [{"relay_a", 5_000, 5_000}])
      assert {"flowing", _text} = view |> tick() |> headline()

      assert {"flowing", _text} = view |> tick() |> headline()
    end

    test "another namespace's traffic does not move this one", %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 1, 1}, {"elsewhere", 0, 0}])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      snapshot(node, [{"relay_a", 1, 1}, {"elsewhere", 5_000, 5_000}])
      html = tick(view)

      assert {"quiet", _text} = headline(html)
      assert figures(html) =~ "0.0 records/s in"
    end

    test "a runner with no relay still reads as nothing running", %{conn: conn, node: node} do
      stack(node, relays: [])
      snapshot(node, [{"elsewhere", 0, 0}])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      snapshot(node, [{"elsewhere", 5_000, 5_000}])
      html = tick(view)

      assert {"empty", "Nothing runs in default yet."} = headline(html)
      assert figures(html) =~ "0 of 0 relays healthy · 1 runner"
      refute figures(html) =~ "records/s"
    end

    test "one suspended relay of eight needs attention", %{conn: conn, node: node} do
      rows = [
        summary_row("relay_s", %{health: :suspended})
        | Enum.map(1..7, &summary_row("relay_#{&1}"))
      ]

      stack(node, rows: rows)

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert headline(html) == {"attention", "1 relay needs attention."}
      assert figures(html) =~ "7 of 8 relays healthy"
    end

    test "dead letters are stated among the figures by their name", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "relay_a", tasklet_id: "sh", entries: 7, bytes: 0}]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert figures(html) =~ "7 dead letters"
      refute figures(html) =~ "parked"
    end

    test "an empty namespace teaches what runners and relays are", %{conn: conn, node: node} do
      stack(node, relays: [], runners: [])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert {"empty", "Nothing runs in default yet."} = headline(html)
      assert html =~ ~s(data-testid="topology-empty")
      assert html =~ "a runner must connect before a relay can run"
      assert html =~ ~s(data-testid="start-relay-empty-btn")
      refute html =~ ~s(data-testid="home-namespace-tiles")
      assert html =~ ~s(data-testid="home-system")
    end
  end

  describe "Home's problems" do
    test "an idle unhealthy relay is listed below the namespace tiles, with why and what to do",
         %{
           conn: conn,
           node: node
         } do
      stack(node, rows: [summary_row("idle_but_sick", %{health: :degraded}), summary_row("fine")])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="problem-relay:default:idle_but_sick")
      assert html =~ "idle_but_sick is degraded"
      assert html =~ ~s(data-testid="problem-diagnose-relay:default:idle_but_sick")

      assert text_of(html, ~s([data-testid="home-attention"] .fui-section-title)) ==
               "1 relay needs attention"

      assert :binary.match(html, "home-namespace-tiles") < :binary.match(html, "home-problems")
      assert :binary.match(html, "home-problems") < :binary.match(html, "home-river")
    end

    test "Diagnose answers inline beneath its problem", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("sick", %{health: :failed})])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html =
        view
        |> element(~s([data-testid="problem-diagnose-relay:default:sick"]))
        |> render_click()

      assert html =~ ~s(data-testid="problem-diagnosis-relay:default:sick")
      assert [["default", "sick", _ctx]] = FakeController.calls(node, {Relay, :diagnose})
    end

    test "an unplaced relay and a coverage-faulted member are problems too", %{
      conn: conn,
      node: node
    } do
      member =
        summary_row("orders_p0", %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        })

      stack(node, rows: [summary_row("stranded", %{node: nil}), member])

      FakeController.set(
        node,
        {Relay, :partition_groups},
        {:ok,
         [
           %{
             group: "orders",
             declared: 2,
             members: [member],
             coverage: {:error, %{gaps: [{128, 255}], overlaps: []}}
           }
         ]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html =~ "stranded is unplaced"
      assert html =~ "orders_p0 owns a broken key range"
      assert html =~ "Partition group orders has broken coverage"
    end

    test "past three, the rest are counted with a link to Open problems", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: Enum.map(1..5, &summary_row("sick_#{&1}", %{health: :failed})))

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html |> String.split(~s(data-testid="problem-relay:)) |> length() == 4
      assert html =~ "2 more problems on the Open problems screen"
    end

    test "a suspended relay's card says whether a runner can wake it", %{conn: conn, node: node} do
      stack(node,
        rows: [
          summary_row("served", %{health: :suspended, factory: "orders"}),
          summary_row("stranded", %{health: :suspended, factory: "gone"}),
          summary_row("fine")
        ]
      )

      FakeController.set(
        node,
        {Fleet, :runners_for_factory},
        {:per_arg, 1, %{"orders" => {:ok, ["runner-a"]}}, {:ok, []}}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      next = &text_of(html, ~s([data-testid="problem-state-relay:default:#{&1}-next"] dd))
      assert next.("served") == "The next message wakes it on a runner."
      assert next.("stranded") =~ "cannot run until a runner for gone connects"

      # Only the factories the shown relays wait on are asked about.
      assert node
             |> FakeController.calls({Fleet, :runners_for_factory})
             |> Enum.map(&Enum.at(&1, 1))
             |> Enum.uniq()
             |> Enum.sort() ==
               ["gone", "orders"]
    end

    test "runners are read for the shown problems only, and not at all with none connected", %{
      conn: conn,
      node: node
    } do
      rows = for i <- 1..6, do: summary_row("sus_#{i}", %{health: :suspended, factory: "f#{i}"})
      stack(node, rows: rows)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Fleet, :runners_for_factory}))
      tick(view)

      # One tick reads at most the three problems Home shows.
      assert length(FakeController.calls(node, {Fleet, :runners_for_factory})) - before <= 3

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      tick(view)
      before = length(FakeController.calls(node, {Fleet, :runners_for_factory}))
      html = tick(view)

      assert length(FakeController.calls(node, {Fleet, :runners_for_factory})) == before

      assert text_of(html, ~s([data-testid="problem-state-relay:default:sus_1-serving"] dd)) ==
               "No runner serves factory f1"
    end

    test "runners that could not be read leave a card's runners unknown, not none", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("sus", %{health: :suspended, factory: "orders"})])
      FakeController.set(node, {Fleet, :runners}, FakeController.error("controller.timeout"))

      FakeController.set(
        node,
        {Fleet, :runners_for_factory},
        FakeController.error("controller.timeout")
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="problem-state-relay:default:sus")
      refute html =~ ~s(data-testid="problem-state-relay:default:sus-serving")
      refute html =~ ~s(data-testid="problem-state-relay:default:sus-next")
    end

    test "a healthy namespace lists none", %{conn: conn, node: node} do
      stack(node)

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="home-problems")
    end
  end

  describe "Home's namespace tiles" do
    test "relays are counted by health, each verdict linking to its relays", %{
      conn: conn,
      node: node
    } do
      rows = [
        summary_row("relay_s", %{health: :suspended})
        | Enum.map(1..7, &summary_row("relay_#{&1}"))
      ]

      stack(node, rows: rows)

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-relays-value"])) == "8"
      assert text_of(html, ~s([data-testid="ns-relays-condition"])) == "7 healthy · 1 suspended"
      assert attrs(html, ~s([data-testid="ns-relays"]), "data-tone") == ["warning"]
      assert text_of(html, ~s([data-testid="ns-relays-verdict"])) == "1 suspended"
      assert html =~ ~s(data-testid="ns-relays-strip")

      assert {:error, {:live_redirect, %{to: "/relays?namespace=default&health=suspended"}}} =
               view |> element(~s([data-testid="ns-relays-suspended"])) |> render_click()
    end

    test "every health verdict is counted on its own, an unknown one never as healthy", %{
      conn: conn,
      node: node
    } do
      verdicts = Enum.with_index([nil | FlezhaUiWeb.Words.health_verdicts()])

      stack(node,
        rows: Enum.map(verdicts, fn {h, i} -> summary_row("relay_#{i}", %{health: h}) end)
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      # The row with no health and the one the loop calls unknown are both unknown.
      assert text_of(html, ~s([data-testid="ns-relays-unknown"])) == "2 unknown"

      for verdict <- FlezhaUiWeb.Words.health_verdicts() -- [:healthy, :unknown] do
        words = :health |> FlezhaUiWeb.Words.text(verdict) |> String.downcase()
        assert text_of(html, ~s([data-testid="ns-relays-#{verdict}"])) == "1 #{words}"
      end

      assert text_of(html, ~s([data-testid="ns-relays-condition"])) =~ "1 healthy"
    end

    test "every relay healthy reads as all healthy, and the list link opens them", %{
      conn: conn,
      node: node
    } do
      stack(node, relays: ["relay_a", "relay_b"])

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-relays-condition"])) == "All healthy"
      assert attrs(html, ~s([data-testid="ns-relays"]), "data-tone") == ["positive"]
      assert text_of(html, ~s([data-testid="ns-relays-verdict"])) == "Healthy"

      assert {:error, {:live_redirect, %{to: "/namespaces/default/relays"}}} =
               view |> element(~s([data-testid="ns-relays-all"])) |> render_click()
    end

    test "the flow is measured from two snapshots, with its history", %{conn: conn, node: node} do
      stack(node, relays: ["relay_a", "relay_b"])
      snapshot(node, [{"relay_a", 0, 0}, {"relay_b", 0, 0}])

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-flow-condition"])) =~ "Measuring"
      refute html =~ ~s(data-testid="ns-flow-value")
      refute html =~ ~s(data-testid="ns-flow-spark")

      snapshot(node, [{"relay_a", 1_000, 0}, {"relay_b", 500, 0}])
      tick(view)
      snapshot(node, [{"relay_a", 3_000, 0}, {"relay_b", 1_000, 0}])
      html = tick(view)

      # The two relays' rates, summed into one figure, its unit apart.
      assert text_of(html, ~s([data-testid="ns-flow-value"])) =~ ~r/^[1-9][\d.]*$/
      assert text_of(html, ~s([data-testid="ns-flow"] .flz-figure-unit)) == "msgs/s"
      assert text_of(html, ~s([data-testid="ns-flow-verdict"])) == "Flowing"
      # Re-read every tick: drawn live, its history filled edge to edge.
      assert [class] = attrs(html, ~s([data-testid="ns-flow"]), "class")
      assert class =~ "fui-indicator--live"
      assert html =~ ~s(class="fui-spark-area")

      assert text_of(html, ~s([data-testid="ns-flow"] .fui-indicator-foot)) =~
               ~r/^Out [\d.]+ msgs\/s$/

      assert text_of(html, ~s([data-testid="ns-flow-condition"])) ==
               "Records arriving each second"

      assert html =~ ~s(data-testid="ns-flow-spark")
    end

    test "the namespace's own dead letters open the dead-letter screen", %{
      conn: conn,
      node: node
    } do
      stack(node)

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok,
         [
           %{relay_class: "relay_a", tasklet_id: "sh", entries: 7, bytes: 0},
           %{relay_class: "elsewhere", tasklet_id: "sh", entries: 5, bytes: 0}
         ]}
      )

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-parked-value"])) == "7"
      assert text_of(html, ~s([data-testid="ns-parked"] .fui-indicator-label)) == "Dead letters"
      refute text_of(html, ~s([data-testid="ns-parked"])) =~ "parked"
      assert attrs(html, ~s([data-testid="ns-parked"]), "data-tone") == ["negative"]
      assert text_of(html, ~s([data-testid="ns-parked-verdict"])) == "Waiting"
      assert has_element?(view, ~s(a[data-testid="ns-parked"][href="/dlq"]))
    end

    test "plugins are counted once however many relays bind them", %{conn: conn, node: node} do
      stack(node, relays: ["relay_a", "relay_b"])

      FakeController.set(
        node,
        {Relay, :relay_plugins},
        {:ok,
         [
           {"relay_a", [{"ws_in", %{}}, {"kafka_out", %{}}]},
           {"relay_b", [{"ws_in", %{}}]}
         ]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-plugins-value"])) == "2"
      assert text_of(html, ~s([data-testid="ns-plugins-condition"])) == "Bound to 2 relays"
    end

    test "schedules are this namespace's, with the next one to fire", %{conn: conn, node: node} do
      stack(node)
      soon = ~U[2026-10-17 09:30:00Z]

      FakeController.set(
        node,
        {Flezha.Service.Schedule, :list},
        {:ok,
         [
           %{
             name: "nightly",
             cron: "0 2 * * *",
             timezone: "Etc/UTC",
             namespace: "default",
             factory_id: "f",
             node: :n,
             next_fire: {:ok, ~U[2026-10-18 02:00:00Z]}
           },
           %{
             name: "soon",
             cron: "30 9 * * *",
             timezone: "Etc/UTC",
             namespace: "default",
             factory_id: "f",
             node: :n,
             next_fire: soon
           },
           %{
             name: "theirs",
             cron: "* * * * *",
             timezone: "Etc/UTC",
             namespace: "staging",
             factory_id: "f",
             node: :n,
             next_fire: ~U[2026-10-17 00:00:00Z]
           }
         ]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-schedules-value"])) == "2"

      assert text_of(html, ~s([data-testid="ns-schedules-condition"])) ==
               "Next fires at #{FlezhaUi.Format.time_of_day(soon)}"
    end

    test "a breached limit comes first, in the negative tone", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :get},
        {:ok, %{name: "default", quotas: %{max_relays: 5, max_runners: 10}}}
      )

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :quota},
        {:per_arg, 1, %{relays: {:ok, 5}, runners: {:ok, 9}}, {:ok, 0}}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert attrs(html, ~s([data-testid="ns-limits"]), "data-tone") == ["negative"]
      assert text_of(html, ~s([data-testid="ns-limits-value"])) == "100%"
      assert text_of(html, ~s([data-testid="ns-limits-verdict"])) == "At its limit"

      assert attrs(html, ~s([data-testid="ns-limits"] [data-testid^="ns-limit-"]), "data-testid") ==
               ["ns-limit-relays", "ns-limit-runners"]

      assert text_of(html, ~s([data-testid="ns-limit-relays"])) =~ "5 of 5"
      assert text_of(html, ~s([data-testid="ns-limits-more"])) == "All limits"
    end

    test "past two limits the tile counts the rest and opens the Limits section", %{
      conn: conn,
      node: node
    } do
      stack(node)

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :get},
        {:ok,
         %{
           name: "default",
           quotas: %{
             max_relays: 5,
             max_runners: 10,
             max_cells_per_relay: 100,
             max_state_bytes: 1_000
           }
         }}
      )

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :quota},
        {:per_arg, 1, %{relays: {:ok, 4}, runners: {:ok, 1}}, {:ok, 0}}
      )

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert attrs(html, ~s([data-testid="ns-limits"] [data-testid^="ns-limit-"]), "data-testid") ==
               ["ns-limit-relays", "ns-limit-runners"]

      assert text_of(html, ~s([data-testid="ns-limits-more"])) == "+2 more in Limits"
      refute has_element?(view, ~s([data-testid="quota-panel"] [data-testid="quota-relays"]))

      view |> element(~s([data-testid="ns-limits-more"])) |> render_click()

      assert has_element?(view, ~s([data-testid="quota-panel"] [data-testid="quota-relays"]))
      assert_push_event(view, "fui:reveal", %{id: "quotas"})
    end

    test "each tile carries a second fact on its foot", %{conn: conn, node: node} do
      stack(node, relays: ["relay_a", "relay_b"])

      FakeController.set(
        node,
        {Relay, :relay_plugins},
        {:ok, [{"relay_a", [{"ws_in", %{}}, {"kafka_out", %{}}, {"tap", %{}}]}]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      foot = &text_of(html, ~s([data-testid="#{&1}"] .fui-indicator-foot))
      assert foot.("ns-runners") == "Running 2 relays"
      assert foot.("ns-plugins") == "ws_in, kafka_out +1"
      assert foot.("ns-parked") == "The queue is empty"
      assert text_of(html, ~s([data-testid="ns-parked-verdict"])) == "Clear"
    end

    test "the namespace's tiles are headed by its kind and its name", %{conn: conn, node: node} do
      stack(node)

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="home-namespace"] .fui-section-title .fui-eyebrow)) ==
               "Namespace"

      assert text_of(html, ~s([data-testid="home-namespace-name"])) == "default"
    end

    test "a tick costs one runners read and no call per relay", %{conn: conn, node: node} do
      stack(node, relays: Enum.map(1..50, &"relay_#{&1}"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      # The shell's first pulse reads too; let it land before counting.
      render_async(view)
      runners = length(FakeController.calls(node, {Fleet, :runners}))
      tick(view)

      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
      assert FakeController.calls(node, {Relay, :registry}) == []
      assert length(FakeController.calls(node, {Fleet, :runners})) == runners + 1
    end

    test "a runner event of its namespace updates the runners before the next tick", %{
      conn: conn,
      node: node
    } do
      stack(node)

      {view, html} = live_loaded(conn, ~p"/namespaces/default")
      assert text_of(html, ~s([data-testid="ns-runners-value"])) == "1"

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"default", "runner-a"}})

      html = render_async(view)
      assert text_of(html, ~s([data-testid="ns-runners-value"])) == "0"
      assert attrs(html, ~s([data-testid="ns-runners"]), "data-tone") == ["warning"]
      assert text_of(html, ~s([data-testid="ns-runners-verdict"])) == "Needed"
    end

    test "a runner event of another namespace does not reload the page", %{conn: conn, node: node} do
      stack(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"other", "runner-z"}})

      assert text_of(render_async(view), ~s([data-testid="ns-runners-value"])) == "1"
    end
  end

  describe "Home's system tiles" do
    test "count every reachable namespace, node, runner and relay", %{conn: conn, node: node} do
      stack(node, relays: ["relay_a", "relay_b"], runners: ["runner-a"])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="sys-namespaces-value"])) == "2"
      # Two namespaces of two relays each.
      assert text_of(html, ~s([data-testid="sys-relays-value"])) == "4"
      assert text_of(html, ~s([data-testid="sys-relays-condition"])) == "All healthy"
      assert text_of(html, ~s([data-testid="sys-relays-verdict"])) == "Healthy"
      assert text_of(html, ~s([data-testid="sys-runners-verdict"])) == "Connected"
      assert text_of(html, ~s([data-testid="sys-nodes-verdict"])) == "Connected"
      # A count with no verdict draws no pill.
      refute html =~ ~s(data-testid="sys-namespaces-verdict")
      # Each namespace answers the same runner id: it is one runner.
      assert text_of(html, ~s([data-testid="sys-runners-value"])) == "1"
      assert text_of(html, ~s([data-testid="sys-nodes-value"])) == "1"
      assert text_of(html, ~s([data-testid="sys-nodes-condition"])) =~ "connected to #{node}"
      assert text_of(html, ~s([data-testid="sys-runners"] .fui-indicator-foot)) == "1 in default"

      assert text_of(html, ~s([data-testid="sys-problems-condition"])) ==
               "Nothing needs attention"

      assert text_of(html, ~s([data-testid="sys-problems-verdict"])) == "Clear"

      assert attrs(html, ~s([data-testid="sys-controller"]), "data-tone") == ["positive"]
      assert html =~ ~s(data-testid="home-system-checked")
    end

    test "a durability breach is stated on the controller tile", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Controller, :durability_breaches},
        {:ok, [%{ref: "r1", age_ms: 90_000, rpo_ms: 60_000}]}
      )

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert attrs(html, ~s([data-testid="sys-controller"]), "data-tone") == ["negative"]
      assert text_of(html, ~s([data-testid="sys-controller-condition"])) =~ "1 durability breach"
    end

    test "open problems are counted in the worst one's tone", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("sick", %{health: :failed}), summary_row("fine")])

      {view, html} = live_loaded(conn, ~p"/namespaces/default")

      # One failed relay in each of the two namespaces.
      assert text_of(html, ~s([data-testid="sys-problems-value"])) == "2"
      assert attrs(html, ~s([data-testid="sys-problems"]), "data-tone") == ["negative"]
      assert text_of(html, ~s([data-testid="sys-problems-verdict"])) == "Urgent"
      assert has_element?(view, ~s(a[data-testid="sys-problems"][href="/problems"]))
    end

    test "only Home asks the pulse for fleet figures", %{conn: conn, node: node} do
      stack(node)

      {_view, _html} = live_loaded(conn, ~p"/problems")

      assert FakeController.calls(node, {Controller, :cluster_status}) == []
      assert FakeController.calls(node, {Controller, :status}) == []
      assert FakeController.calls(node, {Fleet, :runners}) == []
    end

    test "the fleet figures cost the same for two relays and for fifty", %{
      conn: conn,
      node: node
    } do
      reach = fn relays ->
        FakeController.reset(node)
        stack(node, relays: relays)
        live_loaded(conn, ~p"/namespaces/default")

        for key <- [{Controller, :cluster_status}, {Controller, :status}],
            do: length(FakeController.calls(node, key))
      end

      assert reach.(["relay_a", "relay_b"]) == reach.(Enum.map(1..50, &"relay_#{&1}"))
    end

    test "a hidden Home's pulse keeps its fleet figures without reading them", %{
      conn: conn,
      node: node
    } do
      stack(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      assert length(FakeController.calls(node, {Controller, :cluster_status})) == 2

      view
      |> element("#home-visibility")
      |> render_hook("refresh_visibility", %{"hidden" => true})

      send(view.pid, :shell_pulse)
      html = render_async(view)

      assert length(FakeController.calls(node, {Controller, :cluster_status})) == 2
      assert text_of(html, ~s([data-testid="sys-nodes-value"])) == "1"
    end
  end

  describe "Home's reads" do
    test "nothing is read while the tab is hidden, and once when it is shown", %{
      conn: conn,
      node: node
    } do
      stack(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Relay, :relay_plugins}))

      view
      |> element("#home-visibility")
      |> render_hook("refresh_visibility", %{"hidden" => true})

      tick(view)
      assert length(FakeController.calls(node, {Relay, :relay_plugins})) == before

      view
      |> element("#home-visibility")
      |> render_hook("refresh_visibility", %{"hidden" => false})

      assert length(FakeController.calls(node, {Relay, :relay_plugins})) == before + 1
    end

    test "a burst of lifecycle events costs one read", %{conn: conn, node: node} do
      # A window longer than the test, so the read is the one this test sends.
      TestEnv.put_app(:refresh_coalesce_ms, :timer.hours(1))
      stack(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Relay, :relay_plugins}))

      for i <- 1..10 do
        send(view.pid, {:flezha_event, :relay_stopped, {"default", stopped("relay_#{i}")}})
      end

      send(view.pid, {:flezha_event, :relay_stopped, {"staging", stopped("theirs")}})
      html = render_async(view)

      assert length(FakeController.calls(node, {Relay, :relay_plugins})) == before
      assert html |> String.split("stopped: ") |> length() == 11

      send(view.pid, :refresh_requested)
      render_async(view)
      assert length(FakeController.calls(node, {Relay, :relay_plugins})) == before + 1
    end
  end

  describe "inspecting on Home" do
    test "a shared link opens the relay inspector, with one overwatch read", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("relay_a"), summary_row("relay_b")])

      {view, html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      assert html =~ ~s(data-testid="inspector-relay")
      assert html =~ ~s(data-testid="inspector-sentence")
      assert length(FakeController.calls(node, {Relay, :overwatch_state})) == 1
      # Its condition is the same summary as everywhere else.
      assert text_of(html, ~s([data-testid="inspector-state-state"] dd)) == "Healthy"

      # The host's tick does not read it again.
      tick(view)
      assert length(FakeController.calls(node, {Relay, :overwatch_state})) == 1
    end

    test "the relay inspector carries its rates and their history, and opens the relay",
         %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 0, 0}])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      snapshot(node, [{"relay_a", 1_000, 0}])
      tick(view)
      snapshot(node, [{"relay_a", 3_000, 0}])
      tick(view)

      # The inspector takes the rates the screen measured when it opens.
      html = render_patch(view, "/namespaces/default?inspect=relay:relay_a")

      assert html =~ ~s(data-testid="inspector-rate-in")
      assert html =~ ~s(data-testid="inspector-sparkline")
      assert html =~ ~s(data-testid="inspector-plugins")

      assert has_element?(
               view,
               ~s(a[data-testid="inspector-open"][href="/namespaces/default/relays/relay_a"])
             )
    end

    test "a shared runner link opens what it serves and the relays bound to it", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("relay_a"), summary_row("relay_b")])

      FakeController.set(
        node,
        {Fleet, :runners},
        {:ok, [FakeController.runner_row("runner-a", %{connected_at: 1_791_590_400})]}
      )

      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok, [%{id: "store_input", run: :flow, runners: ["runner-a"]}]}
      )

      {view, html} = live_loaded(conn, "/namespaces/default?inspect=runner:runner-a")

      assert html =~ ~s(data-testid="inspector-runner")
      assert text_of(html, ~s([data-testid="inspector-node"])) == "flezha@node-a"
      assert text_of(html, ~s([data-testid="inspector-connected"])) =~ "2026-10-10 00:00:00 UTC"
      assert html =~ ~s(data-testid="inspector-principal")
      assert view |> element(~s([data-testid="inspector-factories"])) |> render() =~ "store_input"
      assert html =~ ~s(href="/namespaces/default/relays/relay_b")
    end

    test "closing the inspector clears the address", %{conn: conn, node: node} do
      stack(node)

      {view, _html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      view
      |> element(~s([data-testid="inspector-close"][phx-click="inspect_close"]))
      |> render_click()

      assert_patch(view, "/namespaces/default")
      refute render(view) =~ ~s(data-testid="inspector-relay")
    end

    test "Diagnose answers inside the drawer, and Stop opens the stop confirmation",
         %{conn: conn, node: node} do
      stack(node)

      {view, _html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      html = view |> element(~s([data-testid="inspector-diagnose"])) |> render_click()
      assert html =~ ~s(data-testid="inspector-diagnosis")
      assert html =~ ~s(data-testid="inspector-state-diagnosis")

      assert view |> element(~s([data-testid="inspector-stop"])) |> render_click() =~
               ~s(data-testid="stop-confirm-modal")

      assert FakeController.calls(node, {Relay, :stop}) == []
    end

    test "a viewer's inspector offers no Stop", %{conn: conn, node: node, user: user} do
      stack(node)
      identity = %{principal: "v", namespace: "default", role: "viewer"}
      enforce_operations(node, user, identity)
      grant_operations(node, identity, ["Relay.diagnose"])

      {_view, html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      assert html =~ ~s(data-testid="inspector-diagnose")
      refute html =~ ~s(data-testid="inspector-stop")
    end

    test "a relay that is no longer running is stated in the drawer", %{conn: conn, node: node} do
      stack(node)
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      {_view, html} = live_loaded(conn, "/namespaces/default?inspect=relay:gone")

      assert html =~ ~s(data-testid="inspector-missing")
      assert html =~ "gone is not running"
    end
  end

  describe "stall detection outcomes, on the relay's graph" do
    test "a refusal is stated with its code and message", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Observability, :query},
        FakeController.error("authz.principal_not_bound", "no principal is bound")
      )

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-stall-refused")
      assert html =~ "authz.principal_not_bound"
      assert html =~ "no principal is bound"
      # The rest of the graph still renders.
      assert html =~ ~s(data-testid="topo-node-relay")
    end

    test "a switched-off subsystem is stated as switched off", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Observability, :query},
        FakeController.error("observability.disabled")
      )

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-stall-disabled")
      assert html =~ "switched off"
    end

    test "any other failure stays silent", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Observability, :query},
        FakeController.error("controller.timeout")
      )

      {:ok, _view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="topology-stall-refused")
      refute html =~ ~s(data-testid="topology-stall-disabled")
      refute html =~ ~s(data-testid="topology-stall")
    end
  end

  # The figure a rate label reads, as a number.
  defp figure(html, testid) do
    [n] = Regex.run(~r"[\d.]+(?=/s)", text_of(html, ~s([data-testid="#{testid}"])))
    String.to_float(n)
  end

  # Home once the shell's first pulse, which its system tiles read, has landed.

  defp stopped(relay) do
    %{
      event: :relay_stopped,
      relay: relay,
      factory: "store_input",
      runner: nil,
      reason: :normal,
      at: DateTime.utc_now()
    }
  end

  defp attrs(html, selector, name) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute(name)
  end

  defp headline(html) do
    el = html |> LazyHTML.from_fragment() |> LazyHTML.query(~s([data-testid="home-headline"]))

    {el |> LazyHTML.attribute("data-condition") |> List.first(),
     el |> LazyHTML.text() |> String.trim()}
  end

  defp figures(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-testid="home-figures"]))
    |> LazyHTML.text()
  end
end
