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

  A pattern bound to a name — `%{source: :ui} = ctx` — is both: the pattern
  constrains the caller and the bound value is recorded. That is how a caller
  context can be asserted on without dropping the constraint that the UI
  identifies itself.
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

  defp recorded?({:=, _meta, [_pattern, bound]}), do: recorded?(bound)

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
      Flezha.Runner.FleetManager,
      Flezha.Transport.LivenessCounters,
      Flezha.Service.Observability,
      Flezha.AuthZ,
      Flezha.AuthZ.TokenStore,
      Flezha.Service.HubManager,
      Flezha.Service.CliManager,
      Flezha.Partition,
      Flezha.AuthZ.NamespaceStore,
      Flezha.AuthZ.QuotaCounters,
      Flezha.AuthZ.RoleStore,
      Flezha.State.Registry,
      Flezha.State.Completion,
      Flezha.State.PersistenceResolver,
      Flezha.State.ProcJournal,
      Flezha.State.ProcInbox,
      Flezha.Operative.PartitionGroup,
      Flezha.Operative.Lifecycle,
      Flezha.Operative.Kind,
      Flezha.Observability,
      Flezha.State.DurabilityTier,
      Flezha.Shutdown.Coordinator,
      Flezha.State.Metrics,
      Flezha.State.TimeTravel,
      Flezha.Service.Identificator,
      Flezha.Plugin.Installer
    ]
  end

  @doc """
  Makes `{module, function}` answer `value` on `node`.

  For a controller that answers differently per call — a factory listing per
  namespace, the runners serving each factory — `value` may be
  `{:per_arg, index, by_arg, default}`: the answer looked up by the call's
  `index`-th recorded argument.

      FakeController.set(node, {FleetManager, :runners_for_factory},
        {:per_arg, 1, %{"store_input" => {:ok, ["runner-a"]}}, {:ok, []}})

  It may *not* be a closure written in a test module. The peer never loads that
  module, so applying one there raises `:undef` — which the seam then reports
  as a version-skewed controller, and the test passes or fails for the wrong
  reason. A function is applied only when it comes from a module the peer has.
  """
  def set(node, key, value), do: :erpc.call(node, __MODULE__, :put, [key, value])

  @doc "Clears every answer and call record on `node`, so one test cannot leak into the next."
  def reset(node), do: :erpc.call(node, __MODULE__, :clear, [])

  @doc "The argument lists `{module, function}` was called with, oldest first."
  def calls(node, key), do: :erpc.call(node, __MODULE__, :recorded, [key])

  @doc """
  A registry row shaped as `Flezha.Service.HubManager.operative_rows/1` answers
  one, with `overrides` applied.

  Every listing, the fleet summary and the cluster rollup read these rows, so
  the shape is written once: when the controller changes it, one fixture is
  wrong rather than six.
  """
  def operative_row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: to_string(id),
        health: :healthy,
        runner: "runner-a",
        factory: "store_input",
        partition: nil,
        node: :"flezha@node-a"
      },
      overrides
    )
  end

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
      [{^key, {:per_arg, index, by_arg, fallback}}] ->
        Map.get(by_arg, Enum.at(args, index), fallback)

      [{^key, fun}] when is_function(fun) ->
        apply(fun, args)

      [{^key, value}] ->
        value

      [] ->
        default
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
  # The real one answers a bare pid; a rewind is a call on that process.
  defstub get_operative_pid(ns, id), do: {:error, :not_found}
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
  # Unlike its siblings this one takes no store argument — it reads the queue's
  # directory layout, which is how the tier groups what it ships.
  defstub procedures(operative_class), do: []
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

  defstub runner_caller_context(ns),
    do: %{source: :sdk, principal: "runner@" <> ns, role: :runner}
end

defmodule Flezha.Transport.LivenessCounters do
  @moduledoc "Stand-in for the controller's data-plane counters. See `FakeController`."
  use FakeController.Stub

  # The real snapshot answers a bare map of two counter lists.
  defstub snapshot_all(), do: %{channels: [], operatives: []}
end

defmodule Flezha.Service.Observability do
  @moduledoc """
  Stand-in for the controller's observability service. See `FakeController`.

  Answers plain maps rather than `Flezha.Observability.Signal` structs: that
  module is not loadable on this node, and a struct arriving from the
  controller is read here as the map it is on the wire.
  """
  use FakeController.Stub

  # The context pattern is kept strict: the UI identifies itself on every read.
  # The pattern constrains the caller; the binding lets a test assert which
  # principal the call named.
  #
  # Sources and sinks answer the controller's real entry shapes: a source
  # carries `status: :active | :disabled` (there is no `:enabled` boolean), and
  # a sink carries a `:pid` and no status at all.
  defstub query(params, %{source: :ui}), do: {:ok, []}
  defstub list_sources(%{source: :ui} = ctx), do: {:ok, []}
  defstub list_sinks(%{source: :ui} = ctx), do: {:ok, []}
  defstub enable_source(source, %{source: :ui} = ctx), do: :ok
  defstub disable_source(source, %{source: :ui} = ctx), do: :ok
  defstub tail(source, %{source: :ui} = ctx), do: :ok
end

defmodule Flezha.Service.HubManager do
  @moduledoc """
  Stand-in for the controller's hub manager. See `FakeController`.

  The bulk reads every listing is built on. Both answer bare lists, as the real
  ones do — a namespace with no live hub answers `[]` rather than an error.
  """
  use FakeController.Stub

  defstub get_running_namespaces(), do: []
  defstub operative_rows(ns), do: []
  defstub operative_plugins(ns), do: []
  # The raw registry dump, which carries each entry's cspec — the durable
  # record of the kind an operative was started with.
  defstub get_registry(ns), do: {:ok, []}
  defstub recovery_state(hub_id), do: {:ok, :normal}
end

defmodule Flezha.Service.CliManager do
  @moduledoc """
  Stand-in for the controller's CLI manager. See `FakeController`.

  Only its non-printing functions are stood in for: the rest write to stdout
  and exit on failure, so the UI does not call them.

  `group_partition_rows/1` defaults to the identity, which is what the real one
  does for rows carrying no partition identity.
  """
  use FakeController.Stub

  defstub group_partition_rows(rows), do: rows

  # `@doc false` on the real one, but a plain function: the memory screen calls
  # it directly because the `mem-top` verb prints.
  defstub cluster_status_recovery(namespace, nodes), do: %{}

  defstub build_mem_top_snapshot(),
    do: %{
      captured_at: "2026-01-01T00:00:00Z",
      node: "flezha@controller",
      erlang_memory: %{total: 1024},
      top_processes: [],
      ets_tables: [],
      dets_files: [],
      recon_alloc_allocated_types: []
    }
end

defmodule Flezha.Partition do
  @moduledoc """
  Stand-in for the controller's partition arithmetic. See `FakeController`.

  Coverage defaults to complete: a test asserting a fault says so explicitly,
  rather than every namespace looking broken by default.
  """
  use FakeController.Stub

  defstub coverage(labelled_ranges), do: :ok
end

defmodule Flezha.Plugin.Installer do
  @moduledoc """
  Stand-in for the controller's plugin installer. See `FakeController`.

  Read-only from this UI: installing moves files on the controller host, which
  is a deploy action rather than a control-panel one.
  """
  use FakeController.Stub

  defstub list(), do: []
end

defmodule Flezha.Observability do
  @moduledoc """
  Stand-in for the controller's observability pubsub. See `FakeController`.

  Named by `FlezhaUi.Service.EventRelay`, which runs on the controller — so it
  has to exist wherever the relay is compiled.
  """
  use FakeController.Stub

  defstub subscribe(source), do: :ok
  defstub unsubscribe(source), do: :ok
end

defmodule Flezha.State.DurabilityTier do
  @moduledoc "Stand-in for the controller's remote durability tier. See `FakeController`."
  use FakeController.Stub

  defstub configured_backend(), do: :unset
  defstub posture(), do: :local_only
  defstub breaches(), do: []
  defstub status(), do: []
end

defmodule Flezha.Shutdown.Coordinator do
  @moduledoc "Stand-in for the controller's shutdown coordinator. See `FakeController`."
  use FakeController.Stub

  defstub status(),
    do: %{
      shutdown_in_progress: false,
      shutdown_phase: :running,
      signal_handler_status: :installed,
      graceful_shutdown_enabled: true,
      graceful_shutdown_timeout_ms: 60_000
    }
end

defmodule Flezha.State.Metrics do
  @moduledoc """
  Stand-in for the controller's per-entity durability counters. See
  `FakeController`.

  Answers `[{entity_id, counters}]` where `entity_id` is the
  `{operative_class, procedure_id, entity_key}` triple, as the real one does.
  """
  use FakeController.Stub

  defstub snapshot_all(), do: []
end

defmodule Flezha.State.TimeTravel do
  @moduledoc "Stand-in for the controller's point-in-time reads. See `FakeController`."
  use FakeController.Stub

  defstub query(entity_id, target), do: {:error, %{kind: :no_data, message: "no persisted state"}}
end

defmodule Flezha.Service.Identificator do
  @moduledoc "Stand-in for the controller's id conventions. See `FakeController`."
  use FakeController.Stub

  defstub hub(namespace), do: :default_hub
end

defmodule Flezha.State.Registry do
  @moduledoc "Stand-in for the controller's durable state registry. See `FakeController`."
  use FakeController.Stub

  # Every operative class that has ever persisted, across namespaces.
  defstub operative_classes(), do: []
end

defmodule Flezha.State.Completion do
  @moduledoc """
  Stand-in for the controller's completion records. See `FakeController`.

  `read/1` answers a bare `:error` for a class with no record, exactly as the
  real one does — the seam is what has to cope with that.
  """
  use FakeController.Stub

  defstub read(operative_class), do: :error
end

defmodule Flezha.State.PersistenceResolver do
  @moduledoc "Stand-in for the controller's retention policy. See `FakeController`."
  use FakeController.Stub

  defstub workflow_completed_retention_hours(operative_class), do: 24
end

defmodule Flezha.State.ProcJournal do
  @moduledoc "Stand-in for a durable instance's journal. See `FakeController`."
  use FakeController.Stub

  defstub read(instance_id), do: {:ok, []}
  defstub committed_iterations(instance_id), do: []
  defstub consumed_offset(instance_id), do: 0
end

defmodule Flezha.State.ProcInbox do
  @moduledoc "Stand-in for a durable instance's inbox. See `FakeController`."
  use FakeController.Stub

  defstub undelivered(instance_id), do: []
  defstub read(instance_id), do: []
  defstub last_offset(instance_id), do: 0
end

defmodule Flezha.Operative.PartitionGroup do
  @moduledoc "Stand-in for the controller's partition-group operations. See `FakeController`."
  use FakeController.Stub

  defstub rescale(namespace, group_id, target, opts), do: :ok
end

defmodule Flezha.Operative.Lifecycle do
  @moduledoc "Stand-in for the controller's operative lifecycle calls. See `FakeController`."
  use FakeController.Stub

  defstub rewind(overwatch_pid, to_iter), do: :ok
end

defmodule Flezha.Operative.Kind do
  @moduledoc """
  Stand-in for the controller's kind model. See `FakeController`.

  Carries the real module's table rather than a flat answer: `known_kinds/0`
  probes per candidate, so a stub answering the same thing for every kind could
  not exercise the case this UI exists to handle — a candidate the controller
  does not recognise.
  """
  use FakeController.Stub

  @capabilities %{
    stream: %{
      persistent_state?: true,
      time_travel?: true,
      dynamic_entities?: true,
      output_stall_watch?: true
    },
    workflow: %{}
  }

  defstub known?(kind), do: Map.has_key?(@capabilities, kind)
  defstub capabilities(kind), do: Map.get(@capabilities, kind, %{})
end

defmodule Flezha.AuthZ.NamespaceStore do
  @moduledoc """
  Stand-in for the controller's declared-namespace store. See `FakeController`.

  `get/1` answers a bare `:error` for an unknown name, as the real one does —
  the seam is what turns that into `{:error, :not_found}`.
  """
  use FakeController.Stub

  defstub list(), do: []
  defstub get(name), do: :error
  defstub create(name, opts), do: {:ok, %{name: name, quotas: %{}}}
  defstub delete(name), do: :ok
  defstub set_quotas(name, quotas), do: {:ok, %{name: name, quotas: quotas}}
end

defmodule Flezha.AuthZ.QuotaCounters do
  @moduledoc "Stand-in for the controller's namespace counters. See `FakeController`."
  use FakeController.Stub

  defstub kinds(), do: [:operatives, :entities, :mailbox_bytes, :runners, :disk_bytes]
  # The real store answers a plain integer, and `0` for a counter never set.
  defstub get(namespace, kind), do: 0
end

defmodule Flezha.AuthZ.RoleStore do
  @moduledoc "Stand-in for the controller's role bindings. See `FakeController`."
  use FakeController.Stub

  defstub list_for_namespace(namespace), do: []
end

defmodule Flezha.AuthZ do
  @moduledoc """
  Stand-in for the controller's policy point. See `FakeController`.

  Only the posture is read by the UI: authorization itself is enforced inside
  the controller's service functions, which is where a refusal is produced.
  """
  use FakeController.Stub

  defstub enforcement_posture(), do: :open
end

defmodule Flezha.AuthZ.TokenStore do
  @moduledoc """
  Stand-in for the controller's token store. See `FakeController`.

  The default answer is `:unknown`, so a test that has not issued a token gets
  the unbound path rather than an accidental identity.
  """
  use FakeController.Stub

  defstub verify(token), do: {:error, :unknown}
end
