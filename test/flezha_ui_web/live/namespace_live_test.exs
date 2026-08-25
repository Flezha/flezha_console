defmodule FlezhaUiWeb.NamespaceLiveTest do
  @moduledoc """
  The namespace index and show screens.

  The browser suite drives the happy path against the seeded `default`
  namespace. Covered here instead: an empty controller, a controller that
  refuses, and the start form's validation branches — which the browser cannot
  reach without leaving half-started operatives behind.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Runner.FleetManager
  alias Flezha.Service.HubManager

  defp with_namespaces(node, names, opts \\ []) do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, names})
    FakeController.set(node, {Flezha, :list_operatives}, {:ok, opts[:operatives] || []})
    FakeController.set(node, {HubManager, :operative_rows}, rows(opts[:operatives] || []))
    FakeController.set(node, {Flezha, :list_runners}, {:ok, opts[:runners] || []})
  end

  # The registry rows a listing reads. An id alone is the ordinary case; a map
  # is a row a test wants to say more about.
  defp rows(operatives), do: Enum.map(operatives, &row/1)

  defp row(%{} = row), do: Map.merge(default_row(row[:id] || "op"), row)
  defp row(id), do: default_row(id)

  defp default_row(id), do: FakeController.operative_row(id)

  defp start_form(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "op_1",
        "factory_id" => "store_input",
        "kind" => "stream",
        "init_values" => "",
        "snapshot_interval" => ""
      },
      overrides
    )
  end

  defp open_launcher(conn) do
    {:ok, view, _html} = live(conn, ~p"/namespaces/default")
    render_click(view, "launcher_open", %{})
    view
  end

  describe "the index" do
    test "lists namespaces with their counts", %{conn: conn, node: node} do
      with_namespaces(node, ["default", "staging"],
        operatives: ["a", "b"],
        runners: [%{id: "runner-a"}]
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespaces-table")
      assert html =~ ~s(data-testid="namespace-row-default")
      assert html =~ ~s(data-testid="namespace-row-staging")
      assert html =~ ~s(data-testid="namespace-operatives-default")
    end

    test "renders the empty state when the controller runs none", %{conn: conn, node: node} do
      with_namespaces(node, [])

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ ~s(data-testid="namespaces-empty")
      assert html =~ "No namespaces found"
    end

    test "a namespace whose operatives cannot be counted still lists", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
      FakeController.set(node, {Flezha, :list_operatives}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      # One failing count must not take the whole page down with it.
      assert html =~ ~s(data-testid="namespace-row-default")
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert html =~ "The flezha controller did not answer in time."
    end
  end

  describe "the show page" do
    test "lists the operatives running in the namespace", %{conn: conn, node: node} do
      with_namespaces(node, ["default"], operatives: ["op_a", "op_b"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="operatives-table")
      assert html =~ ~s(data-testid="operative-row-op_a")
      assert html =~ ~s(data-testid="operative-row-op_b")
    end

    test "explains an empty namespace", %{conn: conn, node: node} do
      with_namespaces(node, ["default"], operatives: [])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="no-operatives-msg")
    end
  end

  describe "operative health" do
    test "every health the loop reports is stated distinctly", %{conn: conn, node: node} do
      with_namespaces(node, ["default"],
        operatives: [
          %{id: "op_ok", health: :healthy},
          %{id: "op_deg", health: :degraded},
          %{id: "op_unb", health: :unbound},
          %{id: "op_fail", health: :failed}
        ]
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      for health <- ~w(healthy degraded unbound failed) do
        assert html =~ ~s(data-health="#{health}")
      end
    end

    test "a row the loop has not classified reads unknown, not healthy", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, ["default"], operatives: [%{id: "op_new", health: :unknown}])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-health="unknown")
      refute html =~ ~s(data-health="healthy")
    end

    test "a row carrying no health at all is still not healthy", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})

      FakeController.set(node, {HubManager, :operative_rows}, [
        %{id: "op_new", runner: nil, factory: nil, partition: nil, node: nil}
      ])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-health="unknown")
    end

    test "an operative with no live node is named as unplaced", %{conn: conn, node: node} do
      with_namespaces(node, ["default"], operatives: [%{id: "op_a", node: nil}])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="unplaced-op_a")
      assert html =~ "unplaced"
    end

    test "the node, factory and runner come from the same rows", %{conn: conn, node: node} do
      with_namespaces(node, ["default"],
        operatives: [
          %{id: "op_a", node: :"flezha@node-b", factory: "compare_filter", runner: "runner-z"}
        ]
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "flezha@node-b"
      assert html =~ "compare_filter"
      assert html =~ "runner-z"
    end

    test "plugin counts are read for the whole namespace, not per operative", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, ["default"], operatives: ["op_a", "op_b"])

      FakeController.set(node, {HubManager, :operative_plugins}, [
        {"op_a", [%{id: "p1"}, %{id: "p2"}]}
      ])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "operative-row-op_a"

      # One rows read and one plugins read per render — the whole namespace at
      # a time, never a call per row, and never the same dump twice.
      assert length(FakeController.calls(node, {HubManager, :operative_plugins})) ==
               length(FakeController.calls(node, {HubManager, :operative_rows}))
    end

    test "a listing tick costs the same whether the namespace holds two or fifty", %{
      conn: conn,
      node: node
    } do
      with_namespaces(node, ["default"], operatives: ["op_a", "op_b"])
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      small = length(FakeController.calls(node, {HubManager, :operative_rows}))

      FakeController.reset(node)
      with_namespaces(node, ["default"], operatives: Enum.map(1..50, &"op_#{&1}"))
      {:ok, _view, _html} = live(conn, ~p"/namespaces/default")
      large = length(FakeController.calls(node, {HubManager, :operative_rows}))

      assert small == large

      # And nothing was asked per operative.
      assert FakeController.calls(node, {Flezha.Service.OperativeManager, :get_overwatch_state}) ==
               []
    end
  end

  describe "partition groups" do
    alias Flezha.Partition
    alias Flezha.Service.CliManager

    defp group(overrides) do
      members = [
        Map.merge(default_row("orders_p0"), %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        }),
        Map.merge(default_row("orders_p1"), %{
          health: :degraded,
          partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}
        })
      ]

      Map.merge(
        %{
          id: "orders",
          health: :degraded,
          runner: "p0→runner-a, p1→runner-b",
          factory: "store_input",
          partitions: "2/2",
          node: :"flezha@node-a",
          members: members
        },
        overrides
      )
    end

    defp with_group(node), do: with_group(node, %{})

    defp with_group(node, overrides) do
      with_namespaces(node, ["default"], operatives: ["orders_p0", "orders_p1"])
      FakeController.set(node, {CliManager, :group_partition_rows}, [group(overrides)])
    end

    test "a complete group shows its member count and is not faulted", %{conn: conn, node: node} do
      with_group(node)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="partition-groups")
      assert html =~ ~s(data-testid="partition-group-orders")
      assert html =~ ~s(data-testid="group-members-orders")
      assert html =~ "2/2"
      refute html =~ ~s(data-testid="group-faulted-orders")
    end

    test "the group reports its sickest member's health", %{conn: conn, node: node} do
      with_group(node)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      # The controller rolls this up; the screen renders what it answered.
      assert html =~ ~s(data-health="degraded")
    end

    test "members are listed with partition index, key range, runner and health", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "p0"
      assert html =~ "p1"
      assert html =~ "0–127"
      assert html =~ "128–255"
      assert html =~ "orders_p0"
    end

    test "a coverage gap is a fault, and the uncovered range is named", %{conn: conn, node: node} do
      with_group(node)

      FakeController.set(
        node,
        {Partition, :coverage},
        {:error, %{gaps: [{128, 255}], overlaps: []}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ ~s(data-testid="group-coverage-orders")
      assert html =~ "128–255"
      assert html =~ "owned by no member"
    end

    test "overlapping owners are a fault, and both are named", %{conn: conn, node: node} do
      with_group(node)

      FakeController.set(
        node,
        {Partition, :coverage},
        {:error, %{gaps: [], overlaps: [{7, ["orders_p0", "orders_p1"]}]}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ "claimed by orders_p0, orders_p1"
    end

    test "a controller that cannot answer coverage says so rather than reading as covered", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      FakeController.set(
        node,
        {Partition, :coverage},
        {:error, {:api_missing, Flezha.Partition, :coverage, 1}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      assert html =~ "coverage unavailable"
      refute html =~ ~s(data-testid="group-faulted-orders")
    end

    test "a namespace with no groups renders no group panel", %{conn: conn, node: node} do
      with_namespaces(node, ["default"], operatives: ["op_a"])

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="partition-groups")
    end
  end

  describe "starting an operative" do
    setup %{node: node} do
      with_namespaces(node, ["default"], operatives: [])
      # The start form reads `factory.id` and `factory.description`, so the
      # controller's factory records are maps rather than bare ids.
      FakeController.set(
        node,
        {Flezha, :list_factories},
        {:ok, [%{id: "store_input", description: "stores its input"}]}
      )

      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "sends the spec to the controller and reports it", %{conn: conn, node: node} do
      view = open_launcher(conn)

      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ "Operative op_1 started."

      assert [["default", %{id: "op_1", factory_id: "store_input", kind: :stream}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "the namespace is this screen's, and is not asked for again", %{conn: conn, node: node} do
      view = open_launcher(conn)

      refute render(view) =~ ~s(data-testid="input-namespace")

      # The form carries no namespace field, and the start still reaches this
      # screen's namespace.
      render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert [["default", _operative]] = FakeController.calls(node, {Flezha, :start_operative})
    end

    test "offers the kinds the controller recognises, with their capabilities", %{conn: conn} do
      view = open_launcher(conn)

      assert has_element?(view, ~s([data-testid="input-kind"] option[value="stream"]))
      assert has_element?(view, ~s([data-testid="input-kind"] option[value="workflow"]))
      assert render(view) =~ "persistent_state?"
    end

    test "a kind the controller does not recognise is not offered", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Flezha.Operative.Kind, :known?},
        {:per_arg, 0, %{stream: true}, false}
      )

      view = open_launcher(conn)

      assert has_element?(view, ~s([data-testid="input-kind"] option[value="stream"]))
      refute has_element?(view, ~s([data-testid="input-kind"] option[value="workflow"]))
    end

    test "the chosen kind is carried into the start call", %{conn: conn, node: node} do
      view = open_launcher(conn)

      render_submit(view, "launcher_submit", %{"start" => start_form(%{"kind" => "workflow"})})

      assert [["default", %{kind: :workflow}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "a kind the controller never offered is refused before calling", %{
      conn: conn,
      node: node
    } do
      view = open_launcher(conn)

      html =
        render_submit(view, "launcher_submit", %{"start" => start_form(%{"kind" => "batch"})})

      assert html =~ ~s(data-testid="start-error")
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "the factory selector reports the runners serving each factory", %{conn: conn} do
      html = conn |> open_launcher() |> render()

      assert html =~ "store_input — stores its input"
      refute html =~ "(no runner)"
    end

    test "a factory no runner serves is marked at the point of choosing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, []})

      html = conn |> open_launcher() |> render()

      assert html =~ "(no runner)"
    end

    test "a namespace with no factories says so and blocks the start", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :list_factories}, {:ok, []})

      view = open_launcher(conn)
      html = render(view)

      assert html =~ "No factories are registered in this namespace"

      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ "No factories are registered in this namespace"
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "a refused catalog says so and leaves the factory id typeable", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Flezha, :list_factories},
        {:error, {:forbidden, :no_role_binding}}
      )

      view = open_launcher(conn)

      assert render(view) =~ "The choices could not be read"

      render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert [["default", %{factory_id: "store_input"}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "requires an id and a factory", %{conn: conn, node: node} do
      view = open_launcher(conn)

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{"id" => ""})})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "ID and Factory ID are required."
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
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
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "passes valid init values through", %{conn: conn, node: node} do
      view = open_launcher(conn)

      render_submit(view, "launcher_submit", %{
        "start" => start_form(%{"init_values" => ~s({"seed":7})})
      })

      assert [["default", %{init_values: %{"seed" => 7}}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "carries a snapshot interval through as a start opt", %{conn: conn, node: node} do
      view = open_launcher(conn)

      render_submit(view, "launcher_submit", %{
        "start" => start_form(%{"snapshot_interval" => "25"})
      })

      assert [["default", %{opts: [snapshot_interval: 25]}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "surfaces a refusal from the controller", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :start_operative}, {:error, :already_running})

      view = open_launcher(conn)

      html = render_submit(view, "launcher_submit", %{"start" => start_form()})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "already_running"
    end

    test "the screen holds still while the form is open", %{conn: conn, node: node} do
      view = open_launcher(conn)

      # A row appearing under an open form is exactly what pausing prevents.
      FakeController.set(node, {HubManager, :operative_rows}, rows(["op_late"]))
      send(view.pid, :refresh)
      refute render(view) =~ ~s(data-testid="operative-row-op_late")

      render_click(view, "launcher_close", %{})
      send(view.pid, :refresh)
      assert render(view) =~ ~s(data-testid="operative-row-op_late")
    end

    test "the listing tick reads no factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Flezha, :list_factories}) == []
    end
  end

  describe "stopping an operative" do
    setup %{node: node} do
      with_namespaces(node, ["default"], operatives: ["op_a"])
      :ok
    end

    test "is confirm-gated, and cancelling leaves it running", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = render_click(view, "confirm_stop", %{"operative_id" => "op_a"})
      assert html =~ ~s(data-testid="stop-confirm-modal")

      html = render_click(view, "cancel_stop", %{})
      refute html =~ ~s(data-testid="stop-confirm-modal")
      assert html =~ ~s(data-testid="operative-row-op_a")

      assert FakeController.calls(node, {Flezha, :stop_operative}) == []
    end

    test "confirming reaches the controller", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      render_click(view, "confirm_stop", %{"operative_id" => "op_a"})
      render_click(view, "stop_operative", %{"operative_id" => "op_a"})

      assert FakeController.calls(node, {Flezha, :stop_operative}) == [["default", "op_a"]]
    end

    test "surfaces a refused stop", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :stop_operative}, {:error, :not_running})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "confirm_stop", %{"operative_id" => "op_a"})

      assert render_click(view, "stop_operative", %{"operative_id" => "op_a"}) =~ "not_running"
    end
  end
end
