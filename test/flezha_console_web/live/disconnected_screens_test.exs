defmodule FlezhaConsoleWeb.DisconnectedScreensTest do
  @moduledoc """
  Every screen rendered with no controller connected at all.

  A screen that crashes when the controller is away is worse than one that says
  so, and "away" is the state an operator is most likely to be looking at the
  UI during. No peer is started here: `NodeManager.connected_node/0` reads the
  VM's connection list, so the absence has to be real rather than mocked.

  Each screen is a row: its route and the element that states the condition.
  A screen added to the router takes one row.
  """

  use FlezhaConsoleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import FlezhaConsoleWeb.LiveCase, only: [text_of: 2]

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @condition "Not connected to a flezha controller"

  setup %{conn: conn} do
    %{conn: log_in_user(conn, FlezhaConsole.AccountsFixtures.user_fixture())}
  end

  # `section` is a folded panel that holds the statement; `async` marks a
  # screen whose condition arrives after mount; `never` is the all-clear a
  # screen must not show in its place.
  @screens [
    %{name: "namespace home", route: "/namespaces/default", says: "topology-disconnected"},
    %{name: "namespaces", route: "/namespaces", says: "runtime-error"},
    %{name: "relays index", route: "/relays", says: "runtime-error"},
    %{name: "controller health", route: "/controller", says: "runtime-error"},
    %{name: "observability", route: "/observability", says: "runtime-error"},
    %{name: "cluster", route: "/cluster", says: "runtime-error"},
    %{name: "plugins", route: "/plugins", says: "runtime-error", never: "plugins-empty"},
    %{
      name: "problems",
      route: "/problems",
      says: "runtime-error",
      async: true,
      never: "problems-clear"
    },
    %{name: "schedules", route: "/schedules", says: "runtime-error"},
    %{name: "dead-letter queue", route: "/dlq", says: "runtime-error"},
    %{name: "logs", route: "/logs/audit", says: "runtime-error"},
    %{name: "relay detail", route: "/namespaces/default/relays/relay_a", says: "runtime-error"},
    %{
      name: "relay listen",
      route: "/namespaces/default/relays/relay_a/listen",
      says: "listen-error",
      async: true
    },
    %{
      name: "relay state",
      route: "/namespaces/default/relays/relay_a/state",
      says: "runtime-error"
    }
  ]

  for screen <- @screens do
    @screen screen

    test "the #{screen.name} screen says no controller is connected", %{conn: conn} do
      %{route: route, says: says} = @screen
      selector = ~s([data-testid="#{says}"])

      assert {:ok, view, _html} = live(conn, route)
      html = render_async(view)

      html =
        if section = @screen[:section],
          do: view |> element(~s([data-testid="section-toggle-#{section}"])) |> render_click(),
          else: html

      if @screen[:async],
        do: assert(PeerNode.eventually(fn -> render(view) =~ @condition end)),
        else: assert(text_of(html, selector) =~ @condition)

      assert has_element?(view, selector)
      refute html =~ ~s(data-health="healthy")
      if never = @screen[:never], do: refute(has_element?(view, ~s([data-testid="#{never}"])))
    end
  end

  test "the cluster screen says it knows of no node", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/cluster")

    assert has_element?(view, ~s([data-testid="cluster-nodes-empty"]))
    assert has_element?(view, ~s([data-testid="cluster-disconnected"]))
  end

  describe "the start form" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      view |> element(~s([data-testid="start-relay-btn"])) |> render_click()
      %{view: view}
    end

    test "still opens, taking a typed factory and asking for no run", %{view: view} do
      # The factories could not be read, so the field takes a typed id, and how
      # the relay runs is never a field.
      assert has_element?(view, ~s([data-testid="start-modal"]))
      assert has_element?(view, ~s([data-testid="input-factory-id"]))
      refute has_element?(view, ~s([name="start[run]"]))
      refute has_element?(view, ~s([data-testid="factory-run"]))
    end

    test "refuses a start with nothing to start into rather than attempting it", %{view: view} do
      view
      |> form(~s(form[phx-submit="launcher_pick"]), factory: "store_input")
      |> render_submit()

      html = view |> form("#start-details", start: %{id: "relay_a"}) |> render_submit()

      assert text_of(html, ~s([data-testid="start-error"])) =~ "A namespace is required."
      refute html =~ ~s(data-testid="start-review")
    end
  end

  test "the seam reports no connection rather than raising", _context do
    assert NodeManager.connected_node() == nil
    assert {:error, :node_not_connected} = NodeManager.relay_list("default", nil)
    assert {:error, :node_not_connected} = NodeManager.enforcement_posture()
    assert {:error, :node_not_connected} = NodeManager.factory_catalog("default", nil)
  end
end
