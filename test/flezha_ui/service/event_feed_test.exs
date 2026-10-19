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

  setup_all do
    PeerNode.setup_controller("feed_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
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

  defp runner_feed, do: feed_spec(:flezha_runner)

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
      start_supervised!(runner_feed())

      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)
      assert [[:flezha_runner, %{source: :ui}]] = FakeController.calls(node, @tail)
    end

    test "broadcasts a runner signal once on the UI's topic", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      feed = start_supervised!(runner_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, runner_signal(:runner_connected))

      assert_receive {:flezha_event, :runner_connected, {"default", "runner-a"}}
      :sys.get_state(feed)
      refute_received {:flezha_event, :runner_connected, _}
    end

    test "broadcasts a drop and a readmit by the runner's stable id", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      start_supervised!(runner_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      for name <- [:runner_dropped, :runner_readmitted] do
        FakeController.emit(node, @tail, %{
          kind: :event,
          source: :flezha_runner,
          name: name,
          metadata: %{namespace: "default", stable_id: "stable-a"}
        })

        assert_receive {:flezha_event, ^name, {"default", "stable-a"}}
      end
    end

    test "a dropped process's refused retry is not broadcast", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      feed = start_supervised!(runner_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, runner_signal(:runner_drop_refused))

      :sys.get_state(feed)
      refute_received {:flezha_event, _, _}
    end

    test "broadcasts nothing for another signal on the same source", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      feed = start_supervised!(runner_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, runner_signal(:quota_refused))

      :sys.get_state(feed)
      refute_received {:flezha_event, _, _}
    end

    test "re-opens an ended stream and holds exactly one", %{node: node} do
      start_supervised!(runner_feed())
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
      start_supervised!(runner_feed())

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
          receive do: (:never -> :ok)
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
      EventFeed.listen("default", "r1", :output, nil, :listen)

      assert_receive {:feed_event, :listen, :attached}

      FakeController.emit(node, key, {:output, "hello", %{}})
      assert_receive {:feed_event, :listen, {:output, "hello", %{}}}

      FakeController.end_stream(node, key, {:ok, :done})
      assert_receive {:feed_ended, :listen, {:ok, :done}}
    end

    test "a calls listen asks the controller for the calls direction", %{node: node} do
      key = {Flezha.Service.Relay, :listen}

      EventFeed.listen("default", "r1", :calls, nil, :listen)

      assert_receive {:feed_event, :listen, :attached}
      assert [["default", "r1", :calls, [], %{source: :ui}]] = FakeController.calls(node, key)

      FakeController.emit(node, key, {:call, "ping", %{"flz.call_id" => "c1"}})
      assert_receive {:feed_event, :listen, {:call, "ping", %{"flz.call_id" => "c1"}}}
    end
  end

  describe "a retrying feed" do
    test "announces a re-opened stream once it is held", %{node: node} do
      feed = open_tail!(nil, retry: true)
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      assert_receive {:feed_ended, :tail, {:ok, :window_closed}}
      assert PeerNode.eventually(fn -> held?(feed) end)
      assert_received {:feed_reconnected, :tail}
    end

    test "does not announce a re-open the controller refused", %{node: node} do
      open_tail!(nil, retry: true)
      assert PeerNode.eventually(fn -> length(open_streams(node)) == 1 end)

      FakeController.set(node, @tail, FakeController.error("authz.principal_not_bound"))
      FakeController.end_stream(node, @tail, {:ok, :window_closed})

      # The fourth open follows the third's refusal, so two refusals were sent.
      assert PeerNode.eventually(fn -> length(FakeController.calls(node, @tail)) >= 4 end)
      assert_received {:feed_error, :tail, %{class: :denied}}
      assert_received {:feed_error, :tail, %{class: :denied}}
      refute_received {:feed_reconnected, :tail}
    end
  end

  describe "the relay lifecycle feed" do
    test "tails the relay source and broadcasts each lifecycle signal as one entry", %{
      node: node
    } do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic(:flezha_relay))
      feed = start_supervised!(relay_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)
      assert [[:flezha_relay, %{source: :ui}]] = FakeController.calls(node, @tail)

      FakeController.emit(node, @tail, %{
        name: :relay_exited,
        metadata: %{namespace: "default", relay_id: "r1", runner_id: "runner-a", reason: "lost"}
      })

      assert_receive {:flezha_event, :relay_exited,
                      {"default",
                       %{event: :relay_exited, relay: "r1", runner: "runner-a", reason: "lost"}}}

      FakeController.emit(node, @tail, %{name: :relay_halted_total, metadata: %{}})
      :sys.get_state(feed)
      refute_received {:flezha_event, _, _}
    end

    test "announces a refusal on the topic, and its clearing once held", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic(:flezha_relay))
      FakeController.set(node, @tail, FakeController.error("observability.pubsub_disabled"))
      start_supervised!(relay_feed())
      name = EventFeed.signal_feed(:flezha_relay)

      assert_receive {:flezha_feed, ^name, %{code: "observability.pubsub_disabled"}}
      assert %{code: "observability.pubsub_disabled"} = EventFeed.error(name)

      FakeController.reset(node)

      assert PeerNode.eventually(fn -> held?(name) end)
      assert_received {:flezha_feed, ^name, nil}
      assert EventFeed.error(name) == nil
    end

    test "a feed that does not run reports no error" do
      assert EventFeed.error(EventFeed.signal_feed(:flezha_relay)) == nil
    end

    # Every refreshing screen subscribes to the runner topic and handles only
    # runner events there, so nothing else may reach it.
    test "neither its signals nor its refusals reach the runner topic", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      feed = start_supervised!(relay_feed())
      assert PeerNode.eventually(fn -> open_streams(node) != [] end)

      FakeController.emit(node, @tail, %{
        name: :relay_started,
        metadata: %{namespace: "default", relay: "r1", factory: "f"}
      })

      :sys.get_state(feed)

      FakeController.end_stream(
        node,
        @tail,
        FakeController.error("observability.pubsub_disabled")
      )

      # Set in the same step that announces the refusal.
      assert PeerNode.eventually(fn -> EventFeed.error(feed) != nil end)
      refute_received {:flezha_event, _, _}
      refute_received {:flezha_feed, _, _}
    end

    test "the runner feed's refusals are not announced", %{node: node} do
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventFeed.topic())
      FakeController.set(node, @tail, FakeController.error("observability.pubsub_disabled"))
      start_supervised!(runner_feed())

      # The second open follows the first refusal, which is when it would
      # have been announced.
      assert PeerNode.eventually(fn -> length(FakeController.calls(node, @tail)) >= 2 end)
      refute_received {:flezha_feed, _, _}
    end
  end

  defp relay_feed, do: feed_spec(:flezha_relay)

  # Holding a stream it re-opened, and has announced so.
  defp held?(feed), do: match?(%{request: %{}, reopening?: false}, :sys.get_state(feed))

  defp feed_spec(source),
    do: Enum.find(EventFeed.signal_child_specs(), &(&1.id == EventFeed.signal_feed(source)))
end
