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

  describe "the durability shipper" do
    test "a shipping remote tier lists each reference with its figures", %{conn: conn, node: node} do
      with_status(node, %{durability_backend: :s3, durability_posture: :remote_tier})

      FakeController.set(
        node,
        {Controller, :durability_status},
        {:ok,
         [
           %{
             ref: {:cell, "default", "orders"},
             last_shipped_ms: 1_760_000_000_000,
             pending_since_ms: nil,
             failures: 3,
             retry_after_ms: nil,
             superseded_by: nil,
             last_error: :timeout
           }
         ]}
      )

      {:ok, view, _html} = live(conn, ~p"/controller")
      row = view |> element(~s([data-testid="shipper-row"])) |> render()

      assert row =~ "orders"
      assert row =~ "2025-10-09"
      assert row =~ "3"
      assert row =~ ":timeout"
    end

    test "a local-only controller states the shipper does not apply", %{conn: conn, node: node} do
      with_status(node, %{durability_posture: :local_only})

      {:ok, view, _html} = live(conn, ~p"/controller")

      assert has_element?(view, ~s([data-testid="shipper-not-applicable"]))
      refute has_element?(view, ~s([data-testid="shipper-table"]))
    end

    test "a failed shipper read is stated and posture and breaches still render", %{
      conn: conn,
      node: node
    } do
      with_status(node, %{durability_backend: :s3, durability_posture: :remote_tier})

      FakeController.set(
        node,
        {Controller, :durability_status},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/controller")

      assert view |> element(~s([data-testid="shipper-status"])) |> render() =~
               "authz.role_insufficient"

      assert view |> element(~s([data-testid="durability-posture"])) |> render() =~ "remote_tier"
    end
  end

  describe "stopping the controller" do
    @admin %{principal: "admin@_system", namespace: "_system", role: :admin}

    setup %{node: node, user: user}, do: enforce_operations(node, user, @admin)

    defp grant(node, operations), do: grant_operations(node, @admin, operations)

    defp open_stop(conn, node) do
      grant(node, ["Controller.status", "Controller.stop"])
      {:ok, view, _html} = live(conn, ~p"/controller")
      view |> element(~s([data-testid="stop-controller-btn"])) |> render_click()
      view
    end

    defp typed(view, text, extra \\ %{}) do
      view
      |> form("#stop-controller-form", stop: Map.merge(%{"typed" => text}, extra))
      |> render_change()
    end

    test "the control is absent when the role does not grant it", %{conn: conn, node: node} do
      grant(node, ["Controller.status"])
      {:ok, view, _html} = live(conn, ~p"/controller")

      refute has_element?(view, ~s([data-testid="stop-controller-btn"]))
    end

    test "confirm stays disabled until the node name is typed", %{conn: conn, node: node} do
      view = open_stop(conn, node)
      node_name = Atom.to_string(node)

      assert has_element?(view, ~s([data-testid="stop-confirm"][disabled]))
      typed(view, "not-the-node")
      assert has_element?(view, ~s([data-testid="stop-confirm"][disabled]))

      render_submit(view, "confirm_stop", %{})
      assert FakeController.calls(node, {Controller, :stop}) == []

      typed(view, node_name)
      refute has_element?(view, ~s([data-testid="stop-confirm"][disabled]))
    end

    test "cancelling calls nothing", %{conn: conn, node: node} do
      view = open_stop(conn, node)
      view |> element(~s([data-testid="stop-cancel"])) |> render_click()

      refute has_element?(view, ~s([data-testid="stop-controller-modal"]))
      assert FakeController.calls(node, {Controller, :stop}) == []
    end

    test "a confirmed stop streams its phases and follows the shutdown status", %{
      conn: conn,
      node: node
    } do
      view = open_stop(conn, node)
      typed(view, Atom.to_string(node), %{"timeout_s" => "30"})
      view |> form("#stop-controller-form") |> render_submit()

      assert PeerNode.eventually(fn ->
               FakeController.streams(node, {Controller, :stop}) != []
             end)

      assert [[[timeout_ms: 30_000], _ctx]] = FakeController.calls(node, {Controller, :stop})

      FakeController.emit(
        node,
        {Controller, :stop},
        {:progress, [:flezha, :shutdown, :phase_started], %{}, %{phase: :drain}}
      )

      assert PeerNode.eventually(fn -> render(view) =~ "phase_started drain" end)
      assert view |> element(~s([data-testid="stop-phase"])) |> render() =~ "drain"

      FakeController.set(
        node,
        {Controller, :shutdown_status},
        {:ok, %{shutdown_in_progress: true, shutdown_phase: :finalise}}
      )

      send(view.pid, :refresh)
      assert view |> element(~s([data-testid="stop-phase"])) |> render() =~ "finalise"

      FakeController.end_stream(node, {Controller, :stop}, {:ok, %{outcome: :clean}})

      assert PeerNode.eventually(fn ->
               view |> element(~s([data-testid="stop-state"])) |> render() =~ "stopped (clean)"
             end)
    end

    test "a forced stop is asked for with force", %{conn: conn, node: node} do
      view = open_stop(conn, node)
      typed(view, Atom.to_string(node), %{"force" => "true"})
      view |> form("#stop-controller-form") |> render_submit()

      assert PeerNode.eventually(fn ->
               FakeController.streams(node, {Controller, :stop}) != []
             end)

      assert [[[force: true], _ctx]] = FakeController.calls(node, {Controller, :stop})
      FakeController.end_stream(node, {Controller, :stop}, {:ok, %{outcome: :forced}})
    end

    test "a timeout that is not a whole number of seconds keeps confirm disabled", %{
      conn: conn,
      node: node
    } do
      view = open_stop(conn, node)
      typed(view, Atom.to_string(node), %{"timeout_s" => "1.5"})

      assert has_element?(view, ~s([data-testid="stop-confirm"][disabled]))
      render_submit(view, "confirm_stop", %{})
      assert FakeController.calls(node, {Controller, :stop}) == []
    end

    test "reopening the dialog during a stop keeps the stop's progress", %{
      conn: conn,
      node: node
    } do
      view = open_stop(conn, node)
      typed(view, Atom.to_string(node))
      view |> form("#stop-controller-form") |> render_submit()

      assert PeerNode.eventually(fn ->
               FakeController.streams(node, {Controller, :stop}) != []
             end)

      render_click(view, "open_stop", %{})
      assert has_element?(view, ~s([data-testid="stop-state"]))

      FakeController.end_stream(node, {Controller, :stop}, {:ok, %{outcome: :clean}})

      assert PeerNode.eventually(fn ->
               view |> element(~s([data-testid="stop-state"])) |> render() =~ "stopped (clean)"
             end)
    end

    test "Stop is not offered while a shutdown is already under way", %{conn: conn, node: node} do
      with_status(node, %{shutdown_in_progress: true, shutdown_phase: :drain})
      grant(node, ["Controller.status", "Controller.stop"])
      {:ok, view, _html} = live(conn, ~p"/controller")

      refute has_element?(view, ~s([data-testid="stop-controller-btn"]))
    end

    test "a refused stop is shown with its code and the controller keeps running", %{
      conn: conn,
      node: node
    } do
      FakeController.set(
        node,
        {Controller, :stop},
        FakeController.error("authz.role_insufficient")
      )

      view = open_stop(conn, node)
      typed(view, Atom.to_string(node))
      view |> form("#stop-controller-form") |> render_submit()

      assert PeerNode.eventually(fn ->
               has_element?(view, ~s([data-testid="stop-failed"])) and
                 render(view) =~ "authz.role_insufficient"
             end)
    end
  end
end
