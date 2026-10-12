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
    test "the adaptive vector icon and a background-free PNG per scheme are linked", %{
      conn: conn
    } do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(href="/favicon.svg")

      assert html =~
               ~r{href="/images/favicon-mark-dark-32.png"\s+media="\(prefers-color-scheme: light\)"}

      assert html =~
               ~r{href="/images/favicon-mark-white-32.png"\s+media="\(prefers-color-scheme: dark\)"}

      refute html =~ "favicon.ico"
    end

    test "the served icons are the stylebook's badger with a transparent ground" do
      svg = File.read!("priv/static/favicon.svg")
      assert svg =~ "prefers-color-scheme"
      refute svg =~ "linearGradient"

      for png <- ~w(favicon-mark-dark-32.png favicon-mark-white-32.png) do
        # A PNG whose colour type 6 carries an alpha channel.
        assert <<0x89, "PNG", _::binary-size(20), 8, 6, _rest::binary>> =
                 File.read!("priv/static/images/#{png}")
      end
    end
  end

  describe "the brand lockup" do
    test "the login screen shows the Flezha UI lockup mask, in the logo ink", %{
      conn: conn
    } do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(class="fui-brand fui-brand--canvas")
      assert html =~ "mask-image: url(/images/flezha-ui-badger-line-text-white.svg)"
      assert html =~ ~s(role="img" aria-label="Flezha UI")
      refute html =~ "flezha-ui-purple"
      refute html =~ "flezha-ui-gold"
    end

    test "the lockup it masks with is served", %{conn: conn} do
      svg = conn |> get("/images/flezha-ui-badger-line-text-white.svg") |> response(200)

      assert svg =~ "<title>Flezha UI</title>"
    end

    test "the rail shows the same lockup in the chrome's ink", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(<span class="flz-brand">)
      assert html =~ "mask-image: url(/images/flezha-ui-badger-line-text-white.svg)"
      assert html =~ ~s(aria-label="Flezha UI")
      refute html =~ "flezha-ui-gold"
    end

    test "the login screen shows the mascot, decorative and hidden on phones", %{conn: conn} do
      html = conn |> get(~p"/users/log-in") |> html_response(200)

      assert html =~ ~s(src="/images/badger-laptop.webp")
      # The kit's mascot recipe hides it below 800 px.
      assert html =~ ~s(alt="" class="fui-auth-mascot")
    end
  end

  describe "the shell" do
    test "the current destination is marked server-side", %{conn: conn} do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(aria-current="page")

      # One destination in the rail, never a second place.
      assert html |> String.split(~s(aria-current="page")) |> length() == 2
    end

    test "the theme control is the stylebook's toggle, always visible in the topbar", %{
      conn: conn
    } do
      conn = log_in_user(conn, user_fixture())
      {:ok, _live, html} = live(conn, ~p"/cluster")
      doc = LazyHTML.from_document(html)

      assert [_toggle] =
               doc |> LazyHTML.query(~s(.flz-topbar [data-flz-theme-toggle])) |> Enum.to_list()

      assert [] =
               doc |> LazyHTML.query(~s(#account-menu [data-flz-theme-toggle])) |> Enum.to_list()

      assert html =~ ~s(class="flz-sidebar")
    end
  end
end
