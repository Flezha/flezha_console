defmodule FlezhaUi.PeerNode do
  @moduledoc """
  Starts a real second BEAM node to stand in for the flezha controller.

  The peer gets Elixir and the deps — a controller runs Elixir too — but never
  this application's own ebin. That exclusion is deliberate: it is what makes a
  test able to catch code that only works because it happened to be loaded
  locally.
  """

  @cookie :flezha_ui_test_cookie

  @doc """
  Ensures this VM is distributed, then starts a peer and returns `{peer, node}`.

  The caller is responsible for stopping the peer; `ExUnit`'s `on_exit/1` is
  the usual place.
  """
  def start!(prefix \\ "peer", modules \\ []) do
    ensure_distributed!()

    # Anything still connected from an earlier test would compete to be the
    # "controller": `NodeManager.connected_node/0` answers whichever node comes
    # first, so a lingering peer silently becomes the target.
    disconnect_all()

    {:ok, peer, node} =
      :peer.start_link(%{
        name: :"#{prefix}_#{System.unique_integer([:positive])}",
        host: ~c"127.0.0.1",
        longnames: true,
        args: [~c"-setcookie", Atom.to_charlist(@cookie) | code_path_args()]
      })

    # A peer starts as a bare Erlang node. The controller it stands in for is an
    # Elixir application, so Elixir has to be running for the peer to behave
    # like one — `Code.compile_string/1` needs it, in particular.
    {:ok, _} = :erpc.call(node, :application, :ensure_all_started, [:elixir])

    # Shipped before returning, so there is no window in which a connected peer
    # is missing a module the relay needs. A retrying bridge that found the peer
    # in that window would fail to compile the relay there.
    Enum.each(modules, &ship!(node, &1))

    {peer, node}
  end

  @doc "Stops a peer, tolerating one that has already gone away."
  def stop(peer) do
    :peer.stop(peer)
  catch
    _, _ -> :ok
  after
    disconnect_all()
  end

  @doc "Drops every distribution link, so no stale peer can pose as the controller."
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

  Remote state settles asynchronously — a relay unwinding, a handler being
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

  defp ensure_distributed! do
    case :net_kernel.start([:"flezha_ui_test@127.0.0.1", :longnames]) do
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
    path |> List.to_string() |> String.contains?("/flezha_ui/ebin")
  end
end
