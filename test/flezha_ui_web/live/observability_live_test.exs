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

  describe "listing" do
    test "sources and sinks are listed with their enabled state", %{conn: conn, node: node} do
      sources(node, [
        %{name: :flezha_data_plane, status: :active},
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

      assert html =~ ~s(data-testid="source-flezha_data_plane")
      assert html =~ ~s(data-testid="source-enabled-platform_authz")
      assert html =~ ~s(data-testid="sink-pubsub")
      assert html =~ "enabled"
      assert html =~ "disabled"
      # A sink has no enabled flag — a live pid is what "running" means.
      assert html =~ ~s(data-testid="sink-running-pubsub")
      assert html =~ "running"
      assert html =~ "not running"
    end

    test "a switched-off subsystem is stated as switched off", %{conn: conn, node: node} do
      FakeController.set(node, {Observability, :list_sources}, {:error, :observability_disabled})

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="observability-disabled")
      assert html =~ "switched off"
      refute html =~ ~s(data-testid="sources-panel")
    end

    test "a refusal names the reason rather than showing an empty list", %{conn: conn, node: node} do
      FakeController.set(
        node,
        {Observability, :list_sources},
        {:error, {:forbidden, :principal_not_bound}}
      )

      {:ok, _view, html} = live(conn, ~p"/observability")

      assert html =~ ~s(data-testid="runtime-error")
      assert html =~ "refused"
      assert html =~ "no flezha principal"
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
        {:error, {:forbidden, :role_insufficient}}
      )

      {:ok, view, _html} = live(conn, ~p"/observability")
      html = render_click(view, "toggle_source", %{"source" => "platform_authz"})

      assert html =~ "refused"
      assert html =~ "role does not grant"
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
    test "tailing subscribes through the relay, not a second mechanism", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :flezha_data_plane, status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      html = render_click(view, "start_tail", %{"source" => "flezha_data_plane"})

      assert html =~ ~s(data-testid="tail-panel")

      # The relay — running on the controller — is what registered.
      assert [[:flezha_data_plane, %{source: :ui}]] =
               FakeController.calls(node, {Observability, :tail})
    end

    test "signals arriving from the relay render", %{conn: conn, node: node} do
      sources(node, [%{name: :flezha_data_plane, status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_data_plane"})

      send(
        view.pid,
        {:relay_event, :observability_tail,
         {:flezha_signal, %{ts: 42, source: :flezha_data_plane, name: :stall, measurements: %{}}}}
      )

      html = render(view)

      assert html =~ "stall"
      assert html =~ "42"
    end

    test "a disabled pubsub sink states that live tailing is unavailable", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :flezha_data_plane, status: :active}])
      FakeController.set(node, {Observability, :tail}, {:error, :pubsub_sink_disabled})

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_data_plane"})

      # The refusal comes back from the relay on the controller, so it arrives
      # after the click returns.
      assert PeerNode.eventually(fn ->
               render(view) =~ ~s(data-testid="pubsub-sink-disabled")
             end)

      assert render(view) =~ "pubsub sink is disabled"
    end

    test "a reconnected relay is announced rather than silently resuming", %{
      conn: conn,
      node: node
    } do
      sources(node, [%{name: :flezha_data_plane, status: :active}])

      {:ok, view, _html} = live(conn, ~p"/observability")
      render_click(view, "start_tail", %{"source" => "flezha_data_plane"})
      send(view.pid, {:relay_reconnected, self()})

      assert render(view) =~ ~s(data-testid="tail-reconnected")
    end
  end
end
