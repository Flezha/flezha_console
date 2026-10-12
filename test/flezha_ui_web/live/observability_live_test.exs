defmodule FlezhaUiWeb.ObservabilityLiveTest do
  @moduledoc """
  Sources, sinks, toggles and the live tail.

  A disabled subsystem, a refused toggle and a disabled pubsub sink are the
  states this screen exists to explain, and none of them can be produced on a
  working dev controller.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Observability

  defp sources(node, list) do
    FakeController.set(node, {Observability, :list_sources}, {:ok, list})
  end

  describe "finding a source" do
    test "a name narrows each area's sources, and the area still counts them all", %{
      conn: conn,
      node: node
    } do
      sources(node, [
        %{name: :flezha_health, status: :active},
        %{name: :platform_authz, status: :disabled}
      ])

      {:ok, view, _html} = live(conn, ~p"/observability")

      html =
        view
        |> element(~s([data-testid="source-filter-form"]))
        |> render_change(%{"q" => "authz"})

      assert html =~ ~s(data-testid="source-filter")
      assert html =~ ~s(data-testid="source-platform_authz")
      refute html =~ ~s(data-testid="source-flezha_health")
      assert html =~ ~s(data-testid="source-group-relay")

      assert view |> element(~s([data-testid="source-group-count-relay"])) |> render() =~
               "1 of 1 on"
    end
  end

  describe "listing" do
    test "sources and sinks are listed with their enabled state", %{conn: conn, node: node} do
      sources(node, [
        %{name: :flezha_health, status: :active},
        %{name: :platform_authz, status: :disabled}
      ])

      FakeController.set(
        node,
        {Observability, :list_sinks},
        {:ok,
         [
           %{name: :pubsub, module: Sink, pid: self()},
           %{name: :ring_buffer, module: Sink, pid: nil}
         ]}
      )

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="source-flezha_health")
      assert html =~ ~s(data-testid="source-enabled-platform_authz")
      assert html =~ ~s(data-testid="sink-pubsub")
      assert html =~ ~r/data-testid="source-enabled-flezha_health"[^>]*data-enabled="true"/
      assert html =~ ~r/data-testid="source-enabled-platform_authz"[^>]*data-enabled="false"/
      # A sink has no enabled flag — a live pid is what "running" means.
      assert html =~ ~s(data-testid="sink-running-pubsub")
      assert html =~ "Running"
      assert html =~ "Not running"
    end

    test "a switched-off subsystem is stated as switched off", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Observability, :list_sources},
        FakeController.error("observability.disabled")
      )

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="observability-disabled")
      assert html =~ "switched off"
      refute html =~ ~s(data-testid="sources-panel")
    end

    test "a refusal names the reason rather than showing an empty list", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Observability, :list_sources},
        FakeController.error("authz.principal_not_bound")
      )

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "refused"
      assert html =~ "authz.principal_not_bound"
    end
  end

  describe "toggling" do
    test "enabling a disabled source calls enable_source with the UI's context", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :platform_authz, status: :disabled}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "toggle_source", %{"source" => "platform_authz"})

      assert [[:platform_authz, %{source: :ui}]] =
               FakeController.calls(node, {Observability, :enable_source})
    end

    test "disabling an enabled source calls disable_source", %{conn: conn, node: node} do
      sources(node, [%{name: :platform_authz, status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "toggle_source", %{"source" => "platform_authz"})

      assert [[:platform_authz, _ctx]] =
               FakeController.calls(node, {Observability, :disable_source})
    end

    test "a refused toggle is shown and the source is unchanged", %{conn: conn, node: node} do
      sources(node, [%{name: :platform_authz, status: :disabled}])

      FakeController.set(
        node,
        {Observability, :enable_source},
        FakeController.error("authz.role_insufficient")
      )

      {:ok, view, _html} = live(conn, ~p"/observability")
      html = render_click(view, "toggle_source", %{"source" => "platform_authz"})

      assert html =~ "refused"
      assert html =~ "authz.role_insufficient"
      # The listing still reports it disabled.
      assert html =~ ~s(data-testid="source-enabled-platform_authz")
    end

    test "a source the listing does not name is never toggled", %{conn: conn, node: node} do
      sources(node, [%{name: :platform_authz, status: :disabled}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "toggle_source", %{"source" => "not_a_source"})

      assert FakeController.calls(node, {Observability, :enable_source}) == []
    end
  end

  describe "the live tail" do
    @tail {Observability, :tail}

    setup %{node: node} do
      sources(node, [%{name: :flezha_health, status: :active}])
      :ok
    end

    defp start_tail(conn, node) do
      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_health"})
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) != [] end)
      view
    end

    test "tailing takes the published tail with the UI's context", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      assert render(view) =~ ~s(data-testid="tail-panel")

      assert [[:flezha_health, %{source: :ui, emit: emit}]] =
               FakeController.calls(node, @tail)

      assert is_pid(emit)
    end

    test "signals the controller forwards render", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.emit(node, @tail, %{
        kind: :event,
        ts: 42,
        source: :flezha_health,
        name: :stall,
        measurements: %{},
        metadata: %{}
      })

      assert PeerNode.eventually(fn -> render(view) =~ "stall" end)
      assert render(view) =~ "42"
    end

    # Core sends its `%Flezha.Observability.Signal{}` struct, whose module this
    # node does not have; a template reading it by key must not crash on it.
    test "a signal arriving as the controller's struct renders", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.emit(node, @tail, %{
        __struct__: Flezha.Observability.Signal,
        kind: :event,
        ts: 77,
        source: :flezha_runner,
        name: :runner_disconnected,
        measurements: %{count: 1},
        metadata: %{namespace: "default", runner: "runner-a"}
      })

      assert PeerNode.eventually(fn -> render(view) =~ "runner_disconnected" end)
      assert Process.alive?(view.pid)
    end

    test "stopping the tail ends the controller's stream", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      render_click(view, "stop_tail", %{})

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
    end

    test "leaving the screen ends the controller's stream", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      Process.flag(:trap_exit, true)
      Process.exit(view.pid, :kill)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [] end)
    end

    test "a disabled pubsub sink states that live tailing is unavailable", %{
      conn: conn,
      node: node
    } do
      FakeController.set(node, @tail, FakeController.error("observability.pubsub_disabled"))

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_health"})

      # The refusal is the stream's answer, so it arrives after the click returns.
      assert PeerNode.eventually(fn ->
               render(view) =~ ~s(data-testid="pubsub-sink-disabled")
             end)

      assert render(view) =~ "pubsub sink is disabled"
    end

    test "another refusal states its code", %{conn: conn, node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.role_insufficient"))

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_health"})

      assert PeerNode.eventually(fn -> render(view) =~ "authz.role_insufficient" end)
      refute render(view) =~ ~s(data-testid="pubsub-sink-disabled")
    end

    test "a stream that ended and was re-opened is announced", %{conn: conn, node: node} do
      view = start_tail(conn, node)

      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      assert PeerNode.eventually(fn -> render(view) =~ ~s(data-testid="tail-reconnected") end)
      assert length(FakeController.calls(node, @tail)) == 2
    end
  end
end
