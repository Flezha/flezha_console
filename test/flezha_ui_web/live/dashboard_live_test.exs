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

  alias Flezha.Service.Fleet
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay

  defp stat(html, testid) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-testid="#{testid}"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  test "reports the connected node and the counts behind it", %{conn: conn, node: node} do
    FakeController.set_fleet(node,
      rows: %{
        "default" => [FakeController.relay_row("relay_a"), FakeController.relay_row("relay_b")],
        "staging" => []
      }
    )

    FakeController.set(
      node,
      {Fleet, :runners},
      {:per_arg, 0, %{"default" => {:ok, [%{id: "runner-a", pid: nil}]}}, {:ok, []}}
    )

    FakeController.set(
      node,
      {PluginManager, :enabled},
      {:per_arg, 0, %{"default" => {:ok, [%{name: "plug_1"}]}}, {:ok, []}}
    )

    FakeController.set(
      node,
      {Fleet, :providers},
      {:ok, %{providers: [%{id: "relay_stdout", module: "StdOut", type: :relay}], refused: 0}}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-testid="node-connected")
    assert html =~ to_string(node)
    refute html =~ ~s(data-testid="node-disconnected")

    assert html =~ ~s(data-testid="dashboard-namespace-default")
    assert html =~ ~s(data-testid="dashboard-namespace-staging")
    assert html =~ ~s(data-testid="dashboard-runner-row-runner-a")
    assert stat(html, "stat-relays") == "2"
    assert stat(html, "stat-plugins") == "1"
    assert html =~ "1 providers available"
  end

  test "counts a declared namespace with no hub but graphs only running ones", %{
    conn: conn,
    node: node
  } do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}, %{namespace: "declared", running: false}]}
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert stat(html, "stat-namespaces") == "2"
    assert html =~ ~s(data-testid="dashboard-namespace-default")
    refute html =~ ~s(data-testid="dashboard-namespace-declared")
  end

  test "a namespace listing that fails is reported without blanking the page", %{
    conn: conn,
    node: node
  } do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      FakeController.error(
        "controller.timeout",
        "a part of the controller did not answer in time"
      )
    )

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ "did not answer in time"
    # Still connected — the node panel must not read as disconnected.
    assert html =~ ~s(data-testid="node-connected")
  end

  test "explains an empty fleet", %{conn: conn, node: node} do
    FakeController.set_fleet(node, namespaces: ["default"])

    {:ok, _view, html} = live(conn, ~p"/")

    assert html =~ ~s(data-testid="dashboard-runners-empty")
  end
end
