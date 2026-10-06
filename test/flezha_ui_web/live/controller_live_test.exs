defmodule FlezhaUiWeb.ControllerLiveTest do
  @moduledoc """
  The controller-health screen.

  `local_only`, an RPO breach, a shutdown in progress and a refused status read
  are all states a healthy dev controller will not hold, so they are produced
  here rather than driven in a browser.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.AuthZ
  alias Flezha.Service.Controller

  setup do
    # Posture and identity are cached per token for a refresh tick, so a token
    # per test keeps one test's posture out of the next one's cache.
    System.put_env("FLEZHA_TOKEN", "flz_controller_#{System.unique_integer([:positive])}")
    on_exit(fn -> System.delete_env("FLEZHA_TOKEN") end)
    :ok
  end

  # `Controller.status/1` answers the durability posture and the shutdown state
  # in one map.
  defp with_status(node, overrides) do
    status =
      Map.merge(
        %{
          shutdown_in_progress: false,
          shutdown_phase: nil,
          signal_handler_status: :installed,
          graceful_shutdown_enabled: true,
          graceful_shutdown_timeout_ms: 60_000,
          durability_backend: :none,
          durability_posture: :local_only,
          durability_rpo_breaches: 0,
          durability_levels: %{},
          durability_superseded: 0,
          node: :"flezha@node-a",
          monotonic_us: 1
        },
        overrides
      )

    FakeController.set(node, {Controller, :status}, {:ok, status})
  end

  defp snapshot(overrides) do
    Map.merge(
      %{
        captured_at: "2026-08-24T02:00:00Z",
        node: "flezha@controller",
        erlang_memory: %{},
        top_processes: [],
        ets_tables: [],
        dets_files: [],
        recon_alloc_allocated_types: []
      },
      overrides
    )
  end

  describe "durability" do
    test "a remote tier shows backend, breaches and superseded shipments", %{
      conn: conn,
      node: node
    } do
      with_status(node, %{
        durability_backend: :s3,
        durability_posture: :remote_tier,
        durability_rpo_breaches: 2,
        durability_superseded: 1
      })

      {:ok, view, html} = live(conn, ~p"/controller")

      assert html =~ "s3"
      assert html =~ "remote_tier"
      assert view |> element(~s([data-testid="durability-superseded"])) |> render() =~ "1"
      assert view |> element(~s([data-testid="durability-breaches"])) |> render() =~ "2"
      refute html =~ ~s(data-testid="durability-local-only")
    end

    test "local_only is stated as a posture, not an alarm", %{conn: conn, node: node} do
      with_status(node, %{durability_posture: :local_only})

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="durability-local-only")
      assert html =~ "exactly one"
    end

    test "breached references are listed with how far past target they are", %{
      conn: conn,
      node: node
    } do
      with_status(node, %{durability_posture: :remote_tier})

      FakeController.set(
        node,
        {Controller, :durability_breaches},
        {:ok, [%{ref: "orders/p0", lag_ms: 90_000, pending_since_ms: 1}]}
      )

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ ~s(data-testid="durability-breach-table")
      assert html =~ "orders/p0"
      assert html =~ "1m 30s"
    end

    test "a refused status read is stated with its code and the rest renders", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Controller, :status},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ "authz.role_insufficient"
      assert html =~ ~s(data-testid="shutdown-unavailable")
      assert html =~ ~s(data-testid="boot-panel")
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
      with_status(node, %{shutdown_in_progress: true, shutdown_phase: :draining})

      {:ok, _view, html} = live(conn, ~p"/controller")

      assert html =~ "draining"
    end

    test "boot status states the readiness verdict and each namespace's recovery", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Controller, :boot_status},
        {:ok,
         %{
           readiness: :ready,
           preconditions: [],
           namespaces: [
             %{namespace: "default", recovery_state: :normal, registry_rows: 3},
             %{namespace: "cold", recovery_state: :unknown, registry_rows: 0}
           ]
         }}
      )

      {:ok, view, _html} = live(conn, ~p"/controller")

      assert view |> element(~s([data-testid="boot-readiness"])) |> render() =~ "ready"
      assert view |> element(~s([data-testid="boot-default"])) |> render() =~ "normal"
      assert view |> element(~s([data-testid="boot-cold"])) |> render() =~ "unknown"
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

      assert FakeController.calls(node, {Controller, :mem_top}) == []
    end

    test "an operator request renders the hot spots with their capture time", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Controller, :mem_top},
        {:ok,
         snapshot(%{
           erlang_memory: %{total: 2048},
           top_processes: [%{name: :busy_worker, memory: 1024}]
         })}
      )

      {:ok, view, _html} = live(conn, ~p"/controller")
      html = render_click(view, "memory_snapshot", %{})

      assert html =~ ~s(data-testid="memory-captured-at")
      assert html =~ "2026-08-24T02:00:00Z"
      assert html =~ ~s(data-testid="memory-top-processes")
      assert html =~ "busy_worker"
    end

    test "a snapshot stays labelled with its capture time across later ticks", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, {Controller, :mem_top}, {:ok, snapshot(%{})})

      {:ok, view, _html} = live(conn, ~p"/controller")
      render_click(view, "memory_snapshot", %{})
      send(view.pid, :refresh)
      html = render(view)

      assert html =~ "2026-08-24T02:00:00Z"
      assert html =~ "point reading, not live"
    end

    test "a refused snapshot is stated and nothing is rendered", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Controller, :mem_top},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/controller")
      html = render_click(view, "memory_snapshot", %{})

      assert html =~ "authz.role_insufficient"
      refute html =~ ~s(data-testid="memory-captured-at")
    end
  end
end
