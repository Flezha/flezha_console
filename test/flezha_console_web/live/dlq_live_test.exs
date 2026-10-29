defmodule FlezhaConsoleWeb.DlqLiveTest do
  @moduledoc """
  The dead-letter queue screen, against a controller that can be made to hold
  entries.

  A healthy dev stack keeps the queue empty, which is why the browser suite
  covers only the empty states: everything here — the table, the inspect modal,
  the confirm gates, the replay outcome — needs parked entries that a live
  controller will not manufacture on request.
  """

  use FlezhaConsoleWeb.LiveCase

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
        "attempts" => 3,
        "payload_bytes" => 2_048,
        "error" => "upstream refused"
      },
      overrides
    )
  end

  defp with_entries(node, entries),
    do: FakeController.set(node, {Dlq, :list}, FakeController.rows(entries))

  # Each verb opens its confirm gate from the row's menu and confirms it.
  defp drop(view) do
    view |> element(~s([data-testid="dlq-drop-#{@ref}"])) |> render_click()
    view |> element(~s([data-testid="dlq-confirm-submit"][phx-click="drop"])) |> render_click()
  end

  defp replay(view) do
    view |> element(~s([data-testid="dlq-replay-#{@ref}"])) |> render_click()
    view |> element(~s([data-testid="dlq-confirm-submit"][phx-click="replay"])) |> render_click()
  end

  defp replayed(view) do
    replay(view)
    render_async(view)
  end

  describe "listing" do
    test "a sink's parked error object reads as its message and code", %{conn: conn, node: node} do
      object =
        ~s({"code":"websocket.unacknowledged","class":"unavailable",) <>
          ~s("message":"the websocket peer did not acknowledge the output","details":{"attempts":3},"hint":null})

      with_entries(node, [entry(%{"error" => object})])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~
               "the websocket peer did not acknowledge the output (websocket.unacknowledged)"

      refute html =~ "&quot;code&quot;"
    end

    test "renders the dead letters with their cell key", %{conn: conn, node: node} do
      with_entries(node, [entry(), entry(%{"id" => "18", "cell_key" => "cust-4"})])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="dlq-table")
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")
      assert html =~ "orders/charge/18"
      assert html =~ "upstream refused"
      assert html =~ "cust-9"
      assert html =~ ~r/data-testid="dlq-group-count-orders-charge"[^>]*>\s*2 dead letters/
    end

    test "each dead letter states when, how often it was tried, its size and its state", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry(), entry(%{"id" => "18", "status" => "replaying"})])

      {:ok, view, html} = live(conn, ~p"/dlq")

      row = view |> element(~s([data-testid="dlq-row-#{@ref}"])) |> render()
      assert text_of(html, ~s([data-testid="dlq-at-#{@ref}"])) =~ "30 s ago"
      assert row =~ "3"
      assert row =~ "2.0 KB"
      assert text_of(html, ~s([data-testid="dlq-state-#{@ref}"])) == "Waiting"
      assert text_of(html, ~s([data-testid="dlq-state-orders/charge/18"])) == "Replaying"
      refute html =~ ~r/>[^<]*\bParked\b/
    end

    test "the queue's total size is shown from the stats", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Dlq, :stats},
        FakeController.rows([
          %{relay_class: "orders", tasklet_id: "charge", entries: 3, bytes: 1_024},
          %{relay_class: "refunds", tasklet_id: "settle", entries: 1, bytes: 1_024}
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert text_of(html, ~s([data-testid="dlq-total-bytes"])) =~ "2.0 KB"
    end

    test "renders the statistics per parked tasklet", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Dlq, :stats},
        FakeController.rows([
          %{relay_class: "orders", tasklet_id: "charge", entries: 3, bytes: 120},
          %{relay_class: "refunds", tasklet_id: "settle", entries: 0, bytes: 0}
        ])
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      stats = view |> element(~s([data-testid="dlq-stats"])) |> render()
      assert stats =~ "<dt>orders/charge</dt>"
      assert stats =~ "3"
      refute stats =~ "refunds/settle"
    end

    test "hides the statistics when every set the controller reports is empty", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Dlq, :stats},
        FakeController.rows([
          %{relay_class: "refunds", tasklet_id: "settle", entries: 0, bytes: 0}
        ])
      )

      {:ok, _view, html} = live(conn, ~p"/dlq")

      refute html =~ ~s(data-testid="dlq-stats")
      assert html =~ "The queue is empty."
    end

    test "filtering by relay class narrows what the controller is asked for", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [entry()])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filter" => %{"relay_class" => "orders"}})

      assert_patch(view, ~p"/dlq?class=orders")

      # The filter is pushed down to the controller rather than applied to a
      # full list here.
      assert ["orders", [limit: 20], %{source: :ui}] =
               node |> FakeController.calls({Dlq, :list}) |> List.last()
    end

    test "an unfiltered listing asks for every class", %{conn: conn, node: node} do
      {:ok, _view, _html} = live(conn, ~p"/dlq")

      assert [nil, [limit: 20], _ctx] = node |> FakeController.calls({Dlq, :list}) |> List.last()
    end
  end

  describe "inspecting an entry" do
    test "opens and closes the payload in the inspector", %{conn: conn, node: node} do
      with_entries(node, [entry()])
      FakeController.set(node, {Dlq, :get}, {:ok, entry(), "the parked payload"})

      {:ok, view, _html} = live(conn, ~p"/dlq")

      view |> element(~s([data-testid="dlq-inspect-#{@ref}"])) |> render_click()
      assert_patch(view, ~p"/dlq?#{[inspect: "entry:#{@ref}"]}")

      assert view |> element(~s([data-testid="inspector-payload"])) |> render() =~
               "the parked payload"

      view |> element(~s([data-testid="inspector-close"])) |> render_click()
      assert_patch(view, ~p"/dlq")
      refute render(view) =~ ~s(data-testid="inspector-entry")
    end

    test "an address naming a kind this screen does not inspect opens nothing", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/dlq?inspect=relay:default/orders")

      refute html =~ ~s(data-testid="inspector-relay")
    end

    test "reports an entry that has since left the queue", %{conn: conn, node: node} do
      with_entries(node, [entry()])

      FakeController.set(
        node,
        {Dlq, :get},
        FakeController.error("dlq.not_found", "entry 'orders/charge/17' is not parked")
      )

      {:ok, view, _html} = live(conn, ~p"/dlq")

      view |> element(~s([data-testid="dlq-inspect-#{@ref}"])) |> render_click()

      assert render(view) =~ "is not parked"
    end
  end

  describe "destructive verbs are confirm-gated" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "confirming a drop reaches the controller and reports it", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = drop(view)

      assert html =~ "Entry dropped"
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :drop})
    end

    test "a refused drop is reported", %{conn: conn, node: node} do
      FakeController.set(node, {Dlq, :drop}, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/dlq")

      assert drop(view) =~ "authz.role_insufficient"
    end
  end

  describe "replay outcome" do
    setup %{node: node} do
      with_entries(node, [entry()])
      :ok
    end

    test "says it is waiting while the controller's grace period runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      assert replay(view) =~ ~s(data-testid="replay-pending")
    end

    test "re-sends through the controller's replay and reports the entry gone", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replayed(view)

      assert html =~ ~s(data-testid="replay-succeeded")
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :replay})
    end

    test "reports a re-park with its new generation", %{conn: conn, node: node} do
      FakeController.set(node, {Dlq, :replay}, {:ok, %{outcome: :re_parked, generation: 3}})

      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = replayed(view)
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

      html = replayed(view)
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

      html = replayed(view)
      assert html =~ ~s(data-testid="replay-refused")
      assert html =~ "entry carries no payload bytes"
    end
  end

  describe "grouping across tasklets" do
    test "entries spanning tasklets are grouped, each with its dead-letter count", %{
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
      assert html =~ "2 dead letters"
      assert html =~ ~r/1 dead letter\s*</
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

      FakeController.set(
        node,
        {Dlq, :tasklets},
        FakeController.rows([%{relay_class: "relay_a", tasklet_id: "orders", node: :flezha@c1}])
      )

      {:ok, _view, html} = live(conn, ~p"/dlq")

      # An empty queue reads as empty, not as a list of empty groups.
      assert html =~ ~s(data-testid="dlq-empty")
    end
  end

  describe "entries on several controllers" do
    defp held_by(entry, node), do: Map.put(entry, :node, node)

    test "one controller's entries name it and offer no controller filter", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [held_by(entry(), :flezha@c1)])

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert text_of(html, ~s([data-testid="row-controller"])) == "c1"
      assert html =~ ~s(title="flezha@c1")
      refute html =~ ~s(data-testid="filter-controller")
    end

    test "two controllers' entries offer a filter that narrows them to one", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [
        held_by(entry(), :flezha@c1),
        held_by(entry(%{"id" => "18"}), :flezha@c2)
      ])

      {:ok, view, html} = live(conn, ~p"/dlq")

      assert html =~ ~s(data-testid="filter-controller")
      assert html =~ ~s(data-testid="dlq-row-orders/charge/18")

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filter" => %{"relay_class" => "", "controller" => "flezha@c1"}})

      assert_patch(view, "/dlq?controller=flezha%40c1")
      html = render_async(view)
      assert html =~ ~s(data-testid="dlq-row-#{@ref}")
      refute html =~ ~s(data-testid="dlq-row-orders/charge/18")
    end

    test "a partial answer is stated, and an empty one is not called an empty queue", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Dlq, :list}, FakeController.rows([], ["flezha@c2"]))

      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert text_of(html, ~s([data-testid="partial-answer"])) =~ "flezha@c2 did not"
      assert text_of(html, ~s([data-testid="partial-empty"])) =~ "No dead letter was found"
      refute html =~ ~s(data-testid="dlq-empty")
    end

    test "drop, replay and mark seen reach an entry another controller holds", %{
      conn: conn,
      node: node
    } do
      with_entries(node, [held_by(entry(), :flezha@c2)])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      assert drop(view) =~ "Entry dropped"
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :drop})

      assert replayed(view) =~ ~s(data-testid="replay-succeeded")
      assert [[@ref, %{source: :ui}]] = FakeController.calls(node, {Dlq, :replay})

      view |> element(~s([data-testid="dlq-mark-seen-#{@ref}"])) |> render_click()
      refute render_async(view) =~ ~s(data-testid="dlq-row-#{@ref}")

      assert [%{relay_class: "orders"}] =
               FlezhaConsole.Repo.all(FlezhaConsole.DeadLetters.Acknowledgement)
    end
  end

  describe "seen" do
    alias FlezhaConsole.DeadLetters
    alias FlezhaConsole.DeadLetters.Acknowledgement
    alias FlezhaConsole.Repo

    # Marking reads the queue again, in the background.
    defp mark(view, ref) do
      view |> element(~s([data-testid="dlq-mark-seen-#{ref}"])) |> render_click()
      render_async(view)
    end

    defp parked(node, entries) do
      with_entries(node, entries)

      stats =
        entries
        |> Enum.group_by(&{&1["relay_class"], &1["tasklet_id"]})
        |> Enum.map(fn {{class, tasklet}, rows} ->
          %{relay_class: class, tasklet_id: tasklet, entries: length(rows), bytes: 0}
        end)

      FakeController.set(node, {Dlq, :stats}, FakeController.rows(stats))
    end

    test "a seen dead letter leaves the listing, and Show seen lists it badged", %{
      conn: conn,
      node: node,
      user: user
    } do
      parked(node, [entry(), entry(%{"id" => "18"})])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = mark(view, @ref)

      refute html =~ ~s(data-testid="dlq-row-#{@ref}")
      assert html =~ ~s(data-testid="dlq-row-orders/charge/18")

      assert text_of(html, ~s([data-testid="dlq-hidden-seen"])) ==
               "1 more is marked seen and hidden."

      assert html =~
               ~r/data-testid="dlq-group-count-orders-charge"[^>]*>\s*2 dead letters, 1 seen/

      assert [%{generation: 2, relay_class: "orders", acknowledged_by: email}] =
               Repo.all(Acknowledgement)

      assert email == user.email
      # Seen is the console's own record: the controller's queue is not touched.
      assert FakeController.calls(node, {Dlq, :drop}) == []

      view
      |> element(~s(form[phx-change="filter"]))
      |> render_change(%{"filter" => %{"relay_class" => "", "show_seen" => "true"}})

      assert_patch(view, ~p"/dlq?seen=shown")
      html = render_async(view)
      assert text_of(html, ~s([data-testid="dlq-seen-#{@ref}"])) == "Seen"
      refute html =~ ~s(data-testid="dlq-mark-seen-#{@ref}")
      refute html =~ ~s(data-testid="dlq-seen-orders/charge/18")
    end

    test "a tasklet's dead letters are marked seen at once", %{conn: conn, node: node} do
      parked(node, [entry(), entry(%{"id" => "18"}), entry("refunds", "settle", "1", %{})])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      view |> element(~s([data-testid="dlq-group-seen-orders-charge"])) |> render_click()
      html = render_async(view)

      refute html =~ ~s(data-testid="dlq-group-orders-charge")
      assert html =~ ~s(data-testid="dlq-row-refunds/settle/1")

      assert text_of(html, ~s([data-testid="dlq-hidden-seen"])) ==
               "2 more are marked seen and hidden."

      assert Repo.aggregate(Acknowledgement, :count) == 2
    end

    test "every dead letter seen says so instead of an empty queue", %{conn: conn, node: node} do
      parked(node, [entry()])
      {:ok, view, _html} = live(conn, ~p"/dlq")

      html = mark(view, @ref)

      assert html =~ "1 dead letter is marked seen and hidden."
      assert text_of(html, ~s([data-testid="dlq-empty"])) =~ "Show seen lists them"
    end

    test "a seen dead letter that parks again under a new generation is unseen", %{
      conn: conn,
      node: node
    } do
      parked(node, [entry()])
      {:ok, view, _html} = live(conn, ~p"/dlq")
      mark(view, @ref)

      parked(node, [entry(%{"generation" => 3})])
      send(view.pid, :refresh)

      assert render_async(view) =~ ~s(data-testid="dlq-row-#{@ref}")
      assert {:ok, %{rows: [%{seen: 0}]}} = DeadLetters.stats(nil)
      # The mark of the generation that left is forgotten.
      assert Repo.all(Acknowledgement) == []
    end

    test "the rail, Open problems and Home leave a seen dead letter out", %{
      conn: conn,
      node: node,
      user: user
    } do
      FakeController.set_fleet(node, rows: %{"default" => [FakeController.relay_row("orders")]})
      parked(node, [entry()])

      {_view, html} = live_loaded(conn, ~p"/problems")
      assert html =~ ~s(data-testid="problem-dead_letters:orders")

      DeadLetters.mark_seen([%{ref: @ref, generation: 2, relay_class: "orders"}], user.email)

      {_view, html} = live_loaded(conn, ~p"/problems")
      assert html =~ ~s(data-testid="problems-clear")
      refute html =~ ~s(data-testid="problems-count")

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="home-headline"])) ==
               "Nothing in default needs attention."

      assert text_of(html, ~s([data-testid="ns-parked-value"])) == "1"
      assert text_of(html, ~s([data-testid="ns-parked-verdict"])) == "Seen"
    end
  end
end
