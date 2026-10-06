defmodule FlezhaUiWeb.ConsoleNavigationTest do
  @moduledoc """
  The shell every screen is rendered inside: the two-section rail, the scope
  carried in the route, the crumb trail, the tabs on a relay, the palette,
  the account menu, and a screen's own liveness.

  Covered here rather than per screen, because none of it belongs to a screen —
  a regression in any of it would otherwise surface as fourteen unrelated
  failures, or as none at all.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay

  defp with_fleet(node, namespaces, rows_by_namespace \\ %{}) do
    FakeController.set_fleet(node,
      namespaces: namespaces,
      rows:
        Map.new(rows_by_namespace, fn {namespace, ids} ->
          {namespace, Enum.map(ids, &FakeController.relay_row/1)}
        end)
    )
  end

  # The rail alone. Both the sidebar and the crumb trail mark their current
  # entry `aria-current="page"`, which is right in both places — so a count of
  # what the rail marks has to read the rail.
  defp rail(html), do: within(html, ".flz-sidebar-nav")

  # One region of a rendered screen, parsed. Read through the DOM rather than
  # by cutting the string: a component's global attributes render in map order,
  # so any assertion about two attributes sitting next to each other is a coin
  # toss.
  defp within(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp hrefs(fragment), do: fragment |> LazyHTML.query("a") |> LazyHTML.attribute("href")

  # The elements of a region carrying the current-page marking.
  defp current_entries(fragment), do: fragment |> LazyHTML.query("[aria-current=page]")

  defp attr(element, name), do: element |> LazyHTML.attribute(name) |> List.first()

  defp open_palette(view) do
    view |> element("#command-palette") |> render_hook("open", %{})
  end

  defp search_palette(view, query) do
    view |> element("#command-palette form") |> render_change(%{"q" => query})
  end

  describe "the rail" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"])
      :ok
    end

    test "is two labelled groups", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      headings =
        html
        |> rail()
        |> LazyHTML.query(".flz-sidebar-section")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert headings == ["Namespace", "Platform"]
    end

    test "says so when nothing is in scope, rather than pointing nowhere", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="no-namespace-scoped")
    end

    test "offers the namespace's own screens once one is in scope", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="no-namespace-scoped")

      assert html |> rail() |> hrefs() |> Enum.take(4) == [
               "/namespaces/default",
               "/namespaces/default/relays",
               "/namespaces/default/plugins",
               "/namespaces/default/schedules"
             ]
    end

    test "the platform relays entry is named Fleet", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      fleet = html |> rail() |> LazyHTML.query(~s(a[href="/relays"]))

      assert LazyHTML.text(fleet) =~ "Fleet"
    end

    test "dead-letter and observability stay platform-global", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      hrefs = html |> rail() |> hrefs()

      assert "/dlq" in hrefs
      assert "/observability" in hrefs
      refute "/namespaces/default/dlq" in hrefs
    end

    test "marks exactly one destination, on a scoped route as on a flat one", %{conn: conn} do
      for path <- [~p"/", ~p"/relays", ~p"/namespaces/default/plugins"] do
        {:ok, _view, html} = live(conn, path)

        assert Enum.count(current_entries(rail(html))) == 1,
               "#{path} did not mark exactly one rail entry"
      end
    end

    test "a scoped route marks its own entry, not the platform twin", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays")

      assert [entry] = Enum.to_list(current_entries(rail(html)))
      assert attr(entry, "href") == "/namespaces/default/relays"
    end
  end

  describe "the crumb trail" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "a top-level screen carries none", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      refute html =~ ~s(data-testid="breadcrumb")
    end

    test "a deep screen names its ancestors, and only they are links", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/state")

      trail = within(html, ~s([data-testid="breadcrumb"]))

      assert hrefs(trail) == [
               "/namespaces",
               "/namespaces/default",
               "/namespaces/default/relays",
               "/namespaces/default/relays/relay_a"
             ]

      assert LazyHTML.text(trail) =~ "Relays"

      # The page being read is plain text, marked current, and not a link.
      current = current_entries(trail)

      assert LazyHTML.tag(current) == ["span"]
      assert LazyHTML.text(current) |> String.trim() == "State"
    end

    test "the listen view's last crumb reads Listen", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

      current = html |> within(~s([data-testid="breadcrumb"])) |> current_entries()

      assert LazyHTML.text(current) |> String.trim() == "Listen"
    end

    test "the bare back arrow is gone", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a")

      refute html =~ "hero-arrow-left"
    end
  end

  describe "the namespace picker" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"])
      :ok
    end

    test "offers only the namespaces the token can reach", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}]}
      )

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="namespace-picker-default")
      refute html =~ ~s(data-testid="namespace-picker-billing")
    end

    test "keeps the screen kind when switching from a scoped screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays")

      assert view
             |> element(~s([data-testid="namespace-picker-billing"]))
             |> render_click()
             |> follow_redirect(conn, ~p"/namespaces/billing/relays")
    end

    test "goes to the namespace's overview from a platform screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert view
             |> element(~s([data-testid="namespace-picker-billing"]))
             |> render_click()
             |> follow_redirect(conn, ~p"/namespaces/billing")
    end
  end

  describe "the account menu" do
    setup %{node: node} do
      with_fleet(node, ["default"])
      :ok
    end

    test "holds the identity, settings, theme and log out", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~s(data-testid="account-menu")
      assert html =~ ~s(data-testid="account-identity")
      assert html =~ ~s(href="/users/settings")
      assert html =~ "data-flz-theme-toggle"
      assert html =~ ~s(data-testid="log-out")
    end

    test "no log-out control sits outside it", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      # One control, and it is a row of the menu rather than a bare topbar link.
      control = within(html, ~s([data-testid="log-out"]))

      assert attr(control, "class") =~ "flz-menu-item"
    end
  end

  describe "namespace-scoped routes" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"], %{
        "default" => ["relay_default"],
        "billing" => ["relay_billing"]
      })

      :ok
    end

    test "relays lists only the namespace, as a fixed scope", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/billing/relays")

      assert html =~ "relay_billing"
      refute html =~ "relay_default"

      # Stated as the screen's scope, not offered as a filter to clear.
      assert html =~ ~s(data-testid="fixed-namespace")
      refute html =~ ~s(data-testid="filter-namespace")
    end

    test "plugins reads the scoped namespace alone, so it needs no filter notice", %{
      conn: conn,
      node: node
    } do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/plugins")

      refute html =~ "view filter"

      namespaces =
        node
        |> FakeController.calls({PluginManager, :enabled})
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      assert namespaces == ["default"]
    end

    test "schedules states that its scope is a view filter", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/schedules")

      assert html =~ ~s(data-testid="schedule-scope-notice")
      assert html =~ "view filter"
    end

    test "a scoped schedule form opens aimed at the scoped namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/billing/schedules")

      html = render_click(view, "open_form", %{})

      assert html =~ ~s(value="billing")
    end

    test "each pair of routes is served by one LiveView", %{conn: _conn} do
      for {platform, scoped} <- [
            {"/relays", "/namespaces/default/relays"},
            {"/plugins", "/namespaces/default/plugins"},
            {"/schedules", "/namespaces/default/schedules"}
          ] do
        assert route_module(platform) == route_module(scoped)
      end
    end
  end

  describe "filters as URL state" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"], %{
        "default" => ["relay_default"],
        "billing" => ["relay_billing"]
      })

      :ok
    end

    test "filtering writes the filter into the query string", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      render_change(view, "filter", %{"filters" => %{"namespace" => "billing"}})

      assert_patch(view, ~p"/relays?namespace=billing")
    end

    test "a filtered URL reproduces the same listing on reload", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/relays?namespace=billing")

      assert html =~ "relay_billing"
      refute html =~ "relay_default"
    end

    test "clearing a filter clears it, so the back button reverses one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays?namespace=billing")

      render_change(view, "filter", %{"filters" => %{"namespace" => ""}})

      assert_patch(view, ~p"/relays")
      assert render(view) =~ "relay_default"
    end

    test "a scoped route keeps its namespace out of the query string", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/billing/relays")

      render_change(view, "filter", %{"filters" => %{"health" => "healthy"}})

      assert_patch(view, ~p"/namespaces/billing/relays?health=healthy")
    end

    test "a run filter is written into the query string as run", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      render_change(view, "filter", %{"filters" => %{"run" => "steps"}})

      assert_patch(view, ~p"/relays?run=steps")
    end
  end

  describe "a relay's views as tabs" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "the detail view carries the strip, marked on itself", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a")

      assert_tabs(html, "detail")
    end

    test "the listen view carries the strip, marked on itself", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

      assert_tabs(html, "listen")
    end

    test "the state view carries the strip, marked on itself", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/state")

      assert_tabs(html, "state")
    end

    test "a tab navigates rather than toggling a panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")

      assert view
             |> element(~s([data-testid="relay-tab-listen"]))
             |> render_click()
             |> follow_redirect(conn, ~p"/namespaces/default/relays/relay_a/listen")
    end

    test "moving from listen to state releases the listen", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

      assert PeerNode.eventually(fn -> listening?(node) end)

      view
      |> element(~s([data-testid="relay-tab-state"]))
      |> render_click()
      |> follow_redirect(conn, ~p"/namespaces/default/relays/relay_a/state")

      assert PeerNode.eventually(fn -> not listening?(node) end),
             "the listen was still open after leaving the listen view"
    end
  end

  describe "a folded panel" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "carries the id its hook needs, and the state the hook restores", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a")

      panel = within(html, ~s([data-section-key="plugins"]))

      # Without an id LiveView refuses to mount the hook, and the viewer's own
      # choice is silently never restored.
      assert attr(panel, "id") == "plugins"
      assert attr(panel, "phx-hook") == "FlzSection"
      assert attr(panel, "data-open") == "false"
    end

    test "a panel with no fold carries neither the hook nor its markings", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      panels = within(html, ".flz-panel")
      hooks = LazyHTML.attribute(panels, "phx-hook")

      # The namespace screen holds panels of both kinds; only the folding ones
      # are hooked, and nothing else on the screen borrowed the marking.
      assert Enum.uniq(hooks) == ["FlzSection"]
      assert length(hooks) < Enum.count(panels)
      assert length(hooks) == Enum.count(within(html, "[data-section-key]"))
    end
  end

  describe "the command palette" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a", "relay_b"]})
      :ok
    end

    test "a screen that never opens it makes no listing call for it", %{conn: conn, node: node} do
      {:ok, _view, _html} = live(conn, ~p"/audit")

      assert FakeController.calls(node, {Relay, :list}) == []
    end

    test "it offers a relay by id, with its namespace and health", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      assert open_palette(view) =~ ~s(data-testid="command-palette")

      html = search_palette(view, "relay_b")

      assert html =~ ~s(data-testid="command-palette-relay-relay_b")
      assert html =~ "default · healthy"
      assert html =~ "/namespaces/default/relays/relay_b"
      refute html =~ ~s(data-testid="command-palette-relay-relay_a")
    end

    test "it offers a screen by name, and that screen is in the rail too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      open_palette(view)
      html = search_palette(view, "dead")

      assert html =~ ~s(data-testid="command-palette-screen-Dead-letter")
      assert "/dlq" in hrefs(rail(html))
    end

    test "nothing matching says so rather than showing an empty list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/audit")

      open_palette(view)
      html = search_palette(view, "nothing-is-called-this")

      assert html =~ ~s(data-testid="command-palette-empty")
      refute html =~ ~s(data-testid="command-palette-results")
    end

    test "a relay that has since stopped lands on the not-found state", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_gone")

      # The relay screen reading every fact as absent, not an error page.
      assert html =~ "relay_gone"
      assert html =~ ~s(data-testid="relay-health")
    end
  end

  describe "a screen's liveness" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "an auto-refreshing screen states its interval and last refresh", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="liveness")
      assert html =~ ~s(data-testid="liveness-toggle")
      assert html =~ "Every 5s"
    end

    test "a screen with no timer states no liveness", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

      refute html =~ ~s(data-testid="liveness")
    end

    test "pausing holds the rows still and says so", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      assert render_click(view, "refresh_toggle", %{}) =~ "Paused"

      with_fleet(node, ["default"], %{"default" => ["relay_later"]})
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "relay_a"
      refute html =~ "relay_later"
    end

    test "resuming refreshes at once and keeps ticking", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      render_click(view, "refresh_toggle", %{})
      with_fleet(node, ["default"], %{"default" => ["relay_later"]})

      html = render_click(view, "refresh_toggle", %{})

      refute html =~ "Paused"
      assert html =~ "relay_later"

      # The timer was never cancelled, so the screen goes on ticking.
      with_fleet(node, ["default"], %{"default" => ["relay_later_still"]})
      send(view.pid, :refresh)

      assert render(view) =~ "relay_later_still"
    end

    test "a screen that suspends for its own modal still does", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      render_click(view, "launcher_open", %{})
      with_fleet(node, ["default"], %{"default" => ["relay_later"]})
      send(view.pid, :refresh)
      html = render(view)

      refute html =~ "relay_later"
      # Its own suspension, not the operator's — the control still reads live.
      refute html =~ "Paused"
    end
  end

  describe "relay routes" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "each relay path mounts its screen", %{conn: conn} do
      for path <- [
            ~p"/relays",
            ~p"/namespaces/default/relays",
            ~p"/namespaces/default/relays/relay_a",
            ~p"/namespaces/default/relays/relay_a/listen",
            ~p"/namespaces/default/relays/relay_a/state"
          ] do
        assert conn |> get(path) |> html_response(200), "#{path} did not mount"
      end
    end

    test "a retired path answers 404 and is not redirected", %{conn: conn} do
      for path <- [
            "/operatives",
            "/namespaces/default/operatives",
            "/namespaces/default/operatives/x",
            "/namespaces/default/operatives/x/stream",
            "/namespaces/default/relays/x/stream"
          ] do
        response = get(conn, path)

        assert response.status == 404, "#{path} answered #{response.status}"
        assert get_resp_header(response, "location") == [], "#{path} was redirected"
      end
    end
  end

  # ---- Helpers ----

  defp assert_tabs(html, current) do
    strip = within(html, ~s([data-testid="relay-tabs"]))

    assert strip |> LazyHTML.query("a") |> LazyHTML.attribute("data-testid") ==
             ~w(relay-tab-detail relay-tab-listen relay-tab-state)

    marked = current_entries(strip)

    assert LazyHTML.attribute(marked, "data-testid") == ["relay-tab-#{current}"]
  end

  defp route_module(path) do
    Phoenix.Router.route_info(FlezhaUiWeb.Router, "GET", path, "localhost").plug_opts
  end

  # The controller holds a listen open while the screen's feed lives.
  defp listening?(node), do: FakeController.streams(node, {Relay, :listen}) != []
end
