defmodule FlezhaUi.Service.NodeManagerDistributedTest do
  @moduledoc """
  Covers the error classification that only a real connected node can exercise.

  The `:undef` case matters most: it is the exact signal that this UI and the
  controller have diverged, and the whole point of normalising it is that the
  next divergence shows up as a message naming the missing function instead of
  a crashed LiveView.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlezhaUi.PeerNode
  alias FlezhaUi.Service.NodeManager

  @moduletag :distributed

  setup do
    {peer, node} = PeerNode.start!("nm_peer")
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

    test "a remote {:error, reason} is the function's own answer, not a transport failure",
         %{node: node} do
      PeerNode.ship!(node, StubRemoteApi)

      assert {:error, :not_found} = NodeManager.erpc_call(StubRemoteApi, :fails, [])
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
