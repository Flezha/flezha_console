defmodule FlezhaUiWeb.ClusterLiveTest do
  @moduledoc """
  The cluster and fleet screen, against a controller whose fleet can be emptied.

  The browser suite asserts the healthy shape — nodes, hubs, runners with
  factories — because the dev stack guarantees a connected runner. What it
  cannot produce is the interesting half: a factory no runner serves, a
  namespace with no hub, a controller that cannot answer at all.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  defp one_namespace(node, opts) do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}]}
    )

    FakeController.set(node, {Relay, :relay_rows}, {:ok, opts[:rows] || []})
    FakeController.set(node, {Fleet, :factories}, {:ok, opts[:factories] || []})
    FakeController.set(node, {Fleet, :runners}, {:ok, opts[:runners] || []})

    FakeController.set(
      node,
      {Fleet, :runners_for_factory},
      opts[:runners_for_factory] || {:ok, []}
    )

    FakeController.set(
      node,
      {Controller, :cluster_status},
      opts[:status] || {:ok, status(opts[:hub_nodes] || [])}
    )
  end

  # The cluster as the namespace sees it: its hub nodes with their recovery
  # state, as `Controller.cluster_status/2` answers it.
  defp status(nodes) do
    %{
      namespace: "default",
      nodes:
        Enum.map(nodes, fn
          {node, recovery} -> %{node: node, relay_count: 0, recovery_state: recovery}
          node -> %{node: node, relay_count: 0, recovery_state: :normal}
        end),
      unplaced_relays: 0,
      relay_health: %{}
    }
  end

  defp factory(id), do: %{id: id, description: nil, run: :flow}

  describe "cluster membership" do
    test "marks the node this UI is connected to", %{conn: conn, node: node} do
      one_namespace(node, [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-nodes")
      assert html =~ "connected to this UI"
      assert html =~ to_string(node)
    end

    test "lists every hub node the controller reports, unioned across namespaces", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, hub_nodes: [:"flezha@node-a", :"flezha@node-b"])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-node-flezha@node-a")
      assert html =~ ~s(data-testid="cluster-node-flezha@node-b")
      assert html =~ ~s(data-testid="cluster-node-#{node}")
      # Membership comes from the controller's answer, never `:erlang.nodes/1`.
      refute html =~ ~s(data-testid="cluster-node-#{Node.self()}")
    end
  end

  describe "namespaces and their fleets" do
    test "renders hub placement and the runners serving a namespace", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [factory("store_input")],
        hub_nodes: [:"flezha@hub-1"],
        runners: [%{id: "runner-a", pid: nil}],
        runners_for_factory: {:ok, ["runner-a"]}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-namespace-default")
      assert html =~ ~s(data-testid="hub-nodes-default")
      assert html =~ "flezha@hub-1"
      assert html =~ ~s(data-testid="runners-default")
      assert html =~ "runner-a"
      assert html =~ "store_input"
    end

    test "runners are read cluster-wide, not from the node this UI reached", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, runners: [%{id: "runner-on-peer", pid: nil}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ "runner-on-peer"
      assert FakeController.calls(node, {Fleet, :runners}) != []
    end

    test "each runner is credited with the factories it serves", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [factory("store_input"), factory("compare_filter")],
        runners: [%{id: "runner-a", pid: nil}, %{id: "runner-b", pid: nil}],
        runners_for_factory:
          {:per_arg, 1,
           %{
             "store_input" => {:ok, ["runner-a", "runner-b"]},
             "compare_filter" => {:ok, ["runner-b"]}
           }, {:ok, []}}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      [_before, fleet] = String.split(html, ~s(data-testid="runners-default"), parts: 2)
      [fleet, _after] = String.split(fleet, "</table>", parts: 2)
      [_prefix, runner_a, runner_b] = String.split(fleet, ~s(data-testid="runner-))

      assert runner_a =~ "store_input"
      refute runner_a =~ "compare_filter"
      assert runner_b =~ "compare_filter, store_input"
    end

    test "each factory states its run", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [
          factory("store_input"),
          %{id: "chat_loop_steps", description: nil, run: :steps}
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")

      assert view |> element(~s([data-testid="factory-chat_loop_steps"])) |> render() =~ "steps"
      assert view |> element(~s([data-testid="factory-store_input"])) |> render() =~ "flow"
    end

    test "renders the empty fleet rather than an empty panel", %{conn: conn, node: node} do
      one_namespace(node, factories: [factory("store_input")], runners: [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runners-empty-default")
    end

    test "renders the empty cluster when no namespace is visible", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-namespaces-empty")
    end

    test "a refused hub read is stated and the rest still renders", %{conn: conn, node: node} do
      one_namespace(node,
        runners: [%{id: "runner-a", pid: nil}],
        status: FakeController.error("authz.role_insufficient")
      )

      {:ok, view, html} = live(conn, ~p"/cluster")

      assert view |> element(~s([data-testid="hub-nodes-default"])) |> render() =~
               "authz.role_insufficient"

      assert html =~ "runner-a"
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.error("controller.timeout")
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runtime-error")
    end
  end

  describe "factory placement lookup" do
    setup %{node: node} do
      one_namespace(node,
        factories: [factory("store_input")],
        runners: [%{id: "runner-a", pid: nil}]
      )

      :ok
    end

    test "names the runners serving the factory", %{conn: conn, node: node} do
      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a", "runner-b"]})

      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        render_click(view, "select_factory", %{
          "namespace" => "default",
          "factory" => "store_input"
        })

      assert html =~ ~s(data-testid="factory-runners")
      assert html =~ "is served by"
      assert html =~ "runner-b"
    end

    test "says so when no runner serves the factory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        render_click(view, "select_factory", %{
          "namespace" => "default",
          "factory" => "store_input"
        })

      assert html =~ ~s(data-testid="factory-runners-empty")
    end

    test "selecting a factory is a lookup, not another controller read", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/cluster")
      before = length(FakeController.calls(node, {Fleet, :runners_for_factory}))

      render_click(view, "select_factory", %{"namespace" => "default", "factory" => "store_input"})

      assert length(FakeController.calls(node, {Fleet, :runners_for_factory})) == before
    end

    test "clearing the selection removes the result", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cluster")

      render_click(view, "select_factory", %{"namespace" => "default", "factory" => "store_input"})

      html = render_click(view, "clear_factory", %{})

      refute html =~ ~s(data-testid="factory-runners")
    end
  end

  describe "runner events" do
    test "a runner connecting refreshes the fleet without waiting for the timer", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, runners: [])

      {:ok, view, html} = live(conn, ~p"/cluster")
      refute html =~ "runner-late"

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-late", pid: nil}]})
      send(view.pid, {:flezha_event, :runner_connected, {"default", "runner-late"}})

      assert render(view) =~ "runner-late"
    end
  end

  describe "per-node rollup" do
    defp row(id, overrides \\ %{}), do: FakeController.relay_row(id, overrides)

    test "each node shows its relay count broken down by health", %{conn: conn, node: node} do
      one_namespace(node,
        rows: [row("a"), row("b", %{health: :degraded}), row("c", %{node: :"flezha@node-b"})],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-rollup-default")
      assert html =~ ~s(data-testid="node-count-flezha@node-a")
      assert html =~ ~s(data-health="degraded")
    end

    test "relays moving off a dead runner are counted under their own verdicts", %{
      conn: conn,
      node: node
    } do
      one_namespace(node,
        rows: [row("a", %{health: :recovering}), row("b", %{health: :parked})],
        hub_nodes: [:"flezha@node-a"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-health="recovering")
      assert html =~ ~s(data-health="parked")
      refute html =~ ~s(data-health="unknown")
    end

    test "a split view makes the disagreement visible", %{conn: conn, node: node} do
      one_namespace(node,
        rows: [row("a"), row("b")],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-flezha@node-a")
      refute html =~ ~s(data-testid="node-flezha@node-b")
    end

    test "relays with no live node are named", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("stranded", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="unplaced-default")
      assert html =~ "stranded"
    end

    test "a hub mid-recovery is distinguishable from one serving", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], hub_nodes: [{:"flezha@node-a", :replaying}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="recovery-flezha@node-a")
      assert html =~ "replaying"
      refute html =~ "serving"
    end

    test "an unreachable node's recovery is stated, and the rest still renders", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, rows: [row("a")], hub_nodes: [{:"flezha@node-a", :unreachable}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="recovery-unavailable-flezha@node-a")
      assert html =~ ~s(data-testid="node-rollup-default")
    end

    test "each namespace's runner principal is shown", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], runners: [%{id: "runner-a", pid: nil}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runner-principal-default")
      assert html =~ "runner@default"
    end

    test "the column is absent when the controller does not say", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], runners: [%{id: "runner-a", pid: nil}])

      FakeController.set(
        node,
        {Fleet, :runner_caller_context},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      refute html =~ ~s(data-testid="runner-principal-default")
      assert html =~ ~s(data-testid="node-rollup-default")
    end
  end

  describe "runner pids" do
    test "a runner's OS pid is on its row, a placeholder when unknown", %{conn: conn, node: node} do
      one_namespace(node,
        runners: [%{id: "runner-a", pid: 4242}, %{id: "runner-b", pid: nil}],
        runners_for_factory: {:ok, []}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~r/data-testid="os-pid-runner-a"[^>]*>\s*4242/
      assert html =~ ~r/data-testid="os-pid-runner-b"[^>]*>\s*—/
    end
  end

  describe "recovery detail" do
    test "shows the hub id, the local hub and every node's recovery", %{conn: conn, node: node} do
      one_namespace(node, hub_nodes: [node, :"flezha@node-b"])

      FakeController.set(
        node,
        {Controller, :recovery_per_node},
        {:ok, %{node => :normal, "flezha@node-b": :replaying}}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      assert view |> element(~s([data-testid="recovery-hub-id"])) |> render() =~ "hub_default"
      assert view |> element(~s([data-testid="recovery-local"])) |> render() =~ "serving"

      assert view |> element(~s([data-testid="recovery-node-flezha@node-b"])) |> render() =~
               "replaying"

      assert [["default", nodes, _ctx]] =
               FakeController.calls(node, {Controller, :recovery_per_node})

      assert node in nodes and :"flezha@node-b" in nodes
    end

    test "an unreachable node is stated while the others still show", %{conn: conn, node: node} do
      one_namespace(node, hub_nodes: [:"flezha@node-b"])

      FakeController.set(
        node,
        {Controller, :recovery_per_node},
        {:ok, %{node => :normal, "flezha@node-b": :unreachable}}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      assert view |> element(~s([data-testid="recovery-node-flezha@node-b"])) |> render() =~
               "could not be reached"

      assert view |> element(~s([data-testid="recovery-node-#{node}"])) |> render() =~ "serving"
    end

    test "a node that finishes recovering shows it on the next tick", %{conn: conn, node: node} do
      one_namespace(node, hub_nodes: [:"flezha@node-b"])

      FakeController.set(
        node,
        {Controller, :recovery_per_node},
        {:ok, %{"flezha@node-b": :replaying}}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      FakeController.set(
        node,
        {Controller, :recovery_per_node},
        {:ok, %{"flezha@node-b": :normal}}
      )

      send(view.pid, :refresh)

      assert view |> element(~s([data-testid="recovery-node-flezha@node-b"])) |> render() =~
               "serving"
    end

    test "a node hosting no hub for the namespace is not asked for one", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, hub_nodes: [:"flezha@node-b"])

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      assert view |> element(~s([data-testid="recovery-local"])) |> render() =~
               "no hub on this node"

      assert FakeController.calls(node, {Controller, :recovery_state}) == []
      assert has_element?(view, ~s([data-testid="recovery-node-flezha@node-b"]))
    end

    test "a refused per-node read keeps the hub and the local state", %{conn: conn, node: node} do
      one_namespace(node, hub_nodes: [node])

      FakeController.set(
        node,
        {Controller, :recovery_per_node},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      assert view |> element(~s([data-testid="recovery-local"])) |> render() =~ "serving"

      assert view |> element(~s([data-testid="recovery-per-node-error"])) |> render() =~
               "authz.role_insufficient"
    end

    test "a refused read is stated and the screen still renders", %{conn: conn, node: node} do
      one_namespace(node, hub_nodes: [])

      FakeController.set(
        node,
        {Controller, :hub_id},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      view |> element(~s([data-testid="open-recovery-default"])) |> render_click()

      assert view |> element(~s([data-testid="recovery-error"])) |> render() =~
               "authz.role_insufficient"

      assert has_element?(view, ~s([data-testid="cluster-namespace-default"]))
    end
  end
end
