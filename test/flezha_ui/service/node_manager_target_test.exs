defmodule FlezhaUi.Service.NodeManagerTargetTest do
  @moduledoc """
  The console calls only the controller `FLEZHA_NODE` names, whatever else is
  connected to it.

  On its own module because it connects and disconnects two peers. Both are
  controlled over stdio, so each outlives its distribution link being cut.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.NodeManager
  alias FlezhaUi.TestEnv

  @moduletag :distributed

  @posture {Flezha.AuthZ, :enforcement_posture}

  setup do
    configured = start_peer("target_configured", :enforced)
    other = start_peer("target_other", :bootstrap_pending)

    # Starting a peer drops every other link, and names the newest as the
    # controller; this test names the first one and links both.
    TestEnv.put_system("FLEZHA_NODE", Atom.to_string(configured))
    true = Node.connect(configured)

    %{configured: configured, other: other}
  end

  test "with another node connected as well, only the configured one is called", %{
    configured: configured,
    other: other
  } do
    assert other in Node.list(:connected)
    assert NodeManager.connected_node() == configured

    assert NodeManager.enforcement_posture() == :enforced
    assert FakeController.calls(configured, @posture) == [[]]
    assert FakeController.calls(other, @posture) == []
  end

  test "with only another node connected, nothing is called", %{
    configured: configured,
    other: other
  } do
    Node.disconnect(configured)
    assert other in Node.list(:connected)

    assert NodeManager.connected_node() == nil

    assert NodeManager.enforcement_posture() == {:error, :node_not_connected}

    assert FakeController.calls(other, @posture) == []
  end

  test "the configured node is called again once it reconnects", %{configured: configured} do
    Node.disconnect(configured)
    assert NodeManager.connected_node() == nil

    true = Node.connect(configured)

    assert NodeManager.connected_node() == configured
    assert NodeManager.enforcement_posture() == :enforced
    assert FakeController.calls(configured, @posture) == [[]]
  end

  defp start_peer(prefix, posture) do
    {peer, node} = PeerNode.start_controller!(prefix, %{connection: :standard_io})
    on_exit(fn -> PeerNode.stop(peer) end)
    FakeController.set(node, @posture, posture)
    node
  end
end
