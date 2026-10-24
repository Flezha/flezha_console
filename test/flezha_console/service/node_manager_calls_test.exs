defmodule FlezhaConsole.Service.NodeManagerCallsTest do
  @moduledoc """
  The published calls the console's controls make, driven through the real
  `:erpc` transport against the controller stand-in: each wrapper's argument
  order with the caller context last, the bare answers normalised at this seam,
  a `%Flezha.Error{}` handed on unchanged, and the operations a token's role is
  granted, read once with its verification.
  """

  use ExUnit.Case, async: false

  alias Flezha.Service.AuditLog
  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule
  alias Flezha.Service.Steps
  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  setup_all do
    PeerNode.setup_controller("nm_calls_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  # Each wrapper with the published function it reaches and the arguments that
  # function must receive before the caller context.
  defp wrappers do
    [
      {&NodeManager.diagnose_relay("ns", "r1", &1), {Relay, :diagnose}, ["ns", "r1"]},
      {&NodeManager.relay_api("ns", "r1", &1), {Relay, :api}, ["ns", "r1"]},
      {&NodeManager.send_relay("ns", "r1", "hi", "in", [msg_id: "m"], &1), {Relay, :send},
       ["ns", "r1", "hi", "in", [msg_id: "m"]]},
      {&NodeManager.call_relay("ns", "r1", "hi", "", [deadline_ms: 100], &1), {Relay, :call},
       ["ns", "r1", "hi", "", [deadline_ms: 100]]},
      {&NodeManager.call_channel("ns", "r1", "place", %{"a" => 1}, [], &1),
       {Relay, :call_channel}, ["ns", "r1", "place", %{"a" => 1}, []]},
      {&NodeManager.replay_cell("ns", "rc/t/k", "5", &1), {Relay, :replay},
       ["ns", "rc/t/k", "5"]},
      {&NodeManager.bind_plugin(
         "p",
         %{namespace: "ns", relay_id: "r1", hooks: ["on_output"]},
         &1
       ), {PluginManager, :bind}, ["p", [hooks: ["on_output"], relay_id: "r1", namespace: "ns"]]},
      {&NodeManager.unbind_plugin("p", "ns", "r1", &1), {PluginManager, :unbind},
       ["p", [namespace: "ns", relay_id: "r1"]]},
      {&NodeManager.update_plugin("p", %{namespace: "ns", opts: %{"x" => 1}}, &1),
       {PluginManager, :update}, ["p", [namespace: "ns", opts: %{"x" => 1}]]},
      {&NodeManager.list_tokens(&1), {Namespace, :tokens}, []},
      {&NodeManager.inbox("r1", &1), {Steps, :inbox}, ["r1"]},
      {&NodeManager.outbox("rc/t/k", &1), {Steps, :outbox}, ["rc/t/k"]},
      {&NodeManager.rotate_cell("rc/t/k", &1), {Steps, :rotate}, ["rc/t/k"]},
      {&NodeManager.delete_cell("rc/t/k", &1), {Steps, :delete}, ["rc/t/k"]},
      {&NodeManager.set_retention("rc", 6, &1), {Steps, :set_retention}, ["rc", 6]},
      {&NodeManager.schedule_run("nightly", &1), {Schedule, :run}, ["nightly"]},
      {&NodeManager.audit_rotate(&1), {AuditLog, :rotate}, []}
    ]
  end

  describe "the wrappers" do
    test "call the published function with the caller context last", %{node: node} do
      for {call, key, args} <- wrappers() do
        call.(nil)

        assert [recorded] = FakeController.calls(node, key), "#{inspect(key)} was not called"
        assert Enum.drop(recorded, -1) == args, "#{inspect(key)} got #{inspect(recorded)}"
        assert %{source: :ui} = List.last(recorded)
      end
    end

    test "hand a controller error on unchanged", %{node: node} do
      error = Flezha.Error.new("relay.not_found", "no relay r1", "flz relay list")

      for {call, key, _args} <- wrappers() do
        FakeController.set(node, key, {:error, error})
        assert call.(nil) == {:error, error}, "#{inspect(key)} changed the error"
      end
    end
  end

  describe "answers normalised at this seam" do
    test "a call answers the payload and the channel it came on", %{node: node} do
      FakeController.set(node, {Relay, :call}, {:ok, "pong", %{"channel" => "out"}})

      assert NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 50], nil) ==
               {:ok, %{payload: "pong", channel: "out"}}
    end

    test "a bind answers whether it bound or found the binding held", %{node: node} do
      fields = %{namespace: "ns", relay_id: "r1"}
      assert NodeManager.bind_plugin("p", fields, nil) == {:ok, :bound}

      FakeController.set(node, {PluginManager, :bind}, :already_bound)
      assert NodeManager.bind_plugin("p", fields, nil) == {:ok, :already_bound}
    end

    test "an unbind answers :ok", %{node: _node} do
      assert NodeManager.unbind_plugin("p", "ns", "r1", nil) == :ok
    end

    test "a read answering two values keeps its own shape", %{node: node} do
      assert NodeManager.cell_state("ns", "r1", nil, nil) == {:ok, "{}", 0}

      FakeController.set(node, {Flezha.Service.Dlq, :get}, {:ok, %{ref: "e1"}, "payload"})
      assert NodeManager.dlq_get("e1", nil) == {:ok, %{ref: "e1"}, "payload"}
    end

    test "a relay with no completion record answers not_found" do
      assert NodeManager.completion("r1", nil) == {:error, :not_found}
    end

    test "the relay ids are read from the relay listing's rows", %{node: node} do
      FakeController.set(
        node,
        {Relay, :list},
        {:ok, [FakeController.relay_row("r1"), FakeController.relay_row("r2")]}
      )

      assert NodeManager.list_relays("ns", nil) == {:ok, ["r1", "r2"]}
      assert [["ns", %{source: :ui}]] = FakeController.calls(node, {Relay, :list})
    end

    test "an answer of another shape is reported, never matched as success", %{node: node} do
      FakeController.set(node, {Relay, :call}, {:ok, %{unexpected: true}})

      assert {:error, {:remote_error, {:ok, %{unexpected: true}}}} =
               NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 50], nil)
    end

    test "the provider listing carries the refused package count", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Fleet, :providers},
        {:ok, %{providers: [%{id: "relay_stdout"}], refused: 2}}
      )

      assert {:ok, %{providers: [%{id: "relay_stdout"}], refused: 2}} =
               NodeManager.providers(nil)
    end
  end

  describe "a call's timeout" do
    test "outlasts a deadline longer than the default controller timeout" do
      assert NodeManager.call_timeout(60_000) > 60_000
      assert NodeManager.call_timeout(60_000) > 15_000
    end

    test "the call carries the deadline it was given", %{node: node} do
      NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 45_000], nil)

      assert [[_, _, _, _, [deadline_ms: 45_000], _ctx]] =
               FakeController.calls(node, {Relay, :call})
    end
  end

  describe "the operations a token's role grants" do
    test "are read from whoami with the verification, once per token", %{node: node} do
      bind(node, ["Relay.list"])
      token = token()

      for _tick <- 1..3, do: assert(NodeManager.operations(token) == ["Relay.list"])

      assert [[%{source: :ui, principal: "v@acme", role: :viewer}]] =
               FakeController.calls(node, {Namespace, :whoami})
    end

    test "are read again once the verification is evicted", %{node: node} do
      bind(node, ["Relay.list"])
      token = token()

      NodeManager.operations(token)
      NodeManager.evict_token(token)
      NodeManager.operations(token)

      assert length(FakeController.calls(node, {Namespace, :whoami})) == 2
    end

    test "are nil when whoami answers no list, so every control renders", %{node: node} do
      bind(node, nil)
      operations = NodeManager.operations(token())

      assert operations == nil
      assert NodeManager.granted?(operations, "Relay.stop")
    end

    test "are nil under the open posture, whatever the role", %{node: node} do
      bind(node, ["Relay.list"])
      FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :open)

      assert NodeManager.operations(token()) == nil
    end

    test "decide whether a control renders" do
      assert NodeManager.granted?(["Relay.stop"], "Relay.stop")
      refute NodeManager.granted?(["Relay.list"], "Relay.stop")
      assert NodeManager.granted?(nil, "Relay.stop")
    end
  end

  defp token, do: "flzt_ops_#{System.unique_integer([:positive])}"

  defp bind(node, operations) do
    FakeController.set(node, {Flezha.AuthZ, :enforcement_posture}, :enforced)

    FakeController.set(
      node,
      {Flezha.Service.Admin, :context},
      {:ok, %{principal: "v@acme", namespace: "default", role: :viewer, source: :ui}}
    )

    if operations do
      FakeController.set(
        node,
        {Namespace, :whoami},
        {:ok, %{principal: "v@acme", namespace: "default", role: :viewer, operations: operations}}
      )
    end
  end
end
