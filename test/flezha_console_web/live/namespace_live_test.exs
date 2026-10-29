defmodule FlezhaConsoleWeb.NamespaceLiveTest do
  @moduledoc """
  The namespace index and show screens.

  The browser suite drives the happy path against the seeded `default`
  namespace. Covered here instead: an empty controller, a controller that
  refuses, and the start form's validation branches — which the browser cannot
  reach without leaving half-started relays behind.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Fleet
  alias Flezha.Service.Logs
  alias Flezha.Service.Namespace
  alias Flezha.Service.Relay

  # A namespace's relays, as every listing reads them. An id alone is the
  # ordinary case; a map is a row a test wants to say more about.
  defp with_relays(node, relays, opts \\ []) do
    rows = Enum.map(relays, &row/1)
    FakeController.set_fleet(node, Keyword.merge([rows: %{"default" => rows}], opts))
    rows
  end

  defp row(%{} = row), do: FakeController.relay_row(row[:id] || "relay", row)
  defp row(id), do: FakeController.relay_row(id)

  describe "the index" do
    test "counts each namespace's relays and runners", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "default", running: true}])
      )

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("a"), FakeController.relay_row("b")])
      )

      FakeController.set(node, {Fleet, :runners}, {:ok, [%{id: "runner-a", pid: nil}]})

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      assert text_of(html, ~s([data-testid="namespace-relays-default"])) == "2 relays"
      assert text_of(html, ~s([data-testid="namespace-runners-default"])) == "1 runner"
    end

    test "a namespace whose relays cannot be counted still lists", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([
          %{namespace: "default", running: true},
          %{namespace: "staging", running: true}
        ])
      )

      FakeController.set(
        node,
        {Relay, :list},
        {:per_arg, 0, %{"default" => FakeController.error("controller.timeout")},
         FakeController.rows([FakeController.relay_row("a")])}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces")

      # One failing count must not take the whole page down with it.
      assert text_of(html, ~s([data-testid="namespace-relays-default"])) == "0 relays"
      assert text_of(html, ~s([data-testid="namespace-relays-staging"])) == "1 relay"
    end
  end

  describe "the show page" do
    test "counts the relays running in the namespace", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])

      {_view, html} = live_loaded(conn, ~p"/namespaces/default")

      assert text_of(html, ~s([data-testid="ns-relays-value"])) == "2"
    end
  end

  describe "relay health" do
    test "the inspector places the relay on the node its row names", %{conn: conn, node: node} do
      with_relays(node, [%{id: "relay_a", node: :"flezha@node-b"}])

      {_view, html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      assert text_of(html, ~s([data-testid="inspector-relay"])) =~ "flezha@node-b"
    end

    test "a listing tick costs the same whether the namespace holds two or fifty", %{
      conn: conn,
      node: node
    } do
      with_relays(node, ["relay_a", "relay_b"])
      {_view, _html} = live_loaded(conn, ~p"/namespaces/default")
      small = length(FakeController.calls(node, {Relay, :list}))

      FakeController.reset(node)
      with_relays(node, Enum.map(1..50, &"relay_#{&1}"))
      {_view, _html} = live_loaded(conn, ~p"/namespaces/default")
      large = length(FakeController.calls(node, {Relay, :list}))

      assert small == large
      # And nothing was asked per relay.
      assert FakeController.calls(node, {Relay, :overwatch_state}) == []
    end
  end

  describe "partition groups" do
    defp members do
      [
        FakeController.relay_row("orders_p0", %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        }),
        FakeController.relay_row("orders_p1", %{
          health: :degraded,
          partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}
        })
      ]
    end

    # The group as the controller lists it: one row as sick as its sickest
    # member, its coverage stated by the namespace's summary.
    defp with_group(node, complete? \\ true) do
      group =
        Map.merge(FakeController.relay_row("orders"), %{
          health: :degraded,
          partitions: "2/2",
          members: members()
        })

      FakeController.set_fleet(node, rows: %{"default" => [group]})

      FakeController.set(
        node,
        {Relay, :list},
        {:ok,
         %{
           rows: [Map.merge(group, %{run: :flow, plugins: 0})],
           total: 1,
           next: nil,
           unreachable: [],
           summary: %{
             health: %{degraded: 1},
             waiting: [],
             faulted_groups:
               if(complete?,
                 do: [],
                 else: [%{group: "orders", health: :degraded, complete: false}]
               )
           }
         }}
      )
    end

    # The groups are read when their section opens, in the background.
    defp open_groups(view) do
      open_section(view, "partition-groups")
      render_async(view)
    end

    test "a complete group shows its member count and is not faulted", %{conn: conn, node: node} do
      with_group(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html = open_groups(view)

      assert html =~ ~s(data-testid="partition-group-orders")
      assert html =~ ~s(data-testid="group-members-orders")
      assert html =~ "2/2"
      refute html =~ ~s(data-testid="group-faulted-orders")
    end

    test "the group reports its sickest member's health", %{conn: conn, node: node} do
      with_group(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert open_groups(view) =~ ~s(data-health="degraded")
    end

    test "members are listed with partition index, key range and health", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      html = open_groups(view)

      assert html =~ "p0"
      assert html =~ "p1"
      assert html =~ "0–127"
      assert html =~ "128–255"
      assert html =~ "orders_p0"
    end

    test "broken coverage is a fault, stated while the section is folded too", %{
      conn: conn,
      node: node
    } do
      with_group(node, false)

      {view, html} = live_loaded(conn, ~p"/namespaces/default")
      assert html =~ "1 with broken coverage"

      html = open_groups(view)

      assert html =~ ~s(data-testid="group-faulted-orders")
      assert html =~ ~s(data-testid="group-coverage-orders")
      assert html =~ "owned by no member or by more than one"
    end

    test "a cancelled rescale target is dropped, and one below one is not taken", %{
      conn: conn,
      node: node
    } do
      with_group(node)

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      open_groups(view)

      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      rescale_target(view, "3")
      view |> element(~s([data-testid="rescale-cancel-btn"])) |> render_click()

      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      rescale_target(view, "0")
      view |> element(~s([data-testid="rescale-confirm-btn"])) |> render_click()

      assert [["default", "orders", 2, [], %{source: :ui}]] =
               FakeController.calls(node, {Flezha.Service.Steps, :rescale})
    end

    defp rescale_target(view, target) do
      view
      |> form(~s(form[phx-change="select_rescale"]), rescale: %{target: target})
      |> render_change()
    end

    test "a namespace with no groups says so when the section opens", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert open_groups(view) =~ ~s(data-testid="partition-groups-none")
    end
  end

  describe "recent runs" do
    defp ended(relay, outcome),
      do: FakeController.history_record(relay, %{"event" => "ended", "outcome" => outcome})

    defp runs_reads(node) do
      for [params, _ctx] <- FakeController.calls(node, {Logs, :read}),
          params[:kind] == "relay_history",
          do: params
    end

    defp open_runs(view) do
      open_section(view, "recent-runs")
      render_async(view)
    end

    test "lists the namespace's ended runs newest first and counts those that did not complete",
         %{conn: conn, node: node} do
      with_relays(node, [])

      FakeController.set(
        node,
        {Logs, :read},
        FakeController.log_page([
          ended("run_c", "completed"),
          ended("run_b", "undone"),
          ended("run_a", "completed")
        ])
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_runs(view)

      positions =
        for id <- ~w(run_c run_b run_a) do
          {index, _} = :binary.match(html, ~s(data-testid="run-row-#{id}"))
          index
        end

      assert positions == Enum.sort(positions)
      assert text_of(html, ~s([data-testid="run-row-run_b"])) =~ "run_b finished: undone"

      assert text_of(html, ~s([data-testid="recent-runs-not-completed"])) =~
               "1 did not complete"

      assert [params | _] = runs_reads(node)
      assert params[:filters] == %{"namespace" => "default", "event" => "ended"}
      assert params[:limit] == 20
    end

    test "grows by the history's cursor, appending the older runs", %{conn: conn, node: node} do
      with_relays(node, [])
      newest = for i <- 1..20, do: ended("new_#{i}", "completed")
      # Older than every run of the first page, as the cursor reads them.
      older =
        for i <- 1..3,
            do: "old_#{i}" |> ended("failed") |> Map.put("ts_us", 1_000_000 - i)

      FakeController.set(
        node,
        {Logs, :read},
        {:per_arg, {0, :before}, %{"c1" => FakeController.log_page(older)},
         FakeController.log_page(newest, "c1")}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_runs(view)

      refute html =~ ~s(data-testid="recent-runs-not-completed")

      assert text_of(html, ~s([data-testid="recent-runs-more"])) ==
               "Show older runs · 20 shown"

      view |> element(~s([data-testid="recent-runs-more"])) |> render_click()
      html = render_async(view)

      assert html =~ ~s(data-testid="run-row-new_20")
      assert html =~ ~s(data-testid="run-row-old_3")
      assert Enum.any?(runs_reads(node), &(&1[:before] == "c1"))
      assert text_of(html, ~s([data-testid="recent-runs-not-completed"])) =~ "3 did not complete"
      # The history holds nothing older, so the listing cannot grow on.
      refute html =~ ~s(data-testid="recent-runs-more")
    end

    test "says where runs come from when none has ended", %{conn: conn, node: node} do
      with_relays(node, [])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert open_runs(view) =~ "Runs appear here when a relay of this namespace finishes."
    end

    test "a refused read is stated, not shown as empty", %{conn: conn, node: node} do
      with_relays(node, [])
      FakeController.set(node, {Logs, :read}, FakeController.error("authz.role_insufficient"))

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      html = open_runs(view)

      assert html =~ "authz.role_insufficient"
      refute html =~ "Runs appear here"
    end

    test "are read on the first read, then only while the section is open", %{
      conn: conn,
      node: node
    } do
      with_relays(node, [])

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      assert length(runs_reads(node)) == 1

      send(view.pid, :refresh)
      render_async(view)
      assert length(runs_reads(node)) == 1

      open_runs(view)
      assert length(runs_reads(node)) == 2
    end
  end

  describe "stopping a relay" do
    setup %{node: node} do
      with_relays(node, ["relay_a"])
      :ok
    end

    # The relay's inspector, opened from a shared link, asks before Stop.
    defp stop(view) do
      view |> element(~s([data-testid="inspector-stop"])) |> render_click()
      view |> element(~s([data-testid="stop-confirm-btn"])) |> render_click()
    end

    test "confirming reaches the controller", %{conn: conn, node: node} do
      {view, _html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      stop(view)

      assert [["default", "relay_a", %{source: :ui}]] = FakeController.calls(node, {Relay, :stop})
    end

    test "a cooperative stop says the relay finishes its work first", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, {:ok, %{id: "relay_a", stopped: :cooperative}})

      {view, _html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      assert stop(view) =~ "finishes its in-flight work"
    end

    test "surfaces a refused stop", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :stop}, FakeController.error("relay.not_found"))

      {view, _html} = live_loaded(conn, "/namespaces/default?inspect=relay:relay_a")

      assert stop(view) =~ "relay.not_found (test)"
    end
  end

  # Home reads in a task. A gated tokens read, which only Home makes, holds
  # that task for as long as a test says; the relay count tells reads apart.
  describe "background reads" do
    defp hold_reads(node) do
      FakeController.close_gate(node, :home)
      FakeController.set(node, {Namespace, :tokens}, {:gated, :home, {:ok, []}})
    end

    defp reads(node), do: length(FakeController.calls(node, {Namespace, :tokens}))

    defp relays_shown(view),
      do: text_of(render(view), ~s([data-testid="ns-relays-value"]))

    test "the screen answers before its first read does", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      hold_reads(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert text_of(render(view), ~s([data-testid="home-headline"])) == "Reading default…"
      html = open_section(view, "quotas")
      assert html =~ ~s(data-testid="section-body-quotas")
      assert html =~ ~s(data-testid="home-namespace-loading")

      FakeController.open_gate(node, :home)
      render_async(view)

      assert relays_shown(view) == "2"
    end

    test "ticks during a read start no second read", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = reads(node)
      hold_reads(node)

      for _tick <- 1..3, do: send(view.pid, :refresh)
      assert_receive {:gate_reached, :home}
      render(view)
      assert reads(node) == before + 1

      FakeController.open_gate(node, :home)
      render_async(view)
      render_async(view)
      assert reads(node) == before + 1
    end

    test "events during a read cost one read after it", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = reads(node)
      hold_reads(node)
      send(view.pid, :refresh)

      for runner <- ~w(runner-a runner-b runner-c),
          do: send(view.pid, {:flezha_event, :runner_connected, {"default", runner}})

      assert_receive {:gate_reached, :home}
      render(view)
      assert reads(node) == before + 1

      FakeController.open_gate(node, :home)
      render_async(view)
      render_async(view)
      assert reads(node) == before + 2
    end

    test "an action during a read is followed by a read that sees it", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = reads(node)
      hold_reads(node)
      send(view.pid, :refresh)
      assert_receive {:gate_reached, :home}

      with_relays(node, ["relay_a"])
      html = render_click(view, "stop_relay", %{"relay_id" => "relay_b"})

      assert html =~ "relay_b"
      assert reads(node) == before + 1

      FakeController.open_gate(node, :home)
      render_async(view)
      render_async(view)

      assert reads(node) == before + 2
      assert relays_shown(view) == "1"
    end

    test "an action on a paused screen still reads", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      render_click(view, "refresh_toggle", %{})

      with_relays(node, ["relay_a"])
      send(view.pid, :refresh)
      render_async(view)
      assert relays_shown(view) == "2"

      render_click(view, "stop_relay", %{"relay_id" => "relay_b"})
      render_async(view)
      assert relays_shown(view) == "1"
    end

    test "an answer landing on an open dialog is dropped", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      hold_reads(node)
      with_relays(node, ["relay_a", "relay_b", "relay_c"])
      send(view.pid, :refresh)

      render_click(view, "confirm_stop", %{"relay_id" => "relay_a"})
      FakeController.open_gate(node, :home)
      render_async(view)
      assert relays_shown(view) == "2"

      view |> element(~s([data-testid="stop-cancel-btn"])) |> render_click()
      send(view.pid, :refresh)
      render_async(view)
      assert relays_shown(view) == "3"
    end

    test "a failed read keeps the figures and says why", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      FakeController.set(node, {Relay, :list}, FakeController.error("controller.timeout"))
      send(view.pid, :refresh)
      html = render_async(view)

      assert text_of(html, ~s([data-testid="ns-relays-value"])) == "2"
      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "controller.timeout"
    end

    test "a first read whose relays failed still shows the rest", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :list}, FakeController.error("controller.timeout"))

      {_view, html} = live_loaded(conn, "/namespaces/default?inspect=runner:runner-a")

      refute html =~ ~s(data-testid="home-namespace-loading")
      refute text_of(html, ~s([data-testid="home-headline"])) =~ "Reading"
      assert html =~ "controller.timeout"
      assert html =~ ~s(data-testid="inspector-runner")
    end

    test "a later read whose relays failed stops there", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = reads(node)

      FakeController.set(node, {Relay, :list}, FakeController.error("controller.timeout"))
      send(view.pid, :refresh)
      render_async(view)

      assert reads(node) == before
    end

    test "a read that dies keeps the figures and says why", %{conn: conn, node: node} do
      with_relays(node, ["relay_a", "relay_b"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      FakeController.set(
        node,
        {Relay, :list},
        {:ok, %{rows: [:not_a_row], total: 1, next: nil, unreachable: [], summary: nil}}
      )

      ExUnit.CaptureLog.capture_log(fn ->
        send(view.pid, :refresh)
        html = render_async(view)

        assert text_of(html, ~s([data-testid="ns-relays-value"])) == "2"
        assert html =~ "This console could not finish the read."
        refute html =~ "not_a_row"
      end)
    end
  end

  describe "the pulse in the background" do
    defp checked_at(view), do: :sys.get_state(view.pid).socket.assigns.shell_pulse.checked_at

    test "a held pulse leaves the screen answering, and starts no second", %{
      conn: conn,
      node: node
    } do
      with_relays(node, ["relay_a"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Controller, :durability_breaches}))

      FakeController.close_gate(node, :pulse)

      FakeController.set(
        node,
        {Controller, :durability_breaches},
        {:gated, :pulse, FakeController.rows([])}
      )

      send(view.pid, :shell_pulse)
      send(view.pid, :shell_pulse)
      assert_receive {:gate_reached, :pulse}

      assert open_section(view, "quotas") =~ ~s(data-testid="section-body-quotas")
      assert length(FakeController.calls(node, {Controller, :durability_breaches})) == before + 1

      FakeController.open_gate(node, :pulse)
      render_async(view)
      assert length(FakeController.calls(node, {Controller, :durability_breaches})) == before + 1
    end

    test "a pulse that dies keeps the last reading", %{conn: conn, node: node} do
      with_relays(node, ["relay_a"])
      {view, _html} = live_loaded(conn, ~p"/namespaces/default")
      read_at = checked_at(view)

      FakeController.set(node, {Relay, :list_namespaces}, FakeController.rows([%{running: true}]))

      ExUnit.CaptureLog.capture_log(fn ->
        send(view.pid, :shell_pulse)
        render_async(view)

        assert checked_at(view) == read_at
      end)
    end
  end
end
