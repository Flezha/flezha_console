defmodule FlezhaUiWeb.DashboardLiveTest do
  @moduledoc """
  The dashboard, which reports the controller's state at a glance.

  The browser suite asserts the connected shape against the dev stack. The
  disconnected state is the one it cannot produce, and it is the state an
  operator is most likely to hit.
  """

  use FlezhaUiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FlezhaUi.AccountsFixtures

  describe "access" do
    test "an unauthenticated visit is redirected to the login form", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/")) == ~p"/users/log-in"
    end
  end

  describe "with no controller connected" do
    setup %{conn: conn} do
      # This case needs a genuinely disconnected UI. Async cases run before the
      # peer-backed sync ones, so nothing is connected here — asserted rather
      # than assumed, because the failure would otherwise read as a rendering
      # bug rather than a run-order one.
      assert FlezhaUi.Service.NodeManager.connected_node() == nil

      %{conn: log_in_user(conn, user_fixture())}
    end

    test "says so rather than reporting zeroes as if they were real", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="node-disconnected")
      assert html =~ "Not connected"
      assert html =~ "FLEZHA_NODE"
      refute html =~ ~s(data-testid="node-connected")
    end

    test "renders zeroed tiles alongside the disconnected notice", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="stat-namespaces")
      assert html =~ "Not connected to a flezha controller"
    end

    test "the topology graph degrades rather than drawing a graph of nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="topology-disconnected")
      refute html =~ ~s(data-testid="topo-node-ingest")
    end
  end
end

defmodule FlezhaUiWeb.DashboardLiveConnectedTest do
  @moduledoc """
  The dashboard against a controller that answers.

  Separate from the disconnected case because that one must run with no peer
  at all — `NodeManager.connected_node/0` reads global VM state, so the two
  cannot share a setup.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.ConfigManager
  alias Flezha.Service.PluginManager

  test "reports the connected node and the counts behind it", %{conn: conn, node: node} do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default", "staging"]})
    FakeController.set(node, {Flezha, :list_operatives}, {:ok, ["op_a", "op_b"]})
    FakeController.set(node, {Flezha, :list_runners}, {:ok, [%{id: "runner-a"}]})
    FakeController.set(node, {PluginManager, :get_plugins}, %{"plug_1" => {"default", "op_a"}})

    FakeController.set(
      node,
      {ConfigManager, :get_provider_info},
      {:ok, [%{id: :operative_stdout, required_fields: []}]}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-testid="node-connected")
    assert html =~ to_string(node)
    refute html =~ ~s(data-testid="node-disconnected")

    assert html =~ ~s(data-testid="dashboard-namespace-default")
    assert html =~ ~s(data-testid="dashboard-namespace-staging")
    assert html =~ ~s(data-testid="dashboard-runner-row-runner-a")
    assert html =~ "1 providers available"
  end

  test "a namespace listing that fails is reported without blanking the page", %{
    conn: conn,
    node: node
  } do
    FakeController.set(node, {Flezha, :list_namespaces}, {:error, :timeout})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "The flezha controller did not answer in time."
    # Still connected — the node panel must not read as disconnected.
    assert html =~ ~s(data-testid="node-connected")
  end

  test "explains an empty fleet", %{conn: conn, node: node} do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
    FakeController.set(node, {Flezha, :list_runners}, {:ok, []})

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-testid="dashboard-runners-empty")
  end
end
