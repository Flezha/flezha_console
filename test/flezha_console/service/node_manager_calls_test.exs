defmodule FlezhaConsole.Service.NodeManagerCallsTest do
  @moduledoc """
  The published calls the console's controls make, driven over the channel
  against the controller stand-in: each wrapper's arguments as the channel
  carries them, with the bearer token the controller judges, the bare answers
  normalised at this seam, a controller error handed on by its fields, and the
  operations a token's role is granted, read once with its verification.
  """

  use ExUnit.Case, async: false

  alias Flezha.Service.Logs
  alias Flezha.Service.Namespace
  alias Flezha.Service.PluginManager
  alias Flezha.Service.Relay
  alias Flezha.Service.Schedule
  alias Flezha.Service.Steps
  alias FlezhaConsole.FakeListener
  alias FlezhaConsole.Service.NodeManager

  @moduletag :channel
  @token "flzt_t"

  setup_all do
    %{node: FakeListener.start!()}
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  # Each wrapper with the published function it reaches and the arguments that
  # function must receive before the caller context, as the channel carries
  # them.
  defp wrappers do
    [
      {&NodeManager.diagnose_relay("ns", "r1", &1), {Relay, :diagnose}, ["ns", "r1"]},
      {&NodeManager.relay_api("ns", "r1", &1), {Relay, :api}, ["ns", "r1"]},
      {&NodeManager.send_relay("ns", "r1", "hi", "in", [msg_id: "m"], &1), {Relay, :send},
       ["ns", "r1", "hi", "in", %{"msg_id" => "m"}]},
      {&NodeManager.call_relay("ns", "r1", "hi", "", [deadline_ms: 100], &1), {Relay, :call},
       ["ns", "r1", "hi", "", %{"deadline_ms" => 100}]},
      {&NodeManager.call_channel("ns", "r1", "place", %{"a" => 1}, [], &1),
       {Relay, :call_channel}, ["ns", "r1", "place", %{"a" => 1}, []]},
      {&NodeManager.replay_cell("ns", "rc/t/k", "5", &1), {Relay, :replay},
       ["ns", "rc/t/k", "5"]},
      {&NodeManager.bind_plugin(
         "p",
         %{namespace: "ns", relay_id: "r1", hooks: ["on_output"]},
         &1
       ), {PluginManager, :bind},
       ["p", %{"hooks" => ["on_output"], "relay_id" => "r1", "namespace" => "ns"}]},
      {&NodeManager.unbind_plugin("p", "ns", "r1", &1), {PluginManager, :unbind},
       ["p", %{"namespace" => "ns", "relay_id" => "r1"}]},
      {&NodeManager.update_plugin("p", %{namespace: "ns", opts: %{"x" => 1}}, &1),
       {PluginManager, :update}, ["p", %{"namespace" => "ns", "opts" => %{"x" => 1}}]},
      {&NodeManager.list_tokens(&1), {Namespace, :tokens}, []},
      {&NodeManager.inbox("r1", &1), {Steps, :inbox}, ["r1"]},
      {&NodeManager.outbox("rc/t/k", &1), {Steps, :outbox}, ["rc/t/k"]},
      {&NodeManager.rotate_cell("rc/t/k", &1), {Steps, :rotate}, ["rc/t/k"]},
      {&NodeManager.delete_cell("rc/t/k", &1), {Steps, :delete}, ["rc/t/k"]},
      {&NodeManager.set_retention("rc", 6, &1), {Steps, :set_retention}, ["rc", 6]},
      {&NodeManager.schedule_run("nightly", &1), {Schedule, :run}, ["nightly"]},
      {&NodeManager.log_kinds(&1), {Logs, :kinds}, []},
      {&NodeManager.log_read(
         "audit",
         %{filters: %{"name" => "x"}, limit: 5_000, before: "c1"},
         &1
       ), {Logs, :read},
       [%{"kind" => "audit", "filters" => %{"name" => "x"}, "before" => "c1", "limit" => 1_000}]},
      {&NodeManager.log_files("audit", &1), {Logs, :files}, [%{"kind" => "audit"}]},
      {&NodeManager.log_stats("audit", &1), {Logs, :stats}, [%{"kind" => "audit"}]},
      {&NodeManager.log_rotate("audit", "flezha@c1", &1), {Logs, :rotate},
       [%{"kind" => "audit", "node" => "flezha@c1"}]}
    ]
  end

  describe "the wrappers" do
    test "call the published function with the bearer token the controller judges", %{
      node: node
    } do
      for {call, key, args} <- wrappers() do
        call.(@token)

        assert [recorded] = FakeController.calls(node, key), "#{inspect(key)} was not called"
        assert Enum.drop(recorded, -1) == args, "#{inspect(key)} got #{inspect(recorded)}"
        assert %{token: @token} = List.last(recorded)
      end
    end

    test "hand a controller error on by its fields", %{node: node} do
      error = Flezha.Error.new("relay.not_found", "no relay r1", "flz relay list")

      read = %{
        code: "relay.not_found",
        class: :not_found,
        message: "no relay r1",
        hint: "flz relay list",
        details: %{}
      }

      for {call, key, _args} <- wrappers() do
        FakeController.set(node, key, {:error, error})
        assert call.(@token) == {:error, read}, "#{inspect(key)} changed the error"
      end
    end
  end

  describe "answers normalised at this seam" do
    test "a call answers the payload and the channel it came on", %{node: node} do
      FakeController.set(node, {Relay, :call}, {:ok, "pong", %{"channel" => "out"}})

      assert NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 50], @token) ==
               {:ok, %{payload: "pong", channel: "out"}}
    end

    test "a bind answers whether it bound or found the binding held", %{node: node} do
      fields = %{namespace: "ns", relay_id: "r1"}
      assert NodeManager.bind_plugin("p", fields, @token) == {:ok, :bound}

      FakeController.set(node, {PluginManager, :bind}, :already_bound)
      assert NodeManager.bind_plugin("p", fields, @token) == {:ok, :already_bound}
    end

    test "an unbind answers :ok", %{node: _node} do
      assert NodeManager.unbind_plugin("p", "ns", "r1", @token) == :ok
    end

    test "a read answering two values keeps its own shape", %{node: node} do
      assert NodeManager.cell_state("ns", "r1", nil, @token) == {:ok, "{}", 0}

      # A parked entry is keyed by text, as the controller's store keeps it.
      FakeController.set(node, {Flezha.Service.Dlq, :get}, {:ok, %{"id" => "e1"}, "payload"})
      assert NodeManager.dlq_get("e1", @token) == {:ok, %{"id" => "e1"}, "payload"}
    end

    test "a log's files and statistics answer as rows, naming who did not answer", %{
      node: node
    } do
      # Node names cross the channel as text.
      file = FakeController.log_file_row("flezha@c1", "audit-1.jsonl")
      stats = FakeController.log_stats_row("flezha@c1")

      FakeController.set(
        node,
        {Logs, :files},
        {:ok, %{files: [file], unreachable: ["flezha@c2"]}}
      )

      FakeController.set(node, {Logs, :stats}, {:ok, %{controllers: [stats], unreachable: []}})

      assert NodeManager.log_files("audit", @token) ==
               {:ok, %{rows: [file], unreachable: ["flezha@c2"]}}

      assert NodeManager.log_stats("audit", @token) == {:ok, %{rows: [stats], unreachable: []}}
    end

    test "a read drops what it leaves empty", %{node: node} do
      NodeManager.log_read("relay_history", %{filters: %{}, before: nil, limit: 50}, @token)

      assert [[params, _ctx]] = FakeController.calls(node, {Logs, :read})
      assert params == %{"kind" => "relay_history", "limit" => 50}
    end

    test "a relay with no recorded end answers not_found" do
      assert NodeManager.kept_until("r1", @token) == {:error, :not_found}
    end

    test "a finished relay's state is kept until a time, or was not kept", %{node: node} do
      FakeController.set(node, {Steps, :completion}, {:ok, %{state_kept: true, expires_at: 9}})
      assert NodeManager.kept_until("r1", @token) == {:ok, 9}

      FakeController.set(node, {Steps, :completion}, {:ok, %{state_kept: false}})
      assert NodeManager.kept_until("r1", @token) == {:ok, nil}
    end

    test "one relay's row is read by its id, a partition member's with its group", %{
      node: node
    } do
      member = fn index ->
        FakeController.relay_row("g#p#{index}", %{
          partition: %{group: "g", index: index, count: 2, range: {index * 64, index * 64 + 63}}
        })
      end

      group = Map.merge(FakeController.relay_row("g"), %{members: [member.(1), member.(0)]})

      FakeController.set(
        node,
        {Relay, :list},
        FakeController.rows([FakeController.relay_row("r1"), group])
      )

      assert {{:ok, _page}, %{id: "r1"}, []} =
               NodeManager.relay_and_partitions("ns", "r1", @token)

      assert {_read, %{id: "g#p1"}, [%{id: "g#p0"}, %{id: "g#p1"}]} =
               NodeManager.relay_and_partitions("ns", "g#p1", @token)

      assert {_read, nil, []} = NodeManager.relay_and_partitions("ns", "gone", @token)

      assert [
               ["ns", %{"filter" => %{"ids" => ["r1"]}}, _ctx],
               ["ns", %{"filter" => %{"ids" => ["g#p1", "g"]}}, _],
               _
             ] = FakeController.calls(node, {Relay, :list})
    end

    test "an answer of another shape is reported, never matched as success", %{node: node} do
      FakeController.set(node, {Relay, :call}, {:ok, %{unexpected: true}})

      assert {:error, {:remote_error, {:ok, %{"unexpected" => true}}}} =
               NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 50], @token)
    end

    test "the provider listing carries each controller's refused package count", %{node: node} do
      FakeController.set(
        node,
        {Flezha.Service.Fleet, :providers},
        {:ok,
         %{
           rows: [%{id: "relay_stdout", nodes: [:"flezha@node-a"]}],
           refused: %{"flezha@node-a": 2},
           unreachable: []
         }}
      )

      assert {:ok, %{rows: [%{id: "relay_stdout"}], refused: %{"flezha@node-a" => 2}}} =
               NodeManager.providers(@token)
    end

    test "a cluster listing that is not rows is reported, never matched as success", %{
      node: node
    } do
      FakeController.set(node, {Flezha.Service.Dlq, :list}, {:ok, [%{"ref" => "a/b/c"}]})

      assert {:error, {:remote_error, {:ok, [_]}}} = NodeManager.dlq_list(nil, @token)
    end
  end

  describe "a call's timeout" do
    test "outlasts a deadline longer than the default controller timeout" do
      assert NodeManager.call_timeout(60_000) > 60_000
      assert NodeManager.call_timeout(60_000) > 15_000
    end

    test "the call carries the deadline it was given", %{node: node} do
      NodeManager.call_relay("ns", "r1", "ping", "", [deadline_ms: 45_000], @token)

      assert [[_, _, _, _, %{"deadline_ms" => 45_000}, _ctx]] =
               FakeController.calls(node, {Relay, :call})
    end
  end

  describe "the operations a token's role grants" do
    test "are read from whoami with the verification, once per token", %{node: node} do
      bind(node, ["Relay.list"])
      token = token()

      for _tick <- 1..3, do: assert(NodeManager.operations(token) == ["Relay.list"])

      assert [[%{token: ^token}]] = FakeController.calls(node, {Namespace, :whoami})
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
      bind(node, ["Relay.list"], :open)

      assert NodeManager.operations(token()) == nil
    end

    test "decide whether a control renders" do
      assert NodeManager.granted?(["Relay.stop"], "Relay.stop")
      refute NodeManager.granted?(["Relay.list"], "Relay.stop")
      assert NodeManager.granted?(nil, "Relay.stop")
    end
  end

  defp token, do: "flzt_ops_#{System.unique_integer([:positive])}"

  # Whoami answers the identity, the operations granted (or no list) and the
  # posture in one answer.
  defp bind(node, operations, posture \\ :enforced) do
    FakeController.set(
      node,
      {Namespace, :whoami},
      {:ok,
       %{
         principal: "v@acme",
         namespace: "default",
         role: :viewer,
         operations: operations,
         posture: posture
       }}
    )
  end
end
