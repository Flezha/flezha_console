defmodule FlezhaUi.Service.NodeManagerStopTest do
  @moduledoc """
  A controller stop goes to exactly the node the operator named, never to
  another that has since become the connected one.
  """

  use FlezhaUiWeb.LiveCase

  alias Flezha.Service.Controller

  test "a node that is no longer connected is not stopped", %{node: node} do
    assert {:error, :node_not_connected} =
             NodeManager.stop_controller(:flezha@gone, [], nil, self())

    assert FakeController.calls(node, {Controller, :stop}) == []
  end

  test "the named connected node is the one asked to stop", %{node: node} do
    assert {:ok, request} = NodeManager.stop_controller(node, [force: true], nil, self())
    assert request.node == node
    assert PeerNode.eventually(fn -> FakeController.streams(node, {Controller, :stop}) != [] end)
    FakeController.end_stream(node, {Controller, :stop}, {:ok, %{outcome: :forced}})
  end
end
