defmodule FlezhaUiWeb.OperativeIndexLiveTest do
  @moduledoc """
  The cross-namespace operatives index.

  Covered here rather than in the browser: a fleet spanning namespaces, a
  refused listing, and the guarantee the screen exists to keep — that its cost
  does not grow with the number of operatives.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Runner.FleetManager
  alias Flezha.Service.HubManager
  alias Flezha.Service.OperativeManager

  defp row(id, overrides \\ %{}), do: FakeController.operative_row(id, overrides)

  # The registry dump `operative_kinds/1` decodes, in the controller's own
  # entry shape: `{operative_id, {cspec, node_pids, metadata}}`.
  defp registry(kinds) do
    Enum.map(kinds, fn {id, kind} ->
      {to_string(id),
       {%{start: {Flezha, :start_operative, [{"default", %{id: to_string(id), kind: kind}}]}}, [],
        %{}}}
    end)
  end

  defp with_fleet(node, opts) do
    namespaces = opts[:namespaces] || ["default"]

    FakeController.set_fleet(node,
      namespaces: namespaces,
      rows: Map.new(namespaces, &{&1, opts[:rows] || []}),
      plugins: opts[:plugins] || []
    )

    FakeController.set(node, {HubManager, :get_registry}, {:ok, registry(opts[:kinds] || [])})
  end

  defp start_form(overrides) do
    Map.merge(
      %{
        "namespace" => "default",
        "id" => "op_new",
        "factory_id" => "store_input",
        "kind" => "stream",
        "init_values" => "",
        "snapshot_interval" => ""
      },
      overrides
    )
  end

  describe "listing" do
    test "lists every operative in every reachable namespace", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("op_a"), row("op_b")])

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ ~s(data-testid="operatives-index-table")
      assert html =~ ~s(data-testid="operative-index-row-op_a")
      assert html =~ ~s(data-testid="operative-index-row-op_b")
    end

    test "each row carries namespace, factory, health, kind, node, runner and plugins", %{
      conn: conn,
      node: node
    } do
      with_fleet(node,
        rows: [
          row("op_a", %{health: :degraded, node: :"flezha@node-z", factory: "compare_filter"})
        ],
        kinds: [{"op_a", :workflow}],
        plugins: [{"op_a", [%{id: "p1"}, %{id: "p2"}]}]
      )

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ "compare_filter"
      assert html =~ ~s(data-health="degraded")
      assert html =~ "workflow"
      assert html =~ "flezha@node-z"
      assert html =~ "runner-a"
      assert html =~ ">2<"
    end

    test "an operative id navigates to its detail screen", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("op_a")])

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ "/namespaces/default/operatives/op_a"
    end

    test "an unplaced operative is named rather than left blank", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("op_a", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ "unplaced"
    end

    test "an entry with no builder is read as a stream, as the controller reads it", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("op_a")])
      FakeController.set(node, {HubManager, :get_registry}, {:ok, [{"op_a", {%{}, [], %{}}}]})

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ "stream"
    end

    test "an empty fleet says so rather than rendering an empty table", %{conn: conn, node: node} do
      with_fleet(node, rows: [])

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ ~s(data-testid="operatives-empty")
      refute html =~ ~s(data-testid="operatives-index-table")
    end

    test "a refused namespace listing is stated, not rendered as empty", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Flezha, :list_namespaces},
        {:error, {:forbidden, :principal_not_bound}}
      )

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "refused"
      assert html =~ "no flezha principal"
    end
  end

  describe "filters" do
    setup %{node: node} do
      with_fleet(node,
        namespaces: ["default", "staging"],
        rows: [row("op_a"), row("op_b", %{health: :failed})],
        kinds: [{"op_a", :stream}, {"op_b", :workflow}]
      )

      :ok
    end

    test "filtering by health lists only matching operatives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operatives")

      html = render_change(view, "filter", %{"filters" => %{"health" => "failed"}})

      assert html =~ ~s(data-testid="operative-index-row-op_b")
      refute html =~ ~s(data-testid="operative-index-row-op_a")
    end

    test "filtering by kind lists only matching operatives", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operatives")

      html = render_change(view, "filter", %{"filters" => %{"kind" => "workflow"}})

      assert html =~ ~s(data-testid="operative-index-row-op_b")
      refute html =~ ~s(data-testid="operative-index-row-op_a")
    end

    test "filtering by namespace lists only that namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operatives")

      html = render_change(view, "filter", %{"filters" => %{"namespace" => "staging"}})

      assert html =~ "staging"
      refute html =~ ~s(>default<)
    end

    test "filtering to suspended instances costs no per-instance read", %{conn: conn, node: node} do
      # The Convergence Loop ranks suspension in the health ladder, so this is
      # a health filter — it rides the listing's own namespace-flat read.
      with_fleet(node,
        rows: [row("op_a"), row("op_b", %{health: :suspended})],
        kinds: [{"op_a", :stream}, {"op_b", :workflow}]
      )

      {:ok, view, _html} = live(conn, ~p"/operatives")
      html = render_change(view, "filter", %{"filters" => %{"health" => "suspended"}})

      assert html =~ ~s(data-testid="operative-index-row-op_b")
      refute html =~ ~s(data-testid="operative-index-row-op_a")
      assert FakeController.calls(node, {OperativeManager, :get_overwatch_state}) == []
    end

    test "the listing asks no operative anything, filtered or not", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_change(view, "filter", %{"filters" => %{"health" => "suspended"}})

      assert FakeController.calls(node, {OperativeManager, :get_overwatch_state}) == []
    end
  end

  describe "starting an operative from the index" do
    setup %{node: node} do
      with_fleet(node, namespaces: ["default", "staging"], rows: [])

      FakeController.set(
        node,
        {Flezha, :list_factories},
        {:ok, [%{id: "store_input", description: "stores its input"}]}
      )

      FakeController.set(node, {FleetManager, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "the screen carries the control that starts one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ ~s(data-testid="start-operative-btn")
    end

    test "the form asks which namespace to start into", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operatives")

      render_click(view, "launcher_open", %{})

      assert has_element?(view, ~s([data-testid="input-namespace"] option[value="default"]))
      assert has_element?(view, ~s([data-testid="input-namespace"] option[value="staging"]))
    end

    test "a start from the index reaches the chosen namespace", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_click(view, "launcher_open", %{})

      html =
        render_submit(view, "launcher_submit", %{
          "start" => start_form(%{"namespace" => "staging"})
        })

      assert html =~ "Operative op_new started in staging."

      assert [["staging", %{id: "op_new", kind: :stream}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "a started operative appears in the index", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_click(view, "launcher_open", %{})

      # The listing reloads from the controller after the start, so what the
      # index shows is what the controller now holds.
      FakeController.set(node, {HubManager, :operative_rows}, [row("op_new")])

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{})})

      assert html =~ ~s(data-testid="operative-index-row-op_new")
    end

    test "changing the namespace re-reads that namespace's factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_click(view, "launcher_open", %{})

      render_change(view, "launcher_change", %{"start" => start_form(%{"namespace" => "staging"})})

      assert [["default"], ["staging"]] = FakeController.calls(node, {Flezha, :list_factories})
    end

    test "a workflow is startable from here", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_click(view, "launcher_open", %{})

      render_submit(view, "launcher_submit", %{"start" => start_form(%{"kind" => "workflow"})})

      assert [["default", %{kind: :workflow}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "the kind filter offers the kinds the controller recognises", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Flezha.Operative.Kind, :known?},
        {:per_arg, 0, %{workflow: true}, false}
      )

      {:ok, _view, html} = live(conn, ~p"/operatives")

      assert html =~ ~s(data-testid="filter-kind-workflow")
      refute html =~ ~s(data-testid="filter-kind-stream")
    end

    test "a tick with the form closed reads no factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Flezha, :list_factories}) == []
    end

    test "the screen holds still while the form is open", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/operatives")
      render_click(view, "launcher_open", %{})

      FakeController.set(node, {HubManager, :operative_rows}, [row("op_late")])
      send(view.pid, :refresh)
      refute render(view) =~ ~s(data-testid="operative-index-row-op_late")

      render_click(view, "launcher_close", %{})
      send(view.pid, :refresh)
      assert render(view) =~ ~s(data-testid="operative-index-row-op_late")
    end
  end

  describe "cost" do
    test "a listing tick costs the same for two operatives as for fifty", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("op_a"), row("op_b")])
      {:ok, _view, _html} = live(conn, ~p"/operatives")
      small = length(FakeController.calls(node, {HubManager, :operative_rows}))

      FakeController.reset(node)
      with_fleet(node, rows: Enum.map(1..50, &row("op_#{&1}")))
      {:ok, _view, _html} = live(conn, ~p"/operatives")
      large = length(FakeController.calls(node, {HubManager, :operative_rows}))

      assert small == large

      # Kind rides one registry read per namespace, not one per operative.
      assert length(FakeController.calls(node, {HubManager, :get_registry})) == small
      assert FakeController.calls(node, {OperativeManager, :get_overwatch_state}) == []
    end
  end
end
