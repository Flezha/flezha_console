defmodule FlezhaConsoleWeb.PageControllerTest do
  use FlezhaConsoleWeb.ConnCase, async: true

  test "GET / redirects to login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/users/log-in"
  end
end
