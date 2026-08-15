defmodule FlezhaUiWeb.TopologyLiveTest do
  @moduledoc """
  The pipeline graph and the fleet summary on their hosts, driven through the
  real erpc transport against a stand-in controller.

  What earns its keep here is everything a live stack will not produce to
  order: two snapshots with a known delta between them, a counter reset, a
  stall verdict of a chosen age, an observability subsystem that refuses, a
  controller that predates the liveness counters, and a listener the controller
  turns down.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Dlq.Store
  alias Flezha.Runner.FleetManager
  alias Flezha.Service.Observability
  alias Flezha.Service.OperativeManager
  alias Flezha.Service.PluginHelper
  alias Flezha.Transport.LivenessCounters

  @operative "/namespaces/default/operatives/op_a"

  defp overwatch(bindings \\ %{}) do
    %{
      id: "op_a",
      factory_id: "store_input",
      runner_id: "runner-a",
      kind: :stream,
      suspended: false,
      started_at: nil,
      extensions: %{subs: bindings}
    }
  end

  defp stack(node, opts \\ []) do
    FakeController.set(
      node,
      {Flezha, :list_namespaces},
      {:ok, Keyword.get(opts, :namespaces, ["staging", "default"])}
    )

    FakeController.set(
      node,
      {Flezha, :list_operatives},
      {:ok, Keyword.get(opts, :operatives, ["op_a"])}
    )

    FakeController.set(
      node,
      {FleetManager, :active_runners},
      {:ok, Keyword.get(opts, :runners, ["runner-a"])}
    )

    FakeController.set(
      node,
      {OperativeManager, :get_overwatch_state},
      {:ok, Keyword.get(opts, :overwatch, overwatch())}
    )
  end

  defp snapshot(node, operatives, channels \\ []) do
    FakeController.set(node, {LivenessCounters, :snapshot_all}, %{
      channels: channels,
      operatives:
        Enum.map(operatives, fn {id, received, forwarded} ->
          %{operative_id: id, io_in_received: received, forwarded: forwarded, filtered_nil: 0}
        end)
    })
  end

  defp stall_signal(node, layer, metadata, age_us) do
    now = :erpc.call(node, :erlang, :monotonic_time, [:microsecond])

    FakeController.set(
      node,
      {Observability, :query},
      {:ok,
       [
         %{
           kind: :event,
           source: :flezha_data_plane,
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

  describe "operative pipeline" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "draws the chain from ingest through the core to the channel", %{conn: conn} do
      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topology-graph")
      assert html =~ ~s(data-testid="topo-node-ingest")
      assert html =~ ~s(data-testid="topo-node-op_a")
      assert html =~ ~s(data-testid="topo-node-channel")
      assert html =~ ~s(data-testid="topo-node-output")
      assert html =~ ~s(data-testid="topology-legend")
      assert html =~ "0 plugins attached"
    end

    test "puts attached plugins on the record path in position order", %{conn: conn, node: node} do
      bindings = %{
        on_output: [%{plugin_id: "fanout", provider: Some.Provider, position: 1}],
        on_input: [%{plugin_id: "guard", provider: Some.Guard, position: 0}]
      }

      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:ok, overwatch(bindings)}
      )

      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topo-node-plugin-guard")
      assert html =~ ~s(data-testid="topo-node-plugin-fanout")
      assert html =~ "2 plugins attached"
      # The input guard feeds the core; the core feeds the output fanout.
      assert html =~ ~s(data-testid="topo-edge-flow-plugin-guard-op_a")
      assert html =~ ~s(data-testid="topo-edge-flow-op_a-plugin-fanout")
    end

    test "an off-path extension hangs off the core rather than joining the chain", %{
      conn: conn,
      node: node
    } do
      bindings = %{on_interval: [%{plugin_id: "ticker", provider: Some.Ticker, position: nil}]}

      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:ok, overwatch(bindings)}
      )

      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topo-node-plugin-ticker")
      assert html =~ ~s(data-testid="topo-edge-branch-plugin-ticker")
    end

    test "an operative bound to no runner shows an unbound channel", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:ok, %{overwatch() | runner_id: nil}}
      )

      {:ok, _view, html} = live(conn, @operative)

      assert html =~ "unbound"
      assert html =~ "topo-edge-degraded"
    end

    test "rates appear on the counted edges once a baseline exists", %{conn: conn, node: node} do
      snapshot(node, [{"op_a", 100, 90}])
      {:ok, view, html} = live(conn, @operative)

      refute html =~ ~s(data-testid="topo-rate-flow-ingest-op_a")

      snapshot(node, [{"op_a", 1_000, 900}])
      html = tick(view)

      assert html =~ ~s(data-testid="topo-rate-flow-ingest-op_a")
      assert html =~ "topo-flow-fast"
    end

    test "counters that reset clamp to zero rather than reading as a burst", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"op_a", 5_000, 4_900}])
      {:ok, view, _html} = live(conn, @operative)

      snapshot(node, [{"op_a", 12, 8}])
      html = tick(view)

      assert html =~ "0.0/s"
      assert html =~ "topo-flow-idle"
    end

    test "a controller without the liveness module still draws structure", %{
      conn: conn,
      node: node
    } do
      :erpc.call(node, :code, :purge, [LivenessCounters])
      :erpc.call(node, :code, :delete, [LivenessCounters])
      on_exit(fn -> FlezhaUi.PeerNode.ship!(node, LivenessCounters) end)

      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topology-skew")
      assert html =~ "have diverged"
      assert html =~ ~s(data-testid="topo-node-op_a")
    end

    test "a recent stall verdict banners, and a stale one does not", %{conn: conn, node: node} do
      stall_signal(node, :operative_not_forwarding, %{operative_id: "op_a"}, 5_000_000)
      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topology-stall")
      assert html =~ "Operative Not Forwarding"

      stall_signal(node, :operative_not_forwarding, %{operative_id: "op_a"}, 120_000_000)
      {:ok, _view, html} = live(conn, @operative)

      refute html =~ ~s(data-testid="topology-stall")
    end

    test "an observability subsystem that refuses leaves no banner and no error", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Observability, :query}, {:error, :observability_disabled})

      {:ok, _view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topo-node-op_a")
      refute html =~ ~s(data-testid="topology-stall")
      refute html =~ "observability_disabled"
    end

    test "selecting the core shows its facts, and dismissing clears them", %{conn: conn} do
      {:ok, view, _html} = live(conn, @operative)

      html = view |> element(~s([data-testid="topo-node-op_a"])) |> render_click()

      assert html =~ ~s(data-testid="topology-detail")
      assert html =~ "store_input"
      assert html =~ "Open live stream"

      refute view |> element(~s([data-testid="topology-detail-dismiss"])) |> render_click() =~
               ~s(data-testid="topology-detail")
    end

    test "selecting the channel offers its counters and the cluster screen", %{
      conn: conn,
      node: node
    } do
      snapshot(node, [{"op_a", 1, 1}], [
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

      {:ok, view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="topo-backpressure")

      html = render_click(view, "graph_select", %{"id" => "channel"})

      assert html =~ ~s(data-testid="topology-channel")
      assert html =~ "chan_a"
      assert has_element?(view, ~s(a[data-testid="topology-detail-link"][href="/cluster"]))
    end

    test "parked entries draw the dead-letter branch, which links to the queue", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Store, :stats},
        {:ok, [%{operative_class: "op_a", procedure_id: "sh", entries: 4, bytes: 128}]}
      )

      {:ok, view, html} = live(conn, @operative)

      assert html =~ "4 parked"
      assert has_element?(view, ~s(a[data-testid="topo-node-dead-letter"][href="/dlq"]))
    end
  end

  describe "payload tap" do
    setup %{node: node} do
      stack(node)
      :ok
    end

    test "opening a tap attaches the listener and closing it detaches", %{conn: conn, node: node} do
      {:ok, view, html} = live(conn, @operative)

      assert html =~ ~s(data-testid="tap-output")
      refute html =~ ~s(data-testid="tap-figures")

      html = render_click(view, "graph_tap", %{"io" => "output"})

      assert html =~ ~s(data-testid="tap-figures")

      assert FlezhaUi.PeerNode.eventually(fn ->
               FakeController.calls(node, {PluginHelper, :enable_io_listener}) != []
             end)

      assert [["default", "op_a", "output", _pid]] =
               FakeController.calls(node, {PluginHelper, :enable_io_listener})

      html = render_click(view, "graph_tap_close", %{})

      refute html =~ ~s(data-testid="tap-figures")

      assert FlezhaUi.PeerNode.eventually(fn ->
               FakeController.calls(node, {Flezha, :disable_plugin}) != []
             end),
             "the listener must not be left attached to the controller"
    end

    test "payloads are counted and sized as they arrive", %{conn: conn} do
      {:ok, view, _html} = live(conn, @operative)
      render_click(view, "graph_tap", %{"io" => "output"})

      send(view.pid, {:stream_message, %{message: "hello", bytes: 5, metadata: %{}}})
      send(view.pid, {:stream_message, %{message: "world!", bytes: 6, metadata: %{}}})
      html = render(view)

      assert html =~ ~s(data-testid="tap-recent")
      assert html =~ "world!"
      # Two messages, eleven bytes — both figures come from the payloads
      # themselves, because nothing on the data plane counts bytes.
      assert html =~ "11 B"
      assert html =~ ~s(data-testid="tap-msg-rate")
    end

    test "a listener the controller refuses is reported rather than silently dead", %{
      conn: conn
    } do
      {:ok, view, _html} = live(conn, @operative)
      render_click(view, "graph_tap", %{"io" => "input"})

      send(view.pid, {:stream_status, {:error, :refused}})

      assert render(view) =~ ~s(data-testid="tap-error")
    end

    test "the raw payload is what gets sized, not its printable rendering" do
      # A non-UTF-8 payload renders as hex, which is twice its real size.
      pid = start_supervised!({Agent, fn -> nil end})
      raw = <<0xFF, 0xFE, 0xFD>>

      assert byte_size(raw) == 3
      assert String.length(FlezhaUi.Format.printable(raw)) == 6
      Agent.stop(pid)
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
      assert html =~ ~s(data-testid="summary-operatives")
      assert html =~ ~s(data-testid="summary-runners")
      refute html =~ ~s(data-testid="topology-empty")
    end

    test "defaults to the first namespace in sorted order", %{conn: conn} do
      # The controller listed "staging" first; sorted order is what decides.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s(option[value="default"][selected]))
    end

    test "the selector moves the summary and the query parameter together", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/?ns=default")

      render_change(view, "select_namespace", %{"ns" => "staging"})

      assert_patch(view, ~p"/?ns=staging")
      assert ["staging"] in FakeController.calls(node, {FleetManager, :active_runners})
    end

    test "ranks the busiest operatives once a baseline exists, linking each one", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Flezha, :list_operatives}, {:ok, ["op_a", "op_b"]})
      snapshot(node, [{"op_a", 100, 100}, {"op_b", 10, 10}])

      {:ok, view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="summary-busiest-empty")

      snapshot(node, [{"op_a", 5_000, 5_000}, {"op_b", 20, 20}])
      html = tick(view)

      assert html =~ ~s(data-testid="summary-busiest")
      assert html =~ ~s(data-testid="summary-operative-op_a")

      assert has_element?(
               view,
               ~s(a[data-testid="summary-operative-op_a"][href="/namespaces/default/operatives/op_a"])
             )
    end

    test "assembling it costs no per-operative controller call", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_operatives}, {:ok, Enum.map(1..50, &"op_#{&1}")})

      {:ok, view, _html} = live(conn, ~p"/?ns=default")
      tick(view)

      # The dashboard's own tiles read namespaces, not overwatch state; the
      # summary must not walk the fleet either, or it stops working at scale.
      assert FakeController.calls(node, {OperativeManager, :get_overwatch_state}) == []
    end

    test "a namespace with nothing in it says so", %{conn: conn, node: node} do
      stack(node, operatives: [], runners: [])

      {:ok, _view, html} = live(conn, ~p"/?ns=default")

      assert html =~ ~s(data-testid="topology-empty")
      assert html =~ "Nothing running in default yet."
    end

    test "backpressure and dead-letter pressure are surfaced as tiles", %{conn: conn, node: node} do
      snapshot(node, [{"op_a", 1, 1}], [
        %{runner_id: "runner-a", name: :chan_a, credit_active: 1, credit_ledger_level: 0}
      ])

      FakeController.set(
        node,
        {Store, :stats},
        {:ok, [%{operative_class: "op_a", entries: 7}]}
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

    test "a relayed runner disconnect is applied before the next tick", %{conn: conn, node: node} do
      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="summary-runners")

      assert has_element?(view, ~s([data-testid="summary-runners"]), "1")

      FakeController.set(node, {FleetManager, :active_runners}, {:ok, []})
      send(view.pid, {:flezha_event, :runner_disconnected, %{runner_id: "runner-a"}})
      render(view)

      assert has_element?(view, ~s([data-testid="summary-runners"]), "0")
    end
  end
end
