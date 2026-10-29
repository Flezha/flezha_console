defmodule FlezhaConsole.Service.NodeManagerDistributedTest do
  @moduledoc """
  Covers the error classification that only a real connected node can exercise.

  The `:undef` case matters most: it is the exact signal that this UI and the
  controller have diverged, and the whole point of normalising it is that the
  next divergence shows up as a message naming the missing function instead of
  a crashed LiveView.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  setup_all do
    {peer, node} = PeerNode.start!("nm_peer", [StubRemoteApi])
    on_exit(fn -> PeerNode.stop(peer) end)
    {:ok, peer: peer, node: node}
  end

  describe "version skew" do
    test "a module the controller does not have is reported as api_missing" do
      assert {:error, {:api_missing, Flezha.Totally.Gone, :list_things, 1}} =
               capture_quietly(fn ->
                 NodeManager.erpc_call(Flezha.Totally.Gone, :list_things, ["default"])
               end)
    end

    test "a function the controller does not export is reported as api_missing" do
      # `:lists` exists everywhere; this function does not.
      assert {:error, {:api_missing, :lists, :no_such_function, 0}} =
               capture_quietly(fn -> NodeManager.erpc_call(:lists, :no_such_function, []) end)
    end

    test "the arity in the report is the arity that was called" do
      assert {:error, {:api_missing, :lists, :no_such_function, 3}} =
               capture_quietly(fn ->
                 NodeManager.erpc_call(:lists, :no_such_function, [1, 2, 3])
               end)
    end

    test "the missing call is logged loudly enough to diagnose" do
      log =
        capture_log(fn ->
          NodeManager.erpc_call(Flezha.Totally.Gone, :list_things, ["default"])
        end)

      assert log =~ "diverged"
      assert log =~ "Flezha.Totally.Gone"
      assert log =~ "list_things/1"
    end

    test "a renamed call on a live module still points at the real name" do
      # The shape version skew actually takes: the controller keeps the module
      # and renames the function, so the module resolves and only the call is
      # missing.
      assert {:error, {:api_missing, :maps, :list_entries, 1}} =
               capture_quietly(fn -> NodeManager.erpc_call(:maps, :list_entries, [%{}]) end)
    end

    test "a controller predating the door is reported as api_missing for the door" do
      # This peer carries no stand-ins at all, so it has no door to run the
      # published read through.
      assert {:error, {:api_missing, Flezha.Service.Admin, :run, 4}} =
               capture_quietly(fn -> NodeManager.liveness_snapshot(nil, filter: [relays: []]) end)
    end
  end

  describe "remote failures that are not version skew" do
    test "a raise inside a real function is a remote_error, not api_missing" do
      assert {:error, {:remote_error, _}} =
               NodeManager.erpc_call(:erlang, :error, [:boom])
    end

    test "a slow call is reported as a timeout" do
      assert {:error, :timeout} = NodeManager.erpc_call(:timer, :sleep, [5_000], 100)
    end
  end

  describe "successful calls" do
    test "a reply is passed through untouched" do
      assert [1, 2, 3] = NodeManager.erpc_call(:lists, :seq, [1, 3])
    end

    test "a remote {:error, %Flezha.Error{}} is the function's own answer, not a transport failure" do
      assert {:error, %Flezha.Error{code: "relay.not_found"} = error} =
               NodeManager.erpc_call(StubRemoteApi, :fails, [])

      assert %{class: :not_found, code: "relay.not_found"} = NodeManager.error(error)
    end
  end

  # The classifier logs a warning by design; silence it where the assertion is
  # about the return value rather than the log.
  defp capture_quietly(fun) do
    result = nil
    _ = capture_log(fn -> send(self(), {:result, fun.()}) end)
    receive do: ({:result, r} -> r), after: (0 -> result)
  end
end

defmodule FlezhaConsole.Service.NodeManagerDataPlaneTest do
  @moduledoc """
  The two data-plane reads the topology graph is built on.

  The interesting half is the observability query: it answers
  `observability.disabled` on a controller with the subsystem switched off,
  and that has to stay distinguishable from a transport failure so the graph
  can render the stall banner as absent rather than broken.
  """

  use ExUnit.Case, async: false

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeManager

  @moduletag :distributed

  setup_all do
    PeerNode.setup_controller("nm_dp_peer")
  end

  setup %{node: node} do
    FakeController.reset(node)
    :ok
  end

  test "the liveness snapshot is passed through as the controller produced it", %{node: node} do
    snapshot = %{
      channels: [%{runner_id: "runner-a", name: :chan_a, io_in_received: 7}],
      relays: [%{relay_id: "relay_a", io_in_received: 9, forwarded: 8, filtered_nil: 1}],
      unreachable: [:"flezha@node-b"]
    }

    FakeController.set(node, {Flezha.Service.Controller, :liveness_counters}, {:ok, snapshot})

    assert NodeManager.liveness_snapshot(nil, filter: [relays: [{"pass", "relay_a"}]]) ==
             {:ok, snapshot}
  end

  test "reads of the same counters with the same token are answered once", %{node: node} do
    FlezhaConsole.TestEnv.put_app(:liveness_ttl_ms, 60_000)
    snapshot = %{channels: [], relays: [], unreachable: []}
    FakeController.set(node, {Flezha.Service.Controller, :liveness_counters}, {:ok, snapshot})
    opts = [filter: [relays: [{"shared", "relay_#{System.unique_integer([:positive])}"}]]]

    assert {:ok, ^snapshot} = NodeManager.liveness_snapshot(nil, opts)
    assert {:ok, ^snapshot} = NodeManager.liveness_snapshot(nil, opts)

    assert [[^opts, _ctx]] =
             FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})

    # Other relays are another read.
    NodeManager.liveness_snapshot(nil, filter: [relays: [{"shared", "another"}]])

    assert length(FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})) ==
             2
  end

  test "a failed counters read is not kept", %{node: node} do
    FakeController.set(node, {Flezha.Service.Controller, :liveness_counters}, {:error, :timeout})
    opts = [filter: [relays: [{"failed", "relay_#{System.unique_integer([:positive])}"}]]]

    assert {:error, _reason} = NodeManager.liveness_snapshot(nil, opts)
    assert {:error, _reason} = NodeManager.liveness_snapshot(nil, opts)

    assert length(FakeController.calls(node, {Flezha.Service.Controller, :liveness_counters})) ==
             2
  end

  test "the observability query carries the UI's caller context and answers every controller",
       %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Observability, :query},
      FakeController.rows([%{name: :stall, node: :"flezha@node-a", at_us: 1}], ["flezha@node-b"])
    )

    assert {:ok,
            %{rows: [%{name: :stall, node: :"flezha@node-a"}], unreachable: [:"flezha@node-b"]}} =
             NodeManager.observability_query(%{source: :flezha_health, limit: 20}, nil)

    assert [[%{source: :flezha_health, limit: 20}, %{source: :ui}]] =
             FakeController.calls(node, {Flezha.Service.Observability, :query})
  end

  test "a disabled observability subsystem answers its own error, untouched", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Observability, :query},
      FakeController.error("observability.disabled")
    )

    assert {:error, %Flezha.Error{code: "observability.disabled"}} =
             NodeManager.observability_query(%{source: :flezha_health}, nil)
  end

  test "one controller's status row is picked out of every controller's", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.rows([
        FakeController.status_row("node-a"),
        FakeController.status_row("node-b", %{durability_posture: :remote_tier})
      ])
    )

    assert {:ok, %{node: :"flezha@node-b", durability_posture: :remote_tier}} =
             nil |> NodeManager.controller_status() |> NodeManager.controller_row("flezha@node-b")
  end

  test "a controller that did not answer is that error, not an empty row", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.rows([FakeController.status_row("node-a")], ["flezha@node-b"])
    )

    answer = NodeManager.controller_status(nil)

    assert NodeManager.controller_row(answer, "flezha@node-b") ==
             {:error, {:controller_unreachable, "flezha@node-b"}}

    assert NodeManager.error({:controller_unreachable, "flezha@node-b"}).message ==
             "flezha@node-b did not answer, so its facts could not be read."

    assert NodeManager.unreachable([answer]) == [:"flezha@node-b"]
  end

  test "a refused status is that refusal for the chosen controller too", %{node: node} do
    FakeController.set(
      node,
      {Flezha.Service.Controller, :status},
      FakeController.error("authz.role_insufficient")
    )

    assert {:error, %Flezha.Error{class: :denied}} =
             nil |> NodeManager.controller_status() |> NodeManager.controller_row("flezha@node-a")
  end
end
