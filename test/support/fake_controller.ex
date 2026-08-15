defmodule FakeController.Stub do
  @moduledoc """
  Declares one stand-in controller function.

      use FakeController.Stub

      defstub list_operatives(ns), do: {:ok, []}

  Generates the function *and* the key `FakeController` files it under, so the
  two cannot drift. Written by hand they can: a key naming the wrong function
  makes `FakeController.calls/2` answer `[]`, which is exactly what an
  assertion like "nothing reached the controller" checks for — so the drift
  would make that assertion pass for the wrong reason.

  Only plain variables are recorded. An underscore-prefixed one is an argument
  the real API takes but the UI never varies — the store handed to every
  `Flezha.Dlq.Store` function — and a literal pattern such as `%{source: :ui}`
  is a constraint on the caller rather than a value worth asserting on. Both
  would be noise in what a test reads back from `FakeController.calls/2`.
  """

  defmacro __using__(_opts) do
    quote do: import(FakeController.Stub, only: [defstub: 2])
  end

  defmacro defstub(call, do: default) do
    {name, _meta, params} = call
    recorded = params |> List.wrap() |> Enum.filter(&recorded?/1)

    quote do
      def unquote(call) do
        FakeController.answer({__MODULE__, unquote(name)}, unquote(recorded), unquote(default))
      end
    end
  end

  # A variable is `{name, meta, context}` with an atom context; anything else in
  # that position is a call or a destructuring pattern.
  defp recorded?({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: not String.starts_with?(Atom.to_string(name), "_")

  defp recorded?(_param), do: false
end

defmodule FakeController do
  @moduledoc """
  Canned answers for the controller modules `NodeManager` names.

  Every stand-in carries a *real* controller module's name on purpose,
  following `Flezha.Service.AuditLog` and `Flezha.Service.EventManager`: a
  stand-in only stands in if the code under test reaches it by the name it
  already uses. Shipped onto a peer node, they let a LiveView be driven through
  the real `:erpc` transport against states a live controller cannot be asked
  to produce — an empty controller, a populated dead-letter queue, a refusal, a
  version-skewed API.

  Shipped to a peer and configured from the test:

      {peer, node} = PeerNode.start_controller!()
      FakeController.set(node, {Flezha, :list_namespaces}, {:ok, ["default"]})

  Compiled only under `MIX_ENV=test`, via `elixirc_paths`.
  """

  @table :fake_controller
  @owner :fake_controller_owner

  @doc """
  Every stand-in module, in the order a peer must load them.

  `FakeController` comes first because the rest call it. The audit and event
  stand-ins live in their own files but are part of the same roster — a peer
  missing one answers `:undef` for that whole subsystem.
  """
  def modules do
    [
      __MODULE__,
      Flezha,
      Flezha.Service.OperativeManager,
      Flezha.Service.PluginManager,
      Flezha.Service.PluginHelper,
      Flezha.Service.ConfigManager,
      Flezha.Service.AuditLog,
      Flezha.Service.EventManager,
      Flezha.Plugin,
      Flezha.Dlq.Store,
      Flezha.Schedule.Store,
      Flezha.Schedule.Hub,
      Flezha.Schedule.Cron,
      Flezha.Cluster.Directory,
      Flezha.Runner.FleetManager
    ]
  end

  @doc """
  Makes `{module, function}` answer `value` on `node`.

  `value` may be a function of the stand-in's recorded arity, called with the
  arguments the code under test passed — for answering differently per call.
  """
  def set(node, key, value), do: :erpc.call(node, __MODULE__, :put, [key, value])

  @doc "Clears every answer and call record on `node`, so one test cannot leak into the next."
  def reset(node), do: :erpc.call(node, __MODULE__, :clear, [])

  @doc "The argument lists `{module, function}` was called with, oldest first."
  def calls(node, key), do: :erpc.call(node, __MODULE__, :recorded, [key])

  # ---- Run on the peer ----

  @doc false
  def put(key, value) do
    :ets.insert(store(), {key, value})
    :ok
  end

  @doc false
  def clear do
    :ets.delete_all_objects(store())
    :ok
  end

  @doc false
  def recorded(key), do: lookup({:calls, key}, [])

  @doc """
  The answer for `key`, or `default` when the test did not set one.

  Records the arguments on the way through, so a test can assert what the
  screen actually asked the controller for, not merely what it rendered.
  """
  def answer(key, args, default) do
    :ets.insert(store(), {{:calls, key}, recorded(key) ++ [args]})

    case :ets.lookup(store(), key) do
      [{^key, fun}] when is_function(fun) -> apply(fun, args)
      [{^key, value}] -> value
      [] -> default
    end
  end

  @doc """
  The table every stand-in on this node stores its state in.

  Created on first use behind a process that does nothing else: an `:erpc` call
  runs in a throwaway process, so a table owned by the call that created it
  would die with it and take the test's setup along.
  """
  def store do
    case :ets.whereis(@table) do
      :undefined -> create_store()
      tid -> tid
    end
  end

  @doc """
  Drops `pid`'s registrations when it dies, as a real registry does.

  A subscriber that is killed outright runs no cleanup of its own — an exit
  signal skips `after` blocks — so without this a stand-in would keep reporting
  a subscription held by a process that no longer exists.
  """
  def watch(pid) do
    store()
    send(Process.whereis(@owner), {:watch, pid})
    :ok
  end

  defp create_store do
    parent = self()

    spawn(fn ->
      tid =
        try do
          Process.register(self(), @owner)
          :ets.new(@table, [:named_table, :public, :set])
        rescue
          # Another caller won the race; its owner keeps the table alive.
          ArgumentError -> :ets.whereis(@table)
        end

      send(parent, {:fake_controller_store, tid})
      watch_loop()
    end)

    receive do
      {:fake_controller_store, tid} -> tid
    after
      5_000 -> raise "FakeController store did not start"
    end
  end

  # A registration is any row whose value is the subscriber's pid.
  defp watch_loop do
    receive do
      {:watch, pid} -> Process.monitor(pid)
      {:DOWN, _ref, :process, pid, _reason} -> :ets.match_delete(@table, {:_, pid})
    end

    watch_loop()
  end

  defp lookup(key, default) do
    case :ets.lookup(store(), key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end

defmodule Flezha do
  @moduledoc "Stand-in for the controller's top-level API. See `FakeController`."
  use FakeController.Stub

  defstub list_namespaces(), do: {:ok, []}
  defstub list_operatives(ns), do: {:ok, []}
  defstub list_runners(ns), do: {:ok, []}
  defstub list_factories(ns), do: {:ok, []}
  defstub start_operative(ns, operative), do: {:ok, :started}
  defstub stop_operative(ns, id), do: :ok
  defstub disable_plugin(plugin_id), do: {:ok, "disabled"}
end

defmodule Flezha.Service.OperativeManager do
  @moduledoc "Stand-in for the controller's operative manager. See `FakeController`."
  use FakeController.Stub

  defstub get_entity_state(ns, id, selector), do: {:ok, "{}", 0}
  defstub get_overwatch_state(ns, id), do: {:ok, %{}}
end

defmodule Flezha.Service.PluginManager do
  @moduledoc "Stand-in for the controller's plugin manager. See `FakeController`."
  use FakeController.Stub

  defstub enable_plugin(plugin_id, plugin), do: :ok
  # The real manager answers a bare map of `plugin_id => {namespace, operative}`.
  defstub get_plugins(), do: %{}
end

defmodule Flezha.Service.PluginHelper do
  @moduledoc "Stand-in for the controller's plugin helper. See `FakeController`."
  use FakeController.Stub

  defstub enable_io_listener(ns, id, io_type, recv_pid), do: {:ok, "listener"}
end

defmodule Flezha.Service.ConfigManager do
  @moduledoc "Stand-in for the controller's config manager. See `FakeController`."
  use FakeController.Stub

  defstub get_provider_info(), do: {:ok, []}
end

defmodule Flezha.Plugin do
  @moduledoc "Stand-in for the controller's plugin builder. See `FakeController`."
  use FakeController.Stub

  defstub new(fields), do: fields
end

defmodule Flezha.Dlq.Store do
  @moduledoc "Stand-in for the controller's dead-letter store. See `FakeController`."
  use FakeController.Stub

  defstub list(_store, operative_class), do: {:ok, []}
  defstub get(_store, ref), do: {:error, :not_found}
  defstub drop(_store, ref), do: :ok
  defstub mark_replaying(_store, ref), do: :ok
  defstub stats(_store), do: {:ok, []}
end

defmodule Flezha.Schedule.Store do
  @moduledoc "Stand-in for the controller's schedule store. See `FakeController`."
  use FakeController.Stub

  # The real store answers a bare list, sorted by name.
  defstub list(), do: []
  defstub add(fields), do: {:ok, fields}
  defstub remove(name), do: :ok
end

defmodule Flezha.Schedule.Hub do
  @moduledoc "Stand-in for the controller's schedule hub. See `FakeController`."
  use FakeController.Stub

  # The real hub answers a bare map of `name => %{node:, last_fire:}`.
  defstub statuses(), do: %{}
  defstub assert(entry), do: :ok
  defstub retract(name), do: :ok
end

defmodule Flezha.Schedule.Cron do
  @moduledoc "Stand-in for the controller's cron parser. See `FakeController`."
  use FakeController.Stub

  defstub parse(cron), do: {:ok, cron}
  defstub next_fire(parsed, timezone, now), do: {:ok, ~U[2030-01-01 00:00:00Z]}
end

defmodule Flezha.Cluster.Directory do
  @moduledoc "Stand-in for the controller's cluster directory. See `FakeController`."
  use FakeController.Stub

  defstub hub_nodes(ns), do: {:ok, []}
end

defmodule Flezha.Runner.FleetManager do
  @moduledoc "Stand-in for the controller's fleet manager. See `FakeController`."
  use FakeController.Stub

  defstub active_runners(ns), do: {:ok, []}
  defstub runners_for_factory(ns, factory_id), do: {:ok, []}
end
