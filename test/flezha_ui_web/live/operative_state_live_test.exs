defmodule FlezhaUiWeb.OperativeStateLiveTest do
  @moduledoc """
  The operative's durable-state screen: entities and their counters, the
  UI-sampled lag series, and point-in-time reads.

  A target before the retained history and an operative with no durable state
  are the states worth asserting, and neither is convenient to arrange live.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.State.Metrics
  alias Flezha.State.PersistenceResolver
  alias Flezha.State.TimeTravel

  @url "/namespaces/default/operatives/op_a/state"

  defp counters(overrides \\ %{}) do
    Map.merge(
      %{
        wal_seq: 120,
        snapshot_seq: 100,
        flush_latency_ms_p99: 3,
        fsync_durability_lag_ms: 0,
        dedup_drops_total: 0
      },
      overrides
    )
  end

  defp metrics(node, rows), do: FakeController.set(node, {Metrics, :snapshot_all}, rows)

  describe "entity listing" do
    test "entities are listed with their sequences and durability metrics", %{
      conn: conn,
      node: node
    } do
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="procedure-orders")
      assert html =~ ~s(data-testid="entity-op_a/orders/k1")
      assert html =~ "120"
      assert html =~ "100"
    end

    test "entities are grouped by procedure", %{conn: conn, node: node} do
      metrics(node, [
        {{"op_a", "orders", "k1"}, counters()},
        {{"op_a", "shipments", "k2"}, counters()}
      ])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="procedure-orders")
      assert html =~ ~s(data-testid="procedure-shipments")
    end

    test "another operative's entities are not shown", %{conn: conn, node: node} do
      metrics(node, [
        {{"op_a", "orders", "mine"}, counters()},
        {{"op_b", "orders", "theirs"}, counters()}
      ])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="entity-op_a/orders/mine")
      refute html =~ ~s(data-testid="entity-op_b/orders/theirs")
    end

    test "an operative with no durable state says so", %{conn: conn, node: node} do
      metrics(node, [])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="state-empty")
      assert html =~ "no durable state yet"
    end

    test "a lagging entity is marked as lagging", %{conn: conn, node: node} do
      metrics(node, [{{"op_a", "orders", "k1"}, counters(%{fsync_durability_lag_ms: 250})}])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="entity-lagging-op_a/orders/k1")
    end

    test "the retention window that applies is stated", %{conn: conn, node: node} do
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])
      FakeController.set(node, {PersistenceResolver, :workflow_completed_retention_hours}, 48)

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="state-retention")
      assert html =~ "48 hours"
    end

    test "no control deletes or rotates state, and flz is named instead", %{
      conn: conn,
      node: node
    } do
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])

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
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="chart-provenance")
      assert html =~ "Sampled by this UI"
      assert html =~ "never interpolated"
    end

    test "a tick the controller could not answer records no point", %{conn: conn, node: node} do
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])
      {:ok, view, _html} = live(conn, @url)

      # The controller goes away; the failed tick must not repeat the last
      # sample as though it were fresh.
      FakeController.set(node, {Metrics, :snapshot_all}, {:error, :timeout})
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ ~s(data-testid="runtime-error")
      refute html =~ ~s(data-testid="spark-op_a/orders/k1")
    end
  end

  describe "point-in-time reads" do
    setup %{node: node} do
      metrics(node, [{{"op_a", "orders", "k1"}, counters()}])
      :ok
    end

    test "reading at a sequence renders the state and states the target", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {TimeTravel, :query}, {:ok, %{"balance" => 7}})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "select_entity", %{"entity" => "op_a/orders/k1"})
      render_change(view, "travel_change", %{"travel" => %{"kind" => "seq", "value" => "42"}})
      html = render_click(view, "travel", %{})

      assert html =~ ~s(data-testid="travel-result")
      assert html =~ ~s(data-testid="travel-target")
      assert html =~ "sequence 42"

      assert [[{"op_a", "orders", "k1"}, {:seq, 42}]] =
               FakeController.calls(node, {TimeTravel, :query})
    end

    test "reading at a timestamp passes a timestamp target", %{conn: conn, node: node} do
      FakeController.set(node, {TimeTravel, :query}, {:ok, %{}})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "select_entity", %{"entity" => "op_a/orders/k1"})

      render_change(view, "travel_change", %{
        "travel" => %{"kind" => "timestamp", "value" => "1700000000"}
      })

      render_click(view, "travel", %{})

      assert [[_entity, {:timestamp, 1_700_000_000}]] =
               FakeController.calls(node, {TimeTravel, :query})
    end

    test "a target before retained history shows the controller's reason and no state", %{
      conn: conn,
      node: node
    } do
      # The controller answers its own exception struct; its module is not
      # loadable here, so it arrives as a map.
      FakeController.set(
        node,
        {TimeTravel, :query},
        {:error, %{kind: :outside_retention, message: "target seq 1 predates retention window"}}
      )

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "select_entity", %{"entity" => "op_a/orders/k1"})
      render_change(view, "travel_change", %{"travel" => %{"kind" => "seq", "value" => "1"}})
      html = render_click(view, "travel", %{})

      assert html =~ ~s(data-testid="travel-error")
      assert html =~ "predates retention window"
      refute html =~ ~s(data-testid="travel-result")
    end

    test "a target that is not a number never reaches the controller", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, @url)
      render_click(view, "select_entity", %{"entity" => "op_a/orders/k1"})
      render_change(view, "travel_change", %{"travel" => %{"kind" => "seq", "value" => "soon"}})
      render_click(view, "travel", %{})

      assert FakeController.calls(node, {TimeTravel, :query}) == []
    end
  end
end
