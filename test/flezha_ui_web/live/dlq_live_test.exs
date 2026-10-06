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

  alias Flezha.Service.Dlq

  @ref "orders/charge/17"

  defp entry(overrides \\ %{}), do: entry("orders", "charge", "17", overrides)

  defp entry(relay_class, tasklet_id, id, overrides) do
    Map.merge(
      %{
        "relay_class" => relay_class,
        "tasklet_id" => tasklet_id,
        "id" => id,
        "cell_key" => "cust-9",
        "channel" => "payments",
        "generation" => 2,
        "status" => "parked",
        "ts_ms" => System.system_time(:millisecond) - 30_000,
        "error" => "upstream refused"
      },
      overrides
    )
  end

  defp with_entries(node, entries), do: FakeController.set(node, {Dlq, :list}, {:ok, entries})

  defp replay(view) do
    render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
    render_click(view, "replay", %{"ref" => @ref})
    render_async(view)
  end

  describe "listing" do
    test "renders the empty state when nothing is parked", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ "The dead-letter queue is empty"
      refute html =~ ~s(data-testid="dlq-table")
    end

    test "renders the parked entries with their cell key", %{conn: conn, node: node} do
      with_entries(node, [entry(), entry(%{"id" => "18", "cell_key" => "cust-4"})])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="dlq-table")
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")
      assert html =~ "orders/charge/18"
      assert html =~ "upstream refused"
      assert html =~ "cust-9"
      assert html =~ "Parked entries (2)"
    end

    test "renders the statistics per parked tasklet", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Dlq, :stats},
        {:ok, [%{relay_class: "orders", tasklet_id: "charge", entries: 3, bytes: 120}]}
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      stats = view |> element(~s([data-testid="dlq-stats"])) |> render()
      assert stats =~ "orders/charge"
      assert stats =~ "3"
    end

    test "filtering by relay class narrows what the controller is asked for", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry()])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_change(view, "filter", %{"filter" => %{"relay_class" => "orders"}})

      # The filter is pushed down to the controller rather than applied to a
      # full list here.
      assert ["orders", %{source: :ui}] =
               node |> FakeController.calls({Dlq, :list}) |> List.last()

      assert ["orders", _ctx] = node |> FakeController.calls({Dlq, :tasklets}) |> List.last()
    end

    test "an unfiltered listing asks for every class", %{conn: conn, node: node} do
      {:ok, _view, _html} = live(conn, ~p"/dlq")

      assert [nil, _ctx] = node |> FakeController.calls({Dlq, :list}) |> List.last()
    end

    test "renders the controller's refusal instead of crashing", %{conn: conn, node: node} do
      FakeController.set(node, {Dlq, :list}, FakeController.error("authz.role_insufficient"))

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "authz.role_insufficient"
    end
  end

  describe "inspecting an entry" do
    test "opens and closes the payload modal", %{conn: conn, node: node} do
      with_entries(node, [entry()])
      FakeController.set(node, {Dlq, :get}, {:ok, entry(), "the parked payload"})

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = render_click(view, "inspect", %{"ref" => @ref})
      assert html =~ ~s(data-testid="dlq-inspect-modal")
      assert html =~ "the parked payload"

      html = render_click(view, "close_inspect", %{})
      refute html =~ ~s(data-testid="dlq-inspect-modal")
    end

    test "reports an entry that has since left the queue", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Dlq, :get},
        FakeController.error("dlq.not_found", "entry 'orders/charge/17' is not parked")
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      assert render_click(view, "inspect", %{"ref" => @ref}) =~ "is not parked"
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

      assert FakeController.calls(node, {Dlq, :drop}) == []
    end

    test "confirming a drop reaches the controller and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_click(view, "confirm", %{"action" => "drop", "ref" => @ref})
      html = render_click(view, "drop", %{"ref" => @ref})

      assert html =~ "Entry dropped"
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :drop})
    end

    test "a refused drop is reported", %{conn: conn, node: node} do
      FakeController.set(node, {Dlq, :drop}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/dlq")
      render_click(view, "confirm", %{"action" => "drop", "ref" => @ref})

      assert render_click(view, "drop", %{"ref" => @ref}) =~ "authz.role_insufficient"
    end

    test "dismissing the replay confirmation attempts nothing", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      assert html =~ ~s(data-testid="dlq-confirm-modal")

      render_click(view, "cancel_confirm", %{})
      assert FakeController.calls(node, {Dlq, :replay}) == []
    end
  end

  describe "replay outcome" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "says it is waiting while the controller's grace period runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      render_click(view, "confirm", %{"action" => "replay", "ref" => @ref})
      html = render_click(view, "replay", %{"ref" => @ref})

      assert html =~ ~s(data-testid="replay-pending")
    end

    test "re-sends through the controller's replay and reports the entry gone", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replay(view)

      assert html =~ ~s(data-testid="replay-succeeded")
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :replay})
    end

    test "reports a re-park with its new generation", %{conn: conn, node: node} do
      FakeController.set(node, {Dlq, :replay}, {:ok, %{outcome: :re_parked, generation: 3}})

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replay(view)
      assert html =~ ~s(data-testid="replay-reparked")
      assert html =~ "generation 3"
    end

    test "a relay that is not running leaves the entry untouched", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Dlq, :replay},
        FakeController.error("relay.not_running", "relay 'orders' is not running; start it first")
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replay(view)
      assert html =~ ~s(data-testid="replay-refused")
      assert html =~ "is not running; start it first"
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")
    end

    test "an entry with no payload bytes is refused with the controller's message", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Dlq, :replay},
        FakeController.error("dlq.payload_not_replayable", "entry carries no payload bytes")
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replay(view)
      assert html =~ ~s(data-testid="replay-refused")
      assert html =~ "entry carries no payload bytes"
    end
  end

  describe "grouping across tasklets" do
    test "entries spanning tasklets are grouped, each with its parked count", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [
        entry("relay_a", "orders", "1", %{}),
        entry("relay_a", "orders", "2", %{}),
        entry("relay_a", "shipments", "3", %{})
      ])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="dlq-group-relay_a-orders")
      assert html =~ ~s(data-testid="dlq-group-relay_a-shipments")
      assert html =~ ~s(data-testid="dlq-group-count-relay_a-orders")
      assert html =~ "2 parked"
      assert html =~ "1 parked"
    end

    test "entries stay oldest first inside a group", %{conn: conn, node: node} do
      now = System.system_time(:millisecond)

      with_entries(node, [
        entry("relay_a", "orders", "new", %{"ts_ms" => now - 1_000}),
        entry("relay_a", "orders", "old", %{"ts_ms" => now - 600_000})
      ])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert :binary.match(html, "dlq-row-relay_a/orders/old") <
               :binary.match(html, "dlq-row-relay_a/orders/new")
    end

    test "a tasklet the controller knows but with nothing parked is not invented", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [])
      FakeController.set(node, {Dlq, :tasklets}, {:ok, [{"relay_a", "orders"}]})

      {:ok, _view, html} = live(conn, ~p"/dlq")

      # An empty queue reads as empty, not as a list of empty groups.
      assert html =~ ~s(data-testid="dlq-empty")
    end
  end
end
