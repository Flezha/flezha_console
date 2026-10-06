defmodule FlezhaUiWeb.RelayStateLiveTest do
  @moduledoc """
  The relay's durable-state screen: cells and their counters, the UI-sampled
  lag series, and point-in-time reads.

  A target outside the retained history and a relay with no durable state are
  the states worth asserting, and neither is convenient to arrange live.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay
  alias Flezha.Service.Steps

  @url "/namespaces/default/relays/relay_a/state"

  defp cell(tasklet, key, overrides \\ %{}, relay_class \\ "relay_a") do
    Map.merge(
      %{
        relay_class: relay_class,
        tasklet_id: tasklet,
        cell_key: key,
        wal_seq: 120,
        snapshot_seq: 100,
        wal_bytes: 4096,
        flush_latency_ms_p99: 3,
        fsync_durability_lag_ms: 0,
        dedup_drops_total: 0
      },
      overrides
    )
  end

  defp cells(node, rows),
    do: FakeController.set(node, {Steps, :cells}, {:ok, %{relay_class: "relay_a", cells: rows}})

  describe "cell listing" do
    test "cells are listed with their sequences and durability metrics", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="tasklet-orders")
      assert html =~ ~s(data-testid="cell-relay_a/orders/k1")
      assert html =~ "120"
      assert html =~ "100"
    end

    test "cells are grouped by tasklet", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1"), cell("shipments", "k2")])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="tasklet-orders")
      assert html =~ ~s(data-testid="tasklet-shipments")
    end

    test "only the relay's own class is read", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])

      {:ok, _view, _html} = live(conn, @url)

      calls = FakeController.calls(node, {Steps, :cells})
      assert calls != []
      assert Enum.all?(calls, &match?(["relay_a", %{source: :ui}], &1))
    end

    test "a builder's relay class is the class read", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, %{builder: %{opts: [relay_class: "orders_class"]}}}
      )

      cells(node, [])

      {:ok, _view, _html} = live(conn, @url)

      assert [["orders_class", _ctx] | _] = FakeController.calls(node, {Steps, :cells})
    end

    test "a relay with no durable state says so", %{conn: conn, node: node} do
      cells(node, [])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="state-empty")
      assert html =~ "no durable state yet"
    end

    test "a lagging cell is marked as lagging", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1", %{fsync_durability_lag_ms: 250})])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="cell-lagging-relay_a/orders/k1")
    end

    test "the retention window that applies is stated", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])
      FakeController.set(node, {Steps, :completed_retention_hours}, {:ok, 48})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="state-retention")
      assert html =~ "48 hours"

      assert [["relay_a", %{}, %{source: :ui}] | _] =
               FakeController.calls(node, {Steps, :completed_retention_hours})
    end

    test "an unreadable retention is stated and the cells still list", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])

      FakeController.set(
        node,
        {Steps, :completed_retention_hours},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ "not reported"
      assert html =~ ~s(data-testid="cell-relay_a/orders/k1")
    end

    test "no control deletes or rotates state, and flz is named instead", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="state-verbs")
      assert html =~ "flz state"
      refute html =~ "phx-click=\"delete_state\""
      refute html =~ "phx-click=\"rotate_state\""
    end
  end

  describe "the lag series" do
    test "states that it is sampled by this UI, not recorded by the controller", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="chart-provenance")
      assert html =~ "Sampled by this UI"
      assert html =~ "never interpolated"
    end

    test "a tick the controller could not answer records no point", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)

      # The controller goes away; the failed tick must not repeat the last
      # sample as though it were fresh.
      FakeController.set(node, {Steps, :cells}, FakeController.error("controller.timeout"))
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ ~s(data-testid="runtime-error")
      refute html =~ ~s(data-testid="spark-relay_a/orders/k1")
    end
  end

  describe "point-in-time reads" do
    setup %{node: node} do
      cells(node, [cell("orders", "k1")])
      :ok
    end

    defp select_and_travel(view, kind, value) do
      render_click(view, "select_cell", %{"cell" => "relay_a/orders/k1"})
      render_change(view, "travel_change", %{"travel" => %{"kind" => kind, "value" => value}})
      render_click(view, "travel", %{})
    end

    test "reading at a sequence shows the resolved sequence and the sizes", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Steps, :time_travel},
        {:ok,
         %{
           cell: "relay_a/orders/k1",
           target: "42",
           terminal_seq: 41,
           snapshot_size: 2048,
           change_log_size: 512
         }}
      )

      {:ok, view, _html} = live(conn, @url)
      html = select_and_travel(view, "seq", "42")

      assert html =~ ~s(data-testid="travel-result")
      assert html =~ ~s(data-testid="travel-target")
      assert html =~ ~r/data-testid="travel-seq"[^>]*>\s*41/
      assert html =~ "2.0 KB"
      assert html =~ "512 B"

      assert [["relay_a/orders/k1", "42", %{source: :ui}]] =
               FakeController.calls(node, {Steps, :time_travel})
    end

    test "the answer is not presented as the cell's state", %{conn: conn} do
      {:ok, view, _html} = live(conn, @url)
      html = select_and_travel(view, "seq", "42")

      refute html =~ ~s(data-testid="state-json")
      refute html =~ "balance"
    end

    test "reading at a time sends it as an ISO 8601 time", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      select_and_travel(view, "time", "2026-10-06T12:00:00Z")

      assert [[_cell, "2026-10-06T12:00:00Z", _ctx]] =
               FakeController.calls(node, {Steps, :time_travel})
    end

    test "a target outside the retained history shows the controller's message", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Steps, :time_travel},
        FakeController.error(
          "relay.outside_retention",
          "seq 1 is older than its retention window"
        )
      )

      {:ok, view, _html} = live(conn, @url)
      html = select_and_travel(view, "seq", "1")

      assert html =~ ~s(data-testid="travel-error")
      assert html =~ "older than its retention window"
      refute html =~ ~s(data-testid="travel-result")
    end

    test "a target that is neither a number nor a time never reaches the controller", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, @url)

      assert select_and_travel(view, "seq", "soon") =~ "whole sequence number or an ISO 8601"
      select_and_travel(view, "time", "yesterday")

      assert FakeController.calls(node, {Steps, :time_travel}) == []
    end
  end
end
