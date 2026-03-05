defmodule FlezhaUiWeb.DashboardLiveTest do
  use FlezhaUiWeb.ConnCase, async: true

  import FlezhaUi.AccountsFixtures

  describe "DashboardLive" do
    test "unauthenticated GET / redirects to login", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert redirected_to(conn) == ~p"/users/log-in"
    end

    test "authenticated GET / renders Dashboard", %{conn: conn} do
      user = user_fixture()
      conn = conn |> log_in_user(user) |> get(~p"/")
      assert html_response(conn, 200) =~ "Dashboard"
    end
  end
end
