defmodule FlezhaUiWeb.WorkflowLiveTest do
  @moduledoc """
  The workflow profile: its panel, its journal and inbox, completion inside and
  outside the retention window, and the two guarded actions.

  All of it lives here rather than in the browser because the states that
  matter — an instance that failed to initialise, one whose completion has just
  aged out, a journal with a parked entry — are ones a live stack cannot be
  asked to produce on demand.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Operative.Lifecycle
  alias Flezha.Operative.PartitionGroup
  alias Flezha.Service.HubManager
  alias Flezha.Service.OperativeManager
  alias Flezha.State.Completion
  alias Flezha.State.PersistenceResolver
  alias Flezha.State.ProcInbox
  alias Flezha.State.ProcJournal
  alias Flezha.State.Registry

  @url "/namespaces/default/operatives/op_wf"

  defp row(id, overrides \\ %{}) do
    FakeController.operative_row(id, Map.merge(%{factory: "chat_loop_workflow"}, overrides))
  end

  defp workflow(node, overwatch \\ %{}) do
    FakeController.set(node, {HubManager, :operative_rows}, [row("op_wf")])

    FakeController.set(
      node,
      {OperativeManager, :get_overwatch_state},
      {:ok,
       Map.merge(
         %{factory_id: "chat_loop_workflow", kind: :workflow, durable_workflow: true},
         overwatch
       )}
    )
  end

  describe "the workflow panel" do
    test "states the instance's workflow profile", %{conn: conn, node: node} do
      workflow(node, %{
        effectively_once: true,
        correction_window_ms: 30_000,
        arrived_via_hotswap?: true
      })

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="workflow-panel")
      assert html =~ ~s(data-testid="workflow-durable")
      assert html =~ ~s(data-testid="workflow-correction-window")
      assert html =~ "30s"
    end

    test "a stream operative gets no workflow panel", %{conn: conn, node: node} do
      FakeController.set(node, {HubManager, :operative_rows}, [row("op_wf")])

      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:ok, %{factory_id: "store_input", kind: :stream}}
      )

      {:ok, _view, html} = live(conn, @url)

      refute html =~ ~s(data-testid="workflow-panel")
      refute html =~ ~s(data-testid="journal-panel")
      refute html =~ ~s(data-testid="inbox-panel")
    end

    test "an instance that failed to initialise says so rather than reading healthy", %{
      conn: conn,
      node: node
    } do
      workflow(node, %{init_error: :factory_missing})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="workflow-init-error")
      assert html =~ "factory_missing"
    end

    test "a field an older controller omits does not break the decode", %{conn: conn, node: node} do
      FakeController.set(node, {HubManager, :operative_rows}, [row("op_wf")])

      FakeController.set(
        node,
        {OperativeManager, :get_overwatch_state},
        {:ok, %{factory_id: "chat_loop_workflow", kind: :workflow}}
      )

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="workflow-panel")
      refute html =~ ~s(data-testid="workflow-init-error")
    end
  end

  describe "journal and inbox" do
    test "committed iterations are listed newest first", %{conn: conn, node: node} do
      workflow(node)
      FakeController.set(node, {ProcJournal, :committed_iterations}, [1, 2, 3])

      FakeController.set(
        node,
        {ProcJournal, :read},
        {:ok,
         [
           %{seq: 1, type: :iter_committed, iter: 1, proc_idx: 0, payload: %{}},
           %{seq: 2, type: :iter_committed, iter: 2, proc_idx: 0, payload: %{}}
         ]}
      )

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "journal")

      assert html =~ ~s(data-testid="journal-panel")
      assert html =~ ~s(data-testid="journal-entry-2")
      # Newest first: seq 2's row is rendered before seq 1's.
      assert :binary.match(html, "journal-entry-2") < :binary.match(html, "journal-entry-1")
    end

    test "a parked entry states its wake deadline", %{conn: conn, node: node} do
      workflow(node)

      FakeController.set(
        node,
        {ProcJournal, :read},
        {:ok,
         [%{seq: 9, type: :parked, iter: 4, proc_idx: 0, payload: %{wake_deadline_ms: 4242}}]}
      )

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "journal")

      assert html =~ ~s(data-testid="journal-parked-9")
      assert html =~ "4242"
    end

    test "the inbox shows its depth and offsets", %{conn: conn, node: node} do
      workflow(node)
      FakeController.set(node, {ProcInbox, :undelivered}, [%{offset: 5}, %{offset: 6}])
      FakeController.set(node, {ProcInbox, :last_offset}, 6)
      FakeController.set(node, {ProcJournal, :consumed_offset}, 4)

      {:ok, view, _html} = live(conn, @url)

      html = open_section(view, "inbox")

      assert html =~ ~s(data-testid="inbox-panel")
      assert html =~ ~s(data-testid="inbox-undelivered")
      assert html =~ ~s(data-testid="inbox-last-offset")
    end

    test "a non-durable workflow gets neither panel", %{conn: conn, node: node} do
      workflow(node, %{durable_workflow: false})

      {:ok, _view, html} = live(conn, @url)

      assert html =~ ~s(data-testid="workflow-panel")
      refute html =~ ~s(data-testid="journal-panel")
      refute html =~ ~s(data-testid="inbox-panel")
    end
  end

  describe "finished instances" do
    defp finished(node, opts) do
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
      FakeController.set(node, {HubManager, :operative_rows}, opts[:rows] || [])
      FakeController.set(node, {Registry, :operative_classes}, opts[:classes] || [])
      FakeController.set(node, {Completion, :read}, opts[:completion] || :error)

      FakeController.set(
        node,
        {PersistenceResolver, :workflow_completed_retention_hours},
        opts[:retention] || 24
      )
    end

    test "a recently finished instance is listed, separated from live operatives", %{
      conn: conn,
      node: node
    } do
      finished(node,
        classes: ["op_done"],
        completion:
          {:ok,
           %{
             namespace: "default",
             status: :completed,
             finished_at: System.system_time(:second) - 60
           }}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "finished-instances")

      assert html =~ ~s(data-testid="finished-instances")
      assert html =~ ~s(data-testid="finished-row-op_done")
      assert html =~ "completed"
    end

    test "an instance past its retention window is not listed", %{conn: conn, node: node} do
      finished(node,
        classes: ["op_old"],
        retention: 1,
        completion:
          {:ok,
           %{
             namespace: "default",
             status: :completed,
             finished_at: System.system_time(:second) - 7200
           }}
      )

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")

      html = open_section(view, "finished-instances")

      refute html =~ ~s(data-testid="finished-row-op_old")
      assert html =~ "No workflow instance has finished"
    end

    test "a completion belonging to another namespace is not listed", %{conn: conn, node: node} do
      finished(node,
        classes: ["op_elsewhere"],
        completion:
          {:ok,
           %{namespace: "other", status: :completed, finished_at: System.system_time(:second)}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="finished-row-op_elsewhere")
    end

    test "a class that is still live is not reported as finished", %{conn: conn, node: node} do
      finished(node,
        rows: [row("op_live")],
        classes: ["op_live"],
        completion:
          {:ok,
           %{namespace: "default", status: :completed, finished_at: System.system_time(:second)}}
      )

      {:ok, _view, html} = live(conn, ~p"/namespaces/default")

      refute html =~ ~s(data-testid="finished-row-op_live")
    end

    test "a finished instance's completion record is shown on its own screen", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {HubManager, :operative_rows}, [])
      FakeController.set(node, {Registry, :operative_classes}, ["op_wf"])

      FakeController.set(
        node,
        {Completion, :read},
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
    end
  end

  describe "rewind" do
    test "only committed iterations are offered", %{conn: conn, node: node} do
      workflow(node)
      FakeController.set(node, {ProcJournal, :committed_iterations}, [2, 5])

      {:ok, view, _html} = live(conn, @url)
      html = render_click(view, "open_rewind", %{})

      assert html =~ ~s(data-testid="rewind-modal")
      assert html =~ ~s(data-testid="rewind-iteration")
      assert html =~ ~s(value="2")
      assert html =~ ~s(value="5")
      # Iterations the journal never committed are not offered at all.
      refute html =~ ~s(value="3")
    end

    test "confirming rewinds to the chosen iteration", %{conn: conn, node: node} do
      workflow(node)
      FakeController.set(node, {ProcJournal, :committed_iterations}, [2, 5])
      FakeController.set(node, {OperativeManager, :get_operative_pid}, self())

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      render_change(view, "select_rewind", %{"rewind" => %{"iteration" => "5"}})
      render_click(view, "rewind", %{})

      assert [[_pid, 5]] = FakeController.calls(node, {Lifecycle, :rewind})
    end

    test "dismissing the confirmation calls nothing", %{conn: conn, node: node} do
      workflow(node)
      FakeController.set(node, {ProcJournal, :committed_iterations}, [2])

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      html = render_click(view, "cancel_rewind", %{})

      refute html =~ ~s(data-testid="rewind-modal")
      assert FakeController.calls(node, {Lifecycle, :rewind}) == []
    end

    test "an iteration the journal never committed is refused before the controller", %{
      conn: conn,
      node: node
    } do
      workflow(node)
      FakeController.set(node, {ProcJournal, :committed_iterations}, [2])

      {:ok, view, _html} = live(conn, @url)
      render_click(view, "open_rewind", %{})
      render_change(view, "select_rewind", %{"rewind" => %{"iteration" => "99"}})
      render_click(view, "rewind", %{})

      assert FakeController.calls(node, {Lifecycle, :rewind}) == []
    end
  end

  describe "rescale" do
    defp with_group(node) do
      members = [
        Map.merge(row("orders_p0"), %{
          partition: %{group: "orders", index: 0, count: 2, range: {0, 127}}
        }),
        Map.merge(row("orders_p1"), %{
          partition: %{group: "orders", index: 1, count: 2, range: {128, 255}}
        })
      ]

      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})
      FakeController.set(node, {HubManager, :operative_rows}, members)

      FakeController.set(node, {Flezha.Service.CliManager, :group_partition_rows}, [
        %{
          id: "orders",
          health: :healthy,
          runner: "p0→runner-a",
          factory: "store_input",
          partitions: "2/2",
          node: :"flezha@node-a",
          members: members
        }
      ])
    end

    test "confirming requests the new target", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_rescale", %{"group" => "orders"})
      render_change(view, "select_rescale", %{"rescale" => %{"target" => "4"}})
      render_click(view, "rescale", %{})

      assert [["default", "orders", 4, []]] =
               FakeController.calls(node, {PartitionGroup, :rescale})
    end

    test "dismissing the confirmation calls nothing", %{conn: conn, node: node} do
      with_group(node)

      {:ok, view, _html} = live(conn, ~p"/namespaces/default")
      render_click(view, "open_rescale", %{"group" => "orders"})
      html = render_click(view, "cancel_rescale", %{})

      refute html =~ ~s(data-testid="rescale-modal")
      assert FakeController.calls(node, {PartitionGroup, :rescale}) == []
    end
  end
end
