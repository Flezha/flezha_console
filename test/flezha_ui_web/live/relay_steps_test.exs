defmodule FlezhaUiWeb.RelayStepsTest do
  @moduledoc """
  A steps relay: its panel, its task journal and input log, finished relays,
  and the two guarded actions.

  All of it lives here rather than in the browser because the states that
  matter — a relay that failed to initialise, a journal with a dead-lettered
  entry, a finished relay — are ones a live stack cannot be asked to produce on
  demand.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Relay
  alias Flezha.Service.Steps

  @url "/namespaces/default/relays/relay_steps"

  defp row(id, overrides \\ %{}) do
    FakeController.relay_row(id, Map.merge(%{factory: "chat_loop_steps"}, overrides))
  end

  defp steps(node, overwatch \\ %{}) do
    FakeController.set(node, {Relay, :relay_rows}, {:ok, [row("relay_steps")]})

    FakeController.set(
      node,
      {Relay, :overwatch_state},
      {:ok,
       Map.merge(
         %{
           factory_id: "chat_loop_steps",
           builder: %{run: :steps, opts: []},
           durable_steps: true
         },
         overwatch
       )}
    )
  end

  describe "the steps panel" do
    test "states the relay's steps facts", %{conn: conn, node: node} do
      steps(node, %{
        effectively_once: true,
        correction_window_ms: 30_000,
        arrived_via_hotswap?: true
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="steps-panel")
      assert html =~ ~s(data-testid="steps-durable")
      assert html =~ ~s(data-testid="steps-correction-window")
      assert html =~ "30s"
    end

    test "a flow relay gets no steps panel", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :relay_rows}, {:ok, [row("relay_steps")]})

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, %{factory_id: "store_input", builder: %{run: :flow, opts: []}}}
      )

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="steps-panel")
      refute html =~ ~s(data-testid="task-journal-panel")
      refute html =~ ~s(data-testid="input-log-panel")
    end

    test "a relay that failed to initialise says so rather than reading healthy", %{
      conn: conn,
      node: node
    } do
      steps(node, %{init_error: :factory_missing})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="steps-init-error")
      assert html =~ "factory_missing"
    end

    test "a field an older controller omits does not break the decode", %{conn: conn, node: node} do
      FakeController.set(node, {Relay, :relay_rows}, {:ok, [row("relay_steps")]})

      FakeController.set(
        node,
        {Relay, :overwatch_state},
        {:ok, %{factory_id: "chat_loop_steps", builder: %{run: :steps, opts: []}}}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="steps-panel")
      refute html =~ ~s(data-testid="steps-init-error")
    end
  end

  describe "task journal and input log" do
    test "the journal report is shown, entries newest first", %{conn: conn, node: node} do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [1, 2, 3]})

      FakeController.set(
        node,
        {Steps, :journal},
        {:ok,
         %{
           instance: "relay_steps",
           entries: [
             %{seq: 1, type: "iter_committed", iter: 1, task_idx: 0},
             %{seq: 2, type: "iter_committed", iter: 2, task_idx: 0}
           ],
           leaf_tasks: ["reply"],
           complete: false
         }}
      )

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "journal")

      assert html =~ ~s(data-testid="task-journal-panel")
      assert html =~ ~s(data-testid="journal-entry-2")
      # Newest first: seq 2's row is rendered before seq 1's.
      assert :binary.match(html, "journal-entry-2") < :binary.match(html, "journal-entry-1")
      assert html =~ "committed iterations: 3, 2, 1"
      assert html =~ "leaf tasklets: reply"
      assert html =~ "has not committed every leaf"
    end

    test "a dead-lettered entry names its tasklet and its dead-letter entry", %{
      conn: conn,
      node: node
    } do
      steps(node)

      FakeController.set(
        node,
        {Steps, :journal},
        {:ok,
         %{
           instance: "relay_steps",
           entries: [
             %{
               seq: 9,
               type: "dead_lettered",
               iter: 4,
               task_idx: 1,
               tasklet: "charge",
               dlq_entry: "relay_steps/charge/abc"
             }
           ],
           leaf_tasks: [],
           complete: true
         }}
      )

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "journal")

      assert html =~ ~s(data-testid="journal-dead-lettered-9")
      assert html =~ "tasklet charge parked as relay_steps/charge/abc"
    end

    test "the input log shows its depth and offsets", %{conn: conn, node: node} do
      steps(node)

      FakeController.set(
        node,
        {Steps, :undelivered},
        {:ok,
         [%{offset: 5, message: "a", metadata: %{}}, %{offset: 6, message: "b", metadata: %{}}]}
      )

      FakeController.set(node, {Steps, :last_offset}, {:ok, 6})
      FakeController.set(node, {Steps, :consumed_offset}, {:ok, 4})

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "input-log")

      assert html =~ ~s(data-testid="input-log-panel")
      assert html =~ ~r/data-testid="input-log-undelivered"[^>]*>\s*2/
      assert html =~ ~r/data-testid="input-log-last-offset"[^>]*>\s*6/
    end

    test "an input log answering -1 is shown as holding no records", %{conn: conn, node: node} do
      steps(node)

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "input-log")

      assert html =~ ~r/data-testid="input-log-last-offset"[^>]*>\s*no records/
      refute html =~ ">-1<"
    end

    test "a non-durable steps relay gets neither panel", %{conn: conn, node: node} do
      steps(node, %{durable_steps: false})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="steps-panel")
      refute html =~ ~s(data-testid="task-journal-panel")
      refute html =~ ~s(data-testid="input-log-panel")
    end
  end

  describe "the input log's records" do
    test "are listed on expanding, consumed up to the floor", %{conn: conn, node: node} do
      steps(node)

      FakeController.set(
        node,
        {Steps, :inbox},
        {:ok,
         %{
           instance: "relay_steps",
           floor: 5,
           entries: [
             %{offset: 5, consumed: true, bytes: 12, channel: "prompts"},
             %{offset: 6, consumed: false, bytes: 2048, channel: nil}
           ]
         }}
      )

      {:ok, view, _html} = live(conn, @url)
      assert FakeController.calls(node, {Steps, :inbox}) == []

      html = open_section(view, "input-log")

      assert [["relay_steps", _ctx]] = FakeController.calls(node, {Steps, :inbox})
      assert html =~ ~r/data-testid="inbox-floor".*Floor <span class="font-mono">5</s
      assert html =~ ~r/data-testid="inbox-entry-5".*consumed.*12 B.*prompts/s
      assert html =~ ~r/data-testid="inbox-entry-6".*pending.*2.0 KB/s
    end

    test "are not read on the tick", %{conn: conn, node: node} do
      steps(node)
      {:ok, view, _html} = live(conn, @url)

      send(view.pid, :refresh)
      render(view)

      assert FakeController.calls(node, {Steps, :inbox}) == []
    end

    test "an unreadable log states why and the screen still renders", %{conn: conn, node: node} do
      steps(node)

      FakeController.set(
        node,
        {Steps, :inbox},
        FakeController.error("state.inbox_unreadable", "the log is on another node")
      )

      {:ok, view, _html} = live(conn, @url)
      html = open_section(view, "input-log")

      assert html =~ ~s(data-testid="inbox-error")
      assert html =~ "state.inbox_unreadable"
      assert html =~ ~s(data-testid="steps-panel")
    end
  end

  describe "finished relays" do
    test "the controller's finished relays are listed, separated from live ones", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Relay, :info},
        {:ok,
         %{
           namespace: "default",
           groups: [],
           relays: [
             %{id: "relay_live", phase: "running"},
             %{
               id: "relay_done",
               phase: "finished",
               run: :steps,
               status: :completed,
               finished_at: System.system_time(:second) - 60
             }
           ]
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "finished-relays")

      assert html =~ ~s(data-testid="finished-relays")
      assert html =~ ~s(data-testid="finished-row-relay_done")
      assert html =~ "completed"
      refute html =~ ~s(data-testid="finished-row-relay_live")
    end

    test "with none finished, the panel says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      assert open_section(view, "finished-relays") =~ "No steps relay has finished"
    end

    test "the listing is read on open and on request, never on a tick", %{
      conn: conn,
      node: node
    } do
      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      before = length(FakeController.calls(node, {Relay, :info}))

      send(view.pid, :refresh)
      _rendered = render(view)
      assert length(FakeController.calls(node, {Relay, :info})) == before

      render_click(view, "reload_finished", %{})
      assert length(FakeController.calls(node, {Relay, :info})) == before + 1
    end

    test "a finished relay's completion record is shown on its own screen", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Relay, :overwatch_state}, FakeController.error("relay.not_found"))

      FakeController.set(
        node,
        {Steps, :completion},
        {:ok,
         %{
           namespace: "default",
           status: :failed,
           error: "boom",
           finished_at: System.system_time(:second) - 30
         }}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="completion-record")
      assert html =~ "failed"
      assert html =~ "boom"
      refute html =~ ~s(data-testid="runtime-error")
    end
  end

  describe "rewind" do
    test "only committed iterations are offered", %{conn: conn, node: node} do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2, 5]})

      {:ok, view, _html} = live(conn, @url)
      html = render_click(view, "open_rewind", %{})

      assert html =~ ~s(data-testid="rewind-modal")
      assert html =~ ~s(data-testid="rewind-iteration")
      assert html =~ ~s(value="2")
      assert html =~ ~s(value="5")
      # Iterations the journal never committed are not offered at all.
      refute html =~ ~s(value="3")
    end

    test "confirming rewinds the relay by its class to the chosen iteration", %{
      conn: conn,
      node: node
    } do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2, 5]})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      render_change(view, "select_rewind", %{"rewind" => %{"iteration" => "5"}})

      assert render_click(view, "rewind", %{}) =~ "Rewound to iteration 5."

      assert [["default", "relay_steps", 5, %{source: :ui}]] =
               FakeController.calls(node, {Steps, :rewind})
    end

    test "a refused rewind states the error and reports nothing as rewound", %{
      conn: conn,
      node: node
    } do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2]})

      FakeController.set(
        node,
        {Steps, :rewind},
        FakeController.error("relay.iteration_not_committed", "iteration 2 has not committed")
      )

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      html = render_click(view, "rewind", %{})

      assert html =~ "iteration 2 has not committed"
      refute html =~ "Rewound to"
    end

    test "dismissing the confirmation calls nothing", %{conn: conn, node: node} do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2]})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      html = render_click(view, "cancel_rewind", %{})

      refute html =~ ~s(data-testid="rewind-modal")
      assert FakeController.calls(node, {Steps, :rewind}) == []
    end

    test "an iteration the journal never committed is refused before the controller", %{
      conn: conn,
      node: node
    } do
      steps(node)
      FakeController.set(node, {Steps, :committed_iterations}, {:ok, [2]})

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      render_change(view, "select_rewind", %{"rewind" => %{"iteration" => "99"}})
      render_click(view, "rewind", %{})

      assert FakeController.calls(node, {Steps, :rewind}) == []
    end
  end

  describe "rescale" do
    defp with_group(node) do
      members = [
        row("orders#p0", %{partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}}),
        row("orders#p1", %{partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}})
      ]

      FakeController.set_fleet(node, rows: %{"default" => members})

      FakeController.set(
        node,
        {Relay, :partition_groups},
        {:ok, [%{group: "orders", declared: 2, members: members, coverage: :ok}]}
      )
    end

    test "confirming requests the new target", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "partition-groups")
      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      assert has_element?(view, ~s([data-testid="rescale-modal"]))
      assert has_element?(view, ~s([data-testid="rescale-target"]))
      render_change(view, "select_rescale", %{"rescale" => %{"target" => "4"}})
      view |> element(~s([data-testid="rescale-confirm-btn"])) |> render_click()

      assert [["default", "orders", 4, [], %{source: :ui}]] =
               FakeController.calls(node, {Steps, :rescale})
    end

    test "dismissing the confirmation calls nothing", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      open_section(view, "partition-groups")
      view |> element(~s([data-testid="rescale-orders"])) |> render_click()
      html = view |> element(~s([data-testid="rescale-cancel-btn"])) |> render_click()

      refute html =~ ~s(data-testid="rescale-modal")
      assert FakeController.calls(node, {Steps, :rescale}) == []
    end
  end
end
