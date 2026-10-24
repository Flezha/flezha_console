defmodule FlezhaConsole.Service.NodeConnectorTest do
  @moduledoc """
  The connector that finds the controller node named by `FLEZHA_NODE` and
  finds it again after the connection drops.

  Serial: it sets `FLEZHA_NODE` and connects and disconnects nodes, all of
  which is global to the VM.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias FlezhaConsole.PeerNode
  alias FlezhaConsole.Service.NodeConnector
  alias FlezhaConsole.TestEnv

  @moduletag :distributed
  @moduletag :capture_log

  # Started without `start_link/1`'s registered name, which the application's
  # own connector already holds.
  defp start_connector(node) do
    TestEnv.put_system("FLEZHA_NODE", Atom.to_string(node))

    start_supervised!(%{
      id: NodeConnector,
      start: {GenServer, :start_link, [NodeConnector, []]}
    })
  end

  defp trace_receives(pid), do: :erlang.trace(pid, true, [:receive])

  test "connects to its node, and reconnects after the node goes down" do
    # Controlled over stdio, the peer stays up while its connection is cut.
    {peer, node} = PeerNode.start!("connector_peer", [], %{connection: :standard_io})
    on_exit(fn -> PeerNode.stop(peer) end)
    Node.disconnect(node)
    refute node in Node.list()

    connector = start_connector(node)
    :sys.get_state(connector)
    assert node in Node.list()

    trace_receives(connector)
    Node.disconnect(node)

    assert_receive {:trace, ^connector, :receive, {:nodedown, ^node}}
    assert_receive {:trace, ^connector, :receive, :retry}
    :sys.get_state(connector)
    assert node in Node.list()
  end

  test "finds the controller through FLEZHA_NODE_QUERY's DNS name" do
    {peer, node} = PeerNode.start!("query_peer", [], %{connection: :standard_io})
    on_exit(fn -> PeerNode.stop(peer) end)
    Node.disconnect(node)
    [name, "127.0.0.1"] = node |> Atom.to_string() |> String.split("@")
    TestEnv.put_system("FLEZHA_NODE", nil)
    TestEnv.put_system("FLEZHA_NODE_QUERY", "#{name}@localhost")

    assert NodeConnector.target_node() == node

    connector =
      start_supervised!(%{
        id: NodeConnector,
        start: {GenServer, :start_link, [NodeConnector, []]}
      })

    :sys.get_state(connector)
    assert node in Node.list()
  end

  test "aims at the query itself when its DNS name does not resolve" do
    TestEnv.put_system("FLEZHA_NODE", nil)
    TestEnv.put_system("FLEZHA_NODE_QUERY", "flezha@no-such-host.invalid")

    assert NodeConnector.target_node() == :"flezha@no-such-host.invalid"
  end

  test "keeps retrying a node it cannot reach" do
    PeerNode.ensure_distributed!()
    node = :"absent_#{System.unique_integer([:positive])}@127.0.0.1"

    connector = start_connector(node)
    trace_receives(connector)

    assert_receive {:trace, ^connector, :receive, :retry}
    assert_receive {:trace, ^connector, :receive, :retry}
    refute node in Node.list()
  end

  test "says so when this VM is not distributed" do
    if Node.alive?() do
      PeerNode.disconnect_all()
      :ok = :net_kernel.stop()
      on_exit(&PeerNode.ensure_distributed!/0)
    end

    log =
      capture_log(fn ->
        connector = start_connector(:"flezha@127.0.0.1")
        :sys.get_state(connector)
      end)

    assert log =~ "Distribution not started"
  end
end
