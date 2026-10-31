defmodule FlezhaConsoleWeb.FleetScaleTest do
  @moduledoc """
  What each screen reads and renders as a namespace grows to thousands of
  relays and plugins: a page, never the whole namespace; a search the
  controller makes; a sample with a count; work per tick that does not grow.

  Here rather than in the browser: the fake controller holds thousands of rows
  at once and counts every call a screen makes.
  """

  use FlezhaConsoleWeb.LiveCase

  alias Flezha.Service.Controller
  alias Flezha.Service.Dlq
  alias Flezha.Service.Fleet
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Steps
  alias FlezhaConsole.DeadLetters
  alias FlezhaConsoleWeb.NamespaceLive.Show

  defp relays(count, overrides \\ fn _index -> %{} end) do
    for index <- 1..count do
      FakeController.relay_row(
        "r" <> String.pad_leading(to_string(index), 5, "0"),
        overrides.(index)
      )
    end
  end

  defp fleet(node, rows_by_namespace),
    do: FakeController.set_fleet(node, rows: rows_by_namespace)

  defp list_calls(node), do: FakeController.calls(node, {Relay, :list})

  # The screen's own list reads, not the shell pulse's, which every screen makes.
  defp screen_calls(node), do: Enum.reject(list_calls(node), &(Enum.at(&1, 1) == pulse_opts()))
  defp pulse_opts, do: FlezhaConsoleWeb.Attention.relay_opts()
  defp last_opts(node), do: node |> screen_calls() |> List.last() |> Enum.at(1)
  defp liveness_calls(node), do: FakeController.calls(node, {Controller, :liveness_counters})

  defp shown_rows(html),
    do: html |> testids(~s([data-testid^="relay-index-row-"])) |> length()

  describe "a controller listing" do
    test "asks for 20 rows, then 40 as it grows, its foot reading the total", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(60)})
      {view, html} = live_loaded(conn, ~p"/namespaces/default/relays")

      assert last_opts(node)[:limit] == 20
      assert shown_rows(html) == 20
      assert text_of(html, ~s([data-testid="relay-rows-more"])) == "Show 20 more · 20 of 60"

      view |> element(~s([data-testid="relay-rows-more"])) |> render_click()
      html = render_async(view)

      assert last_opts(node)[:limit] == 40
      assert shown_rows(html) == 40
      assert text_of(html, ~s([data-testid="relay-rows-more"])) == "Show 20 more · 40 of 60"

      # A tick re-reads the page the operator grew, not the first.
      send(view.pid, :refresh)
      html = render_async(view)
      assert last_opts(node)[:limit] == 40
      assert shown_rows(html) == 40
    end

    test "reaches 500 rows, then states the total and asks to narrow it", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(600)})
      {view, _html} = live_loaded(conn, ~p"/namespaces/default/relays")

      # Grown page by page to 480 rows, then once more by its own control.
      render_click(view, "grid_more", %{"id" => "relay-rows", "shown" => "460", "step" => "20"})
      render_async(view)
      view |> element(~s([data-testid="relay-rows-more"])) |> render_click()
      html = render_async(view)
      assert last_opts(node)[:limit] == 500
      refute html =~ ~s(data-testid="relay-rows-more")

      assert text_of(html, ~s([data-testid="relay-rows-reach"])) ==
               "Showing 500 of 600 · search or filter to narrow"
    end
  end

  describe "the relays index" do
    test "a tick makes one list call per namespace and one liveness read naming the rows shown",
         %{conn: conn, node: node} do
      fleet(node, %{"default" => relays(30), "billing" => relays(3)})
      {view, _html} = live_loaded(conn, ~p"/relays")

      lists = length(screen_calls(node))
      reads = length(liveness_calls(node))

      send(view.pid, :refresh)
      render_async(view)

      assert length(screen_calls(node)) == lists + 2
      assert length(liveness_calls(node)) == reads + 1

      [opts, _ctx] = List.last(liveness_calls(node))
      named = opts[:filter][:relays]
      assert length(named) == 20
      assert {"billing", "r00001"} in named
      refute Enum.any?(named, &match?({"default", "r00030"}, &1))

      assert FakeController.calls(node, {Relay, :relay_plugins}) == []
    end

    test "the search, each filter and the sort reach the controller as its opts", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(5)})

      {view, _html} =
        live_loaded(
          conn,
          ~p"/namespaces/default/relays?#{[health: "failed", run: "steps", runner: "runner-a", sort: "severity", q: "r0"]}"
        )

      opts = last_opts(node)
      assert opts[:sort] == :severity
      assert {:text, "r0"} in opts[:filter]
      assert {:health, "failed"} in opts[:filter]
      assert {:run, "steps"} in opts[:filter]
      assert {:runner, "runner-a"} in opts[:filter]

      view
      |> form(~s([data-testid="relay-filters"]))
      |> render_change(%{"filters" => %{"q" => "r00003"}})

      assert assert_patch(view) =~ "q=r00003"
      render_async(view)

      assert {:text, "r00003"} in last_opts(node)[:filter]
    end

    test "a search finds a relay from anywhere in the namespace, and states how many match", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(5_000)})

      {_view, html} = live_loaded(conn, ~p"/namespaces/default/relays?#{[q: "r0050"]}")

      assert testids(html, ~s([data-testid^="relay-index-row-"])) ==
               Enum.map(500..509, &"relay-index-row-r00#{&1}")

      assert text_of(html, ~s([data-testid="relays-count"])) =~ "10 relays in default"
    end

    test "an opened partition group pages its members", %{conn: conn, node: node} do
      fleet(node, %{"default" => [group_row("orders", 30)]})
      {view, _html} = live_loaded(conn, ~p"/namespaces/default/relays")

      html = view |> element(~s([data-testid="relay-members-orders"])) |> render_click()

      assert html =~ ~s(data-testid="relay-index-row-orders#p19")
      refute html =~ ~s(data-testid="relay-index-row-orders#p20")

      assert text_of(html, ~s([data-testid="group-default-orders-more"])) ==
               "Show 10 more · 20 of 30"

      html = view |> element(~s([data-testid="group-default-orders-more"])) |> render_click()
      assert html =~ ~s(data-testid="relay-index-row-orders#p29")
      refute html =~ ~s(data-testid="group-default-orders-more")
    end
  end

  describe "a relay's screen" do
    test "reads its own row by id, and a partition member with its group", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :list}, FakeController.rows([group_row("orders", 3)]))

      {:ok, _view, html} = live(conn, "/namespaces/default/relays/orders%23p1")

      assert Enum.any?(list_calls(node), fn
               ["default", opts, _ctx] -> opts[:filter] == [ids: ["orders#p1", "orders"]]
               _other -> false
             end)

      assert text_of(html, ~s([data-testid="partition-menu"])) == "Partition p1 of 3"
    end

    test "its partition menu pages the group's members and searches them", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :list}, FakeController.rows([group_row("orders", 30)]))
      {:ok, view, html} = live(conn, "/namespaces/default/relays/orders%23p0")

      assert html =~ ~s(data-testid="partition-menu-orders#p19")
      refute html =~ ~s(data-testid="partition-menu-orders#p25")
      assert html =~ ~s(data-testid="partition-menu-more")

      search = %{listing: "partition-menu", q: "p25"}

      html =
        view
        |> form(
          ~s([data-testid="partition-menu-search-form"][phx-change="listing_search"]),
          search
        )
        |> render_change()

      assert html =~ ~s(data-testid="partition-menu-orders#p25")
      refute html =~ ~s(data-testid="partition-menu-orders#p1")
    end
  end

  describe "the pulse" do
    defp pulse_calls(conn, node, rows) do
      FakeController.reset(node)
      fleet(node, %{"default" => rows})
      {_view, _html} = live_loaded(conn, ~p"/problems")

      {length(list_calls(node)),
       length(FakeController.calls(node, {Fleet, :runners_for_factory}))}
    end

    test "makes the same calls for 10 relays and for 5,000", %{conn: conn, node: node} do
      suspended = fn index -> if rem(index, 3) == 0, do: %{health: :suspended}, else: %{} end

      assert pulse_calls(conn, node, relays(10, suspended)) ==
               pulse_calls(conn, node, relays(5_000, suspended))

      # One runner read for the one factory relays wait on.
      assert {_lists, 1} = pulse_calls(conn, node, relays(5_000, suspended))
    end

    test "never pulses while its tab is hidden, and pulses once it is shown", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(3)})
      {view, _html} = live_loaded(conn, ~p"/problems")
      before = length(list_calls(node))

      view
      |> element("#shell-visibility")
      |> render_hook("refresh_visibility", %{"hidden" => true})

      send(view.pid, :shell_pulse)
      render_async(view)
      assert length(list_calls(node)) == before

      view
      |> element("#shell-visibility")
      |> render_hook("refresh_visibility", %{"hidden" => false})

      render_async(view)
      assert length(list_calls(node)) == before + 1
    end

    test "reads the 50 most severe and says how many more are not healthy", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(300, fn _index -> %{health: :halted} end)})
      {view, html} = live_loaded(conn, ~p"/problems")

      assert node |> list_calls() |> List.last() |> Enum.at(1) == [
               limit: 50,
               sort: :severity,
               filter: [health: ["unhealthy", "suspended"]]
             ]

      # The problems page 20 at a time; the item saying how many more follows them.
      assert text_of(html, ~s([data-testid="problems-more"])) == "Show 20 more · 20 of 51"

      for _page <- 1..2, do: view |> element(~s([data-testid="problems-more"])) |> render_click()
      html = render(view)
      assert html =~ "250 more relays in default are not healthy"

      view |> element(~s([data-testid="problem-grow-unread:default"])) |> render_click()
      render_async(view)

      assert node |> list_calls() |> List.last() |> Enum.at(1) |> Keyword.get(:limit) == 100

      assert Enum.any?(
               :sys.get_state(view.pid).socket.assigns.shell_pulse.items,
               &(&1.what == "200 more relays in default are not healthy")
             )
    end

    test "Dashboard and Open problems show the same items", %{conn: conn, node: node} do
      rows = [
        FakeController.relay_row("relay_h", %{health: :halted}),
        FakeController.relay_row("relay_d", %{health: :degraded}),
        FakeController.relay_row("relay_s", %{health: :suspended})
      ]

      fleet(node, %{"default" => rows ++ relays(5)})

      {home, _html} = live_loaded(conn, ~p"/namespaces/default")
      {problems, _html} = live_loaded(conn, ~p"/problems")

      home_items = :sys.get_state(home.pid).socket.assigns.items
      pulse_items = :sys.get_state(problems.pid).socket.assigns.shell_pulse.items

      assert Enum.map(home_items, & &1.id) |> Enum.sort() ==
               pulse_items
               |> Enum.filter(&(&1.namespace == "default"))
               |> Enum.map(& &1.id)
               |> Enum.sort()
    end
  end

  describe "Dashboard" do
    test "reads its Flow as the namespace's totals, never every relay's counters", %{
      conn: conn,
      node: node
    } do
      fleet(node, %{"default" => relays(5)})

      FakeController.set(
        node,
        {Controller, :liveness_counters},
        {:ok,
         %{
           channels: [],
           relays: [
             FakeController.relay_counters("r00001", %{io_in_received: 10, forwarded: 4}),
             FakeController.relay_counters("r00002", %{io_in_received: 30, forwarded: 6})
           ],
           unreachable: []
         }}
      )

      {view, _html} = live_loaded(conn, ~p"/namespaces/default")

      assert [[[filter: [namespace: "default"], limit: 0], _ctx] | _] = liveness_calls(node)
      assert Enum.all?(liveness_calls(node), fn [opts, _ctx] -> opts != [] end)

      # 40 records arrived, then 100: 60 more over the tick's second.
      FakeController.set(
        node,
        {Controller, :liveness_counters},
        {:ok,
         %{
           channels: [],
           relays: [
             FakeController.relay_counters("r00001", %{io_in_received: 50, forwarded: 4}),
             FakeController.relay_counters("r00002", %{io_in_received: 50, forwarded: 6})
           ],
           unreachable: []
         }}
      )

      html = tick(view)
      assert text_of(html, ~s([data-testid="ns-flow"])) =~ ~r/[1-9]\d\.\dmsgs\/s Flowing/
      assert [%{in: rate}] = :sys.get_state(view.pid).socket.assigns.topology_state.history.totals
      assert rate > 50
    end

    test "renders no slower with 10,000 relays than with 100, within a factor of 2", %{
      conn: conn,
      node: node
    } do
      timed = fn count ->
        FakeController.reset(node)

        fleet(node, %{
          "default" =>
            relays(count, fn i -> if rem(i, 7) == 0, do: %{health: :failed}, else: %{} end)
        })

        {view, _html} = live_loaded(conn, ~p"/namespaces/default")
        assigns = :sys.get_state(view.pid).socket.assigns

        {micros, _html} =
          :timer.tc(fn ->
            for _render <- 1..20,
                do: assigns |> Show.render() |> rendered_to_string()
          end)

        micros
      end

      small = timed.(100)
      large = timed.(10_000)

      assert large <= 2 * small + 50_000, "100 relays: #{small} µs, 10,000 relays: #{large} µs"
    end
  end

  describe "the plugin form's relay picker" do
    setup %{node: node} do
      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "default", running: true}])
      )

      FakeController.set(
        node,
        {PluginManager, :enabled},
        {:ok,
         [
           %{
             name: "out_1",
             provider: "std_out",
             provider_id: "relay_stdout",
             single: false,
             relays: ["r00001"],
             controllers: [],
             hooks: ["on_output"],
             lagging: []
           }
         ]}
      )

      FakeController.set(
        node,
        {Fleet, :providers},
        FakeController.rows([
          %{id: "relay_stdout", module: "Flezha.Plugin.relay_stdout", type: :relay}
        ])
      )

      FakeController.set(node, {Relay, :list}, FakeController.rows(relays(30)))
      :ok
    end

    test "offers the first 20 relays, says how many more match, and searches the rest", %{
      conn: conn,
      node: node
    } do
      {view, _html} = live_loaded(conn, ~p"/plugins")

      html = view |> element(~s([data-testid="plugin-bind-out_1"])) |> render_click()
      assert html =~ ~s(data-testid="input-plugin-relay-r00020")
      refute html =~ ~s(data-testid="input-plugin-relay-r00021")

      assert text_of(html, ~s([data-testid="input-plugin-relay-more"])) ==
               "10 more match · keep typing"

      html =
        view
        |> element(~s([phx-keyup="plugin_form_relays"]))
        |> render_keyup(%{"value" => "r00025"})

      assert last_opts(node) == [limit: 20, filter: [text: "r00025"]]
      assert html =~ ~s(data-testid="input-plugin-relay-r00025")
      refute html =~ ~s(data-testid="input-plugin-relay-r00001")
    end
  end

  describe "the plugins screen" do
    setup %{node: node} do
      bound = Enum.map(1..1_000, &"relay_#{&1}")

      FakeController.set(
        node,
        {Relay, :list_namespaces},
        FakeController.rows([%{namespace: "default", running: true}])
      )

      FakeController.set(
        node,
        {PluginManager, :enabled},
        {:ok,
         [
           %{
             name: "out_1",
             provider: "std_out",
             provider_id: "relay_stdout",
             single: false,
             relays: bound,
             controllers: [],
             hooks: ["on_output"],
             lagging: []
           }
         ]}
      )

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows(Enum.map(["relay_500", "lone"], &FakeController.relay_row/1))
      )

      :ok
    end

    test "a plugin bound to a thousand relays shows ten and how many more", %{
      conn: conn,
      node: node
    } do
      {_view, html} = live_loaded(conn, ~p"/plugins")

      assert [["default", opts, _ctx] | _] = FakeController.calls(node, {PluginManager, :enabled})
      assert opts[:limit] == 20
      assert text_of(html, ~s([data-testid="plugin-relays-more-out_1"])) == "+ 990 more"
      assert length(testids(html, ~s([data-testid^="plugin-unbind-out_1-"]))) == 10
      assert html =~ ~s(data-testid="plugin-unbind-other-out_1")
    end

    test "a search is written to the address", %{conn: conn} do
      {view, _html} = live_loaded(conn, ~p"/plugins")

      view
      |> form(~s([data-testid="plugins-view"]))
      |> render_change(%{"view" => %{"q" => "out"}})

      assert_patch(view, ~p"/plugins?#{[q: "out"]}")
    end

    test "Unbind another relay confirms the binding before it asks, and refuses one not bound",
         %{conn: conn, node: node} do
      {view, _html} = live_loaded(conn, ~p"/plugins")

      view |> element(~s([data-testid="plugin-unbind-other-out_1"])) |> render_click()

      html =
        view
        |> element(~s([phx-keyup="unbind_other_search"]))
        |> render_keyup(%{"value" => "lone"})

      assert html =~ ~s(data-testid="unbind-other-relay-lone")

      view
      |> form(~s([data-testid="unbind-other-form"]))
      |> render_change(%{"unbind" => %{"relay" => "lone"}})

      html = view |> element(~s([data-testid="unbind-other-next"])) |> render_click()
      assert html =~ ~s(data-testid="unbind-other-not-bound")
      refute html =~ ~s(data-testid="plugin-unbind-modal")

      view
      |> form(~s([data-testid="unbind-other-form"]))
      |> render_change(%{"unbind" => %{"relay" => "relay_500"}})

      html = view |> element(~s([data-testid="unbind-other-next"])) |> render_click()
      assert html =~ ~s(data-testid="plugin-unbind-modal")
      assert html =~ "relay_500"

      assert Enum.any?(FakeController.calls(node, {PluginManager, :enabled}), fn
               ["default", opts, _ctx] -> opts == [filter: [relay: "relay_500", text: "out_1"]]
               _other -> false
             end)

      view |> element(~s([data-testid="plugin-unbind-cancel"])) |> render_click()
      view |> element(~s([data-testid="plugin-unbind-other-out_1"])) |> render_click()
      html = view |> element(~s([data-testid="unbind-other-cancel"])) |> render_click()
      refute html =~ ~s(data-testid="plugin-unbind-other-modal")
    end
  end

  describe "a relay's state" do
    defp durable(node) do
      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("relay_a")])
      )

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok,
         %{factory_id: "chat_loop_steps", builder: %{run: :steps, opts: []}, durable_steps: true}}
      )
    end

    defp cell(index),
      do: %{
        relay_class: "relay_a",
        tasklet_id: "orders",
        cell_key: "k" <> String.pad_leading(to_string(index), 3, "0"),
        wal_seq: 120,
        snapshot_seq: 100,
        wal_bytes: 4096,
        flush_latency_ms_p99: 3,
        fsync_durability_lag_ms: 0,
        dedup_drops_total: 0
      }

    test "reads a page of Cells, draws the lag chart of those alone, and searches the rest", %{
      conn: conn,
      node: node
    } do
      durable(node)

      FakeController.set(
        node,
        {Steps, :cells},
        {:ok,
         %{relay_class: "relay_a", history_retention_hours: 24, cells: Enum.map(1..30, &cell/1)}}
      )

      {:ok, view, html} = live(conn, "/namespaces/default/relays/relay_a/state")

      assert [_class, [limit: 20, filter: []], _ctx] =
               node |> FakeController.calls({Steps, :cells}) |> List.last()

      assert length(testids(html, ~s([data-testid^="spark-relay_a/orders/"]))) == 20
      assert text_of(html, ~s([data-testid="cells-more"])) == "Show 10 more · 20 of 30"

      search = %{listing: "cells", q: "k025"}

      view
      |> form(~s([data-testid="cells-search-form"][phx-change="listing_search"]), search)
      |> render_change()

      html = render_async(view)

      assert [_class, [limit: 20, filter: [text: "k025"]], _ctx] =
               node |> FakeController.calls({Steps, :cells}) |> List.last()

      assert testids(html, ~s([data-testid^="spark-relay_a/orders/"])) == [
               "spark-relay_a/orders/k025"
             ]

      # The input log's undelivered records are counted, not read.
      assert Enum.all?(FakeController.calls(node, {Steps, :undelivered}), fn [_id, opts, _ctx] ->
               opts == [limit: 0]
             end)
    end

    test "the rewind picker holds the 20 newest iterations and reads older ones on request", %{
      conn: conn,
      node: node
    } do
      durable(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, Enum.to_list(1..45)})

      {:ok, view, _html} = live(conn, "/namespaces/default/relays/relay_a/state")
      html = view |> element(~s([data-testid="open-rewind-btn"])) |> render_click()

      assert html =~ ~s(data-testid="rewind-iteration-45")
      assert html =~ ~s(data-testid="rewind-iteration-26")
      refute html =~ ~s(data-testid="rewind-iteration-25")
      assert text_of(html, ~s([data-testid="rewind-older"])) == "Older · 20 of 45 shown"

      html = view |> element(~s([data-testid="rewind-older"])) |> render_click()
      assert html =~ ~s(data-testid="rewind-iteration-6")
      refute html =~ ~s(data-testid="rewind-iteration-5")

      html = view |> element(~s([data-testid="rewind-older"])) |> render_click()
      assert html =~ ~s(data-testid="rewind-iteration-1")
      refute html =~ ~s(data-testid="rewind-older")
    end
  end

  describe "dead letters" do
    defp entry(class, id),
      do: %{
        "relay_class" => class,
        "tasklet_id" => "t",
        "id" => id,
        "generation" => 1,
        "node" => :"flezha@node-a"
      }

    defp parked(node, class, entries) do
      FakeController.set(
        node,
        {Dlq, :stats},
        FakeController.rows([
          %{
            relay_class: class,
            tasklet_id: "t",
            entries: entries,
            bytes: entries * 10,
            node: :"flezha@node-a"
          }
        ])
      )

      FakeController.set(
        node,
        {Dlq, :list},
        FakeController.rows(Enum.map(1..entries, &entry(class, "e#{&1}")))
      )
    end

    defp listed(node, class),
      do: node |> FakeController.calls({Dlq, :list}) |> Enum.count(&(hd(&1) == class))

    test "a class's seen count is listed again only after its figures or its marks change", %{
      node: node,
      user: user
    } do
      FlezhaConsole.TestEnv.put_app(:dead_letter_seen_ttl_ms, 60_000)
      class = "cache_#{System.unique_integer([:positive])}"
      parked(node, class, 2)

      :ok =
        DeadLetters.mark_seen(
          [%{ref: "#{class}/t/e1", generation: 1, relay_class: class}],
          user.email
        )

      assert {:ok, %{rows: [%{seen: 1}]}} = DeadLetters.stats(nil)
      assert {:ok, %{rows: [%{seen: 1}]}} = DeadLetters.stats(nil)
      assert listed(node, class) == 1

      :ok =
        DeadLetters.mark_seen(
          [%{ref: "#{class}/t/e2", generation: 1, relay_class: class}],
          user.email
        )

      assert {:ok, %{rows: [%{seen: 2}]}} = DeadLetters.stats(nil)
      assert listed(node, class) == 2

      parked(node, class, 3)
      assert {:ok, %{rows: [%{seen: 2}]}} = DeadLetters.stats(nil)
      assert listed(node, class) == 3
    end

    test "the queue is read a page at a time, newest first", %{conn: conn, node: node} do
      parked(node, "orders", 30)
      {:ok, _view, html} = live(conn, ~p"/dlq")

      assert [nil, [limit: 20], _ctx] = node |> FakeController.calls({Dlq, :list}) |> List.last()
      assert length(testids(html, ~s([data-testid^="dlq-row-"]))) == 20
      assert text_of(html, ~s([data-testid="dlq-more"])) == "Show 10 more · 20 of 30"
    end
  end

  describe "the namespaces and the cluster" do
    test "count a namespace's relays from its summary, reading no row", %{conn: conn, node: node} do
      fleet(node, %{
        "default" => relays(40, fn i -> if i <= 4, do: %{health: :failed}, else: %{} end)
      })

      {:ok, _view, html} = live(conn, ~p"/namespaces")
      assert Enum.all?(screen_calls(node), fn [_ns, opts, _ctx] -> opts == [limit: 0] end)
      assert html =~ "40 relays"

      {:ok, _view, html} = live(conn, ~p"/cluster")
      assert text_of(html, ~s([data-testid="ns-health-default"])) =~ "4"
    end
  end

  describe "the command palette" do
    test "searches the controller for relays as the operator types", %{conn: conn, node: node} do
      fleet(node, %{"default" => relays(3_000)})
      {view, _html} = live_loaded(conn, ~p"/namespaces/default/relays")

      view |> element("#command-palette") |> render_hook("open", %{})

      html =
        view
        |> element(~s([data-testid="command-palette-search"]))
        |> render_change(%{"q" => "stop r02999"})

      assert last_opts(node) == [limit: 20, filter: [text: "r02999"]]
      assert html =~ ~s(data-testid="command-palette-action-Stop r02999")
    end
  end

  describe "the namespace switcher" do
    test "is not re-sent on a tick when the namespaces did not change", %{conn: conn, node: node} do
      fleet(node, %{"default" => relays(3), "billing" => relays(1)})
      {view, _html} = live_loaded(conn, ~p"/relays")

      :erlang.trace(view.pid, true, [:send])
      send(view.pid, :refresh)
      render_async(view)
      render(view)
      :erlang.trace(view.pid, false, [:send])

      sent = traced(view.pid, [])
      assert Enum.any?(sent, &(&1 =~ "diff")), "the tick sent no diff to look into"
      refute Enum.any?(sent, &(&1 =~ "namespace-picker-billing"))
    end

    defp traced(pid, acc) do
      receive do
        {:trace, ^pid, :send, message, _to} ->
          traced(pid, [inspect(message, limit: :infinity) | acc])
      after
        0 -> acc
      end
    end
  end
end
