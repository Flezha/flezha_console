defmodule FlezhaUiWeb.BrandTest do
  @moduledoc """
  What every page must carry to be recognisably Flezha: the theme contract's
  pre-paint hydration, the Flezha favicon, and the brand lockup.

  These live in the layouts, so no screen asserts them individually — but a
  regression in any of them is invisible until someone loads the console and
  sees a flash of the wrong theme or a framework favicon.
  """

  use FlezhaUiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FlezhaUi.AccountsFixtures

  describe "the theme contract" do
    test "the document defaults to dark before any script runs", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(data-theme="dark")
      refute html =~ ~s(id="html-root")
    end

    test "hydration is inlined in the head, ahead of the stylesheet", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ "localStorage.getItem('flezha-theme')"

      # Ahead of the stylesheet, or the first paint uses the wrong theme.
      [head | _] = String.split(html, "</head>")
      assert :binary.match(head, "flezha-theme") < :binary.match(head, "/assets/app.css")
    end

    test "the superseded contract is gone", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      refute html =~ "toggleTheme()"
      refute html =~ ~s(class="light")
    end
  end

  describe "the favicon" do
    test "both the vector icon and its raster fallback are linked", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(href="/favicon.svg")
      assert html =~ ~s(href="/favicon.ico")
    end

    test "the served icons are the Flezha mark, not the framework default" do
      assert File.read!("priv/static/favicon.svg") =~ "linearGradient"
      # An ICO container: reserved 0, type 1 (icon), one image.
      assert <<0, 0, 1, 0, 1, 0, _rest::binary>> = File.read!("priv/static/favicon.ico")
    end
  end

  describe "the brand lockup" do
    test "the login screen shows the themed canvas pair", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ "/images/flezha-ui-purple-on-dark.svg"
      assert html =~ "/images/flezha-ui-purple-on-light.svg"
      assert html =~ ~s(alt="Flezha UI")

      # The hand-set wordmark it replaced.
      refute html =~ ~s(>flezha</span>)
    end

    test "the sidebar shows the flat lockup that does not clash with the chrome", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "/images/flezha-ui-gold-mono-on-dark.svg"
      assert html =~ ~s(alt="Flezha UI")
    end
  end

  describe "the shell" do
    test "the current destination is marked server-side", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(aria-current="page")

      # Exactly one destination, or the rail marks two places at once.
      assert html |> String.split(~s(aria-current="page")) |> length() == 2
    end

    test "the theme control is the stylebook's toggle", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ "data-flz-theme-toggle"
      assert html =~ "flz-sidebar"
      assert html =~ "flz-topbar"
    end
  end
end
