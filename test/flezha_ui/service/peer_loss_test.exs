defmodule FlezhaUi.Service.PeerLossTest do
  @moduledoc """
  What the seam and the feed answer when the controller goes away: before a
  call, in the middle of one, and while a stream is held.

  Each test stops its peer, so each boots its own rather than sharing one per
  module as the other peer-backed modules do.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  @tail {Flezha.Service.Observability, :tail}

  setup do
    PeerNode.setup_controller("loss_peer")
  end

  # Linked, so a feed that crashed would fail the test rather than vanish.
  defp tail_feed(opts \\ []) do
    {:ok, feed} =
      EventFeed.start_link(
        [
          open: &NodeManager.observability_tail(:flezha_health, nil, &1),
          to: {:send, self(), :tail}
        ] ++ opts
      )

    feed
  end

  describe "a controller already gone" do
    test "a feed answers an error rather than crashing", %{peer: peer} do
      PeerNode.stop(peer)
      feed = tail_feed()

      assert_receive {:feed_error, :tail, :node_not_connected}
      assert PeerNode.eventually(fn -> not Process.alive?(feed) end)
    end

    test "a transport failure is not an answer about the token", %{peer: peer} do
      token = "flzt_test_#{System.unique_integer([:positive])}"
      PeerNode.stop(peer)

      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
      # Nothing was cached, so a reachable controller answers for itself.
      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
    end

    test "an unreachable controller is not reported as open", %{peer: peer} do
      PeerNode.stop(peer)

      assert {:error, :node_not_connected} = NodeManager.enforcement_posture()
    end
  end

  describe "a controller lost mid-call" do
    test "a call in flight answers node_not_connected", %{peer: peer, node: node} do
      # A stream operation holds its call open until its emit pid exits, which
      # makes it a call that is observably in flight.
      call =
        Task.async(fn ->
          NodeManager.erpc_call(Flezha.Service.Observability, :tail, [
            :flezha_runner,
            %{source: :ui, emit: self()}
          ])
        end)

      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [call.pid] end)

      PeerNode.stop(peer)

      assert Task.await(call) == {:error, :node_not_connected}
    end

    test "a held stream ends as node_not_connected", %{peer: peer, node: node} do
      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, nil, self())
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [self()] end)

      PeerNode.stop(peer)

      assert {:ended, {:error, :node_not_connected}} = await_end(request)
    end
  end

  describe "a feed whose controller goes down" do
    test "retries once and holds one stream on the controller that replaces it", %{
      peer: peer,
      node: node
    } do
      feed = tail_feed(retry: true)
      assert PeerNode.eventually(fn -> FakeController.streams(node, @tail) == [feed] end)

      # Held still, so both the nodedown and the stream's own answer are
      # waiting for it once a new controller is up.
      :sys.suspend(feed)
      PeerNode.stop(peer)
      %{node: successor} = PeerNode.setup_controller("loss_successor")
      :sys.resume(feed)
      :sys.get_state(feed)

      assert_received {:feed_error, :tail, :node_not_connected}
      refute_received {:feed_error, :tail, _}

      assert PeerNode.eventually(fn ->
               match?(%{request: %{node: ^successor}, reopening?: false}, :sys.get_state(feed))
             end)

      assert_received {:feed_reconnected, :tail}
      assert FakeController.streams(successor, @tail) == [feed]
      assert length(FakeController.calls(successor, @tail)) == 1
    end
  end

  defp await_end(request) do
    assert_receive message

    case NodeManager.stream_result(message, request) do
      :no_response -> await_end(request)
      ended -> ended
    end
  end
end
