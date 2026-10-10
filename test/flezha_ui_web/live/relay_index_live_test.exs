defmodule FlezhaUiWeb.RelayIndexLiveTest do
  @moduledoc """
  The cross-namespace relays index.

  Covered here rather than in the browser: a fleet spanning namespaces, a
  refused listing, and the guarantee the screen exists to keep — that its cost
  does not grow with the number of relays.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Fleet
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

  defp start_form(overrides) do
    Map.merge(
      %{
        "namespace" => "default",
        "id" => "relay_new",
        "factory_id" => "store_input",
        "init_values" => "",
        "snapshot_interval" => ""
      },
      overrides
    )
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

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ "compare_filter"
      assert html =~ ~s(data-health="degraded")
      assert html =~ "steps"
      assert html =~ "flezha@node-z"
      assert html =~ "runner-a"
      assert html =~ ">2<"
    end

    test "every health verdict the controller answers renders distinctly", %{
      conn: conn,
      node: node
    } do
      with_fleet(node,
        rows: [row("relay_a", %{health: :recovering}), row("relay_b", %{health: :parked})]
      )

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-health="recovering")
      assert html =~ ~s(data-health="parked")
    end

    test "a relay id navigates to its detail screen", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("relay_a")])

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ "/namespaces/default/relays/relay_a"
    end

    test "an unplaced relay is named rather than left blank", %{conn: conn, node: node} do
      with_fleet(node, rows: [row("relay_a", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ "unplaced"
    end

    test "a builder without a run reads as flow, and plugin entries are skipped", %{
      conn: conn,
      node: node
    } do
      # `set_fleet/2` puts a `{:plugin, name}` entry in every registry, as a
      # real one carries; the listing must read past it.
      with_fleet(node, rows: [row("relay_a")])

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="relay-index-row-relay_a")
      assert html =~ "flow"
    end

    test "an empty fleet says so rather than rendering an empty table", %{conn: conn, node: node} do
      with_fleet(node, rows: [])

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="relays-empty")
      assert html =~ "No relays are running in any reachable namespace."
      refute html =~ ~s(data-testid="relays-index-table")
    end

    test "a refused namespace listing is stated, not rendered as empty", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.error("authz.principal_not_bound", "no principal is bound")
      )

      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "refused"
      assert html =~ "authz.principal_not_bound"
      assert html =~ "no principal is bound"
    end
  end

  describe "filters" do
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

      html = render_change(view, "filter", %{"filters" => %{"health" => "failed"}})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
    end

    test "a scoped namespace with no relays says nothing runs there", %{conn: conn, node: node} do
      with_fleet(node, namespaces: ["default", "staging"], rows: [])

      {:ok, _view, html} = live(conn, ~p"/namespaces/staging/relays")

      assert html =~ "No relays are running in staging."
      refute html =~ "No running relay matches these filters."
    end

    test "filters that match nothing say so, not that nothing runs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html =
        render_change(view, "filter", %{"filters" => %{"health" => "failed", "run" => "flow"}})

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

      html = render_change(view, "filter", %{"filters" => %{"run" => "steps"}})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
    end

    test "the run filter offers the runs present in the listing", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="filter-run-flow")
      assert html =~ ~s(data-testid="filter-run-steps")

      # Choosing one does not take the other away from the choice.
      html = render_change(view, "filter", %{"filters" => %{"run" => "steps"}})
      assert html =~ ~s(data-testid="filter-run-flow")
    end

    test "filtering by namespace lists only that namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = render_change(view, "filter", %{"filters" => %{"namespace" => "staging"}})

      assert html =~ "staging"
      refute html =~ ~s(>default<)
    end

    test "filtering to suspended relays costs no per-relay read", %{conn: conn, node: node} do
      # The Convergence Loop ranks suspension in the health ladder, so this is
      # a health filter — it rides the listing's own namespace-flat read.
      with_fleet(node, rows: [row("relay_a"), row("relay_b", %{health: :suspended})])

      {:ok, view, _html} = live(conn, ~p"/relays")
      html = render_change(view, "filter", %{"filters" => %{"health" => "suspended"}})

      assert html =~ ~s(data-testid="relay-index-row-relay_b")
      refute html =~ ~s(data-testid="relay-index-row-relay_a")
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "starting a relay from the index" do
    setup %{node: node} do
      with_fleet(node, namespaces: ["default", "staging"], rows: [])

      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok,
         [
           %{id: "store_input", description: "stores its input", run: :flow},
           %{id: "chat_loop_steps", description: "chats", run: :steps}
         ]}
      )

      FakeController.set(node, {Fleet, :runners_for_factory}, {:ok, ["runner-a"]})

      :ok
    end

    test "the screen carries the control that starts one", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/relays")

      assert html =~ ~s(data-testid="start-relay-btn")
    end

    test "the form asks which namespace to start into, and no kind", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")

      html = render_click(view, "launcher_open", %{})

      assert has_element?(view, ~s([data-testid="input-namespace"] option[value="default"]))
      assert has_element?(view, ~s([data-testid="input-namespace"] option[value="staging"]))
      refute html =~ "start[kind]"
    end

    test "the chosen factory's run is stated, not offered", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      html =
        render_change(view, "launcher_change", %{
          "start" => start_form(%{"factory_id" => "chat_loop_steps"})
        })

      assert html =~ ~s(data-testid="factory-run")
      assert html =~ ~r/data-testid="factory-run"[^>]*>\s*Runs as\s*<span[^>]*>steps/
    end

    test "a start reaches the chosen namespace with no run", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      html =
        render_submit(view, "launcher_submit", %{
          "start" => start_form(%{"namespace" => "staging"})
        })

      assert html =~ ~s(data-testid="start-result")
      assert html =~ "Relay started in staging."
      assert html =~ "/namespaces/staging/relays/relay_new"

      assert [["staging", relay, %{source: :ui}]] = FakeController.calls(node, {Relay, :start})
      assert relay[:id] == "relay_new"
      assert relay[:factory_id] == "store_input"
      assert relay[:init_values] == %{}
      refute Keyword.has_key?(relay, :run)
      refute Keyword.has_key?(relay, :kind)
    end

    test "an empty id is left to the controller, and the drawn id is linked", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{"id" => ""})})

      assert [["default", relay, _ctx]] = FakeController.calls(node, {Relay, :start})
      refute Keyword.has_key?(relay, :id)
      assert html =~ "/namespaces/default/relays/relay-generated"
    end

    test "a relay already running under the id is said so, not reported started", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :start},
        {:ok, %{id: "relay_new", outcome: :already_running}}
      )

      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{})})

      assert html =~ "already running in default"
      refute html =~ "Relay started"
    end

    test "a refused start states the controller's error on the form", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :start},
        FakeController.error("authz.role_insufficient", "viewers cannot start relays")
      )

      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{})})

      assert html =~ ~s(data-testid="start-error")
      assert html =~ "viewers cannot start relays"
      refute html =~ ~s(data-testid="start-result")
    end

    test "a started relay appears in the index", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      # The listing reloads from the controller after the start, so what the
      # index shows is what the controller now holds.
      FakeController.set(node, {Relay, :list}, {:ok, [row("relay_new")]})

      html = render_submit(view, "launcher_submit", %{"start" => start_form(%{})})

      assert html =~ ~s(data-testid="relay-index-row-relay_new")
    end

    test "changing the namespace re-reads that namespace's factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      render_change(view, "launcher_change", %{"start" => start_form(%{"namespace" => "staging"})})

      assert [["default", _], ["staging", _]] = FakeController.calls(node, {Fleet, :factories})
    end

    test "a tick with the form closed reads no factories", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      send(view.pid, :refresh)
      _rendered = render(view)

      assert FakeController.calls(node, {Fleet, :factories}) == []
    end

    test "the screen holds still while the form is open", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/relays")
      render_click(view, "launcher_open", %{})

      FakeController.set(node, {Relay, :list}, {:ok, [row("relay_late")]})
      send(view.pid, :refresh)
      refute render(view) =~ ~s(data-testid="relay-index-row-relay_late")

      render_click(view, "launcher_close", %{})
      send(view.pid, :refresh)
      assert render(view) =~ ~s(data-testid="relay-index-row-relay_late")
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
               ~r/data-testid="lifecycle-what-0"[^>]*>\s*exited on runner runner-a: runner_disconnected/

      assert html =~ ~r/data-testid="lifecycle-what-1"[^>]*>\s*stopped: :stopped/
      assert html =~ ~r/data-testid="lifecycle-what-2"[^>]*>\s*started from orders/
      assert length(FakeController.calls(node, {Relay, :list})) >= reads + 3
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

      assert html =~ "Lifecycle (50)"
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
