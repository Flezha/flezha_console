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
        {"/", "dashboard"},
        {"/namespaces", "namespaces"},
        {"/operatives", "operatives index"},
        {"/controller", "controller health"},
        {"/observability", "observability"},
        {"/cluster", "cluster"},
        {"/plugins", "plugins"},
        {"/schedules", "schedules"},
        {"/dlq", "dead-letter queue"},
        {"/audit", "audit log"},
        {"/namespaces/default/operatives/op_a", "operative detail"},
        {"/namespaces/default/operatives/op_a/state", "operative state"}
      ] do
    test "the #{name} screen renders without a controller", %{conn: conn} do
      assert {:ok, _view, html} = live(conn, unquote(route))

      # It rendered rather than raising, and it claims no health it cannot know.
      assert html =~ "flezha"
      refute html =~ ~s(data-health="healthy")
    end
  end

  test "the seam reports no connection rather than raising", _context do
    # The shape every one of those screens depends on.
    assert FlezhaUi.Service.NodeManager.connected_node() == nil
    assert {:error, :node_not_connected} = FlezhaUi.Service.NodeManager.operative_rows("default")
    assert {:error, :node_not_connected} = FlezhaUi.Service.NodeManager.enforcement_posture()
  end
end
