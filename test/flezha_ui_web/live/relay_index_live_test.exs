defmodule FlezhaUiWeb.RelayIndexLiveTest do
  @moduledoc """
  The cross-namespace relays index.

  Covered here rather than in the browser: a fleet spanning namespaces, a
  refused listing, and the guarantee the screen exists to keep — that its cost
  does not grow with the number of relays.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay
  alias FlezhaUi.Service.EventFeed

  defp row(id, overrides \\ %{}), do: FakeController.relay_row(id, overrides)

  defp signal(name, metadata),
    do: EventFeed.signal_event(:flezha_relay, %{name: name, metadata: metadata})

  defp feed(view, message) do
    send(view.pid, message)
    render(view)
  end

  defp with_fleet(node, opts) do
    namespaces = opts[:namespaces] || ["default"]

    FakeController.set_fleet(node,
      namespaces: namespaces,
      rows: Map.new(namespaces, &{&1, opts[:rows] || []}),
      runs: opts[:runs] || %{},
      plugins: opts[:plugins] || []
    )
  end

  describe "a row" do
    test "names its relay as a link to the relay's page, and offers Open", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("relay_a")])
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays")

      assert view |> element(~s([data-testid="relay-link-relay_a"])) |> render() =~
               ~s(href="/namespaces/default/relays/relay_a")

      assert view |> element(~s([data-testid="open-relay-relay_a"])) |> render() =~
               ~s(href="/namespaces/default/relays/relay_a")

      # Following the link leaves for the relay; it does not open the inspector.
      view |> element(~s([data-testid="relay-link-relay_a"])) |> render_click()
      assert_redirect(view, ~p"/namespaces/default/relays/relay_a")
    end

    test "a partition group links each of its members", %{conn: conn, node: node} do
      group = %{
        row("demo")
        | runner: "p0→runner-a, p1→runner-a"
      }

      group =
        Map.merge(group, %{
          partitions: "2/2",
          members: [row("demo#p0"), row("demo#p1")]
        })

      with_fleet(node, rows: [group])
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays")

      members = view |> element(~s([data-testid="relay-members-demo"])) |> render()
      assert members =~ ~s(href="/namespaces/default/relays/demo%23p0")
      assert members =~ ~s(href="/namespaces/default/relays/demo%23p1")
      assert has_element?(view, ~s([data-testid="relay-link-demo#p0"]))
      refute has_element?(view, ~s([data-testid="open-relay-demo"]))
    end

    defp counters(node, received) do
      FakeController.set(
        node,
        {Flezha.Service.Controller, :liveness_counters},
        {:ok,
         %{
           channels: [],
           relays: [
             %{relay_id: "relay_a", io_in_received: received, forwarded: 0, filtered_nil: 0}
           ]
         }}
      )
    end

    test "its rate carries its recent history once two readings exist", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("relay_a")])
      counters(node, 0)
      {:ok, view, html} = live(conn, ~p"/relays")

      assert view |> element(~s([data-testid="relay-rate-relay_a"])) |> render() =~ "—"
      refute html =~ ~s(data-testid="relay-spark-relay_a")

      counters(node, 1_000)
      tick(view)
      counters(node, 3_000)
      html = tick(view)

      assert html =~ ~s(data-testid="relay-spark-relay_a")
      assert view |> element(~s([data-testid="relay-rate-relay_a"])) |> render() =~ "/s"
    end

    test "its menu inspects it in place", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("relay_a")])
      {:ok, view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="relay-menu-relay_a")

      view |> element(~s([data-testid="inspect-relay-relay_a"])) |> render_click()
      assert_patch(view, ~p"/relays?#{[inspect: "relay:default/relay_a"]}")
      assert render(view) =~ ~s(data-testid="inspector-relay")
    end

    test "a runner filter says which runner, and is cleared in one step", %{
      conn: conn,
      node: node
    } do
      with_fleet(node,
        rows: [row("relay_a", %{runner: "runner-a"}), row("relay_b", %{runner: "runner-b"})]
      )

      {:ok, view, html} = live(conn, ~p"/relays?runner=runner-a")

      assert html =~ ~s(data-testid="filter-runner")
      assert html =~ ~s(data-testid="relay-index-row-relay_a")
      refute html =~ ~s(data-testid="relay-index-row-relay_b")

      view |> element(~s([data-testid="filter-runner-clear"])) |> render_click()
      assert_patch(view, ~p"/relays")
      assert render(view) =~ ~s(data-testid="relay-index-row-relay_b")
    end
  end

  describe "listing" do
    test "lists every relay in every reachable namespace", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("relay_a"), row("relay_b")])

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="relays-index-table")
      assert html =~ ~s(data-testid="relay-index-row-relay_a")
      assert html =~ ~s(data-testid="relay-index-row-relay_b")
    end

    test "each row carries namespace, factory, health, run, node, runner and plugins", %{
      conn: conn,
      node: node
    } do
      with_fleet(node,
        rows: [
          row("relay_a", %{health: :degraded, node: :"flezha@node-z", factory: "compare_filter"})
        ],
        runs: %{"relay_a" => :steps},
        plugins: [{"relay_a", [{"p1", %{}}, {"p2", %{}}]}]
      )

      {:ok, view, _html} = live(conn, ~p"/relays")
      row = view |> element(~s([data-testid="relay-index-row-relay_a"])) |> render()

      assert row =~ "compare_filter"
      assert row =~ ~s(data-health="degraded")
      assert row =~ "steps"
      assert row =~ "flezha@node-z"
      assert row =~ "runner-a"
      assert row =~ ~r/<td[^>]*class="fui-cell-num"[^>]*>\s*2\s*<\/td>/
    end
  end

  describe "filters" do
    defp filter(view, fields),
      do: view |> element(~s(form[phx-change="filter"])) |> render_change(%{"filters" => fields})

    setup %{node: node} do
      with_fleet(node,
        namespaces: ["default", "staging"],
        rows: [row("relay_a"), row("relay_b", %{health: :failed})],
        runs: %{"relay_a" => :flow, "relay_b" => :steps}
      )

      :ok
    end

    test "filtering by health lists only matching relays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = filter(view, %{"health" => "failed"})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
    end

    test "a scoped namespace with no relays says nothing runs there", %{conn: conn, node: node} do
      with_fleet(node, namespaces: ["default", "staging"], rows: [])

      {:ok, _view, html} = live(conn, ~p"/namespaces/staging/relays")

      assert html =~ "None is running in staging."
      refute html =~ "No running relay matches these filters."
    end

    test "filters that match nothing say so, not that nothing runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html =
        filter(view, %{"health" => "failed", "run" => "flow"})

      assert html =~ ~s(data-testid="relays-empty")
      assert html =~ "No running relay matches these filters."
      refute html =~ "No relays are running"
    end

    test "the health filter offers every verdict, recovering and parked included", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/relays")

      for verdict <- ~w(healthy unknown suspended degraded recovering unbound failed parked) do
        assert html =~ ~s(data-testid="filter-health-#{verdict}"), "no #{verdict} option"
      end
    end

    test "filtering by run lists only matching relays", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = filter(view, %{"run" => "steps"})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
    end

    test "the run filter offers the runs present in the listing", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="filter-run-flow")
      assert html =~ ~s(data-testid="filter-run-steps")

      # Choosing one does not take the other away from the choice.
      html = filter(view, %{"run" => "steps"})
      assert html =~ ~s(data-testid="filter-run-flow")
    end

    test "filtering by namespace lists only that namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = filter(view, %{"namespace" => "staging"})

      assert html =~ "/namespaces/staging/relays/relay_a"
      refute html =~ "/namespaces/default/relays/relay_a"
    end

    test "filtering to suspended relays costs no per-relay read", %{conn: conn, node: node} do
      # The Convergence Loop ranks suspension in the health ladder, so this is
      # a health filter — it rides the listing's own namespace-flat read.
      with_fleet(node, rows: [row("relay_a"), row("relay_b", %{health: :suspended})])

      {:ok, view, _html} = live(conn, ~p"/relays")
      html = filter(view, %{"health" => "suspended"})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "cost" do
    test "a listing tick costs the same for two relays as for fifty", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("relay_a"), row("relay_b")])
      {:ok, _view, _html} = live(conn, ~p"/relays")
      small = length(FakeController.calls(node, {Relay, :list}))

      FakeController.reset(node)
      with_fleet(node, rows: Enum.map(1..50, &row("relay_#{&1}")))
      {:ok, _view, _html} = live(conn, ~p"/relays")
      large = length(FakeController.calls(node, {Relay, :list}))

      assert small == large

      # The run rides one registry read per namespace, not one per relay.
      assert length(FakeController.calls(node, {Relay, :registry})) == small
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "the relay lifecycle feed" do
    test "each signal is an entry, newest first, and reloads the rows", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/relays")
      reads = length(FakeController.calls(node, {Relay, :list}))

      feed(view, signal(:relay_started, %{namespace: "default", relay: "r1", factory: "orders"}))
      feed(view, signal(:relay_stopped, %{namespace: "default", relay: "r1", reason: :stopped}))

      html =
        feed(
          view,
          signal(:relay_exited, %{
            namespace: "default",
            relay_id: "r1",
            runner_id: "runner-a",
            reason: "runner_disconnected"
          })
        )

      assert html =~
               ~r/data-testid="lifecycle-what-0"[^>]*>\s*<span[^>]*>default<\/span> exited on runner runner-a: runner_disconnected/

      assert html =~
               ~r/data-testid="lifecycle-what-1"[^>]*>\s*<span[^>]*>default<\/span> stopped: :stopped/

      assert html =~
               ~r/data-testid="lifecycle-what-2"[^>]*>\s*<span[^>]*>default<\/span> started from orders/

      assert length(FakeController.calls(node, {Relay, :list})) >= reads + 3
    end

    test "a runner dropped or readmitted is said, and the index keeps running", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/relays")

      send(view.pid, {:flezha_event, :runner_dropped, {"default", "runner-a"}})
      send(view.pid, {:flezha_event, :runner_readmitted, {"default", "runner-a"}})
      html = render(view)

      assert html =~ "runner readmitted"
      assert html =~ "runner dropped"
    end

    test "a signal from a namespace the token does not reach is not shown", %{
      conn: conn,
      node: node
    } do
      with_fleet(node, rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/relays")

      reads = length(FakeController.calls(node, {Relay, :list}))
      html = feed(view, signal(:relay_started, %{namespace: "secret", relay: "x", factory: "f"}))

      refute html =~ ~s(data-testid="lifecycle-entry-0")
      assert length(FakeController.calls(node, {Relay, :list})) == reads
    end

    test "the scoped screen shows its own namespace's signals alone", %{conn: conn, node: node} do
      with_fleet(node, namespaces: ["default", "staging"], rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays")

      feed(view, signal(:relay_started, %{namespace: "staging", relay: "s1", factory: "f"}))

      html =
        feed(view, signal(:relay_started, %{namespace: "default", relay: "r1", factory: "f"}))

      assert html =~ ~s(data-testid="lifecycle-entry-0")
      refute html =~ ~s(data-testid="lifecycle-entry-1")
    end

    test "only the most recent fifty are kept", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/relays")

      for n <- 1..55,
          do:
            send(
              view.pid,
              signal(:relay_started, %{namespace: "default", relay: "r#{n}", factory: "f"})
            )

      html = render(view)

      assert html =~ ~s(data-testid="lifecycle-entry-49")
      refute html =~ ~s(data-testid="lifecycle-entry-50")
      assert html =~ "/namespaces/default/relays/r55"
      refute html =~ "/namespaces/default/relays/r5\""
    end

    test "a refused feed states why, and the index keeps refreshing", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("r1")])
      {:ok, view, _html} = live(conn, ~p"/relays")

      refusal =
        Flezha.Error.new("observability.pubsub_disabled", "pubsub is off", "enable the sink")

      html = feed(view, {:flezha_feed, EventFeed.signal_feed(:flezha_relay), refusal})

      assert html =~ ~s(data-testid="lifecycle-error")
      assert html =~ "observability.pubsub_disabled"
      assert html =~ "enable the sink"

      reads = length(FakeController.calls(node, {Relay, :list}))
      feed(view, :refresh)
      assert length(FakeController.calls(node, {Relay, :list})) > reads

      html = feed(view, {:flezha_feed, EventFeed.signal_feed(:flezha_relay), nil})
      refute html =~ ~s(data-testid="lifecycle-error")
    end
  end
end
