defmodule FlezhaUiWeb.ControllerLiveTest do
  @moduledoc """
  The controller-health screen.

  `local_only`, an RPO breach, a shutdown in progress and an unreachable
  coordinator are all states a healthy dev controller will not hold, so they
  are produced here rather than driven in a browser.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.AuthZ
  alias Flezha.Service.CliManager
  alias Flezha.Shutdown.Coordinator
  alias Flezha.State.DurabilityTier

  setup do
    # Posture and identity are cached per token for a refresh tick, so a token
    # per test keeps one test's posture out of the next one's cache.
    System.put_env("FLEZHA_TOKEN", "flz_controller_#{System.unique_integer([:positive])}")
    on_exit(fn -> System.delete_env("FLEZHA_TOKEN") end)
    :ok
  end

  describe "durability" do
    test "a remote tier shows backend, breaches and superseded shipments", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {DurabilityTier, :configured_backend}, :s3)
      FakeController.set(node, {DurabilityTier, :posture}, :remote_tier)

      FakeController.set(node, {DurabilityTier, :status}, [
        %{ref: "a", superseded_by: "writer-2"},
        %{ref: "b", superseded_by: nil}
      ])

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="durability-backend")
      assert html =~ "s3"
      assert html =~ "remote_tier"
      assert html =~ ~s(data-testid="durability-superseded")
      refute html =~ ~s(data-testid="durability-local-only")
    end

    test "local_only is stated as a posture, not an alarm", %{conn: conn, node: node} do
      FakeController.set(node, {DurabilityTier, :posture}, :local_only)

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="durability-local-only")
      assert html =~ "exactly one"
      # An informational notice, not an error one.
      refute html =~ ~s(data-testid="durability-local-only" role="alert")
    end

    test "breached references are listed with how far past target they are", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {DurabilityTier, :posture}, :remote_tier)

      FakeController.set(node, {DurabilityTier, :breaches}, [
        %{ref: "orders/p0", lag_ms: 90_000, pending_since_ms: 1}
      ])

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="durability-breach-table")
      assert html =~ "orders/p0"
      assert html =~ "1m 30s"
    end
  end

  describe "shutdown and boot" do
    test "a controller running normally states so with its configuration", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="shutdown-in-progress")
      assert html =~ ~s(data-testid="shutdown-phase")
      assert html =~ "enabled"
    end

    test "a shutdown in progress shows its phase", %{conn: conn, node: node} do
      FakeController.set(node, {Coordinator, :status}, %{
        shutdown_in_progress: true,
        shutdown_phase: :draining,
        signal_handler_status: :installed,
        graceful_shutdown_enabled: true,
        graceful_shutdown_timeout_ms: 60_000
      })

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ "draining"
    end

    test "an unreachable coordinator does not take the screen down", %{conn: conn, node: node} do
      FakeController.set(node, {Coordinator, :status}, {:error, :timeout})

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="shutdown-unavailable")
      # The rest still renders.
      assert html =~ ~s(data-testid="durability-panel")
    end

    test "boot state is listed per namespace", %{conn: conn, node: node} do
      FakeController.set(node, {Flezha.Service.HubManager, :get_running_namespaces}, ["default"])
      FakeController.set(node, {Flezha.Service.HubManager, :recovery_state}, {:ok, :normal})

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="boot-default")
      assert html =~ "normal"
    end
  end

  describe "authorization" do
    test "an open controller is called out as open", %{conn: conn, node: node} do
      FakeController.set(node, {AuthZ, :enforcement_posture}, :open)

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="authz-open")
      assert html =~ "Authorization is disabled"
    end

    test "an enforced controller states that it is enforced", %{conn: conn, node: node} do
      FakeController.set(node, {AuthZ, :enforcement_posture}, :enforced)

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="authz-posture")
      assert html =~ "enforced"
      refute html =~ ~s(data-testid="authz-open")
    end
  end

  describe "memory snapshot" do
    test "the refresh tick takes no memory snapshot", %{conn: conn, node: node} do
      {:ok, view, _html} = live(conn, ~p"/controller")
      send(view.pid, :refresh)
      _ = render(view)

      assert FakeController.calls(node, {CliManager, :build_mem_top_snapshot}) == []
    end

    test "an operator request renders the hot spots with their capture time", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {CliManager, :build_mem_top_snapshot}, %{
        captured_at: "2026-08-24T02:00:00Z",
        node: "flezha@controller",
        erlang_memory: %{total: 2048},
        top_processes: [%{name: :some_proc, memory: 1024}],
        ets_tables: [],
        dets_files: [],
        recon_alloc_allocated_types: []
      })

      {:ok, view, _html} = live(conn, ~p"/controller")
      html = render_click(view, "memory_snapshot", %{})

      assert html =~ ~s(data-testid="memory-captured-at")
      assert html =~ "2026-08-24T02:00:00Z"
      assert html =~ ~s(data-testid="memory-top-processes")
      assert html =~ "some_proc"
    end

    test "a snapshot stays labelled with its capture time across later ticks", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {CliManager, :build_mem_top_snapshot}, %{
        captured_at: "2026-08-24T02:00:00Z",
        node: "flezha@controller",
        erlang_memory: %{},
        top_processes: [],
        ets_tables: [],
        dets_files: [],
        recon_alloc_allocated_types: []
      })

      {:ok, view, _html} = live(conn, ~p"/controller")
      render_click(view, "memory_snapshot", %{})
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "2026-08-24T02:00:00Z"
      assert html =~ "point reading, not live"
    end
  end
end
