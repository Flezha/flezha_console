defmodule FlezhaConsole.PeerNode do
  @moduledoc """
  Starts a real second BEAM node to stand in for the flezha controller.

  The peer gets Elixir and the deps — a controller runs Elixir too — but never
  this application's own ebin. That exclusion is deliberate: it is what makes a
  test able to catch code that only works because it happened to be loaded
  locally.

  The peer started last is the controller: `start!/3` names it as
  `FLEZHA_NODE`, which `NodeManager.connected_node/0` answers, until the test
  or module that started it ends.
  """

  alias FlezhaConsole.TestEnv

  @cookie :flezha_console_test_cookie

  @doc """
  Ensures this VM is distributed, then starts a peer and returns `{peer, node}`.

  `peer_opts` are merged into `:peer.start_link/1`'s options. With
  `connection: :standard_io` the peer is controlled over its stdio rather than
  over distribution, so it outlives `Node.disconnect/1`.

  The caller is responsible for stopping the peer; `ExUnit`'s `on_exit/1` is
  the usual place. Called from a test or its `setup_all`, since naming the
  peer as the controller is undone by `on_exit/1`.
  """
  def start!(prefix \\ "peer", modules \\ [], peer_opts \\ %{}) do
    ensure_distributed!()

    disconnect_all()

    {:ok, peer, node} =
      :peer.start_link(
        %{
          name: :"#{prefix}_#{System.unique_integer([:positive])}",
          host: ~c"127.0.0.1",
          longnames: true,
          args: [~c"-setcookie", Atom.to_charlist(@cookie) | code_path_args()]
        }
        |> Map.merge(peer_opts)
      )

    TestEnv.put_system("FLEZHA_NODE", Atom.to_string(node))

    # A peer starts as a bare Erlang node. The controller it stands in for is an
    # Elixir application, so Elixir has to be running for the peer to behave
    # like one.
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    # Shipped before returning, so there is no window in which a connected peer
    # is missing a stand-in. A retrying feed that found the peer in that window
    # would be answered `:undef`.
    Enum.each(modules, &ship!(node, &1))

    {peer, node}
  end

  @doc """
  Starts a peer standing in for the whole controller.

  Ships every stand-in `FakeController` names, so each call `NodeManager` makes
  is answered on the peer rather than raising `:undef`. Returns `{peer, node}`
  exactly as `start!/3` does.
  """
  def start_controller!(prefix \\ "controller", peer_opts \\ %{}) do
    {peer, node} = start!(prefix, FakeController.modules(), peer_opts)

    FakeController.reset(node)
    {peer, node}
  end

  @doc """
  Boots a controller peer for the calling test and stops it when the test ends.

  The `setup` form of `start_controller!/2`. Forgetting the `on_exit` leaks a
  running node into whatever runs next, so the pairing is written once rather
  than at each test that wants a peer.
  """
  def setup_controller(prefix \\ "controller") do
    {peer, node} = start_controller!(prefix)
    ExUnit.Callbacks.on_exit(fn -> stop(peer) end)
    %{peer: peer, node: node}
  end

  @doc "Stops a peer, tolerating one that has already gone away."
  def stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  after
    disconnect_all()
  end

  @doc "Drops every distribution link, so each test starts with no peer from an earlier one."
  def disconnect_all do
    Enum.each(Node.list(:connected), &Node.disconnect/1)
    :ok
  end

  @doc "Loads `module`'s object code onto `node`."
  def ship!(node, module) do
    {^module, binary, filename} = :code.get_object_code(module)
    {:module, ^module} = :erpc.call(node, :code, :load_binary, [module, filename, binary])
    :ok
  end

  @doc "True when `module` is loaded on `node`."
  def loaded?(node, module) do
    match?({:file, _}, :erpc.call(node, :code, :is_loaded, [module]))
  end

  @doc "True when `pid` is alive on `node`."
  def alive?(node, pid) do
    :erpc.call(node, Process, :alive?, [pid])
  catch
    _, _ -> false
  end

  @doc """
  Polls `fun` until it returns true or the attempts run out.

  Remote state settles asynchronously — a stream ending, a subscription being
  removed — so a bare assertion after the triggering call is flaky by
  construction.
  """
  def eventually(fun, attempts \\ 50)
  def eventually(_fun, 0), do: false

  def eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  @doc "Makes this VM a distributed node, if it is not one already."
  def ensure_distributed! do
    # Named per OS process, so two test runs on one host do not collide.
    case :net_kernel.start([:"flezha_console_test_#{System.pid()}@127.0.0.1", :longnames]) do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
    end

    :erlang.set_cookie(node(), @cookie)
    :ok
  end

  defp code_path_args do
    :code.get_path()
    |> Enum.reject(&app_path?/1)
    |> Enum.flat_map(fn path -> [~c"-pa", path] end)
  end

  defp app_path?(path) do
    path |> List.to_string() |> String.contains?("/flezha_console/ebin")
  end
end
