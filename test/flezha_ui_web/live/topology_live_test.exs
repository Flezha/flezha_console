defmodule FlezhaUiWeb.TopologyLiveTest do
  @moduledoc """
  The pipeline graph and the fleet summary on their hosts, driven through the
  real erpc transport against a stand-in controller.

  What earns its keep here is everything a live stack will not produce to
  order: two snapshots with a known delta between them, a stall verdict of a
  chosen age, an observability subsystem that refuses, a controller that
  predates the liveness counters, and a listen the controller turns down.
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

  defp overwatch(bindings \\ %{}) do
    %{
      id: "relay_a",
      factory_id: "store_input",
      runner_id: "runner-a",
      builder: %{run: :flow, opts: []},
      suspended: false,
      started_at: nil,
      extensions: %{subs: bindings}
    }
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
      {:ok, Keyword.get(opts, :overwatch, overwatch())}
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

  describe "relay pipeline" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "rates appear on the counted edges once a baseline exists, keyed by relay id", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 100, 90}])
      {:ok, view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="topo-rate-in")

      snapshot(node, [{"relay_a", 1_000, 900}])
      html = tick(view)

      assert html =~ ~s(data-testid="topo-rate-in")
      assert html =~ ~s(data-testid="topo-rate-out")
      assert html =~ ~s(data-testid="topo-rate-flow-channel-output")
      assert html =~ "topo-flow-fast"
      assert html =~ ~s(data-testid="topo-band-flow-ingest-relay_a")
      assert view |> element(~s([data-testid="topo-port-state-in"])) |> render() =~ "continuous"
    end

    test "each tick's counter advances are pushed for the graph to replay, from the second on", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 100, 90, 1}])
      {:ok, view, _html} = live(conn, @relay)

      refute_push_event(view, "pipeline_counts", %{}, 50)

      snapshot(node, [{"relay_a", 103, 92, 2}])
      tick(view)

      assert_push_event(view, "pipeline_counts", %{
        in: 3,
        out: 2,
        filtered: 1,
        parked: 0,
        interval_ms: interval,
        modes: %{in: _, out: _, chan: _}
      })

      assert interval > 0
    end

    test "a liveness read that fails leaves no rate, band or stream standing", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 100, 90}])
      {:ok, view, _html} = live(conn, @relay)
      snapshot(node, [{"relay_a", 1_000, 900}])
      assert tick(view) =~ ~s(data-testid="topo-band-flow-ingest-relay_a")

      FakeController.set(node, {Controller, :liveness_counters}, {:error, :timeout})
      html = tick(view)

      refute html =~ ~s(data-testid="topo-rate-in")
      refute html =~ ~s(data-testid="topo-band-)
      assert view |> element(~s([data-testid="topo-port-state-in"])) |> render() =~ "measuring"
    end

    test "a controller without the liveness read still draws structure", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Controller, :liveness_counters},
        {:error, {:api_missing, Controller, :liveness_counters, 1}}
      )

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-skew")
      assert html =~ "have diverged"
      assert html =~ ~s(data-testid="topo-node-relay_a")
    end

    test "a recent stall verdict naming the relay banners, and a stale one does not", %{
      conn: conn,
      node: node
    } do
      stall_signal(node, :relay_not_forwarding, %{relay_id: "relay_a"}, 5_000_000)
      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-stall")
      assert html =~ "Relay Not Forwarding"
      assert html =~ "relay_a"

      stall_signal(node, :relay_not_forwarding, %{relay_id: "relay_a"}, 120_000_000)
      {:ok, _view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="topology-stall")
    end

    test "selecting the core shows its facts and links to its listen view", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      html = view |> element(~s([data-testid="topo-node-relay_a"])) |> render_click()

      assert html =~ ~s(data-testid="topology-detail")
      assert html =~ "store_input"

      assert has_element?(
               view,
               ~s(a[data-testid="topology-detail-link"][href="/namespaces/default/relays/relay_a/listen"])
             )

      refute view |> element(~s([data-testid="topology-detail-dismiss"])) |> render_click() =~
               ~s(data-testid="topology-detail")
    end

    test "Enter selects a focused node and Escape dismisses it", %{conn: conn} do
      {:ok, view, _html} = live(conn, @relay)

      html =
        view
        |> element(~s([data-testid="topo-node-relay_a"]))
        |> render_keydown(%{"key" => "Enter"})

      assert html =~ ~s(data-testid="topology-detail")

      html =
        view
        |> element(~s([data-testid="topology-canvas"]))
        |> render_keydown(%{"key" => "Escape"})

      refute html =~ ~s(data-testid="topology-detail")
    end

    test "selecting the channel offers its counters and the cluster screen", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 1, 1}], [
        %{
          runner_id: "runner-a",
          name: :chan_a,
          io_in_received: 10,
          send_frame_calls: 9,
          nil_drops: 0,
          credit_active: 1,
          credit_ledger_level: 0,
          credit_overrun_total: 2,
          hb_count: 40,
          hb_dispatches: 12
        }
      ])

      {:ok, view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topo-backpressure")

      html = view |> element(~s([data-testid="topo-node-channel"])) |> render_click()

      assert html =~ ~s(data-testid="topology-channel")
      assert html =~ "chan_a"
      assert has_element?(view, ~s(a[data-testid="topology-detail-link"][href="/cluster"]))
    end

    test "parked entries of the relay's class draw the dead-letter branch", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "relay_a", tasklet_id: "sh", entries: 4, bytes: 128}]}
      )

      {:ok, view, html} = live(conn, @relay)

      assert html =~ "4 parked"
      assert has_element?(view, ~s(a[data-testid="topo-node-dead-letter"][href="/dlq"]))

      # A branch that exists by structure is not drawn as a failure.
      classes = attrs(html, ~s([data-testid^="topo-edge-"][data-testid*="dead"]), "class")
      assert classes != []
      assert Enum.all?(classes, &(&1 =~ "topo-edge-dlq"))
      refute Enum.any?(classes, &(&1 =~ "flz-graph-wire--fail"))
    end
  end

  describe "the relay's inside" do
    setup %{node: node} do
      stack(node,
        overwatch:
          Map.put(
            overwatch(%{
              on_output: [%{plugin_id: "kafka", provider: Some.Producer, position: 0}]
            }),
            :extensions,
            %{
              subs: %{on_output: [%{plugin_id: "kafka", provider: Some.Producer, position: 0}]},
              plugins: %{
                "kafka" => %{provider: Some.Producer, opts: %{filter_channel: ["ohlc_out"]}},
                "trade_ws" => %{provider: Some.Socket, opts: %{entry_channel: "trades_in"}}
              }
            }
          )
      )

      FakeController.set(node, {Relay, :graph}, {:ok, inside_graph()})
      snapshot(node, [{"relay_a", 0, 0}])
      :ok
    end

    defp inside_graph do
      %{
        relay: "relay_a",
        factory: "market",
        disagree: false,
        reason: nil,
        graph: %{
          channels: [
            FakeController.graph_channel("trades_in", "entry", nil, ["ohlc"], "none"),
            FakeController.graph_channel("ohlc_out", "inter_tasklet", "ohlc", ["atr"], "output"),
            FakeController.graph_channel("atr_out", "plugin_bound", "atr", [], "output")
          ],
          tasklets:
            for name <- ["ohlc", "atr"] do
              %{name: name, mode: "dynamic", cell_keys: ["symbol"], mailbox_capacity: 1024}
            end
        }
      }
    end

    # How often the page has read the relay's graph or its activity.
    defp reads(node, function), do: length(FakeController.calls(node, {Relay, function}))

    defp tasklet_activity(node, read_at, ohlc) do
      FakeController.set(
        node,
        {Relay, :activity},
        {:ok,
         %{
           relay: "relay_a",
           runner: "runner-a",
           read_at_ms: read_at,
           instance_seq: 1,
           tasklets: [
             FakeController.activity_row("ohlc", ohlc),
             FakeController.activity_row("atr")
           ]
         }}
      )
    end

    test "a tasklet's rate comes from its activity, and its inspector names its figures", %{
      conn: conn,
      node: node
    } do
      tasklet_activity(node, 10_000, %{admitted_total: 100})
      {:ok, view, _html} = live(conn, @relay)

      tasklet_activity(node, 20_000, %{admitted_total: 150})
      snapshot(node, [{"relay_a", 1, 1}])
      html = tick(view)

      assert html =~
               ~r/data-testid="topo-rate-wire-channel-trades_in-tasklet-ohlc-trades_in"[^>]*>\s*5.0\/s/

      view |> element(~s([data-testid="topo-node-tasklet-ohlc"])) |> render_click()
      detail = view |> element(~s([data-testid="topology-detail"])) |> render()

      assert detail =~ "Cell mode"
      assert detail =~ "symbol"
      assert detail =~ "5.0 msgs/s"
      assert detail =~ "Live Cells"
    end

    test "a queue held over two reads is marked as a backlog", %{conn: conn, node: node} do
      tasklet_activity(node, 1_000, %{queued_max: 40, queued: 40})
      {:ok, view, html} = live(conn, @relay)
      refute html =~ ~s(data-testid="topo-backlog-ohlc")

      tasklet_activity(node, 3_000, %{queued_max: 40, queued: 40})
      html = tick(view)

      assert html =~ ~r/data-testid="topo-backlog-ohlc"[^>]*>\s*40 queued/
    end

    test "an output plugin's inspector names its channel and the order outputs run in", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-node-plugin-kafka-on_output"])) |> render_click()
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
      graph_reads = 1
      for _tick <- 1..10, do: tick(view)

      assert reads(node, :graph) == graph_reads
      assert reads(node, :activity) == 11

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, Map.put(overwatch(), :bound_at, 1_760_000_000_000)}
      )

      tick(view)
      assert reads(node, :graph) == graph_reads + 1

      # A runner that started another instance announced again.
      FakeController.set(
        node,
        {Relay, :activity},
        {:ok,
         %{relay: "relay_a", runner: "runner-a", read_at_ms: 9_000, instance_seq: 2, tasklets: []}}
      )

      tick(view)
      tick(view)
      assert reads(node, :graph) == graph_reads + 2
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
      assert_push_event(view, "pipeline_counts", %{in: 5})

      # As after a tab hidden for a minute: the last reading is long past.
      :sys.replace_state(view.pid, fn %{socket: socket} = channel ->
        state = socket.assigns.topology_state
        aged = %{state | prev_at: state.prev_at - 60_000}
        %{channel | socket: Phoenix.Component.assign(socket, :topology_state, aged)}
      end)

      snapshot(node, [{"relay_a", 500, 500}])
      tick(view)
      refute_push_event(view, "pipeline_counts", %{in: 495})
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
      rate = ~s(data-testid="topo-rate-wire-channel-trades_in-tasklet-ohlc-trades_in")
      tasklet_activity(node, 10_000, %{admitted_total: 100})
      {:ok, view, _html} = live(conn, @relay)
      tasklet_activity(node, 20_000, %{admitted_total: 150})
      snapshot(node, [{"relay_a", 1, 1}])
      assert tick(view) =~ rate

      FakeController.set(node, {Relay, :activity}, FakeController.error("relay.not_found"))
      snapshot(node, [{"relay_a", 2, 2}])
      html = tick(view)

      assert html =~ ~s(data-testid="topo-node-tasklet-ohlc")
      refute html =~ rate
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

      {:ok, _view, html} = live(conn, @relay)
      assert html =~ "the runners of factory market announced no graph"
      refute html =~ ~s(data-testid="topo-node-tasklet-ohlc")
      assert FakeController.calls(node, {Relay, :activity}) == []

      FakeController.set(
        node,
        {Relay, :graph},
        {:error, {:api_missing, Relay, :graph, 3}}
      )

      {:ok, _view, html} = live(conn, @relay)
      assert html =~ "this controller does not report relay graphs"
    end
  end

  describe "payload tap" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "opening a tap listens and closing it ends the listen", %{conn: conn, node: node} do
      {:ok, view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="tap-figures")

      html = view |> element(~s([data-testid="topo-port-out"])) |> render_click()

      assert html =~ ~s(data-testid="tap-figures")
      assert html =~ ~s(data-testid="topology-tap")
      assert has_element?(view, ~s([data-testid="topo-port-out"].is-tapped))
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      html = view |> element(~s([data-testid="tap-close"])) |> render_click()

      refute html =~ ~s(data-testid="tap-figures")

      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) == [] end),
             "the listen must not be left open on the controller"
    end

    test "a tap opens from the IN port, and from it with Enter", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-port-in"])) |> render_keydown(%{"key" => "Enter"})

      assert has_element?(view, ~s([data-testid="topo-port-in"].is-tapped))
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)
      assert [["default", "relay_a", :input | _] | _] = FakeController.calls(node, @listen)

      # Selecting the tapped port again closes its tap.
      view |> element(~s([data-testid="topo-port-in"])) |> render_click()
      refute has_element?(view, ~s([data-testid="topology-tap"]))
    end

    test "switching ports ends the first listen", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)

      view |> element(~s([data-testid="topo-port-out"])) |> render_click()
      assert PeerNode.eventually(fn -> length(FakeController.streams(node, @listen)) == 1 end)
      [first] = FakeController.streams(node, @listen)

      view |> element(~s([data-testid="topo-port-in"])) |> render_click()

      assert PeerNode.eventually(fn ->
               match?([other] when other != first, FakeController.streams(node, @listen))
             end)
    end

    test "what the tap hears reaches the graph coalesced, previews cut to 40 characters", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-port-out"])) |> render_click()
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      long = String.duplicate("x", 50)
      {:error, failure} = FakeController.error("internal.uncatalogued")
      FakeController.emit(node, @listen, {:output, long, %{}})
      FakeController.emit(node, @listen, {:output, "short", %{}})
      FakeController.emit(node, @listen, {:dead_lettered, failure, %{}})

      assert_push_event(
        view,
        "pipeline_records",
        %{port: "output", records: 2, dead_letters: 1, previews: [preview, "short"]},
        1_000
      )

      assert preview == String.duplicate("x", 40)
      assert view |> element(~s([data-testid="tap-dead-letters"])) |> render() =~ "1"
    end

    test "closing the tap drops what it had not yet pushed", %{conn: conn, node: node} do
      # Held until the test delivers it, so the close lands before the flush.
      TestEnv.put_app(:tap_flush_ms, :timer.hours(1))

      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-port-out"])) |> render_click()
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      FakeController.emit(node, @listen, {:output, "late", %{}})
      assert PeerNode.eventually(fn -> render(view) =~ "late" end)
      %{socket: %{assigns: %{tap: %{flush: {ref, _timer}}}}} = :sys.get_state(view.pid)

      view |> element(~s([data-testid="tap-close"])) |> render_click()
      send(view.pid, {:tap_flush, ref})
      render(view)

      refute_push_event(view, "pipeline_records", %{}, 0)
    end

    test "payloads are counted and sized as they arrive", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-port-out"][phx-click="graph_tap"])) |> render_click()
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      FakeController.emit(node, @listen, {:output, "hello", %{}})
      FakeController.emit(node, @listen, {:output, "world!", %{}})

      assert PeerNode.eventually(fn -> render(view) =~ "world!" end)
      html = render(view)

      assert html =~ ~s(data-testid="tap-recent")
      # Two payloads, eleven bytes — both figures come from the payloads
      # themselves, because nothing on the data plane counts bytes.
      assert html =~ "11 B"
      assert html =~ ~s(data-testid="tap-msg-rate")
    end

    test "a listen the controller refuses is reported rather than silently dead", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, @listen, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, @relay)
      view |> element(~s([data-testid="topo-port-in"][phx-click="graph_tap"])) |> render_click()

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tap-error") end)
      # A tap that is not listening does not claim its port.
      refute has_element?(view, ~s([data-testid="topo-port-in"].is-tapped))
    end
  end

  describe "Home's headline" do
    test "every relay healthy and moving reads as flowing, with its figures", %{
      conn: conn,
      node: node
    } do
      stack(node, relays: ["relay_a", "relay_b"])
      snapshot(node, [{"relay_a", 100, 100}, {"relay_b", 10, 10}])

      {:ok, view, html} = live(conn, ~p"/namespaces/default")

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

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert {"quiet", _text} = view |> tick() |> headline()
    end

    test "one suspended relay of eight needs attention", %{conn: conn, node: node} do
      rows = [
        summary_row("relay_s", %{health: :suspended})
        | Enum.map(1..7, &summary_row("relay_#{&1}"))
      ]

      stack(node, rows: rows)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert headline(html) == {"attention", "1 relay needs attention."}
      assert figures(html) =~ "7 of 8 relays healthy"
    end

    test "parked entries are stated among the figures", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "relay_a", tasklet_id: "sh", entries: 7, bytes: 0}]}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert figures(html) =~ "7 parked"
    end

    test "an empty namespace teaches what runners and relays are", %{conn: conn, node: node} do
      stack(node, relays: [], runners: [])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert {"empty", "Nothing runs in default yet."} = headline(html)
      assert html =~ ~s(data-testid="topology-empty")
      assert html =~ "a runner must connect before a relay can run"
      assert html =~ ~s(data-testid="start-relay-empty-btn")
      refute html =~ ~s(data-testid="namespace-map")
    end
  end

  describe "Home's problems" do
    test "an idle unhealthy relay is listed above the map, with why and what to do", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("idle_but_sick", %{health: :degraded}), summary_row("fine")])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="problem-relay:default:idle_but_sick")
      assert html =~ "idle_but_sick is degraded"
      assert html =~ ~s(data-testid="problem-diagnose-relay:default:idle_but_sick")
      assert :binary.match(html, "home-problems") < :binary.match(html, "namespace-map")
    end

    test "Diagnose answers inline beneath its problem", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("sick", %{health: :failed})])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

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

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "stranded is unplaced"
      assert html =~ "orders_p0 owns a broken key range"
      assert html =~ "Partition group orders has broken coverage"
    end

    test "past three, the rest are counted with a link to Open problems", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: Enum.map(1..5, &summary_row("sick_#{&1}", %{health: :failed})))

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html |> String.split(~s(data-testid="problem-relay:)) |> length() == 4
      assert html =~ "2 more problems on the Open problems screen"
    end

    test "a healthy namespace lists none", %{conn: conn, node: node} do
      stack(node)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="home-problems")
    end
  end

  describe "Home's map" do
    test "draws each relay in its runner's band, and one with no runner apart", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("orders"), summary_row("testnet_echo", %{runner: nil})])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="map-band-runner-a")
      assert html =~ ~s(data-testid="map-lane-orders")
      assert html =~ ~s(data-testid="map-unbound")
      assert html =~ "Waiting for a runner"
    end

    test "costs one plugin read and no call per relay", %{conn: conn, node: node} do
      stack(node, relays: Enum.map(1..50, &"relay_#{&1}"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Relay, :relay_plugins}))
      tick(view)

      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
      assert length(FakeController.calls(node, {Relay, :relay_plugins})) == before + 1
    end

    test "wires animate at their speed only once two snapshots exist", %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 0, 0}])

      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ "topo-flow-"
      refute html =~ ~s(data-testid="map-rate-relay_a")

      snapshot(node, [{"relay_a", 2_000, 0}])
      html = tick(view)

      assert [wire] = attrs(html, ~s([data-testid="map-wire-calls->relay-relay_a"]), "class")
      assert wire =~ ~r/\btopo-flow-[a-z]+\b/

      assert html =~ ~s(data-testid="map-rate-relay_a")
    end

    test "parked entries open the dead-letter drain", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "relay_a", tasklet_id: "sh", entries: 7, bytes: 0}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert has_element?(view, ~s(a[data-testid="map-drain"][href="/dlq"]), "7 parked")
    end

    test "another namespace's parked entries are not this Home's", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "elsewhere", tasklet_id: "sh", entries: 5, bytes: 0}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      refute has_element?(view, ~s([data-testid="map-drain"]), "5 parked")
    end

    test "a stack of four expands on request, from what the last tick read", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: Enum.map(1..4, &summary_row("store_#{&1}", %{factory: "store_input"})))

      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "store_input ×4"
      refute html =~ ~s(data-testid="map-lane-store_1")
      # The shell's first pulse reads the rows too; let it land before counting.
      render(view)
      calls = length(FakeController.calls(node, {Relay, :relay_rows}))

      html =
        view
        |> element(~s([data-testid="map-lane-runner-a/store_input"][phx-click="map_expand"]))
        |> render_click()

      assert html =~ ~s(data-testid="map-lane-store_1")
      assert length(FakeController.calls(node, {Relay, :relay_rows})) == calls
    end

    test "a runner event of its namespace redraws the bands before the next tick", %{
      conn: conn,
      node: node
    } do
      stack(node)

      {:ok, view, html} = live(conn, ~p"/namespaces/default")
      assert html =~ ~s(data-testid="map-band-runner-a")

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"default", "runner-a"}})

      refute render(view) =~ ~s(data-testid="map-band-runner-a")
    end

    test "a runner event of another namespace does not reload the page", %{conn: conn, node: node} do
      stack(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"other", "runner-z"}})

      assert render(view) =~ ~s(data-testid="map-band-runner-a")
    end
  end

  describe "inspecting from the map" do
    test "activating a lane opens the relay inspector in place, with one overwatch read",
         %{conn: conn, node: node} do
      stack(node, rows: [summary_row("relay_a"), summary_row("relay_b")])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      view |> element(~s([data-testid="map-lane-relay_a"])) |> render_click()
      assert_patch(view, "/namespaces/default?inspect=relay%3Arelay_a")

      html = render(view)
      assert html =~ ~s(data-testid="inspector-relay")
      assert html =~ ~s(data-testid="inspector-sentence")

      assert attrs(html, ~s([data-testid="map-lane-relay_a"]), "aria-pressed") == ["true"]

      assert length(FakeController.calls(node, {Relay, :overwatch_state})) == 1

      # The host's tick does not read it again.
      tick(view)
      assert length(FakeController.calls(node, {Relay, :overwatch_state})) == 1
    end

    test "the relay inspector carries its rates and their history, and opens the relay",
         %{conn: conn, node: node} do
      stack(node)
      snapshot(node, [{"relay_a", 0, 0}])
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      snapshot(node, [{"relay_a", 1_000, 0}])
      tick(view)
      snapshot(node, [{"relay_a", 3_000, 0}])
      assert tick(view) =~ ~s(data-testid="map-spark-relay_a")

      html = view |> element(~s([data-testid="map-lane-relay_a"])) |> render_click()

      assert html =~ ~s(data-testid="inspector-rate-in")
      assert html =~ ~s(data-testid="inspector-sparkline")
      assert html =~ ~s(data-testid="inspector-plugins")

      assert has_element?(
               view,
               ~s(a[data-testid="inspector-open"][href="/namespaces/default/relays/relay_a"])
             )
    end

    test "a runner's band opens what it serves and what is bound to it", %{
      conn: conn,
      node: node
    } do
      stack(node)
      FakeController.set(node, {Fleet, :factories}, {:ok, [%{id: "store_input", run: :flow}]})
      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = view |> element(~s([data-testid="map-runner-runner-a"])) |> render_click()

      assert html =~ ~s(data-testid="inspector-runner")
      assert html =~ ~s(data-testid="inspector-pid")
      assert html =~ ~s(data-testid="inspector-principal")
      assert view |> element(~s([data-testid="inspector-factories"])) |> render() =~ "store_input"
      assert view |> element(~s([data-testid="inspector-relays"])) |> render() =~ "relay_a"
    end

    test "a band holding more than twelve lanes links to the rest", %{conn: conn, node: node} do
      stack(node, rows: Enum.map(1..13, &summary_row("relay_#{&1}", %{factory: "f#{&1}"})))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert has_element?(view, ~s(a[data-testid="map-more-runner-a"]), "+1 more")
    end

    test "a shared link opens the same inspector, and closing it clears the address",
         %{conn: conn, node: node} do
      stack(node)

      {:ok, view, html} = live(conn, "/namespaces/default?inspect=relay:relay_a")
      assert html =~ ~s(data-testid="inspector-relay")

      view
      |> element(~s([data-testid="inspector-close"][phx-click="inspect_close"]))
      |> render_click()

      assert_patch(view, "/namespaces/default")
      refute render(view) =~ ~s(data-testid="inspector-relay")
    end

    test "Diagnose answers inside the drawer, and Stop opens the stop confirmation",
         %{conn: conn, node: node} do
      stack(node)

      {:ok, view, _html} = live(conn, "/namespaces/default?inspect=relay:relay_a")

      assert view |> element(~s([data-testid="inspector-diagnose"])) |> render_click() =~
               ~s(data-testid="inspector-diagnosis")

      assert view |> element(~s([data-testid="inspector-stop"])) |> render_click() =~
               ~s(data-testid="stop-confirm-modal")

      assert FakeController.calls(node, {Relay, :stop}) == []
    end

    test "a viewer's inspector offers no Stop", %{conn: conn, node: node, user: user} do
      stack(node)
      identity = %{principal: "v", namespace: "default", role: "viewer"}
      enforce_operations(node, user, identity)
      grant_operations(node, identity, ["Relay.diagnose"])

      {:ok, _view, html} = live(conn, "/namespaces/default?inspect=relay:relay_a")

      assert html =~ ~s(data-testid="inspector-diagnose")
      refute html =~ ~s(data-testid="inspector-stop")
    end

    test "a relay that is no longer running is stated in the drawer", %{conn: conn, node: node} do
      stack(node)
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      {:ok, _view, html} = live(conn, "/namespaces/default?inspect=relay:gone")

      assert html =~ ~s(data-testid="inspector-missing")
      assert html =~ "gone is not running"
    end

    test "a runner band's heading opens the runner inspector with its relays", %{
      conn: conn,
      node: node
    } do
      stack(node, rows: [summary_row("relay_a"), summary_row("relay_b")])
      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: 4242}]})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = view |> element(~s([data-testid="map-runner-runner-a"])) |> render_click()
      assert_patch(view, "/namespaces/default?inspect=runner%3Arunner-a")

      html = render(view) <> html
      assert html =~ ~s(data-testid="inspector-runner")
      assert html =~ "4242"
      assert html =~ ~s(href="/namespaces/default/relays/relay_b")
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
      assert html =~ ~s(data-testid="topo-node-ingest")
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
