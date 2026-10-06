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
      assert html =~ "topo-edge-degraded"
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

  describe "fleet summary on the dashboard" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "reports what is running in the namespace named by ?ns=", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="topology-summary")
      assert html =~ ~s(data-testid="summary-relays")
      assert html =~ ~s(data-testid="summary-runners")
      refute html =~ ~s(data-testid="topology-empty")
    end

    test "defaults to the first namespace in sorted order", %{conn: conn} do
      # The controller listed "staging" first; sorted order is what decides.
      {:ok, view, _html} = live(conn, ~p"/")

      # The picker is a dropdown, so the chosen value lives in the hidden input
      # the enclosing form submits.
      assert has_element?(view, ~s(input#topology-namespace-value[value="default"]))
    end

    test "the selector moves the summary and the query parameter together", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/?ns=default")

      render_change(view, "select_namespace", %{"ns" => "staging"})

      assert_patch(view, ~p"/?ns=staging")
      assert Enum.any?(FakeController.calls(node, {Fleet, :runners}), &match?(["staging", _], &1))
    end

    test "ranks the busiest relays once a baseline exists, linking each one", %{
      conn: conn,
      node: node
    } do
      stack(node, relays: ["relay_a", "relay_b"])
      snapshot(node, [{"relay_a", 100, 100}, {"relay_b", 10, 10}])

      {:ok, view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-busiest-empty")

      snapshot(node, [{"relay_a", 5_000, 5_000}, {"relay_b", 20, 20}])
      html = tick(view)

      assert html =~ ~s(data-testid="summary-busiest")
      assert html =~ ~s(data-testid="summary-relay-relay_a")

      assert has_element?(
               view,
               ~s(a[data-testid="summary-relay-relay_a"][href="/namespaces/default/relays/relay_a"])
             )
    end

    test "assembling it costs no per-relay controller call", %{conn: conn, node: node} do
      stack(node, relays: Enum.map(1..50, &"relay_#{&1}"))

      {:ok, view, _html} = live(conn, ~p"/?ns=default")
      tick(view)

      # The dashboard's own tiles read namespaces, not overwatch state; the
      # summary must not walk the fleet either, or it stops working at scale.
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end

    test "a namespace with nothing in it says so", %{conn: conn, node: node} do
      stack(node, relays: [], runners: [])

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="topology-empty")
      assert html =~ "Nothing running in default yet."
    end

    test "backpressure and dead-letter pressure are surfaced as tiles", %{conn: conn, node: node} do
      snapshot(node, [{"relay_a", 1, 1}], [
        %{runner_id: "runner-a", name: :chan_a, credit_active: 1, credit_ledger_level: 0}
      ])

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "relay_a", tasklet_id: "sh", entries: 7, bytes: 0}]}
      )

      {:ok, view, _html} = live(conn, ~p"/?ns=default")

      assert has_element?(view, ~s([data-testid="summary-backpressure"]), "1")
      assert has_element?(view, ~s([data-testid="summary-parked"]), "7")
    end
  end

  describe "fleet summary on the namespace page" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "renders scoped to its own namespace, without a selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="topology-summary")
      refute html =~ ~s(data-testid="topology-namespace")
    end

    test "a forwarded runner disconnect is applied before the next tick", %{
      conn: conn,
      node: node
    } do
      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="summary-runners")
      assert has_element?(view, ~s([data-testid="summary-runners"]), "1")

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"default", "runner-a"}})
      render(view)

      assert has_element?(view, ~s([data-testid="summary-runners"]), "0")
    end

    test "a runner event of another namespace does not reload the page", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      FakeController.set(node, {Fleet, :runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, {"other", "runner-z"}})
      render(view)

      assert has_element?(view, ~s([data-testid="summary-runners"]), "1")
    end
  end

  describe "fleet summary health" do
    test "counts are broken down by health, each bucket linking to those relays", %{
      conn: conn,
      node: node
    } do
      stack(node,
        rows: [
          summary_row("relay_a"),
          summary_row("relay_b", %{health: :failed})
        ]
      )

      {:ok, view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-health")
      assert html =~ ~s(data-testid="summary-health-healthy")
      assert html =~ ~s(data-testid="summary-health-failed")

      assert has_element?(
               view,
               ~s(a[data-testid="summary-health-failed"][href="/relays?namespace=default&health=failed"])
             )
    end

    test "recovering and parked are buckets of their own", %{conn: conn, node: node} do
      stack(node,
        rows: [
          summary_row("relay_a", %{health: :recovering}),
          summary_row("relay_b", %{health: :parked})
        ]
      )

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-health-recovering")
      assert html =~ ~s(data-testid="summary-health-parked")
      refute html =~ ~s(data-testid="summary-health-unknown")
    end

    test "an unhealthy relay is surfaced even at zero throughput", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("idle_but_sick", %{health: :degraded})])

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      # No snapshot has advanced, so it can never rank as busiest.
      assert html =~ ~s(data-testid="summary-busiest-empty")
      assert html =~ ~s(data-testid="summary-attention")
      assert html =~ ~s(data-testid="summary-attention-idle_but_sick")
    end

    test "an unplaced relay is surfaced and named as unplaced", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("stranded", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-attention-stranded")
      assert html =~ "unplaced"
    end

    test "a member of a coverage-faulted group is surfaced", %{conn: conn, node: node} do
      member =
        summary_row("orders_p0", %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        })

      stack(node, rows: [member])

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

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-attention-orders_p0")
      assert html =~ "coverage faulted"
    end

    test "a healthy fleet needs no attention list", %{conn: conn, node: node} do
      stack(node, rows: [summary_row("relay_a")])

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      refute html =~ ~s(data-testid="summary-attention")
    end
  end

  describe "stall detection outcomes" do
    test "a refusal is stated with its code and message", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Observability, :query},
        FakeController.error("authz.principal_not_bound", "no principal is bound")
      )

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="topology-stall-refused")
      assert html =~ "authz.principal_not_bound"
      assert html =~ "no principal is bound"
      # The rest of the summary still renders.
      assert html =~ ~s(data-testid="summary-relays")
    end

    test "a switched-off subsystem is stated as switched off", %{conn: conn, node: node} do
      stack(node)

      FakeController.set(
        node,
        {Observability, :query},
        FakeController.error("observability.disabled")
      )

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

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

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      refute html =~ ~s(data-testid="topology-stall-refused")
      refute html =~ ~s(data-testid="topology-stall-disabled")
      refute html =~ ~s(data-testid="topology-stall")
    end
  end
end
