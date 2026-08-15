defmodule FlezhaUi.Service.EventRelayTest do
  @moduledoc """
  Proves the relay mechanism against a real second node.

  The point under test is the one that cannot be checked in-process: the relay
  must *live on the controller*, and must work there even though the controller
  carries none of this application's code. `FlezhaUi.PeerNode` starts a node
  with this app's ebin excluded, so a relay that leaned on locally-loaded code
  fails here exactly as it would in production.
  """

  use ExUnit.Case, async: false

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.EventBridge
  alias FlezhaUi.Service.EventRelay

  @moduletag :distributed

  setup do
    # The relay calls the controller's services by name, so the stand-ins have
    # to be present on the peer before the relay is compiled there.
    {peer, node} =
      PeerNode.start!("relay_peer", [
        FakeController,
        Flezha.Service.EventManager,
        Flezha.Service.AuditLog
      ])

    on_exit(fn -> PeerNode.stop(peer) end)

    {:ok, peer: peer, node: node}
  end

  describe "shipping the relay" do
    test "compiles the relay on a node that does not have it", %{node: node} do
      refute PeerNode.loaded?(node, EventRelay), "peer must start without the relay module"

      assert {:ok, pid} = start_relay(node, self())

      assert node(pid) == node, "relay must live on the remote node"
      assert PeerNode.loaded?(node, EventRelay)
    end

    test "ships source, so the two nodes need not share an OTP release", %{node: node} do
      {module, source} = EventBridge.relay_source()

      assert module == EventRelay
      assert is_binary(source)
      assert source =~ "defmodule FlezhaUi.Service.EventRelay"

      # Compiling on the peer is what makes the version independence real.
      assert [{^module, _binary} | _] = :erpc.call(node, Code, :compile_string, [source])
    end

    test "the shipped code references no other module of this application" do
      {_module, source} = EventBridge.relay_source()

      offenders =
        source
        |> strip_prose()
        |> then(&Regex.scan(~r/FlezhaUi\.[A-Za-z.]+/, &1))
        |> List.flatten()
        |> Enum.uniq()
        |> Enum.reject(&(&1 == "FlezhaUi.Service.EventRelay"))

      assert offenders == [],
             "the relay runs where no FlezhaUi code exists; found #{inspect(offenders)}"
    end

    test "reports an error when the node is unreachable" do
      assert {:error, _} =
               EventBridge.start_relay(
                 :"nonexistent@127.0.0.1",
                 EventBridge.relay_source(),
                 self(),
                 [{:events, EventBridge.events()}, :tag]
               )
    end

    test "reports an error when the source will not compile", %{node: node} do
      assert {:error, _} =
               EventBridge.start_relay(
                 node,
                 {EventRelay, "defmodule Broken do this is not elixir end"},
                 self(),
                 [{:events, EventBridge.events()}, :tag]
               )
    end
  end

  describe "the relay running on the controller" do
    test "subscribes as itself and forwards controller events", %{node: node} do
      {:ok, relay} = start_relay(node, self())

      assert node(relay) == node

      # The relay, not a throwaway erpc process, holds the registration.
      assert PeerNode.eventually(fn ->
               Enum.sort(handlers(node, relay)) == Enum.sort(EventBridge.events())
             end),
             "relay must register the controller events from its own process"

      send(relay, {:runner_connected_event, {"default", "session-1"}})

      assert_receive {:relay_event, :controller_events,
                      {:runner_connected_event, {"default", "session-1"}}},
                     2_000
    end

    test "forwards a disconnect as readily as a connect", %{node: node} do
      {:ok, relay} = start_relay(node, self())

      send(relay, {:runner_disconnected_event, {"default", "runner-1"}})

      assert_receive {:relay_event, :controller_events, {:runner_disconnected_event, _}}, 2_000
    end

    test "stops when its owner dies, so its handlers do not leak", %{node: node} do
      test_pid = self()

      owner =
        spawn(fn ->
          {:ok, relay} = start_relay(node, self())
          send(test_pid, {:relay, relay})
          receive do: (:stop -> :ok)
        end)

      assert_receive {:relay, relay}, 2_000

      assert PeerNode.eventually(fn ->
               length(handlers(node, relay)) == length(EventBridge.events())
             end)

      send(owner, :stop)

      assert PeerNode.eventually(fn -> not PeerNode.alive?(node, relay) end),
             "relay must not outlive its owner"
    end
  end

  describe "the audit-tail subscription" do
    test "subscribes through the audit service and forwards records", %{node: node} do
      {:ok, relay} = start_audit_relay(node, self())

      assert PeerNode.eventually(fn -> tail_subscribed?(node, relay) end),
             "relay must hold the audit tail subscription itself"

      send(relay, %{"event" => "operative.started"})

      assert_receive {:relay_event, :audit_tail, %{"event" => "operative.started"}}, 2_000
    end

    test "still forwards when the controller refuses the subscription", %{node: node} do
      # A relay that stayed up but silently dropped messages would look healthy
      # while delivering nothing; it must not register a tail it did not get.
      {:ok, relay} =
        EventBridge.start_relay(node, EventBridge.relay_source(), self(), [
          {:audit_tail, %{refuse: true}},
          :audit_tail
        ])

      assert PeerNode.alive?(node, relay)
      assert :erpc.call(node, Flezha.Service.AuditLog, :tails, []) == []
    end

    test "unsubscribes when it unwinds", %{node: node} do
      {:ok, relay} = start_audit_relay(node, self())
      assert PeerNode.eventually(fn -> tail_subscribed?(node, relay) end)

      Process.unlink(relay)
      Process.exit(relay, :shutdown)

      assert PeerNode.eventually(fn -> not PeerNode.alive?(node, relay) end)

      assert PeerNode.eventually(fn ->
               :erpc.call(node, Flezha.Service.AuditLog, :tails, []) == []
             end),
             "a killed relay must not leave an audit tail registered"
    end
  end

  describe "relay replacement" do
    test "a replaced relay is terminated, so each event is delivered once", %{node: node} do
      {:ok, first} = start_relay(node, self())
      assert PeerNode.alive?(node, first)

      # What `attempt_subscribe/1` does before spawning a replacement.
      Process.unlink(first)
      Process.exit(first, :shutdown)

      assert PeerNode.eventually(fn -> not PeerNode.alive?(node, first) end)

      {:ok, second} = start_relay(node, self())
      assert PeerNode.alive?(node, second)
      refute PeerNode.alive?(node, first)

      send(second, {:runner_connected_event, {"default", "session-1"}})
      assert_receive {:relay_event, :controller_events, {:runner_connected_event, _}}, 2_000

      # Exactly one delivery: a leaked first relay would double every event.
      refute_receive {:relay_event, :controller_events, {:runner_connected_event, _}}, 200
    end
  end

  defp start_relay(node, owner) do
    EventBridge.start_relay(node, EventBridge.relay_source(), owner, [
      {:events, EventBridge.events()},
      :controller_events
    ])
  end

  defp start_audit_relay(node, owner) do
    EventBridge.start_relay(node, EventBridge.relay_source(), owner, [
      {:audit_tail, %{}},
      :audit_tail
    ])
  end

  defp tail_subscribed?(node, relay) do
    :erpc.call(node, Flezha.Service.AuditLog, :tails, []) == [relay]
  catch
    _, _ -> false
  end

  # Docstrings and comments may name anything; only code has to obey the
  # no-FlezhaUi rule.
  defp strip_prose(source) do
    source
    |> String.replace(~r/@(module)?doc\s+"""".*?""""/s, "")
    |> String.replace(~r/@(module)?doc\s+""".*?"""/s, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end

  defp handlers(node, pid) do
    case :erpc.call(node, Process, :info, [pid, :dictionary]) do
      {:dictionary, dict} -> Keyword.get(dict, :handlers, [])
      _ -> []
    end
  catch
    _, _ -> []
  end
end
