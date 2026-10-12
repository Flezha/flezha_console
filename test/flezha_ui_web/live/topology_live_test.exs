defmodule FlezhaUiWeb.TopologyLiveTest do
  @moduledoc """
  The pipeline graph and the fleet summary on their hosts, driven through the
  real erpc transport against a stand-in controller.

  What earns its keep here is everything a live stack will not produce to
  order: two snapshots with a known delta between them, a counter reset, a
  stall verdict of a chosen age, an observability subsystem that refuses, a
  controller that predates the liveness counters, and a listen the controller
  turns down.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Dlq
  alias Flezha.Service.Fleet
  alias Flezha.Service.Observability
  alias Flezha.Service.Relay

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
           Enum.map(relays, fn {id, received, forwarded} ->
             %{relay_id: id, io_in_received: received, forwarded: forwarded, filtered_nil: 0}
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

  # A second tick. The sleep buys elapsed time for the delta to be divided by;
  # without it both snapshots land in the same millisecond and there is no rate.
  defp tick(view) do
    Process.sleep(20)
    send(view.pid, :refresh)
    render(view)
  end

  describe "relay pipeline" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "draws the chain from ingest through the core and channel to the output", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topology-graph")
      assert html =~ ~s(data-testid="topo-node-ingest")
      assert html =~ ~s(data-testid="topo-node-relay_a")
      assert html =~ ~s(data-testid="topo-node-channel")
      assert html =~ ~s(data-testid="topo-node-output")
      assert html =~ "topo-node-output"
      refute html =~ "sink"
      assert html =~ ~s(data-testid="topology-legend")
      assert html =~ "0 plugins attached"
    end

    test "puts bound plugins on the record path in position order", %{conn: conn, node: node} do
      bindings = %{
        on_output: [%{plugin_id: "fanout", provider: Some.Provider, position: 1}],
        on_input: [%{plugin_id: "guard", provider: Some.Guard, position: 0}]
      }

      FakeController.set(node, {Relay, :overwatch_state}, {:ok, overwatch(bindings)})

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topo-node-plugin-guard")
      assert html =~ ~s(data-testid="topo-node-plugin-fanout")
      assert html =~ "2 plugins attached"
      # The input guard feeds the core; the core feeds the output fanout.
      assert html =~ ~s(data-testid="topo-edge-flow-plugin-guard-relay_a")
      assert html =~ ~s(data-testid="topo-edge-flow-relay_a-plugin-fanout")
    end

    test "an off-path hook hangs off the core rather than joining the chain", %{
      conn: conn,
      node: node
    } do
      bindings = %{on_interval: [%{plugin_id: "ticker", provider: Some.Ticker, position: nil}]}

      FakeController.set(node, {Relay, :overwatch_state}, {:ok, overwatch(bindings)})

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="topo-node-plugin-ticker")
      assert html =~ ~s(data-testid="topo-edge-branch-plugin-ticker")
    end

    test "a relay bound to no runner shows an unbound channel", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{overwatch() | runner_id: nil}})

      {:ok, _view, html} = live(conn, @relay)

      assert html =~ "unbound"

      assert html =~
               ~r/data-testid="topo-edge-[^"]+"[^>]*class="flz-graph-wire flz-graph-wire--fail"/

      assert html =~ ~r/data-testid="topo-node-channel".*?class="[^"]*flz-graph-node--dead/s
    end

    test "rates appear on the counted edges once a baseline exists, keyed by relay id", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 100, 90}])
      {:ok, view, html} = live(conn, @relay)

      refute html =~ ~s(data-testid="topo-rate-flow-ingest-relay_a")

      snapshot(node, [{"relay_a", 1_000, 900}])
      html = tick(view)

      assert html =~ ~s(data-testid="topo-rate-flow-ingest-relay_a")
      assert html =~ "topo-flow-fast"
    end

    test "counters that reset clamp to zero rather than reading as a burst", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"relay_a", 5_000, 4_900}])
      {:ok, view, _html} = live(conn, @relay)

      snapshot(node, [{"relay_a", 12, 8}])
      html = tick(view)

      assert html =~ "0.0/s"
      assert html =~ "topo-flow-idle"
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

      html = render_click(view, "graph_select", %{"id" => "channel"})

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
      assert html =~ ~r/data-testid="topo-edge-[^"]*dead[^"]*"[^>]*class="[^"]*topo-edge-dlq"/
      refute html =~ ~r/data-testid="topo-edge-[^"]*dead[^"]*"[^>]*flz-graph-wire--fail/
    end
  end

  describe "payload tap" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "opening a tap listens and closing it ends the listen", %{conn: conn, node: node} do
      {:ok, view, html} = live(conn, @relay)

      assert html =~ ~s(data-testid="tap-output")
      refute html =~ ~s(data-testid="tap-figures")

      html = render_click(view, "graph_tap", %{"direction" => "output"})

      assert html =~ ~s(data-testid="tap-figures")
      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) != [] end)

      html = render_click(view, "graph_tap_close", %{})

      refute html =~ ~s(data-testid="tap-figures")

      assert PeerNode.eventually(fn -> FakeController.streams(node, @listen) == [] end),
             "the listen must not be left open on the controller"
    end

    test "payloads are counted and sized as they arrive", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @relay)
      render_click(view, "graph_tap", %{"direction" => "output"})
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
      render_click(view, "graph_tap", %{"direction" => "input"})

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tap-error") end)
    end

    test "the raw payload is what gets sized, not its printable rendering" do
      # A non-UTF-8 payload renders as hex, which is twice its real size.
      frame = FlezhaUi.Format.frame(<<0xFF, 0xFE, 0xFD>>, %{})

      assert frame.bytes == 3
      assert String.length(frame.message) == 6
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

      assert html =~
               ~r/data-testid="map-wire-calls-&gt;relay-relay_a"[^>]*class="fui-map-wire topo-flow-|class="fui-map-wire topo-flow-[a-z]+"[^>]*data-testid="map-wire-calls-&gt;relay-relay_a"/

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

      html = render_click(view, "map_expand", %{"id" => "runner-a/store_input"})

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

      assert html =~
               ~r/data-testid="map-lane-relay_a"[^>]*aria-pressed="true"|aria-pressed="true"[^>]*data-testid="map-lane-relay_a"/

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

    test "sources and outputs are drawn either side of the runners", %{conn: conn, node: node} do
      stack(node)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="map-node-calls")
      assert html =~ ~s(data-testid="map-node-stream")
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

      view |> element(~s([data-testid="inspector-close"])) |> render_click()
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
