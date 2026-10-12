defmodule FlezhaUiWeb.NamespaceLiveTest do
  @moduledoc """
  The namespace index and show screens.

  The browser suite drives the happy path against the seeded `default`
  namespace. Covered here instead: an empty controller, a controller that
  refuses, and the start form's validation branches — which the browser cannot
  reach without leaving half-started relays behind.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  # A namespace's relays, as every listing reads them. An id alone is the
  # ordinary case; a map is a row a test wants to say more about.
  defp with_relays(node, relays, opts \\ []) do
    rows = Enum.map(relays, &row/1)
    FakeController.set_fleet(node, Keyword.merge([rows: %{"default" => rows}], opts))
    rows
  end

  defp row(%{} = row), do: FakeController.relay_row(row[:id] || "relay", row)
  defp row(id), do: FakeController.relay_row(id)

  defp start_form(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "relay_1",
        "factory_id" => "store_input",
        "init_values" => ""
      },
      overrides
    )
  end

  defp open_launcher(conn) do
    {:ok, view, _html} = live(conn, ~p"/namespaces/default")
    render_click(view, "launcher_open", %{})
    view
  end

  defp starts(node), do: FakeController.calls(node, {Relay, :start})

  describe "the index" do
    test "lists namespaces with their counts", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}, %{namespace: "staging", running: true}]}
      )

      FakeController.set(node, {Relay, :list_relays}, {:ok, ["a", "b"]})
      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: nil}]})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespaces-table")
      assert html =~ ~s(data-testid="namespace-row-default")
      assert html =~ ~s(data-testid="namespace-row-staging")
      assert html =~ ~s(data-testid="namespace-relays-default")
    end

    test "a declared namespace with no hub is listed with zero counts", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "staging", running: false}]}
      )

      FakeController.set(
        node,
        {Flezha.Service.Namespace, :list},
        {:ok, [%{name: "staging", quotas: %{}}]}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces")

      assert view |> element(~s([data-testid="namespace-state-staging"])) |> render() =~
               "Declared, no hub running"

      assert view |> element(~s([data-testid="namespace-relays-staging"])) |> render() =~ "0"
      # A namespace with no hub is not asked what runs in it.
      assert FakeController.calls(node, {Relay, :list_relays}) == []
    end

    test "renders the empty state when the catalog is empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespaces-empty")
      assert html =~ "None is reachable with this console"
    end

    test "a namespace whose relays cannot be counted still lists", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        {:ok, [%{namespace: "default", running: true}]}
      )

      FakeController.set(node, {Relay, :list_relays}, FakeController.error("controller.timeout"))

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      # One failing count must not take the whole page down with it.
      assert html =~ ~s(data-testid="namespace-row-default")
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "authz.role_insufficient"
    end
  end

  # A relay's lane on Home's map, as its accessible name reads it.
  defp lane(html, id) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s([data-testid="map-lane-#{id}"]))
    |> LazyHTML.attribute("aria-label")
    |> List.first()
  end

  describe "the show page" do
    test "draws the relays running in the namespace on its map", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="namespace-map")
      assert lane(html, "relay_a")
      assert lane(html, "relay_b")

      # Below the map: the river, empty until something happens, and the
      # folded access section.
      assert html =~ ~s(data-testid="home-river")
      assert html =~ ~s(data-testid="river-empty")
      assert html =~ ~s(data-testid="access-panel")
    end

    test "explains an empty namespace", %{conn: conn, node: node} do
      with_relays(node, [])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="topology-empty")
    end

    test "states each relay's run, read from the registry", %{conn: conn, node: node} do
      with_relays(node, ["relay_flow", "relay_steps"], runs: %{"relay_steps" => :steps})

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert lane(html, "relay_steps") =~ "steps"
      assert lane(html, "relay_flow") =~ "flow"
    end
  end

  describe "relay health" do
    test "every verdict the controller answers is stated distinctly", %{conn: conn, node: node} do
      verdicts = ~w(healthy degraded recovering unbound failed parked suspended unknown)a

      with_relays(node, Enum.map(verdicts, &%{id: "relay_#{&1}", health: &1}))

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      for health <- verdicts do
        words = health |> then(&FlezhaUiWeb.Words.text(:health, &1)) |> String.downcase()
        assert lane(html, "relay_#{health}") =~ words, "#{health} does not read #{words}"
      end
    end

    test "a row carrying no health at all reads unknown, not healthy", %{conn: conn, node: node} do
      FakeController.set_fleet(node,
        rows: %{
          "default" => [%{id: "relay_new", runner: nil, factory: nil, partition: nil, node: nil}]
        }
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert lane(html, "relay_new") =~ "unknown"
      refute lane(html, "relay_new") =~ "healthy"
    end

    test "a relay with no live node is named as unplaced", %{conn: conn, node: node} do
      with_relays(node, [%{id: "relay_a", node: nil}])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert lane(html, "relay_a") =~ "unplaced"
    end

    test "the node, factory and runner come from the same rows", %{conn: conn, node: node} do
      with_relays(node, [
        %{id: "relay_a", node: :"flezha@node-b", factory: "compare_filter", runner: "runner-z"}
      ])

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-z", pid: nil}]})

      {:ok, view, html} = live(conn, ~p"/namespaces/default")

      assert lane(html, "relay_a") =~ "compare_filter"
      assert html =~ "runner-z"

      html = render_click(view, "inspect", %{"kind" => "relay", "id" => "relay_a"})
      assert html =~ "flezha@node-b"
    end

    test "a listing tick costs the same whether the namespace holds two or fifty", %{
      conn: conn,
      node: node
    } do
      with_relays(node, ["relay_a", "relay_b"])
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      small = length(FakeController.calls(node, {Relay, :list}))

      FakeController.reset(node)
      with_relays(node, Enum.map(1..50, &"relay_#{&1}"))
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      large = length(FakeController.calls(node, {Relay, :list}))

      assert small == large
      # And nothing was asked per relay.
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "partition groups" do
    defp members do
      [
        FakeController.relay_row("orders_p0", %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        }),
        FakeController.relay_row("orders_p1", %{
          health: :degraded,
          partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}
        })
      ]
    end

    defp with_group(node, coverage \\ :ok) do
      FakeController.set_fleet(node, rows: %{"default" => members()})

      FakeController.set(
        node,
        {Relay, :partition_groups},
        {:ok, [%{group: "orders", declared: 2, members: members(), coverage: coverage}]}
      )
    end

    test "a complete group shows its member count and is not faulted", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="partition-group-orders")
      assert html =~ ~s(data-testid="group-members-orders")
      assert html =~ "2/2"
      refute html =~ ~s(data-testid="group-faulted-orders")
    end

    test "the group reports its sickest member's health", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "partition-groups") =~ ~s(data-health="degraded")
    end

    test "members are listed with partition index, key range and health", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ "p0"
      assert html =~ "p1"
      assert html =~ "0–127"
      assert html =~ "128–255"
      assert html =~ "orders_p0"
    end

    test "a coverage gap is a fault, and the uncovered range is named", %{conn: conn, node: node} do
      with_group(node, {:error, %{gaps: [{128, 255}], overlaps: []}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ ~s(data-testid="group-coverage-orders")
      assert html =~ "owned by no member"
    end

    test "overlapping owners are a fault, and both are named", %{conn: conn, node: node} do
      with_group(node, {:error, %{gaps: [], overlaps: [{7, ["orders_p0", "orders_p1"]}]}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "partition-groups")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ "claimed by orders_p0, orders_p1"
    end

    test "a namespace with no groups renders no group panel", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="partition-groups")
    end
  end

  describe "finished relays" do
    test "lists the finished relays the controller retains", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])

      FakeController.set(
        node,
        {Relay, :info},
        {:ok,
         %{
           namespace: "default",
           groups: [],
           relays: [
             %{id: "relay_a", phase: "running"},
             %{id: "echo_1", phase: "finished", status: :completed, finished_at: 1_700_000_000}
           ]
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      html = open_section(view, "finished-relays")

      assert html =~ ~s(data-testid="finished-row-echo_1")
      refute html =~ ~s(data-testid="finished-row-relay_a")
    end

    test "a refused read is stated, not shown as empty", %{conn: conn, node: node} do
      with_relays(node, [])
      FakeController.set(node, {Relay, :info}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "finished-relays") =~ "authz.role_insufficient"
    end
  end

  describe "starting a relay" do
    setup %{node: node} do
      with_relays(node, [])

      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok,
         [
           %{id: "store_input", description: "stores its input", run: :flow},
           %{id: "chat_loop_steps", description: nil, run: :steps}
         ]}
      )

      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "sends the named fields, without a run, and reports the relay", %{
      conn: conn,
      node: node
    } do
      view = open_launcher(conn)

      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ ~s(data-testid="start-result")
      assert html =~ "/namespaces/default/relays/relay_1"

      assert [["default", fields, %{source: :ui}]] = starts(node)
      assert fields[:id] == "relay_1"
      assert fields[:factory_id] == "store_input"
      refute Keyword.has_key?(fields, :run)
      refute Keyword.has_key?(fields, :kind)
    end

    test "an empty id is left for the controller to generate, and named", %{
      conn: conn,
      node: node
    } do
      view = open_launcher(conn)

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{"id" => ""})})

      assert [["default", fields, _ctx]] = starts(node)
      refute Keyword.has_key?(fields, :id)
      assert html =~ "relay-generated"
    end

    test "an id already running is stated, not reported as a new start", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :start},
        {:ok, %{id: "relay_1", outcome: :already_running}}
      )

      view = open_launcher(conn)
      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ "already running"
    end

    test "the namespace is this screen's, and is not asked for again", %{conn: conn, node: node} do
      view = open_launcher(conn)

      refute render(view) =~ ~s(data-testid="input-namespace")

      render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert [["default", _fields, _ctx]] = starts(node)
    end

    test "the chosen factory's run is shown read-only", %{conn: conn} do
      view = open_launcher(conn)

      html = render_click(view, "launcher_pick", %{"factory" => "chat_loop_steps"})

      assert html =~ "which runs as steps"
      refute has_element?(view, ~s([name="start[kind]"]))
      refute has_element?(view, ~s([name="start[run]"]))
    end

    test "the factory selector reports the runners serving each factory", %{conn: conn} do
      html = conn |> open_launcher() |> render()

      choice =
        text_of(html, ~s([data-testid="factory-choice-store_input"]))

      assert choice =~ "stores its input"
      assert choice =~ ~r/Served by \d+ runners?\./
      refute html =~ "Unavailable: no runner serves it"
    end

    test "a factory no runner serves is marked at the point of choosing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, []})

      html = conn |> open_launcher() |> render()

      assert html =~ "Unavailable: no runner serves it right now."
    end

    test "a namespace with no factories says so and blocks the start", %{conn: conn, node: node} do
      FakeController.set(node, {Fleet, :factories}, {:ok, []})

      view = open_launcher(conn)
      assert render(view) =~ ~s(data-testid="start-no-factories")
      assert render(view) =~ "No factories are registered in this namespace"

      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ "No factories are registered in this namespace"
      assert starts(node) == []
    end

    test "a refused catalog says so and leaves the factory id typeable", %{conn: conn, node: node} do
      FakeController.set(node, {Fleet, :factories}, FakeController.error("authz.no_role_binding"))

      view = open_launcher(conn)

      html = render(view)
      assert html =~ "authz.no_role_binding"
      assert html =~ ~s(data-testid="input-factory-id")
      assert html =~ ~s(data-testid="start-typed-factory")

      render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert [["default", fields, _ctx]] = starts(node)
      assert fields[:factory_id] == "store_input"
    end

    test "requires a factory", %{conn: conn, node: node} do
      view = open_launcher(conn)

      html =
        render_submit(view, "launcher_submit", %{"start" => start_form(%{"factory_id" => ""})})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "A Factory ID is required."
      assert starts(node) == []
    end

    test "rejects init values that are not JSON before calling the controller", %{
      conn: conn,
      node: node
    } do
      view = open_launcher(conn)

      html =
        render_submit(view, "launcher_submit", %{
          "start" => start_form(%{"init_values" => "not json{{{"})
        })

      assert html =~ "Init Values must be valid JSON."
      assert starts(node) == []
    end

    test "passes valid init values through", %{conn: conn, node: node} do
      view = open_launcher(conn)

      render_submit(view, "launcher_submit", %{
        "start" => start_form(%{"init_values" => ~s({"seed":7})})
      })

      assert [["default", fields, _ctx]] = starts(node)
      assert fields[:init_values] == %{"seed" => 7}
      assert fields[:opts] == []
    end

    test "surfaces a refusal from the controller with its code", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :start}, FakeController.error("authz.role_insufficient"))

      view = open_launcher(conn)
      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="start-result")
    end

    test "the screen holds still while the form is open", %{conn: conn, node: node} do
      view = open_launcher(conn)

      # A row appearing under an open form is exactly what pausing prevents.
      with_relays(node, ["relay_late"])
      send(view.pid, :refresh)
      refute render(view) =~ ~s(data-testid="map-lane-relay_late")

      render_click(view, "launcher_close", %{})
      send(view.pid, :refresh)
      assert render(view) =~ ~s(data-testid="map-lane-relay_late")
    end

    test "the listing tick reads no factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Fleet, :factories}) == []
    end
  end

  describe "stopping a relay" do
    setup %{node: node} do
      with_relays(node, ["relay_a"])
      :ok
    end

    test "is confirm-gated, and cancelling leaves it running", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = render_click(view, "confirm_stop", %{"relay_id" => "relay_a"})
      assert html =~ ~s(data-testid="stop-confirm-modal")

      html = render_click(view, "cancel_stop", %{})
      refute html =~ ~s(data-testid="stop-confirm-modal")
      assert html =~ ~s(data-testid="map-lane-relay_a")

      assert FakeController.calls(node, {Relay, :stop}) == []
    end

    test "confirming reaches the controller", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      render_click(view, "confirm_stop", %{"relay_id" => "relay_a"})
      render_click(view, "stop_relay", %{"relay_id" => "relay_a"})

      assert [["default", "relay_a", %{source: :ui}]] = FakeController.calls(node, {Relay, :stop})
    end

    test "a cooperative stop says the relay finishes its work first", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, {:ok, %{id: "relay_a", stopped: :cooperative}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "confirm_stop", %{"relay_id" => "relay_a"})

      assert render_click(view, "stop_relay", %{"relay_id" => "relay_a"}) =~
               "finishes its in-flight work"
    end

    test "surfaces a refused stop", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, FakeController.error("relay.not_found"))

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "confirm_stop", %{"relay_id" => "relay_a"})

      assert render_click(view, "stop_relay", %{"relay_id" => "relay_a"}) =~
               "relay.not_found (test)"
    end
  end
end
