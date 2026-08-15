defmodule FlezhaUiWeb.DlqLiveTest do
  @moduledoc """
  The dead-letter queue screen, against a controller that can be made to hold
  entries.

  A healthy dev stack keeps the queue empty, which is why the browser suite
  covers only the empty states: everything here — the table, the inspect modal,
  the confirm gates, the replay outcome — needs parked entries that a live
  controller will not manufacture on request.
  """

  use FlezhaUiWeb.LiveCase

  @ref "orders/charge/17"

  defp entry(overrides \\ %{}) do
    Map.merge(
      %{
        "operative_class" => "orders",
        "procedure_id" => "charge",
        "id" => "17",
        "entity_key" => "cust-9",
        "channel" => "payments",
        "generation" => 2,
        "ts_ms" => System.system_time(:millisecond) - 30_000,
        "error" => "upstream refused"
      },
      overrides
    )
  end

  defp with_entries(node, entries) do
    FakeController.set(node, {Flezha.Dlq.Store, :list}, {:ok, entries})
  end

  describe "listing" do
    test "renders the empty state when nothing is parked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ "The dead-letter queue is empty"
      refute html =~ ~s(data-testid="dlq-table")
    end

    test "renders the parked entries", %{conn: conn, node: node} do
      with_entries(node, [entry(), entry(%{"id" => "18", "entity_key" => "cust-4"})])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="dlq-table")
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")
      assert html =~ "orders/charge/18"
      assert html =~ "upstream refused"
      assert html =~ "cust-9"
      assert html =~ "Parked entries (2)"
    end

    test "renders the statistics panel when the controller reports any", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Flezha.Dlq.Store, :stats},
        {:ok, [%{"operative_class" => "orders", "count" => 3}]}
      )

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="dlq-stats")
      assert html =~ "orders"
    end

    test "filtering narrows what the controller is asked for", %{conn: conn, node: node} do
      with_entries(node, [entry()])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_change(view, "filter", %{"filter" => %{"operative_class" => "orders"}})

      # The screen must push the filter down to the controller rather than
      # filter a full list in the browser.
      assert ["orders" | _] =
               node |> FakeController.calls({Flezha.Dlq.Store, :list}) |> List.last()
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha.Dlq.Store, :list}, {:error, :dlq_unavailable})

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ "dlq_unavailable"
    end
  end

  describe "inspecting an entry" do
    test "opens and closes the payload modal", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Flezha.Dlq.Store, :get},
        {:ok, entry(), "the parked payload"}
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = render_click(view, "inspect", %{"ref" => @ref})
      assert html =~ ~s(data-testid="dlq-inspect-modal")
      assert html =~ "the parked payload"

      html = render_click(view, "close_inspect", %{})
      refute html =~ ~s(data-testid="dlq-inspect-modal")
    end

    test "reports an entry that has since left the queue", %{conn: conn, node: node} do
      with_entries(node, [entry()])
      FakeController.set(node, {Flezha.Dlq.Store, :get}, {:error, :not_found})

      {:ok, view, _html} = live(conn, ~p"/dlq")

      assert render_click(view, "inspect", %{"ref" => @ref}) =~
               "That entry is no longer in the queue."
    end
  end

  describe "destructive verbs are confirm-gated" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "dropping asks first, and cancelling leaves the entry alone", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = render_click(view, "confirm", %{"action" => "drop", "ref" => @ref})
      assert html =~ ~s(data-testid="dlq-confirm-modal")

      html = render_click(view, "cancel_confirm", %{})
      refute html =~ ~s(data-testid="dlq-confirm-modal")
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")

      # Cancelling must not have reached the controller at all.
      assert FakeController.calls(node, {Flezha.Dlq.Store, :drop}) == []
    end

    test "confirming a drop reaches the controller and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_click(view, "confirm", %{"action" => "drop", "ref" => @ref})
      html = render_click(view, "drop", %{"ref" => @ref})

      assert html =~ "Entry dropped"
      assert FakeController.calls(node, {Flezha.Dlq.Store, :drop}) == [[@ref]]
    end

    test "a refused drop is reported and the entry stays", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha.Dlq.Store, :drop}, {:error, :not_found})

      {:ok, view, _html} = live(conn, ~p"/dlq")
      render_click(view, "confirm", %{"action" => "drop", "ref" => @ref})

      assert render_click(view, "drop", %{"ref" => @ref}) =~
               "That entry is no longer in the queue."
    end

    test "replaying asks first and says what it will report", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      assert html =~ ~s(data-testid="dlq-confirm-modal")
      assert html =~ "Replay"
    end
  end

  describe "replay outcome" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "reports pending while the grace period runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      html = render_click(view, "replay", %{"ref" => @ref})

      assert html =~ ~s(data-testid="replay-pending")
    end

    test "reports success when the entry left the queue", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/dlq")
      render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      render_click(view, "replay", %{"ref" => @ref})

      # Gone from the queue means the payload was accepted.
      FakeController.set(node, {Flezha.Dlq.Store, :get}, {:error, :not_found})
      send(view.pid, {:replay_outcome, @ref})

      assert render(view) =~ ~s(data-testid="replay-succeeded")
    end

    test "reports a re-park, which otherwise looks identical to success", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/dlq")
      render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      render_click(view, "replay", %{"ref" => @ref})

      FakeController.set(
        node,
        {Flezha.Dlq.Store, :get},
        {:ok, entry(%{"error" => "refused again"}), "payload"}
      )

      send(view.pid, {:replay_outcome, @ref})

      html = render(view)
      assert html =~ ~s(data-testid="replay-reparked")
      assert html =~ "refused again"
    end
  end
end
