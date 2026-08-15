defmodule FlezhaUiWeb.NamespaceLiveTest do
  @moduledoc """
  The namespace index and show screens.

  The browser suite drives the happy path against the seeded `default`
  namespace. Covered here instead: an empty controller, a controller that
  refuses, and the start form's validation branches — which the browser cannot
  reach without leaving half-started operatives behind.
  """

  use FlezhaUiWeb.LiveCase

  defp with_namespaces(node, names, opts \\ []) do
    FakeController.set(node, {Flezha, :list_namespaces}, {:ok, names})
    FakeController.set(node, {Flezha, :list_operatives}, {:ok, opts[:operatives] || []})
    FakeController.set(node, {Flezha, :list_runners}, {:ok, opts[:runners] || []})
  end

  defp start_form(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "op_1",
        "factory_id" => "store_input",
        "init_values" => "",
        "snapshot_interval" => ""
      },
      overrides
    )
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

      :ok
    end

    test "sends the spec to the controller and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_start_modal", %{})

      html = render_submit(view, "start_operative", %{"start" => start_form()})

      assert html =~ "Operative op_1 started."

      assert [["default", %{id: "op_1", factory_id: "store_input", kind: :stream}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "requires an id and a factory", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_start_modal", %{})

      html = render_submit(view, "start_operative", %{"start" => start_form(%{"id" => ""})})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "ID and Factory ID are required."
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "rejects init values that are not JSON before calling the controller", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_start_modal", %{})

      html =
        render_submit(view, "start_operative", %{
          "start" => start_form(%{"init_values" => "not json{{{"})
        })

      assert html =~ "Init Values must be valid JSON."
      assert FakeController.calls(node, {Flezha, :start_operative}) == []
    end

    test "passes valid init values through", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_start_modal", %{})

      render_submit(view, "start_operative", %{
        "start" => start_form(%{"init_values" => ~s({"seed":7})})
      })

      assert [["default", %{init_values: %{"seed" => 7}}]] =
               FakeController.calls(node, {Flezha, :start_operative})
    end

    test "surfaces a refusal from the controller", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha, :start_operative}, {:error, :already_running})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_start_modal", %{})

      html = render_submit(view, "start_operative", %{"start" => start_form()})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "already_running"
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
