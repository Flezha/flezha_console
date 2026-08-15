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
end
