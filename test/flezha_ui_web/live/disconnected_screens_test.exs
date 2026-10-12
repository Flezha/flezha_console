defmodule FlezhaUiWeb.DisconnectedScreensTest do
  @moduledoc """
  Every screen this change adds, rendered with no controller connected at all.

  A screen that crashes when the controller is away is worse than one that says
  so, and "away" is the state an operator is most likely to be looking at the
  UI during. No peer is started here: `NodeManager.connected_node/0` reads the
  VM's connection list, so the absence has to be real rather than mocked.
  """

  use FlezhaUiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    %{conn: log_in_user(conn, FlezhaUi.AccountsFixtures.user_fixture())}
  end

  for {route, name} <- [
        {"/namespaces/default", "namespace home"},
        {"/namespaces", "namespaces"},
        {"/relays", "relays index"},
        {"/controller", "controller health"},
        {"/observability", "observability"},
        {"/cluster", "cluster"},
        {"/plugins", "plugins"},
        {"/schedules", "schedules"},
        {"/dlq", "dead-letter queue"},
        {"/audit", "audit log"},
        {"/namespaces/default/relays/relay_a", "relay detail"},
        {"/namespaces/default/relays/relay_a/listen", "relay listen"},
        {"/namespaces/default/relays/relay_a/state", "relay state"}
      ] do
    test "the #{name} screen renders without a controller", %{conn: conn} do
      assert {:ok, _view, html} = live(conn, unquote(route))

      # It rendered rather than raising, and it claims no health it cannot know.
      assert html =~ "flezha"
      refute html =~ ~s(data-health="healthy")
    end
  end

  test "Home says no controller is connected rather than drawing an empty map", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/namespaces/default")

    assert html =~ ~s(data-testid="topology-disconnected")
  end

  test "the cluster screen says it knows of no node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cluster")

    assert has_element?(view, ~s([data-testid="cluster-nodes-empty"]))
    assert has_element?(view, ~s([data-testid="cluster-disconnected"]))
  end

  test "the start form still opens, asking for no run", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/relays")

    html = render_click(view, "launcher_open", %{})

    # The factories could not be read, so the field takes a typed id, and how
    # the relay runs is never a field.
    assert html =~ ~s(data-testid="start-modal")
    assert has_element?(view, ~s([data-testid="input-factory-id"]))
    refute has_element?(view, ~s([name="start[run]"]))
    refute has_element?(view, ~s([data-testid="factory-run"]))
  end

  test "a start with nothing to start into is refused rather than attempted", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/relays")
    render_click(view, "launcher_open", %{})

    html =
      render_submit(view, "launcher_submit", %{
        "start" => %{
          "namespace" => "",
          "id" => "relay_a",
          "factory_id" => "store_input",
          "init_values" => "",
          "snapshot_interval" => ""
        }
      })

    assert html =~ ~s(data-testid="start-error")
    assert html =~ "A namespace is required."
  end

  test "the listen screen says it could not attach rather than spinning", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

    # The feed reports its refusal to the screen asynchronously.
    assert FlezhaUi.PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="listen-error") end)
    assert render(view) =~ "Not connected to a flezha controller"
  end

  test "the seam reports no connection rather than raising", _context do
    # The shape every one of those screens depends on.
    alias FlezhaUi.Service.NodeManager

    assert NodeManager.connected_node() == nil
    assert {:error, :node_not_connected} = NodeManager.relay_list("default", nil)
    assert {:error, :node_not_connected} = NodeManager.enforcement_posture()
    assert {:error, :node_not_connected} = NodeManager.factory_catalog("default", nil)
  end
end
