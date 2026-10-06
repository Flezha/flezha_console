defmodule FlezhaUi.Service.EventFeedTest do
  @moduledoc """
  The feed driven as it runs in production: a published stream operation held
  open over real `:erpc` against a controller stand-in, with only data crossing
  the wire.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.EventFeed
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  @tail {Flezha.Service.Observability, :tail}

  setup do
    {peer, node} = PeerNode.start_controller!("feed_peer")
    on_exit(fn -> PeerNode.stop(peer) end)
    %{peer: peer, node: node}
  end

  defp runner_signal(name) do
    %{
      kind: :event,
      source: :flezha_runner,
      name: name,
      metadata: %{namespace: "default", runner: "runner-a"}
    }
  end

  defp open_streams(node), do: FakeController.streams(node, @tail)

  defp open_tail!(token \\ nil, opts \\ []) do
    {:ok, feed} =
      EventFeed.start_link(
        [
          open: &NodeManager.observability_tail(:flezha_health, token, &1),
          to: {:send, self(), :tail}
        ] ++ opts
      )

    feed
  end

  describe "the runner feed" do
    test "tails the runner source", %{node: node} do
      start_supervised!(EventFeed.runners_child_spec())

      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)
      assert [[:flezha_runner, %{source: :ui}]] = FakeController.calls(node, @tail)
    end

    test "broadcasts a runner signal once on the UI's topic", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      start_supervised!(EventFeed.runners_child_spec())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, runner_signal(:runner_connected))

      assert_receive {:flezha_event, :runner_connected, {"default", "runner-a"}}
      refute_receive {:flezha_event, :runner_connected, _}, 100
    end

    test "broadcasts nothing for another signal on the same source", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      start_supervised!(EventFeed.runners_child_spec())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, runner_signal(:quota_refused))

      refute_receive {:flezha_event, _, _}, 200
    end

    test "re-opens an ended stream and holds exactly one", %{node: node} do
      start_supervised!(EventFeed.runners_child_spec())
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      for round <- 1..3 do
        FakeController.end_stream(node, @tail, {:ok, :window_closed})

        assert PeerNode.eventually(fn ->
                 length(FakeController.calls(node, @tail)) == round + 1 and
                   length(open_streams(node)) == 1
               end)
      end

      assert length(open_streams(node)) == 1
    end

    test "retries a refused tail", %{node: node} do
      FakeController.set(node, @tail, FakeController.error("observability.pubsub_disabled"))
      start_supervised!(EventFeed.runners_child_spec())

      assert PeerNode.eventually(fn -> length(FakeController.calls(node, @tail)) >= 2 end),
             "a refused tail was not retried"
    end
  end

  describe "a feed sending to its owner" do
    test "ends the controller's stream when its owner dies", %{node: node} do
      test = self()

      owner =
        spawn(fn ->
          send(test, {:feed, open_tail!()})
          Process.sleep(:infinity)
        end)

      assert_receive {:feed, feed}
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      Process.exit(owner, :kill)

      assert PeerNode.eventually(fn -> open_streams(node) == [] end),
             "the stream outlived the process that held it"

      refute Process.alive?(feed)
    end

    test "hands a refusal to its owner", %{node: node} do
      FakeController.set(node, @tail, FakeController.error("authz.principal_not_bound"))
      feed = open_tail!()

      assert_receive {:feed_error, :tail, %{code: "authz.principal_not_bound", class: :denied}}
      assert PeerNode.eventually(fn -> not Process.alive?(feed) end)
    end

    test "stopped under its tag, drops what it already sent", %{node: node} do
      feed = open_tail!()
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      send(self(), {:feed_event, :tail, :already_sent})
      send(self(), {:feed_reconnected, :tail})
      send(self(), {:feed_event, :other, :kept})

      EventFeed.stop(feed, :tail)

      refute_received {:feed_event, :tail, _}
      refute_received {:feed_reconnected, :tail}
      assert_received {:feed_event, :other, :kept}
      assert PeerNode.eventually(fn -> open_streams(node) == [] end)
    end

    test "delivers events, then the operation's own answer", %{node: node} do
      key = {Flezha.Service.Relay, :listen}

      {:ok, _feed} =
        EventFeed.start_link(
          open: &NodeManager.listen("default", "r1", :output, nil, &1),
          to: {:send, self(), :listen}
        )

      assert_receive {:feed_event, :listen, :attached}

      FakeController.emit(node, key, {:output, "hello", %{}})
      assert_receive {:feed_event, :listen, {:output, "hello", %{}}}

      FakeController.end_stream(node, key, {:ok, :done})
      assert_receive {:feed_ended, :listen, {:ok, :done}}
    end
  end

  describe "a retrying feed" do
    test "announces a re-opened stream once it is held", %{node: node} do
      open_tail!(nil, retry: true)
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      assert_receive {:feed_ended, :tail, {:ok, :window_closed}}
      assert_receive {:feed_reconnected, :tail}, 1_000
    end

    test "does not announce a re-open the controller refused", %{node: node} do
      open_tail!(nil, retry: true)
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      FakeController.set(node, @tail, FakeController.error("authz.principal_not_bound"))
      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      assert_receive {:feed_error, :tail, %{class: :denied}}, 1_000
      assert_receive {:feed_error, :tail, %{class: :denied}}, 1_000
      refute_received {:feed_reconnected, :tail}
    end
  end

  test "a missing controller is a feed error, not a crash", %{peer: peer} do
    PeerNode.stop(peer)
    feed = open_tail!()

    assert_receive {:feed_error, :tail, :node_not_connected}
    assert PeerNode.eventually(fn -> not Process.alive?(feed) end)
  end
end
