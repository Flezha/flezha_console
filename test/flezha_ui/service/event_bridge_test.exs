defmodule FlezhaUi.Service.EventBridgeTest do
  @moduledoc """
  The bridge driven as it runs in production, against a real controller stand-in.

  A dropped connection delivers two signals — the relay's `EXIT` and the node's
  `:nodedown`. Each used to schedule its own retry, so the second attempt would
  spawn a remote relay purely to tear down the one the first had just made.
  The reconnect tests here pin that pair collapsing to a single relay.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.EventBridge

  @moduletag :distributed

  describe "events/0" do
    test "names the controller's current runner events" do
      assert EventBridge.events() == [:runner_connected_event, :runner_disconnected_event]
    end

    test "carries no trace of the old compute-engine names" do
      refute Enum.any?(EventBridge.events(), &(Atom.to_string(&1) =~ "compute_engine"))
    end
  end

  describe "relay_source/0" do
    test "answers the relay module and its source, read at build time" do
      assert {FlezhaUi.Service.EventRelay, source} = EventBridge.relay_source()
      assert source =~ "def start(owner, subscription, tag)"
    end
  end

  describe "against a controller" do
    setup do
      # Both stand-ins: the relay source names both controller services, so a
      # peer missing either cannot compile it.
      {peer, node} =
        PeerNode.start!("bridge_peer", [Flezha.Service.EventManager, Flezha.Service.AuditLog])

      on_exit(fn -> PeerNode.stop(peer) end)

      # The bridge finds its controller through `NodeManager.connected_node/0`,
      # which answers the first connected node — here, the peer.
      {:ok, peer: peer, node: node}
    end

    test "establishes exactly one relay on connect", %{node: node} do
      start_bridge!()

      assert PeerNode.eventually(fn -> relays_on(node) |> length() == 1 end),
             "expected exactly one relay, saw #{length(relays_on(node))}"
    end

    test "broadcasts a runner event onto the UI's PubSub topic", %{node: node} do
      start_bridge!()
      Phoenix.PubSub.subscribe(FlezhaUi.PubSub, EventBridge.topic())

      assert PeerNode.eventually(fn -> relays_on(node) != [] end)
      [relay] = relays_on(node)

      send(relay, {:runner_connected_event, {"default", "session-1"}})

      assert_receive {:flezha_event, :runner_connected, {"default", "session-1"}}, 2_000
    end

    test "a dead relay is replaced by exactly one successor", %{node: node} do
      start_bridge!()
      assert PeerNode.eventually(fn -> relays_on(node) != [] end)
      [first] = relays_on(node)

      # What a controller-side failure looks like to the bridge.
      Process.exit(first, :kill)

      assert PeerNode.eventually(fn ->
               case relays_on(node) do
                 [only] -> only != first
                 _ -> false
               end
             end),
             "expected one fresh relay, saw #{inspect(relays_on(node))}"
    end

    test "a gracefully stopped bridge leaves no relay behind", %{node: node} do
      bridge = start_bridge!()
      assert PeerNode.eventually(fn -> relays_on(node) != [] end)

      # The graceful path is the point: `terminate/2` is what tears the relay
      # down, so this must not be a kill.
      :ok = GenServer.stop(bridge, :normal, 5_000)

      assert PeerNode.eventually(fn -> relays_on(node) == [] end),
             "a stopped bridge must not leave a relay registered on the controller"
    end
  end

  # Started directly rather than through the supervisor: the application's own
  # bridge is not running in test, and this keeps the process owned here.
  #
  # Cleanup is registered immediately, not left to the end of the test body: a
  # bridge that outlives a failed assertion keeps retrying against a torn-down
  # peer and corrupts every test that follows.
  defp start_bridge! do
    {:ok, pid} = GenServer.start(EventBridge, [])
    ExUnit.Callbacks.on_exit(fn -> stop_bridge(pid) end)
    pid
  end

  # Killed and waited for, not asked politely: a graceful stop can time out
  # while the bridge is blocked on a dying node, and a bridge that survives into
  # the next test keeps recompiling the relay on whatever peer connects next,
  # racing that test's own compile of the same module.
  defp stop_bridge(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        5_000 -> :ok
      end
    end

    :ok
  end

  # Relays are the processes on the controller running the relay module.
  defp relays_on(node) do
    :erpc.call(node, :erlang, :processes, [])
    |> Enum.filter(fn pid ->
      case :erpc.call(node, Process, :info, [pid, :current_function]) do
        {:current_function, {FlezhaUi.Service.EventRelay, _fun, _arity}} -> true
        _ -> false
      end
    end)
  catch
    _, _ -> []
  end
end
