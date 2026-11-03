defmodule FlezhaConsole.Service.PeerLossTest do
  @moduledoc """
  What the seam and the feed answer when the controller goes away: before a
  call, in the middle of one, and while a stream is held.

  Each test stops its listener, so each serves its own rather than sharing one
  per module as the other channel-backed modules do.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.EventFeed
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel

  @tail {Flezha.Service.Observability, :tail}
  @token "flzt_t"

  setup do
    %{node: FakeListener.start!()}
  end

  # Linked, so a feed that crashed would fail the test rather than vanish.
  defp tail_feed(opts \\ []) do
    {:ok, feed} =
      EventFeed.start_link(
        [
          open: &NodeManager.observability_tail(:flezha_health, @token, &1),
          to: {:send, self(), :tail}
        ] ++ opts
      )

    feed
  end

  describe "a controller already gone" do
    test "a feed answers an error rather than crashing", %{node: node} do
      FakeListener.stop(node)
      feed = tail_feed()

      assert_receive {:feed_error, :tail, :node_not_connected}
      assert FakeController.eventually(fn -> not Process.alive?(feed) end)
    end

    test "a transport failure is not an answer about the token", %{node: node} do
      token = "flzt_test_#{System.unique_integer([:positive])}"
      FakeListener.stop(node)

      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
      # Nothing was cached, so a reachable controller answers for itself.
      assert {:error, :node_not_connected} = NodeManager.verify_token(token)
    end

    test "an unreachable controller is reported with no posture, not as open", %{node: node} do
      FakeListener.stop(node)

      assert %{posture: nil, reason: :node_not_connected} = NodeManager.authz_status(@token)
    end
  end

  describe "a controller lost mid-call" do
    test "a call in flight answers node_not_connected", %{node: node} do
      FakeController.close_gate(node, :held)
      FakeController.set(node, {Flezha.Service.Relay, :stop}, {:gated, :held, {:ok, %{}}})
      call = Task.async(fn -> NodeManager.stop_relay("default", "r1", @token) end)
      assert_receive {:gate_reached, :held}

      FakeListener.stop(node)

      assert Task.await(call) == {:error, :node_not_connected}
    end

    test "a held stream ends as node_not_connected", %{node: node} do
      assert {:ok, request} = NodeManager.observability_tail(:flezha_runner, @token, self())
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      FakeListener.stop(node)

      assert {:ended, {:error, :node_not_connected}} = FakeController.await_stream_end(request)
    end
  end

  describe "a feed whose controller goes down" do
    test "retries and holds one stream on the controller that replaces it", %{node: node} do
      feed = tail_feed(retry: true)
      assert FakeController.eventually(fn -> FakeController.streams(node, @tail) != [] end)

      FakeListener.stop(node)
      assert_receive {:feed_error, :tail, :node_not_connected}

      successor = FakeListener.start!()

      assert FakeController.eventually(fn -> FakeController.streams(successor, @tail) != [] end)
      assert FakeController.eventually(fn -> not :sys.get_state(feed).reopening? end)
      assert_received {:feed_reconnected, :tail}
      assert length(FakeController.streams(successor, @tail)) == 1
    end
  end
end
