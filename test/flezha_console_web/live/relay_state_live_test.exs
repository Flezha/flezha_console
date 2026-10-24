defmodule FlezhaConsoleWeb.RelayStateLiveTest do
  @moduledoc """
  The relay's durable-state screen: cells and their counters, the UI-sampled
  lag series, and point-in-time reads.

  A target outside the retained history and a relay with no durable state are
  the states worth asserting, and neither is convenient to arrange live.
  """

  use FlezhaConsoleWeb.LiveCase

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

  defp cells(node, rows, extra \\ []) do
    answer = Map.merge(%{relay_class: "relay_a", cells: rows}, Map.new(extra))
    FakeController.set(node, {Steps, :cells}, {:ok, answer})
  end

  defp select_cell(view),
    do: view |> element(~s([data-testid="select-relay_a/orders/k1"])) |> render_click()

  defp select_and_target(view, kind, value) do
    select_cell(view)

    # The kind's combobox sets its hidden input from JS, so the change carries it.
    view
    |> form(~s(form[phx-change="travel_change"]))
    |> render_change(%{"travel" => %{"kind" => kind, "value" => value}})
  end

  defp set_retention(view, hours) do
    view
    |> form(~s([data-testid="retention-form"]), %{"retention" => %{"hours" => hours}})
    |> render_submit()
  end

  defp run(node, run),
    do: FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{builder: %{run: run}}})

  describe "partitions" do
    test "a partition member's menu opens another partition on State", %{conn: conn, node: node} do
      partition_group(node, "orders", 2)

      {:ok, view, html} = live(conn, "/namespaces/default/relays/orders%23p0/state")

      assert text_of(html, ~s([data-testid="partition-menu"])) == "Partition p0 of 2"

      assert {:error, {:live_redirect, %{to: "/namespaces/default/relays/orders%23p1/state"}}} =
               view |> element(~s([data-testid="partition-menu-orders#p1"])) |> render_click()
    end

    test "a relay of no partition group shows no menu", %{conn: conn, node: node} do
      partition_group(node, "orders", 2)

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="partition-menu")
    end
  end

  describe "cell listing" do
    test "cells are listed with their sequences and durability metrics", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])

      {:ok, _view, html} = live(conn, @url)

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
      assert html =~ "This relay has none persisted yet."
    end

    test "a lagging cell is marked as lagging", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1", %{fsync_durability_lag_ms: 250})])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="cell-lagging-relay_a/orders/k1")
    end

    test "a steps relay states both retentions, each under its own label", %{
      conn: conn,
      node: node
    } do
      run(node, :steps)
      cells(node, [cell("orders", "k1")], history_retention_hours: 12)
      FakeController.set(node, {Steps, :completed_retention_hours}, {:ok, 48})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~r/data-testid="history-retention"[^>]*>\s*12 hours/
      assert html =~ ~r/data-testid="finished-retention"[^>]*>\s*48 hours/

      assert [["relay_a", %{}, %{source: :ui}] | _] =
               FakeController.calls(node, {Steps, :completed_retention_hours})
    end

    test "a finished relay, with no overwatch, states its finished-instance retention", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))
      cells(node, [], history_retention_hours: 12)
      FakeController.set(node, {Steps, :completed_retention_hours}, {:ok, 72})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~r/data-testid="finished-retention"[^>]*>\s*72 hours/
    end

    test "a flow relay states the history retention alone", %{conn: conn, node: node} do
      run(node, :flow)
      cells(node, [cell("orders", "k1")], history_retention_hours: 12)

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~r/data-testid="history-retention"[^>]*>\s*12 hours/
      refute html =~ ~s(data-testid="finished-retention")
      assert FakeController.calls(node, {Steps, :completed_retention_hours}) == []
    end

    test "an unreadable retention is unavailable and the cells still list", %{
      conn: conn,
      node: node
    } do
      run(node, :steps)
      cells(node, [cell("orders", "k1")])

      FakeController.set(
        node,
        {Steps, :completed_retention_hours},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~r/data-testid="finished-retention"[^>]*>\s*Unavailable/
      assert html =~ ~s(data-testid="cell-relay_a/orders/k1")
    end

    test "an older controller's answer states the history retention as unknown", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Steps, :cells}, {:ok, %{relay_class: "relay_a", cells: []}})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~r/data-testid="history-retention"[^>]*>\s*Unknown/
    end
  end

  describe "setting the history retention" do
    test "sets the class's retention and states it lasts until the next boot", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])
      {:ok, view, html} = live(conn, @url)
      assert html =~ "lasts until the controller next boots"

      html = set_retention(view, "6")

      assert [["relay_a", 6, _ctx]] = FakeController.calls(node, {Steps, :set_retention})
      assert html =~ "History retention set to 6 hours until the controller next boots."
      assert html =~ ~r/data-testid="history-retention"[^>]*>\s*6 hours/
    end

    test "a negative or non-numeric value is named and nothing is called", %{
      conn: conn,
      node: node
    } do
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)

      for hours <- ["-1", "six", ""] do
        html = set_retention(view, hours)
        assert html =~ "Hours must be a whole number of zero or more."
      end

      assert FakeController.calls(node, {Steps, :set_retention}) == []
    end
  end

  describe "a selected cell's outbox" do
    test "is read on selecting and its facts are shown", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])

      FakeController.set(
        node,
        {Steps, :outbox},
        {:ok,
         %{
           cell: "relay_a/orders/k1",
           last_persisted_seq: 118,
           outbox_durable_seq: 118,
           outbox_flushed_seq: 117,
           epoch: 3,
           pending: 2,
           held: 1,
           input_watermark: 40
         }}
      )

      {:ok, view, _html} = live(conn, @url)
      html = select_cell(view)

      assert [["relay_a/orders/k1", _ctx]] = FakeController.calls(node, {Steps, :outbox})
      assert html =~ ~r/data-testid="outbox-durable-seq"[^>]*>\s*118/
      assert html =~ ~r/data-testid="outbox-persisted-seq"[^>]*>\s*118/
      assert html =~ ~r/data-testid="outbox-pending"[^>]*>\s*2/
    end

    test "without a running writer, pending and held are unknown", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])

      FakeController.set(
        node,
        {Steps, :outbox},
        {:ok,
         %{
           cell: "relay_a/orders/k1",
           last_persisted_seq: 118,
           outbox_flushed_seq: 117,
           epoch: 3,
           pending: nil,
           held: nil
         }}
      )

      {:ok, view, _html} = live(conn, @url)
      html = select_cell(view)

      assert html =~ ~r/data-testid="outbox-pending"[^>]*>\s*Unknown — writer not running/
      assert html =~ ~r/data-testid="outbox-held"[^>]*>\s*Unknown — writer not running/
      assert html =~ ~r/data-testid="outbox-durable-seq"[^>]*>\s*Unknown — writer not running/
      assert html =~ ~r/data-testid="outbox-persisted-seq"[^>]*>\s*118/
    end
  end

  describe "rotating and deleting a cell" do
    test "a rotation is confirmed by name and requests a compaction", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)

      html = view |> element(~s([data-testid="rotate-relay_a/orders/k1"])) |> render_click()
      assert html =~ ~s(data-testid="state-confirm-modal")
      assert html =~ "relay_a/orders/k1"

      html = view |> element(~s([data-testid="state-confirm-btn"])) |> render_click()

      assert [["relay_a/orders/k1", _ctx]] = FakeController.calls(node, {Steps, :rotate})
      assert html =~ "Compaction requested for relay_a/orders/k1."
    end

    test "a delete says it cannot be undone and refreshes the row", %{conn: conn, node: node} do
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)

      html = view |> element(~s([data-testid="delete-relay_a/orders/k1"])) |> render_click()
      assert html =~ "cannot be recovered"

      cells_before = length(FakeController.calls(node, {Steps, :cells}))
      cells(node, [])
      html = view |> element(~s([data-testid="state-confirm-btn"])) |> render_click()

      assert [["relay_a/orders/k1", _ctx]] = FakeController.calls(node, {Steps, :delete})
      assert length(FakeController.calls(node, {Steps, :cells})) > cells_before
      assert html =~ ~s(data-testid="state-empty")
    end
  end

  describe "replaying a flow relay's cell" do
    test "replays from a sequence after confirming", %{conn: conn, node: node} do
      run(node, :flow)
      cells(node, [cell("orders", "k1")])

      FakeController.set(
        node,
        {Relay, :replay},
        {:ok, %{cell: "relay_a/orders/k1", from_seq: 40}}
      )

      {:ok, view, _html} = live(conn, @url)
      select_and_target(view, "seq", "40")

      html = view |> element(~s([data-testid="replay-open"])) |> render_click()
      assert html =~ "retained inputs are run again"

      html =
        view
        |> element(~s([data-testid="state-confirm-btn"][phx-click="replay"]))
        |> render_click()

      assert [["default", "relay_a/orders/k1", "40", _ctx]] =
               FakeController.calls(node, {Relay, :replay})

      assert html =~ ~r/data-testid="replay-result".*relay_a\/orders\/k1.*40/s
    end

    test "replays from an ISO 8601 time", %{conn: conn, node: node} do
      run(node, :flow)
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)
      select_and_target(view, "time", "2026-10-06T12:00:00Z")

      view |> element(~s([data-testid="replay-open"])) |> render_click()

      view
      |> element(~s([data-testid="state-confirm-btn"][phx-click="replay"]))
      |> render_click()

      assert [["default", "relay_a/orders/k1", "2026-10-06T12:00:00Z", _ctx]] =
               FakeController.calls(node, {Relay, :replay})
    end

    test "a steps relay offers no replay", %{conn: conn, node: node} do
      run(node, :steps)
      cells(node, [cell("orders", "k1")])
      {:ok, view, _html} = live(conn, @url)

      html = select_cell(view)

      assert html =~ ~s(data-testid="time-travel")
      refute html =~ ~s(data-testid="replay-open")
    end
  end

  describe "the lag series" do
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
      select_and_target(view, kind, value)
      view |> element(~s([data-testid="travel-submit"])) |> render_click()
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

      assert html =~ ~r/data-testid="travel-seq"[^>]*>\s*41/
      assert html =~ "2.0 KB"
      assert html =~ "512 B"

      assert [["relay_a/orders/k1", "42", %{source: :ui}]] =
               FakeController.calls(node, {Steps, :time_travel})
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
