defmodule FlezhaConsoleWeb.ConsoleNavigationTest do
  @moduledoc """
  The shell every screen is rendered inside: the rail and its Problems count,
  the topbar and its namespace picker, the scope carried in the route, the
  crumb trail, the tabs on a relay, the palette and its actions, liveness, and
  where `/` lands.

  Covered here rather than per screen, because none of it belongs to a screen —
  a regression in any of it would otherwise surface as fourteen unrelated
  failures, or as none at all.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias FlezhaConsole.TestEnv

  defp with_fleet(node, namespaces, rows_by_namespace \\ %{}) do
    FakeController.set_fleet(node,
      namespaces: namespaces,
      rows:
        Map.new(rows_by_namespace, fn {namespace, ids} ->
          {namespace, Enum.map(ids, &FakeController.relay_row/1)}
        end)
    )
  end

  # One region of a rendered screen, parsed. Read through the DOM rather than
  # by cutting the string: a component's global attributes render in map order,
  # so any assertion about two attributes sitting next to each other is a coin
  # toss.
  defp within(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp hrefs(fragment), do: fragment |> LazyHTML.query("a") |> LazyHTML.attribute("href")

  defp attr(element, name), do: element |> LazyHTML.attribute(name) |> List.first()

  # The rail alone. Both the rail and the crumb trail mark their current entry
  # `aria-current="page"`, so a count of what the rail marks has to read the
  # rail.
  defp rail(html), do: within(html, ".flz-sidebar-nav")

  defp current_entries(fragment), do: LazyHTML.query(fragment, "[aria-current=page]")

  defp current_destination(html),
    do: html |> rail() |> current_entries() |> LazyHTML.text() |> String.trim()

  defp open_palette(view) do
    view |> element("#command-palette") |> render_hook("open", %{})
  end

  defp search_palette(view, query) do
    view
    |> element(~s([data-testid="command-palette-search"]))
    |> render_change(%{"q" => query})
  end

  describe "the rail and topbar" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "the all-namespaces relays are the Relays screen's switch, not a destination", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/relays")

      assert current_destination(html) == ""
      assert html |> within(~s([data-testid="scope-all"])) |> attr("aria-current") == "true"
    end

    test "dead-letter and observability stay platform-global", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert current_destination(html) =~ "Dead-letter"

      for path <- ["/namespaces/default/dlq", "/namespaces/default/observability"] do
        assert get(conn, path).status == 404
      end
    end
  end

  describe "the narrow shell" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "with no namespace in scope, Home and Relays fall back as the shortcuts do", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html |> within(".flz-tabbar") |> hrefs() |> Enum.take(2) == [
               "/namespaces",
               "/relays"
             ]
    end

    test "the bar and the menu control count open problems in the worst one's tone", %{
      conn: conn,
      node: node
    } do
      FakeController.set_fleet(node,
        namespaces: ["default"],
        rows: %{"default" => [FakeController.relay_row("relay_d", %{health: :degraded})]}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")

      # The bar on a phone, the menu control on a tablet.
      for testid <- ~w(tabbar-problems-count nav-toggle-problems-count) do
        count = view |> render_async() |> within(~s([data-testid="#{testid}"]))
        assert LazyHTML.text(count) =~ "1", testid
        assert attr(count, "data-tone") == "warning"
      end

      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      send(view.pid, :shell_pulse)
      refute render_async(view) =~ ~s(data-testid="tabbar-problems-count")
      refute render(view) =~ ~s(data-testid="nav-toggle-problems-count")
    end

    test "Search in the bar and in the topbar opens the palette, and Cancel closes it", %{
      conn: conn
    } do
      for testid <- ~w(tabbar-search search-open) do
        {:ok, view, _html} = live(conn, ~p"/cluster")
        refute has_element?(view, ~s([data-testid="command-palette"]))

        view |> element(~s([data-testid="#{testid}"])) |> render_click()
        assert has_element?(view, ~s([data-testid="command-palette"])), testid

        view |> element(~s([data-testid="command-palette-close"])) |> render_click()
        refute has_element?(view, ~s([data-testid="command-palette"])), testid
      end
    end
  end

  describe "the crumb trail" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "a deep screen names its ancestors in its page header, and only they are links", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/state")

      trail = within(html, ~s([data-testid="page-header"] [data-testid="breadcrumb"]))

      assert trail |> LazyHTML.text() |> String.split(~r/\s*\/\s*|\s+/, trim: true) ==
               ~w(default Relays relay_a State)

      assert hrefs(trail) == [
               "/namespaces/default",
               "/namespaces/default/relays",
               "/namespaces/default/relays/relay_a"
             ]

      assert trail |> LazyHTML.query("[aria-current=page]") |> LazyHTML.text() =~ "State"
    end
  end

  describe "the namespace picker" do
    setup %{node: node} do
      with_fleet(node, ["billing", "default"], %{"default" => ["relay_a"]})
      :ok
    end

    test "offers only the namespaces the token can reach", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "default", running: true}])
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="namespace-picker-default")
      refute html =~ ~s(data-testid="namespace-picker-billing")
    end

    test "keeps the screen kind when switching from a scoped screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/plugins")

      assert view
             |> element(~s([data-testid="namespace-picker-billing"]))
             |> render_click()
             |> follow_redirect(conn, ~p"/namespaces/billing/plugins")
    end

    test "a platform screen keeps the namespace last worked in", %{conn: conn} do
      {:ok, _view, _html} = live(conn, ~p"/namespaces/billing/relays")
      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html |> within(~s([data-testid="namespace-picker"])) |> LazyHTML.text() =~
               "billing"

      assert "/namespaces/billing/relays" in (html |> rail() |> hrefs())
      refute html =~ ~s(data-testid="no-namespace-scoped")
    end

    test "the namespace is remembered across sessions", %{conn: conn, user: user} do
      {_view, _html} = live_loaded(conn, ~p"/namespaces/billing")

      assert FlezhaConsole.Repo.reload!(user).last_namespace == "billing"
    end

    test "an address naming a namespace the controller lacks is not remembered", %{
      conn: conn,
      user: user
    } do
      {_view, _html} = live_loaded(conn, ~p"/namespaces/billing")
      {:ok, _view, _html} = live(conn, ~p"/namespaces/#{String.duplicate("x", 300)}")

      assert FlezhaConsole.Repo.reload!(user).last_namespace == "billing"
    end

    test "a remembered namespace the controller no longer has is not shown", %{
      conn: conn,
      user: user
    } do
      FlezhaConsole.Accounts.remember_namespace(user, "gone")

      {:ok, _view, html} = live(conn, ~p"/logs/audit")

      refute html |> within(~s([data-testid="namespace-picker"])) |> LazyHTML.text() =~ "gone"
      assert html =~ ~s(data-testid="no-namespace-scoped")
    end
  end

  describe "the shell's pulse" do
    test "counts open problems in the worst one's tone", %{conn: conn, node: node} do
      FakeController.set_fleet(node,
        namespaces: ["default"],
        rows: %{
          "default" => [
            FakeController.relay_row("relay_d", %{health: :degraded}),
            FakeController.relay_row("relay_h", %{health: :halted})
          ]
        }
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      count = view |> render_async() |> within(~s([data-testid="problems-count"]))

      assert LazyHTML.text(count) =~ "2"
      assert attr(count, "data-tone") == "negative"
    end

    test "shows no count when nothing is open", %{conn: conn, node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})

      {:ok, view, _html} = live(conn, ~p"/cluster")

      refute render_async(view) =~ ~s(data-testid="problems-count")
    end

    test "makes no call on the dead render", %{conn: conn, node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})

      conn |> get(~p"/problems") |> html_response(200)

      assert FakeController.calls(node, {Flezha.Service.Dlq, :stats}) == []
    end

    test "costs the same number of calls whatever a namespace holds", %{conn: conn, node: node} do
      reads = fn ids ->
        FakeController.reset(node)
        with_fleet(node, ["default"], %{"default" => ids})
        {:ok, view, _html} = live(conn, ~p"/problems")
        render(view)

        length(FakeController.calls(node, {Relay, :list})) +
          length(FakeController.calls(node, {Relay, :overwatch_state}))
      end

      assert reads.(["a"]) == reads.(for i <- 1..30, do: "relay_#{i}")
    end

    test "gathers with the operator's own token, and only what it reaches", %{
      conn: conn,
      node: node,
      user: user
    } do
      with_fleet(node, ["billing", "default"], %{
        "default" => ["relay_a"],
        "billing" => ["relay_b"]
      })

      enforce_operations(node, user, %{principal: "ann", namespace: "default", role: "ops"})

      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "default", running: true}])
      )

      {:ok, view, _html} = live(conn, ~p"/problems")
      render(view)

      read = node |> FakeController.calls({Relay, :list}) |> Enum.map(&hd/1) |> Enum.uniq()
      assert read == ["default"]
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

    test "relays lists only the namespace, as the screen's scope", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/billing/relays")

      assert html =~ "relay_billing"
      refute html =~ "relay_default"
      refute html =~ ~s(data-testid="filter-namespace")
      assert html |> within(~s([data-testid="scope-namespace"])) |> attr("aria-current") == "true"
    end

    test "the scope switch moves between the two forms of a screen", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/billing/relays")

      view |> element(~s([data-testid="scope-all"])) |> render_click()
      assert_patch(view, ~p"/relays")

      html = render_async(view)
      assert html =~ "relay_default"
      refute html |> rail() |> LazyHTML.text() =~ "Fleet"
    end

    test "plugins reads the scoped namespace alone", %{conn: conn, node: node} do
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default/plugins")

      namespaces =
        node
        |> FakeController.calls({PluginManager, :enabled})
        |> Enum.map(&hd/1)
        |> Enum.uniq()

      assert namespaces == ["default"]
    end

    test "a scoped schedule form opens aimed at the scoped namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/billing/schedules")

      html = view |> element(~s([data-testid="schedule-new-btn"])) |> render_click()

      assert html =~ ~s(value="billing")
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

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filters" => %{"namespace" => "billing"}})

      assert_patch(view, ~p"/relays?namespace=billing")
    end

    test "a filtered URL reproduces the same listing on reload", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/relays?namespace=billing")

      assert html =~ "relay_billing"
      refute html =~ "relay_default"
    end

    test "clearing a filter clears it, so the back button reverses one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays?namespace=billing")

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filters" => %{"namespace" => ""}})

      assert_patch(view, ~p"/relays")
      assert render(view) =~ "relay_default"
    end

    test "a scoped route keeps its namespace out of the query string", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/billing/relays")

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filters" => %{"health" => "healthy"}})

      assert_patch(view, ~p"/namespaces/billing/relays?health=healthy")
    end

    test "a run filter is written into the query string as run", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filters" => %{"run" => "steps"}})

      assert_patch(view, ~p"/relays?run=steps")
    end
  end

  describe "where / lands" do
    test "on the first reachable namespace when the remembered one is gone", %{
      conn: conn,
      node: node,
      user: user
    } do
      with_fleet(node, ["zeta", "default"])
      FlezhaConsole.Accounts.remember_namespace(user, "gone")

      assert redirected_to(get(conn, ~p"/")) == "/namespaces/default"
    end
  end

  describe "a relay's views as tabs" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a"]})
      :ok
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

  describe "the command palette" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => ["relay_a", "relay_b"]})
      :ok
    end

    test "a screen that never opens it makes no listing call for it", %{conn: conn, node: node} do
      {:ok, _view, _html} = live(conn, ~p"/logs/audit")

      # The shell's pulse reads each namespace's most severe relays; nothing else.
      assert Enum.all?(
               FakeController.calls(node, {Relay, :list}),
               fn [_ns, opts, _ctx] -> opts == FlezhaConsoleWeb.Attention.relay_opts() end
             )
    end

    test "it offers a relay by id, with its namespace and health", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/logs/audit")

      assert open_palette(view) =~ ~s(data-testid="command-palette")

      html = search_palette(view, "relay_b")

      assert html =~ ~s(data-testid="command-palette-relay-relay_b")
      assert html =~ "default · Healthy"
      assert html =~ "/namespaces/default/relays/relay_b"
      refute html =~ ~s(data-testid="command-palette-relay-relay_a")
    end

    test "it offers any rail destination by name", %{conn: conn} do
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      open_palette(view)

      assert search_palette(view, "dead") =~ ~s(data-testid="command-palette-screen-Dead-letter")

      assert search_palette(view, "prob") =~ ~s(data-testid="command-palette-screen-Problems")
    end

    test "stop lands on the relay's own confirmation and stops nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/logs/audit")

      open_palette(view)
      html = search_palette(view, "stop relay_b")

      assert html =~ ~s(data-testid="command-palette-action-Stop relay_b")
      assert html =~ "/namespaces/default/relays/relay_b?do=stop"

      {:ok, _relay, relay_html} = live(conn, "/namespaces/default/relays/relay_b?do=stop")

      assert relay_html =~ ~s(data-testid="stop-confirm-modal")
      assert FakeController.calls(node, {Relay, :stop}) == []
    end

    test "diagnose, listen, run now and open problems are offered as actions", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Flezha.Service.Schedule, :list},
        FakeController.rows([
          %{
            name: "nightly",
            cron: "0 * * * *",
            timezone: "Etc/UTC",
            namespace: "default",
            factory_id: "f"
          }
        ])
      )

      {:ok, view, _html} = live(conn, ~p"/logs/audit")
      open_palette(view)

      assert search_palette(view, "diagnose relay_a") =~ "?do=diagnose"

      assert search_palette(view, "listen to relay_a") =~
               "/namespaces/default/relays/relay_a/listen"

      assert search_palette(view, "open open") =~
               ~s(data-testid="command-palette-action-Open open problems")

      assert search_palette(view, "run nightly") =~ "/schedules?run=nightly"
    end

    test "an action the role does not grant is not offered", %{conn: conn, node: node, user: user} do
      identity = %{principal: "viewer", namespace: "default", role: "viewer"}
      enforce_operations(node, user, identity)
      grant_operations(node, identity, ["Relay.diagnose"])

      {:ok, view, _html} = live(conn, ~p"/logs/audit")
      open_palette(view)

      refute search_palette(view, "stop relay_a") =~ "command-palette-action-Stop"
      assert search_palette(view, "diagnose relay_a") =~ "command-palette-action-Diagnose relay_a"
    end

    test "nothing matching says so rather than showing an empty list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/logs/audit")

      open_palette(view)
      html = search_palette(view, "nothing-is-called-this")

      assert html =~ ~s(data-testid="command-palette-empty")
      refute html =~ ~s(data-testid="command-palette-results")
    end

    test "more matches than it lists are counted, not dropped silently", %{
      conn: conn,
      node: node
    } do
      ids = for i <- 1..25, do: "many_#{String.pad_leading(to_string(i), 2, "0")}"
      with_fleet(node, ["default"], %{"default" => ids})
      {:ok, view, _html} = live(conn, ~p"/logs/audit")

      open_palette(view)
      html = search_palette(view, "stop many_")

      assert view |> element(~s([data-testid="command-palette-truncated"])) |> render() =~
               "5 more match"

      assert html =~ ~s(data-testid="command-palette-action-Stop many_20")
      refute html =~ ~s(data-testid="command-palette-action-Stop many_21")
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

    test "states the configured interval and last refresh, beside a pause control", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html |> within(~s([data-testid="liveness-state"])) |> LazyHTML.text() =~
               "Every 1h 0m ·"

      toggle = within(html, ~s([data-testid="liveness-toggle"]))
      assert attr(toggle, "aria-label") == "Pause refreshing"
      assert attr(toggle, "aria-pressed") == "false"
    end

    test "with no interval configured, a screen refreshes at its own", %{conn: conn} do
      TestEnv.put_app(:refresh_interval_ms, nil)

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html |> within(~s([data-testid="liveness-state"])) |> LazyHTML.text() =~ "Every 5s ·"
    end

    test "a screen with no timer states no liveness", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces/default/relays/relay_a/listen")

      refute html =~ ~s(data-testid="liveness")
    end

    test "pausing holds the rows still and says so in words", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = view |> element(~s([data-testid="liveness-toggle"])) |> render_click()
      assert html |> within(~s([data-testid="liveness-state"])) |> LazyHTML.text() =~ "Paused"

      with_fleet(node, ["default"], %{"default" => ["relay_later"]})
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "relay_a"
      refute html =~ "relay_later"
    end

    test "resuming refreshes at once and keeps ticking", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      toggle = element(view, ~s([data-testid="liveness-toggle"]))
      render_click(toggle)
      with_fleet(node, ["default"], %{"default" => ["relay_later"]})

      render_click(toggle)
      html = render_async(view)

      refute html =~ "Paused"
      assert html =~ "relay_later"

      # The timer was never cancelled, so the screen goes on ticking.
      with_fleet(node, ["default"], %{"default" => ["relay_later_still"]})
      send(view.pid, :refresh)

      assert render_async(view) =~ "relay_later_still"
    end

    test "a screen that suspends for its own modal still does", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      view |> element(~s([data-testid="start-relay-btn"])) |> render_click()
      with_fleet(node, ["default"], %{"default" => ["relay_later"]})
      send(view.pid, :refresh)
      html = render(view)

      refute html =~ "relay_later"
      # Its own suspension, not the operator's — liveness still reads live.
      refute html =~ "Paused"
    end
  end

  describe "before the socket connects" do
    setup %{node: node} do
      with_fleet(node, ["default"], %{"default" => []})
      :ok
    end

    # The first render has read nothing yet, so it draws the shape of what is
    # coming rather than claiming there is nothing.
    test "each data screen shows skeletons, never an empty state", %{conn: conn} do
      for {path, skeleton, empty} <- [
            {~p"/relays", "relays-loading", "relays-empty"},
            {~p"/namespaces/default", "home-namespace-loading", "topology-empty"},
            {~p"/plugins", "plugins-loading", "plugins-empty"},
            {~p"/schedules", "schedules-loading", "schedule-empty"},
            {~p"/problems", "problems-loading", "problems-clear"}
          ] do
        html = conn |> get(path) |> html_response(200)

        assert html =~ ~s(data-testid="#{skeleton}"), "#{path} shows no skeleton"
        assert html =~ ~s(aria-busy="true")
        refute html =~ ~s(data-testid="#{empty}"), "#{path} claims to be empty"
      end
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

  # The controller holds a listen open while the screen's feed lives.
  defp listening?(node), do: FakeController.streams(node, {Relay, :listen}) != []
end
