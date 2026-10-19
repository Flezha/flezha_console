defmodule FlezhaUiWeb.ClusterLiveTest do
  @moduledoc """
  The cluster and fleet screen, against a controller whose fleet can be emptied.

  The browser suite asserts the healthy shape — nodes, hubs, runners with
  factories — because the dev stack guarantees a connected runner. What it
  cannot produce is the interesting half: a factory no runner serves, a
  namespace with no hub, a controller that cannot answer at all.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Fleet
  alias Flezha.Service.Relay

  defp one_namespace(node, opts) do
    FakeController.set(
      node,
      {Relay, :list_namespaces},
      {:ok, [%{namespace: "default", running: true}]}
    )

    FakeController.set(node, {Relay, :relay_rows}, {:ok, opts[:rows] || []})
    FakeController.set(node, {Fleet, :factories}, {:ok, opts[:factories] || []})
    FakeController.set(node, {Fleet, :runners}, {:ok, opts[:runners] || []})

    FakeController.set(
      node,
      {Controller, :cluster_status},
      opts[:status] || {:ok, status(opts[:hub_nodes] || [])}
    )
  end

  # The cluster as the namespace sees it: its hub nodes with their recovery
  # state, as `Controller.cluster_status/2` answers it.
  defp status(nodes) do
    %{
      namespace: "default",
      nodes:
        Enum.map(nodes, fn
          {node, recovery} -> %{node: node, relay_count: 0, recovery_state: recovery}
          node -> %{node: node, relay_count: 0, recovery_state: :normal}
        end),
      unplaced_relays: 0,
      relay_health: %{}
    }
  end

  defp factory(id, runners \\ []), do: %{id: id, description: nil, run: :flow, runners: runners}

  describe "cluster membership" do
    test "marks the node this UI is connected to", %{conn: conn, node: node} do
      one_namespace(node, [])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ "Connected to this console"
      assert html =~ to_string(node)
    end

    test "lists every hub node the controller reports, unioned across namespaces", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, hub_nodes: [:"flezha@node-a", :"flezha@node-b"])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="cluster-node-flezha@node-a")
      assert html =~ ~s(data-testid="cluster-node-flezha@node-b")
      assert html =~ ~s(data-testid="cluster-node-#{node}")
      # Membership comes from the controller's answer, never `:erlang.nodes/1`.
      refute html =~ ~s(data-testid="cluster-node-#{Node.self()}")
    end
  end

  describe "namespaces and their fleets" do
    test "renders hub placement and the runners serving a namespace", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [factory("store_input", ["runner-a"])],
        hub_nodes: [:"flezha@hub-1"],
        runners: [%{id: "runner-a"}]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ "flezha@hub-1"
      assert html =~ "runner-a"
      assert html =~ "store_input"
    end

    test "runners are read cluster-wide, not from the node this UI reached", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, runners: [%{id: "runner-on-peer"}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ "runner-on-peer"
      assert FakeController.calls(node, {Fleet, :runners}) != []
    end

    test "each runner is credited with the factories it serves", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [
          factory("store_input", ["runner-a", "runner-b"]),
          factory("compare_filter", ["runner-b"])
        ],
        runners: [%{id: "runner-a"}, %{id: "runner-b"}]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      runner_a =
        text_of(html, ~s([data-testid="runners-default"] [data-testid="runner-runner-a"]))

      runner_b =
        text_of(html, ~s([data-testid="runners-default"] [data-testid="runner-runner-b"]))

      assert runner_a =~ "store_input"
      refute runner_a =~ "compare_filter"
      assert runner_b =~ "compare_filter"
      assert runner_b =~ "store_input"
    end

    test "each factory states its run", %{conn: conn, node: node} do
      one_namespace(node,
        factories: [
          factory("store_input"),
          %{id: "chat_loop_steps", description: nil, run: :steps}
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")

      assert view |> element(~s([data-testid="factory-chat_loop_steps"])) |> render() =~ "steps"
      assert view |> element(~s([data-testid="factory-store_input"])) |> render() =~ "flow"
    end

    test "a refused hub read is stated and the rest still renders", %{conn: conn, node: node} do
      one_namespace(node,
        runners: [%{id: "runner-a"}],
        status: FakeController.error("authz.role_insufficient")
      )

      {:ok, view, html} = live(conn, ~p"/cluster")

      assert view |> element(~s([data-testid="hub-nodes-default"])) |> render() =~
               "authz.role_insufficient"

      assert html =~ "runner-a"
    end
  end

  describe "factory placement lookup" do
    setup %{node: node} do
      one_namespace(node,
        factories: [factory("store_input")],
        runners: [%{id: "runner-a"}]
      )

      :ok
    end

    test "names the runners serving the factory", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok, [factory("store_input", ["runner-a", "runner-b"])]}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        view |> element(~s([data-testid="factory-store_input"])) |> render_click()

      assert html =~ ~s(data-testid="factory-runners")
      assert html =~ "is served by"
      assert html =~ "runner-b"
    end

    test "says so when no runner serves the factory", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        view |> element(~s([data-testid="factory-store_input"])) |> render_click()

      assert html =~ ~s(data-testid="factory-runners-empty")
    end

    test "selecting a factory is a lookup, not another controller read", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/cluster")
      before = length(FakeController.calls(node, {Fleet, :factories}))

      view |> element(~s([data-testid="factory-store_input"])) |> render_click()

      assert length(FakeController.calls(node, {Fleet, :factories})) == before
    end

    test "a refresh reads the factories and their runners once, never per factory",
         %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Fleet, :factories},
        {:ok, [factory("store_input", ["runner-a"]), factory("compare_filter", ["runner-a"])]}
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")
      before = length(FakeController.calls(node, {Fleet, :factories}))

      send(view.pid, :refresh)
      _ = render(view)

      assert length(FakeController.calls(node, {Fleet, :factories})) == before + 1
      assert FakeController.calls(node, {Fleet, :runners_for_factory}) == []
    end

    test "clearing the selection removes the result", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cluster")

      view |> element(~s([data-testid="factory-store_input"])) |> render_click()

      html = view |> element(~s([data-testid="clear-factory"])) |> render_click()

      refute html =~ ~s(data-testid="factory-runners")
    end
  end

  describe "runner events" do
    test "a runner connecting refreshes the fleet without waiting for the timer", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, runners: [])

      {:ok, view, html} = live(conn, ~p"/cluster")
      refute html =~ "runner-late"

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-late"}]})
      send(view.pid, {:flezha_event, :runner_connected, {"default", "runner-late"}})

      assert render(view) =~ "runner-late"
    end
  end

  describe "per-node rollup" do
    defp row(id, overrides \\ %{}), do: FakeController.relay_row(id, overrides)

    test "each node shows its relay count broken down by health", %{conn: conn, node: node} do
      one_namespace(node,
        rows: [row("a"), row("b", %{health: :degraded}), row("c", %{node: :"flezha@node-b"})],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-rollup-default")
      assert html =~ ~s(data-testid="node-count-flezha@node-a")
      assert html =~ ~s(data-health="degraded")
    end

    test "relays moving off a dead runner are counted under their own verdicts", %{
      conn: conn,
      node: node
    } do
      one_namespace(node,
        rows: [row("a", %{health: :recovering}), row("b", %{health: :halted})],
        hub_nodes: [:"flezha@node-a"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-health="recovering")
      assert html =~ ~s(data-health="halted")
      refute html =~ ~s(data-health="unknown")
    end

    test "a split view makes the disagreement visible", %{conn: conn, node: node} do
      one_namespace(node,
        rows: [row("a"), row("b")],
        hub_nodes: [:"flezha@node-a", :"flezha@node-b"]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-flezha@node-a")
      refute html =~ ~s(data-testid="node-flezha@node-b")
    end

    test "relays with no live node are named", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("stranded", %{node: nil})])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="unplaced-default")
      assert html =~ "stranded"
    end

    test "a hub mid-recovery is distinguishable from one serving", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], hub_nodes: [{:"flezha@node-a", :replaying}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~r/data-testid="recovery-flezha@node-a"[^>]*>\s*Replaying/
      refute html =~ ~r/data-testid="recovery-flezha@node-a"[^>]*>\s*Serving/
    end

    test "an unreachable node's recovery is stated, and the rest still renders", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, rows: [row("a")], hub_nodes: [{:"flezha@node-a", :unreachable}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="recovery-unavailable-flezha@node-a")
      assert html =~ ~s(data-testid="node-rollup-default")
    end

    test "each namespace's runner principal is shown", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], runners: [%{id: "runner-a"}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="runner-principal-default")
      assert html =~ "runner@default"
    end

    test "the column is absent when the controller does not say", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], runners: [%{id: "runner-a"}])

      FakeController.set(
        node,
        {Fleet, :runner_caller_context},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      refute html =~ ~s(data-testid="runner-principal-default")
      assert html =~ ~s(data-testid="node-rollup-default")
    end
  end

  describe "the runner table" do
    defp runner(id, overrides \\ %{}), do: FakeController.runner_row(id, overrides)
    defp now, do: System.system_time(:second)
    defp listed(html), do: testids(html, ~s([data-testid="runners-default"] tbody tr))

    test "each runner states its node, connection, last contact and relays",
         %{conn: conn, node: node} do
      one_namespace(node,
        runners: [runner("runner-a"), runner("runner-b", %{silent_ms: 40_000, late?: true})],
        rows: [row("a", %{runner: "runner-a"}), row("b", %{runner: "runner-a"})]
      )

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert text_of(html, ~s([data-testid="runner-node-of-runner-a"])) =~ "flezha@node-a"
      assert text_of(html, ~s([data-testid="runner-connected-runner-a"])) =~ "2h 0m ago"
      assert text_of(html, ~s([data-testid="runner-contact-runner-a"])) =~ "3 s ago"
      assert html =~ ~r/data-testid="runner-contact-runner-b"[^>]*data-late="true"/

      assert html =~
               ~r{href="/namespaces/default/relays\?runner=runner-a"[^>]*data-testid="runner-relays-runner-a"[^>]*>\s*2}

      # Late first, and counted in the summary.
      assert ["runner-runner-b" | _] = listed(html)
      assert text_of(html, ~s([data-testid="runners-summary-default"])) =~ "2 connected"
      assert text_of(html, ~s([data-testid="runners-summary-default"])) =~ "1 late"
    end

    test "a row the controller answers without connection facts shows placeholders",
         %{conn: conn, node: node} do
      one_namespace(node, runners: [%{id: "runner-old"}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert text_of(html, ~s([data-testid="runner-node-of-runner-old"])) == "—"
      assert text_of(html, ~s([data-testid="runner-connected-runner-old"])) == "—"
      assert text_of(html, ~s([data-testid="runner-contact-runner-old"])) == "—"
      refute html =~ "os-pid-"
    end

    test "Serves shows two factories, the rest behind a count, and who shares the set",
         %{conn: conn, node: node} do
      shared = ~w(alpha beta gamma delta)

      one_namespace(node,
        factories: Enum.map(shared, &factory(&1, ["runner-a", "runner-b"])),
        runners: [runner("runner-a"), runner("runner-b")]
      )

      {:ok, view, html} = live(conn, ~p"/cluster")

      assert text_of(html, ~s([data-testid="serves-more-runner-a"])) =~ "+2 more"
      assert text_of(html, ~s([data-testid="same-set-runner-a"])) =~ "same 4 as 1 other runner"

      # The rest is in the page, shown by the control without a server round trip.
      assert view |> element(~s([data-testid="serves-more-runner-a"])) |> render() =~
               "serves-rest-default-runner-a"
    end

    test "the filter, node, late-only and sort narrow and order the table",
         %{conn: conn, node: node} do
      one_namespace(node,
        factories: [factory("orders", ["runner-a"]), factory("prices", ["runner-b"])],
        runners: [
          runner("runner-a", %{connected_at: now() - 60}),
          runner("runner-b", %{node: :"flezha@node-b", connected_at: now() - 3_600}),
          runner("runner-c", %{node: :"flezha@node-b", silent_ms: 50_000, late?: true})
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/cluster")

      html =
        view
        |> element(~s([data-testid="runner-view-default"]))
        |> render_change(%{namespace: "default", view: %{q: "orders"}})

      assert listed(html) == ["runner-runner-a"]
      # The summary still counts the whole fleet.
      assert text_of(html, ~s([data-testid="runners-summary-default"])) =~ "3 connected"

      html =
        view
        |> element(~s([data-testid="runner-view-default"]))
        |> render_change(%{namespace: "default", view: %{q: "", node: "flezha@node-b"}})

      assert Enum.sort(listed(html)) == ["runner-runner-b", "runner-runner-c"]

      html =
        view
        |> element(~s([data-testid="runner-view-default"]))
        |> render_change(%{namespace: "default", view: %{q: "", node: "", late: "true"}})

      assert listed(html) == ["runner-runner-c"]

      html =
        view
        |> element(~s([data-testid="runner-view-default"]))
        |> render_change(%{namespace: "default", view: %{late: "false", sort: "newest"}})

      assert listed(html) == ["runner-runner-a", "runner-runner-b", "runner-runner-c"]

      html =
        view
        |> element(~s([data-testid="runner-view-default"]))
        |> render_change(%{namespace: "default", view: %{q: "nothing-like-it"}})

      assert html =~ ~s(data-testid="runners-none-match-default")
    end
  end

  describe "hub recovery" do
    test "a serving hub is not announced", %{conn: conn, node: node} do
      one_namespace(node, rows: [row("a")], hub_nodes: [:"flezha@node-a"])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="node-flezha@node-a")
      refute html =~ ~s(data-testid="hub-not-serving-)
    end

    test "a hub mid-recovery is announced, saying nothing needs doing", %{
      conn: conn,
      node: node
    } do
      one_namespace(node, rows: [row("a")], hub_nodes: [{:"flezha@node-a", :recovering}])

      {:ok, _view, html} = live(conn, ~p"/cluster")

      assert html =~ ~s(data-testid="hub-not-serving-flezha@node-a")
      assert html =~ "recovering"
      assert html =~ "needs doing"
    end
  end
end
