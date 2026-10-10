defmodule FlezhaUiWeb.ControllerStopDisconnectTest do
  @moduledoc """
  A stop whose controller goes away before it answers.

  On its own module because the disconnect has to be real —
  `NodeManager.connected_node/0` reads the VM's connection list — and a module
  gets its own peer, so cutting it loose cannot leak into another test.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller

  setup do
    System.put_env("FLEZHA_TOKEN", "flz_stop_#{System.unique_integer([:positive])}")
    on_exit(fn -> System.delete_env("FLEZHA_TOKEN") end)
    :ok
  end

  test "a node that disconnects after a stop was asked for is shown as stopped", %{
    conn: conn,
    node: node
  } do
    {:ok, view, _html} = live(conn, ~p"/controller")
    view |> element(~s([data-testid="stop-controller-btn"])) |> render_click()

    view
    |> form("#stop-controller-form", stop: %{"typed" => Atom.to_string(node)})
    |> render_change()

    view |> form("#stop-controller-form") |> render_submit()
    assert PeerNode.eventually(fn -> FakeController.streams(node, {Controller, :stop}) != [] end)

    Node.disconnect(node)

    assert PeerNode.eventually(fn ->
             view |> element(~s([data-testid="stop-state"])) |> render() =~
               "stopped (disconnected)"
           end)

    refute has_element?(view, ~s([data-testid="stop-failed"]))
  end
end
