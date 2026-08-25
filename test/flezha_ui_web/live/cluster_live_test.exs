defmodule FlezhaUiWeb.ClusterLiveTest do
  @moduledoc """
  The cluster and fleet screen, against a controller whose fleet can be emptied.

  The browser suite asserts the healthy shape — nodes, hubs, runners with
  factories — because the dev stack guarantees a connected runner. What it
  cannot produce is the interesting half: a factory no runner serves, a
  namespace with no hub, a controller that cannot answer at all.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Cluster.Directory
  alias Flezha.Runner.FleetManager
  alias Flezha.Service.CliManager
  alias Flezha.Service.HubManager

  defp one_namespace(node, opts) do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
    FakeController.set(node, {Flezha, :list_factories}, {:ok, opts[:factories] || []})
    FakeController.set(node, {Directory, :hub_nodes}, {:ok, opts[:hub_nodes] || []})
    FakeController.set(node, {FleetManager, :active_runners}, {:ok, opts[:runners] || []})

    FakeController.set(
      node,
      {FleetManager, :runners_for_factory},
      opts[:runners_for_factory] || {:ok, []}
    )
  end

  describe "cluster membership" do
    test "marks the node this UI is connected to", %{conn: conn, node: node} do
      one_namespace(node, [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-nodes")
      assert html =~ "connected to this UI"
      assert html =~ to_string(node)
    end

    test "lists the cluster the controller reports, not just the connected node", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      # `controller_cluster_nodes/0` asks the controller for `:erlang.nodes/1`,
      # so the test VM shows up alongside the peer — proving the list came from
      # the controller rather than from this side of the connection.
      assert html =~ ~s(data-testid="cluster-node-#{node}")
      assert html =~ ~s(data-testid="cluster-node-#{Node.self()}")
    end
  end

  describe "namespaces and their fleets" do
    test "renders hub placement and the runners serving a namespace", %{conn: conn, node: node} do
      one_namespace(node,
        factories: ["store_input"],
        hub_nodes: [:"flezha@hub-1"],
        runners: [%{id: "runner-a"}],
        runners_for_factory: {:ok, [%{id: "runner-a"}]}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-namespace-default")
      assert html =~ ~s(data-testid="hub-nodes-default")
      assert html =~ "flezha@hub-1"
      assert html =~ ~s(data-testid="runners-default")
      assert html =~ "runner-a"
      assert html =~ "store_input"
    end

    test "each runner is credited with the factories it serves", %{conn: conn, node: node} do
      # The pairing now comes from the shared catalog rather than an inversion
      # built here; what the fleet view reports must not have changed with it.
      one_namespace(node,
        factories: ["store_input", "compare_filter"],
        runners: [%{id: "runner-a"}, %{id: "runner-b"}],
        runners_for_factory:
          {:per_arg, 1,
           %{
             "store_input" => {:ok, [%{id: "runner-a"}, %{id: "runner-b"}]},
             "compare_filter" => {:ok, [%{id: "runner-b"}]}
           }, {:ok, []}}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      [_before, fleet] = String.split(html, ~s(data-testid="runners-default"), parts: 2)
      [fleet, _after] = String.split(fleet, "</ul>", parts: 2)
      [_prefix, runner_a, runner_b] = String.split(fleet, ~s(data-testid="runner-))

      assert runner_a =~ "store_input"
      refute runner_a =~ "compare_filter"
      assert runner_b =~ "compare_filter, store_input"
    end

    test "renders the empty fleet rather than an empty panel", %{conn: conn, node: node} do
      one_namespace(node, factories: ["store_input"], runners: [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runners-empty-default")
    end

    test "renders the empty cluster when no namespace is running", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, []})

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-namespaces-empty")
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ "The flezha controller did not answer in time."
    end
  end

  describe "factory placement lookup" do
    setup %{node: node} do
      one_namespace(node, factories: ["store_input"], runners: [%{id: "runner-a"}])
      :ok
    end

    test "names the runners serving the factory", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {FleetManager, :runners_for_factory},
        {:ok, [%{id: "runner-a"}, %{id: "runner-b"}]}
      )

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

    test "says so when no runner serves the factory", %{conn: conn, node: node} do
      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, []})

      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        render_click(view, "select_factory", %{
          "namespace" => "default",
          "factory" => "store_input"
        })

      # The state the browser suite cannot reach: every factory it can offer
      # comes from a connected runner.
      assert html =~ ~s(data-testid="factory-runners-empty")
    end

    test "selecting a factory is a lookup, not another controller read", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/cluster")
      before = length(FakeController.calls(node, {FleetManager, :runners_for_factory}))

      render_click(view, "select_factory", %{"namespace" => "default", "factory" => "store_input"})

      # The catalog this screen already loaded says which runners serve each
      # factory; asking again would be paying twice for the same answer.
      assert length(FakeController.calls(node, {FleetManager, :runners_for_factory})) == before
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
      one_namespace(node, factories: [], runners: [])

      {:ok, view, html} = live(conn, ~p"/cluster")
      refute html =~ "runner-late"

      FakeController.set(node, {FleetManager, :active_runners}, {:ok, [%{id: "runner-late"}]})
      send(view.pid, {:flezha_event, :runner_connected, %{}})

      assert render(view) =~ "runner-late"
    end
  end

  describe "per-node rollup" do
    defp row(id, overrides \\ %{}), do: FakeController.operative_row(id, overrides)

    defp placed(node, opts) do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
      FakeController.set(node, {HubManager, :operative_rows}, opts[:rows] || [])

      FakeController.set(
        node,
        {Directory, :hub_nodes},
        {:ok, opts[:hub_nodes] || [:"flezha@node-a"]}
      )

      FakeController.set(node, {CliManager, :cluster_status_recovery}, opts[:recovery] || %{})
    end

    test "each node shows its operative count broken down by health", %{conn: conn, node: node} do
      placed(node,
        rows: [
          row("a"),
          row("b", %{health: :degraded}),
          row("c", %{node: :"flezha@node-b"})
        ],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-rollup-default")
      assert html =~ ~s(data-testid="node-count-flezha@node-a")
      assert html =~ ~s(data-health="degraded")
    end

    test "a split view makes the disagreement visible", %{conn: conn, node: node} do
      # One node hosts everything; its peer hosts none.
      placed(node,
        rows: [row("a"), row("b")],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-flezha@node-a")
      refute html =~ ~s(data-testid="node-flezha@node-b")
    end

    test "operatives with no live node are named", %{conn: conn, node: node} do
      placed(node, rows: [row("stranded", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="unplaced-default")
      assert html =~ "stranded"
    end

    test "a hub mid-recovery is distinguishable from one serving", %{conn: conn, node: node} do
      placed(node,
        rows: [row("a")],
        recovery: %{:"flezha@node-a" => :replaying}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="recovery-flezha@node-a")
      assert html =~ "replaying"
      refute html =~ "serving"
    end

    test "unavailable recovery state does not fail the screen", %{conn: conn, node: node} do
      placed(node, rows: [row("a")], recovery: %{})

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="recovery-unavailable-flezha@node-a")
      assert html =~ ~s(data-testid="node-rollup-default")
    end

    test "each namespace's runner principal is shown", %{conn: conn, node: node} do
      placed(node, rows: [row("a")])
      FakeController.set(node, {FleetManager, :active_runners}, {:ok, ["runner-a"]})

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runner-principal-default")
      assert html =~ "runner@default"
    end

    test "the column is absent when the controller does not carry principals", %{
      conn: conn,
      node: node
    } do
      placed(node, rows: [row("a")])

      FakeController.set(
        node,
        {FleetManager, :runner_caller_context},
        {:error, {:api_missing, FleetManager, :runner_caller_context, 1}}
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      refute html =~ ~s(data-testid="runner-principal-default")
      assert html =~ ~s(data-testid="node-rollup-default")
    end
  end
end
