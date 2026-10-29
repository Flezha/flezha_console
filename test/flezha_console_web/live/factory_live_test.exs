defmodule FlezhaConsoleWeb.FactoryLiveTest do
  @moduledoc """
  The Factories screens, against a controller whose factory rows, graphs and
  history a test decides.

  The browser suite opens a factory the dev runner announces; the states
  covered here — a saga's compensations, undo_all with nothing to undo,
  runners that report nothing, runners that disagree, a refused history — are
  the ones a live runner will not announce on request.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Fleet
  alias Flezha.Service.Logs
  alias Flezha.Service.Relay

  @page "/namespaces/default/factories/fan_trade"

  defp testid(id), do: ~s([data-testid="#{id}"])

  # Whether the render holds the element named `id`.
  defp shows?(html, id), do: html =~ ~s(data-testid="#{id}")

  # The words of `id` as a reader sees them: a glossary term by its words,
  # without the definition it shows on hover.
  defp words(html, id) do
    doc = LazyHTML.from_document(html)

    tips =
      LazyHTML.query(doc, "#{testid(id)} [role=tooltip], #{testid(id)} [data-fcon-pop-panel]")

    tips
    |> Enum.map(&LazyHTML.text/1)
    |> Enum.reduce(doc |> LazyHTML.query(testid(id)) |> LazyHTML.text(), fn tip, text ->
      String.replace(text, tip, "", global: false)
    end)
    |> String.replace(~r/\s+/, " ")
    |> String.replace(~r/ ([.:,])/, "\\1")
    |> String.trim()
  end

  defp href(html, selector), do: attributes(html, selector, "href")

  defp catalog(node, rows, unreachable \\ []),
    do: FakeController.set(node, {Fleet, :factories}, FakeController.rows(rows, unreachable))

  # `fan_trade`: an entry step reserving funds, a step opening the position
  # and one notifying, the first two compensating as `compensating` says.
  defp saga_graph(compensating) do
    FakeController.graph_answer(
      [
        FakeController.graph_channel("orders", "entry", nil, ["reserve_funds"]),
        FakeController.graph_channel("reserved", "inter_tasklet", "reserve_funds", [
          "open_position"
        ]),
        FakeController.graph_channel("opened", "inter_tasklet", "open_position", ["notify"]),
        FakeController.graph_channel("done", "plugin_bound", "notify", [], "output")
      ],
      factory: "fan_trade",
      compensates: compensating
    )
  end

  defp describe_factory(node, row, graph, opts \\ []),
    do:
      FakeController.set(node, {Fleet, :factory}, FakeController.factory_answer(row, graph, opts))

  defp ended(relay, n) do
    FakeController.history_record(relay, %{
      "event" => "ended",
      "factory" => "fan_trade",
      "outcome" => "completed",
      "duration_ms" => 1_200,
      "ts_us" => 1_793_270_000_000_000 + n
    })
  end

  defp open_page(conn), do: live_loaded(conn, @page)

  describe "the listing" do
    test "an idle factory is listed with its description, its run and its runner", %{
      conn: conn,
      node: node
    } do
      catalog(node, [FakeController.factory_row("fan_trade", %{description: "Fans a trade out"})])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default/factories")
      row = testid("factory-row-fan_trade")

      assert text_of(html, row) =~ "Fans a trade out"
      assert text_of(html, row) =~ "steps: one pass over its first message, then the run ends"
      assert text_of(html, testid("factory-served-fan_trade")) =~ "1 runner on node-a"

      assert href(html, testid("factory-link-fan_trade")) == [
               "/namespaces/default/factories/fan_trade"
             ]

      assert [_namespace] = FakeController.calls(node, {Fleet, :factories})
      assert FakeController.calls(node, {Fleet, :factory}) == []
    end

    test "a factory no runner serves says so", %{conn: conn, node: node} do
      catalog(node, [FakeController.factory_row("fan_trade", %{runners: [], nodes: []})])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default/factories")

      assert text_of(html, testid("factory-unserved-fan_trade")) == "No runner serves it"
    end

    test "every namespace's factories are listed under its name", %{conn: conn, node: node} do
      FakeController.set_fleet(node, rows: %{"default" => [], "second" => []})

      FakeController.set(
        node,
        {Fleet, :factories},
        {:per_arg, 0,
         %{
           "default" => FakeController.rows([FakeController.factory_row("fan_trade")]),
           "second" => FakeController.rows([FakeController.factory_row("ma_fan")])
         }, FakeController.rows([])}
      )

      {_view, html} = live_loaded(conn, ~p"/factories")

      assert text_of(html, testid("factories-default")) =~ "fan_trade"
      refute text_of(html, testid("factories-default")) =~ "ma_fan"
      assert text_of(html, testid("factories-second")) =~ "ma_fan"

      assert href(html, testid("factory-link-ma_fan")) == [
               "/namespaces/second/factories/ma_fan"
             ]
    end

    test "a namespace with no factory says where they come from", %{conn: conn} do
      {_view, html} = live_loaded(conn, ~p"/namespaces/default/factories")

      assert text_of(html, testid("factories-empty")) ==
               "Factories appear here when a runner announces them."
    end

    test "a partial catalog is said once, naming the missing controller", %{
      conn: conn,
      node: node
    } do
      catalog(node, [FakeController.factory_row("fan_trade")], ["flezha@c9"])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default/factories")

      assert text_of(html, testid("partial-answer")) =~ "flezha@c9 did not"
      assert text_of(html, testid("factory-row-fan_trade")) =~ "fan_trade"
    end
  end

  describe "how a factory runs" do
    test "a steps factory that undoes its work says so in one sentence", %{
      conn: conn,
      node: node
    } do
      describe_factory(node, FakeController.factory_row("fan_trade"), saga_graph(%{}))

      {_view, html} = open_page(conn)

      assert words(html, "factory-run") ==
               "Each pass works through its steps in order, committing each one: one pass " <>
                 "over its first message, then the run ends. A failed run undoes every " <>
                 "finished step by its compensation."

      for term <- ~w(run each on_failure), do: assert(shows?(html, "term-#{term}"))
    end

    test "a flow factory says nothing of each or on_failure, nor of compensation", %{
      conn: conn,
      node: node
    } do
      row =
        FakeController.factory_row("fan_trade", %{run: :flow, each: nil, on_failure: nil})

      describe_factory(node, row, saga_graph(%{}))

      {_view, html} = open_page(conn)

      assert words(html, "factory-run") ==
               "Records stream through its tasklets for as long as it runs."

      refute shows?(html, "term-each")
      refute shows?(html, "factory-compensation")
    end

    test "the crumbs name the namespace, Factories and the factory", %{conn: conn} do
      {_view, html} = open_page(conn)

      assert text_of(html, ~s([data-testid="breadcrumb"] [aria-current="page"])) == "fan_trade"

      assert href(html, ~s([data-testid="breadcrumb"] a)) == [
               "/namespaces/default",
               "/namespaces/default/factories"
             ]
    end

    test "an unknown factory is not found, with the way back to the listing", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Fleet, :factory},
        FakeController.error("relay.factory_unknown", "no runner serves factory 'fan_trade'")
      )

      {_view, html} = open_page(conn)

      assert text_of(html, testid("factory-not-found")) =~ "announces the factory fan_trade"

      assert href(html, testid("factory-not-found-back")) == [
               "/namespaces/default/factories"
             ]

      refute shows?(html, "topology-graph")
    end

    test "runners that disagree are said once, above the page", %{conn: conn, node: node} do
      describe_factory(node, FakeController.factory_row("fan_trade"), saga_graph(%{}),
        disagree: true
      )

      {_view, html} = open_page(conn)

      assert text_of(html, testid("factory-disagree")) =~ "the newest announcement is shown"
      refute shows?(html, "topology-inside-disagree")
    end
  end

  describe "what a factory declares" do
    test "a durable factory that keeps no finished state", %{conn: conn, node: node} do
      row =
        FakeController.factory_row("fan_trade", %{
          declarations: FakeController.declarations(%{durable: :local, max_duration_ms: 600_000})
        })

      describe_factory(node, row, saga_graph(%{}))

      {_view, html} = open_page(conn)

      assert words(html, "declaration-durable") ==
               "It keeps state on its controller's disk."

      assert words(html, "declaration-max_duration_ms") ==
               "It cancels a run 10m 0s after it first starts."

      assert words(html, "declaration-keep_finished") ==
               "It does not keep a finished run's state."

      refute shows?(html, "declaration-ack")
    end

    test "a flow factory's own declarations, each with its term", %{conn: conn, node: node} do
      row =
        FakeController.factory_row("fan_trade", %{
          run: :flow,
          each: nil,
          on_failure: nil,
          declarations:
            FakeController.declarations(%{
              durable: :memory,
              sleep_after_ms: nil,
              effectively_once: true,
              ack: :checkpoint,
              keyed: false,
              keep_finished: 24
            })
        })

      describe_factory(node, row, saga_graph(%{}))

      {_view, html} = open_page(conn)

      assert words(html, "factory-declarations") ==
               "It keeps state in memory only, so a crash starts it over. " <>
                 "It delivers each output effectively once. " <>
                 "It acknowledges its input at checkpoints. It cannot be partitioned. " <>
                 "It keeps a finished run's state for 24 hours."

      assert shows?(html, "term-partition group")
      assert shows?(html, "term-keep_finished")
    end

    test "runners that describe nothing still show the run and the graph", %{
      conn: conn,
      node: node
    } do
      describe_factory(
        node,
        FakeController.factory_row("fan_trade", %{declarations: nil}),
        saga_graph(%{})
      )

      {_view, html} = open_page(conn)

      assert text_of(html, testid("factory-no-declarations")) ==
               "Its runners do not describe its settings."

      assert shows?(html, "factory-run")
      assert shows?(html, "topo-node-tasklet-reserve_funds")
    end
  end

  describe "whether a factory can undo a failed run" do
    test "names the tasklets that compensate, and marks them on the graph", %{
      conn: conn,
      node: node
    } do
      graph = saga_graph(%{"open_position" => true, "reserve_funds" => true})
      describe_factory(node, FakeController.factory_row("fan_trade"), graph)

      {_view, html} = open_page(conn)

      assert words(html, "factory-compensation") =~ "It supports compensation"
      assert words(html, "factory-compensation") =~ "reserve_funds and open_position"
      assert shows?(html, "topo-mark-tasklet-open_position")
      assert shows?(html, "topology-legend-compensates")
      refute shows?(html, "factory-undo-warning")
    end

    test "undo_all with nothing to undo is a warning", %{conn: conn, node: node} do
      describe_factory(node, FakeController.factory_row("fan_trade"), saga_graph(%{}))

      {_view, html} = open_page(conn)

      assert words(html, "factory-compensation") =~ "No tasklet of it declares"

      assert text_of(html, testid("factory-undo-warning")) =~
               "A failed run cannot undo the work of its completed steps"
    end

    test "keep_progress with nothing to undo is no warning", %{conn: conn, node: node} do
      row = FakeController.factory_row("fan_trade", %{on_failure: :keep_progress})
      describe_factory(node, row, saga_graph(%{}))

      {_view, html} = open_page(conn)

      refute shows?(html, "factory-undo-warning")
    end

    test "runners that do not report compensation are not read as none", %{
      conn: conn,
      node: node
    } do
      graph = saga_graph(%{})

      graph =
        put_in(graph.graph.tasklets, Enum.map(graph.graph.tasklets, &%{&1 | compensates: nil}))

      describe_factory(node, FakeController.factory_row("fan_trade"), graph)

      {_view, html} = open_page(conn)

      assert words(html, "factory-compensation") ==
               "Its runners do not report compensation."

      refute shows?(html, "factory-undo-warning")
    end
  end

  describe "the graph and the API" do
    test "an idle factory's graph is drawn still, with no live read", %{
      conn: conn,
      node: node
    } do
      describe_factory(node, FakeController.factory_row("fan_trade"), saga_graph(%{}))

      {view, html} = open_page(conn)

      assert shows?(html, "topo-node-entry-orders")
      assert shows?(html, "topo-node-exit-done")
      refute shows?(html, "topology-state")

      view |> element(~s([data-testid="topo-node-tasklet-reserve_funds"])) |> render_click()
      html = view |> element(~s([data-testid="topo-node-entry-orders"])) |> render_click()
      tick(view)

      assert text_of(html, testid("topology-detail")) =~ "entry channel"

      for call <- [{Relay, :activity}, {Relay, :graph}, {Relay, :listen}],
          do: assert(FakeController.calls(node, call) == [], "#{inspect(call)} was called")
    end

    test "a factory whose runners announce no graph says so, and the rest renders", %{
      conn: conn,
      node: node
    } do
      describe_factory(node, FakeController.factory_row("fan_trade"), nil)

      {_view, html} = open_page(conn)

      assert text_of(html, testid("topology-inside-note")) =~
               "Its graph is not shown: the runners of factory fan_trade announced no graph."

      assert shows?(html, "factory-run")
      assert shows?(html, "factory-runs")
    end

    test "lists its entry API with the relay screen's rendering", %{conn: conn, node: node} do
      channel = %{
        channel: "orders",
        codec: "json",
        schema: %{"type" => "object"},
        description: "One order",
        answer_codec: nil,
        answer_schema: nil
      }

      describe_factory(
        node,
        FakeController.factory_row("fan_trade", %{api: [channel]}),
        saga_graph(%{})
      )

      {_view, html} = open_page(conn)

      assert text_of(html, testid("api-channel-orders")) =~ "One order"
      assert shows?(html, "api-schema-orders")
    end

    test "the graph is read again when a runner of the namespace comes or goes", %{
      conn: conn,
      node: node
    } do
      {view, _html} = open_page(conn)
      tick(view)
      assert [_once] = FakeController.calls(node, {Fleet, :factory})

      send(view.pid, {:flezha_event, :runner_connected, {"default", "runner-b"}})

      assert PeerNode.eventually(fn ->
               length(FakeController.calls(node, {Fleet, :factory})) == 2
             end)
    end
  end

  describe "the last runs" do
    test "show the 10 newest, each linking to its history, and all of them", %{
      conn: conn,
      node: node
    } do
      records = for n <- 14..1//-1, do: ended("run_#{n}", n)
      FakeController.set(node, {Logs, :read}, FakeController.log_page(records))

      {_view, html} = open_page(conn)

      assert length(testids(html, ~s(tr[data-testid^="factory-run-run_"]))) == 10
      assert text_of(html, testid("factory-run-run_14")) =~ "run_14 finished: completed"

      assert href(html, testid("factory-run-link-run_14")) == [
               "/logs/relay_history?namespace=default&relay=run_14"
             ]

      assert href(html, testid("factory-runs-all")) == [
               "/logs/relay_history?namespace=default&factory=fan_trade"
             ]

      assert [[params, _ctx] | _] = FakeController.calls(node, {Logs, :read})

      assert Keyword.take(params, [:kind, :filters, :limit]) == [
               kind: "relay_history",
               filters: %{"namespace" => "default", "factory" => "fan_trade", "event" => "ended"},
               limit: 10
             ]
    end

    test "a factory that never ran says runs appear when one ends", %{conn: conn} do
      {_view, html} = open_page(conn)

      assert text_of(html, testid("factory-runs-empty")) == "Runs appear here when one ends."
    end

    test "a refused history is said in the list, and the page still renders", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Logs, :read},
        FakeController.error("logs.kind_disabled", "the relay history is off")
      )

      {_view, html} = open_page(conn)

      assert text_of(html, testid("factory-runs")) =~ "the relay history is off"
      assert shows?(html, "factory-run")
      assert shows?(html, "topology-graph")
    end
  end

  describe "the way to a factory" do
    test "the rail's Factories entry is current on a factory's page", %{conn: conn} do
      {_view, html} = open_page(conn)

      assert href(html, ~s(.flz-sidebar-nav [aria-current="page"])) == [
               "/namespaces/default/factories"
             ]
    end

    test "the relay screen links its factory", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :overwatch_state}, {:ok, %{factory_id: "fan_trade"}})

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays/relay_a")

      assert {:error, {:live_redirect, %{to: @page}}} =
               view |> element(~s([data-testid="relay-factory"] a)) |> render_click()
    end

    test "the launcher offers the chosen factory's page", %{conn: conn, node: node} do
      FakeController.set_fleet(node, rows: %{"default" => []})
      catalog(node, [FakeController.factory_row("fan_trade")])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default/relays")
      render_async(view)
      view |> element(~s([data-testid="start-relay-btn"])) |> render_click()
      html = view |> element(~s([data-testid="factory-choice-fan_trade"])) |> render_click()

      assert href(html, testid("factory-how-it-works")) == [@page]
    end

    test "the Cluster screen's factory lookup links the factory", %{conn: conn, node: node} do
      FakeController.set_fleet(node, rows: %{"default" => []})
      catalog(node, [FakeController.factory_row("fan_trade")])

      {:ok, view, _html} = live(conn, ~p"/cluster")
      html = view |> element(~s([data-testid="factory-fan_trade"])) |> render_click()

      assert href(html, testid("factory-page-link")) == [@page]
    end

    test "the command palette reaches a factory by its id", %{conn: conn, node: node} do
      FakeController.set_fleet(node, rows: %{"default" => []})
      catalog(node, [FakeController.factory_row("fan_trade")])

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      view |> element("#command-palette") |> render_hook("open", %{})

      html =
        view
        |> element(~s([data-testid="command-palette-search"]))
        |> render_change(%{"q" => "fan_tr"})

      assert href(html, testid("command-palette-factory-fan_trade")) == [@page]
    end
  end
end
