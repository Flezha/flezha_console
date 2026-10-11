defmodule FlezhaUiWeb.BrandTest do
  @moduledoc """
  What every page must carry to be recognisably Flezha: the theme contract's
  pre-paint hydration, the badger favicon, and the badger lockup.

  These live in the layouts, so no screen asserts them individually — but a
  regression in any of them is invisible until someone loads the console and
  sees a flash of the wrong theme or a framework favicon.
  """

  use FlezhaUiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import FlezhaUi.AccountsFixtures

  describe "the theme contract" do
    test "the server sets no theme, leaving it to the device and the visitor", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      refute html =~ ~s(data-theme=")
      assert html =~ "prefers-color-scheme: light"
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

    test "the served icons are the stylebook's badger, not the framework default" do
      svg = File.read!("priv/static/favicon.svg")
      assert svg =~ "prefers-color-scheme"
      refute svg =~ "linearGradient"

      # An ICO container: reserved 0, type 1 (icon), several sizes.
      assert <<0, 0, 1, 0, count::little-16, _rest::binary>> =
               File.read!("priv/static/favicon.ico")

      assert count > 1
    end
  end

  describe "the brand lockup" do
    test "the login screen shows the Flezha UI lockup mask, in the brand ink", %{
      conn: conn
    } do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(class="flz-brand text-th-brand")
      assert html =~ "mask-image: url(/images/flezha-ui-badger-line-text-white.svg)"
      assert html =~ ~s(role="img" aria-label="Flezha UI")
      refute html =~ "flezha-ui-purple"
      refute html =~ "flezha-ui-gold"
    end

    test "the lockup it masks with is served", %{conn: conn} do
      svg = conn |> get("/images/flezha-ui-badger-line-text-white.svg") |> response(200)

      assert svg =~ "<title>Flezha UI</title>"
    end

    test "the sidebar shows the same lockup in the chrome's ink", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/")

      assert html =~ ~r/<span class="flz-brand\s*">/
      assert html =~ "mask-image: url(/images/flezha-ui-badger-line-text-white.svg)"
      assert html =~ ~s(aria-label="Flezha UI")
      refute html =~ "flezha-ui-gold"
    end

    test "the login screen shows the mascot, decorative and hidden on phones", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(src="/images/badger-laptop.webp")
      assert html =~ ~s(alt="" class="flz-hide-mobile)
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
