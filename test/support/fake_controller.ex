defmodule FakeController.Stub do
  @moduledoc """
  Declares one stand-in controller function.

      use FakeController.Stub

      defstub list_relays(ns, %{source: :ui} = ctx), do: {:ok, []}

  Generates the function *and* the key `FakeController` files it under, so the
  two cannot drift. Written by hand they can: a key naming the wrong function
  makes `FakeController.calls/2` answer `[]`, which is exactly what an
  assertion like "nothing reached the controller" checks for — so the drift
  would make that assertion pass for the wrong reason.

  Only plain variables are recorded. An underscore-prefixed one is an argument
  the real API takes but no test asserts on, and a literal pattern such as
  `%{source: :ui}` is a constraint on the caller rather than a value worth
  asserting on. Both would be noise in what a test reads back from
  `FakeController.calls/2`.

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
  Canned answers for the published consumer API `NodeManager` calls.

  Every stand-in carries the name of a module on core's published surface —
  `Flezha.Service.*`, plus the two context-free reads in `Flezha.AuthZ` and
  `Flezha.AuthZ.TokenStore` — and every stub takes the caller context last and
  answers in the shape the core function answers. A stand-in only stands in if
  the code under test reaches it by the name it already uses. Shipped onto a
  peer node, they let a LiveView be driven through the real `:erpc` transport
  against states a live controller cannot be asked to produce — an empty
  controller, a populated dead-letter queue, a refusal, a version-skewed API.

  Shipped to a peer and configured from the test:

      {peer, node} = PeerNode.start_controller!()
      FakeController.set(node, {Flezha.Service.Relay, :list_namespaces}, {:ok, []})

  A stream operation registers the context's `:emit` pid and holds the call
  open until that pid exits, as core does; `emit/3` hands it an event and
  `end_stream/3` makes the operation answer.

  Compiled only under `MIX_ENV=test`, via `elixirc_paths`.
  """

  @table :fake_controller
  @owner :fake_controller_owner

  @doc """
  Every stand-in module, in the order a peer must load them.

  `FakeController` comes first because the rest call it. The audit stand-in
  lives in its own file but is part of the same roster — a peer missing one
  answers `:undef` for that whole subsystem.
  """
  def modules do
    [
      __MODULE__,
      Flezha.Error,
      Flezha.Service.Relay,
      Flezha.Service.Steps,
      Flezha.Service.Fleet,
      Flezha.Service.Namespace,
      Flezha.Service.Dlq,
      Flezha.Service.Schedule,
      Flezha.Service.Controller,
      Flezha.Service.PluginManager,
      Flezha.Service.AuditLog,
      Flezha.Service.Observability,
      Flezha.AuthZ,
      Flezha.AuthZ.TokenStore
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
  An error as the controller answers it, `{:error, %Flezha.Error{}}`, for
  `code` with the class core's catalogue gives it.
  """
  def error(code, message \\ nil), do: {:error, Flezha.Error.new(code, message)}

  @doc """
  A running relay's hook table holding one `on_input` binding of `plugin_id`,
  as the `extensions` of `Relay.overwatch_state/2`'s answer.
  """
  def hook_table(plugin_id),
    do: %{subs: %{on_input: [%{plugin_id: plugin_id, provider: Flezha.Plugin.Provider.StdOut}]}}

  @doc """
  A channel of the graph `Relay.graph/3` answers, as the controller stores a
  runner's announcement.
  """
  def graph_channel(name, kind, producer, consumers, plugin_end \\ "none") do
    %{
      name: name,
      kind: kind,
      producer: producer,
      consumers: consumers,
      plugin_end: plugin_end,
      call_target: nil,
      overflow: "drop_nothing"
    }
  end

  @doc "One tasklet's row of `Relay.activity/3`'s answer: `figures` over an idle tasklet."
  def activity_row(tasklet, figures \\ %{}),
    do:
      Map.merge(
        %{tasklet: tasklet, cells: 1, queued: 0, queued_max: 0, admitted_total: 0},
        figures
      )

  @doc """
  A relay row shaped as `Flezha.Service.Relay.relay_rows/2` answers one, with
  `overrides` applied.

  Every listing, the fleet summary and the cluster rollup read these rows, so
  the shape is written once: when the controller changes it, one fixture is
  wrong rather than six.
  """
  def relay_row(id, overrides \\ %{}) do
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

  @doc """
  One option row as `Flezha.Service.Fleet.provider/2` answers it in `options`,
  with `overrides` applied.

  A row always holds `name`, `type`, `required` and `doc`; core leaves out
  `default`, `values`, `min`, `max`, `live` and `transient` when the provider
  does not declare them, so they appear here only when `overrides` give them.
  """
  def option_row(name, overrides \\ %{}) do
    Map.merge(%{name: to_string(name), type: :any, required: false, doc: nil}, overrides)
  end

  @doc """
  A registry entry for a relay whose builder carries `run`, as
  `Flezha.Service.Relay.registry/2` answers one under the relay's id.
  """
  def registry_entry(run, opts \\ []) do
    builder = %{id: nil, factory_id: "store_input", run: run, init_values: %{}, opts: opts}
    {%{start: {Flezha.Relay, :start_link, [{"default", builder}]}}, [], %{}}
  end

  @doc """
  Answers the calls every relay listing makes: which namespaces the token
  reaches, each namespace's rows (as both `list/2` and `relay_rows/2`), its
  plugin pairs and its registry.

  `:rows` maps a namespace to its rows, `:plugins` is the `relay_plugins/2`
  answer, and `:runs` maps a relay id to its run — every row defaults to
  `:flow`. The registry also carries a `{:plugin, name}` entry, as a real one
  does, so the decoder that skips it is exercised by every listing test.
  """
  def set_fleet(node, opts) do
    rows = Keyword.get(opts, :rows, %{})
    runs = Keyword.get(opts, :runs, %{})
    namespaces = Keyword.get(opts, :namespaces, Map.keys(rows))
    catalog = Enum.map(namespaces, &%{namespace: &1, running: true})

    registry =
      Map.new(rows, fn {namespace, ns_rows} ->
        entries =
          Map.new(ns_rows, fn row ->
            {to_string(row.id), registry_entry(Map.get(runs, to_string(row.id), :flow))}
          end)

        {namespace, {:ok, Map.put(entries, {:plugin, "fixture-plugin"}, {%{}, [], %{}})}}
      end)

    by_namespace = Map.new(rows, fn {namespace, ns_rows} -> {namespace, {:ok, ns_rows}} end)

    set(node, {Flezha.Service.Relay, :list_namespaces}, {:ok, catalog})
    set(node, {Flezha.Service.Relay, :list}, {:per_arg, 0, by_namespace, {:ok, []}})
    set(node, {Flezha.Service.Relay, :relay_rows}, {:per_arg, 0, by_namespace, {:ok, []}})
    set(node, {Flezha.Service.Relay, :relay_plugins}, {:ok, Keyword.get(opts, :plugins, [])})
    set(node, {Flezha.Service.Relay, :registry}, {:per_arg, 0, registry, {:ok, %{}}})
  end

  @doc """
  Hands `event` to every open stream of `{module, function}` on `node`, as
  `{:flezha_emit, event}` to the `:emit` pid its caller context named.
  """
  def emit(node, key, event), do: :erpc.call(node, __MODULE__, :emit_here, [key, event])

  @doc "Makes every open stream of `{module, function}` on `node` answer `answer`."
  def end_stream(node, key, answer),
    do: :erpc.call(node, __MODULE__, :end_here, [key, answer])

  @doc "The emit pids holding an open stream of `{module, function}` on `node`."
  def streams(node, key), do: :erpc.call(node, __MODULE__, :open_streams, [key])

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
    record_call(key, args)

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
  A stream operation, as core runs one: the call is held open in the `:erpc`
  worker, the context's `:emit` pid is handed each event, and the call answers
  once that pid exits, or with what `end_stream/3` gives it. An answer set with
  `set/3` — a refusal — is answered at once instead.
  """
  def stream(key, args, %{emit: emit}, attached \\ []) when is_pid(emit) do
    record_call(key, args)

    case :ets.lookup(store(), key) do
      [{^key, answer}] ->
        answer

      [] ->
        :ets.insert(store(), {{:open_stream, key, self()}, emit})
        Enum.each(attached, &send(emit, {:flezha_emit, &1}))
        ref = Process.monitor(emit)

        receive do
          {:DOWN, ^ref, :process, ^emit, _reason} -> {:ok, :caller_down}
          {:end_stream, answer} -> answer
        after
          60_000 -> {:ok, :window_closed}
        end
        |> tap(fn _ -> :ets.delete(store(), {:open_stream, key, self()}) end)
    end
  end

  defp record_call(key, args), do: :ets.insert(store(), {{:calls, key}, recorded(key) ++ [args]})

  @doc false
  def emit_here(key, event) do
    for {_holder, emit} <- holders(key), do: send(emit, {:flezha_emit, event})
    :ok
  end

  @doc false
  def end_here(key, answer) do
    for {holder, _emit} <- holders(key), do: send(holder, {:end_stream, answer})
    :ok
  end

  @doc false
  def open_streams(key), do: Enum.map(holders(key), &elem(&1, 1))

  defp holders(key) do
    for [holder, emit] <- :ets.match(store(), {{:open_stream, key, :"$1"}, :"$2"}),
        Process.alive?(holder),
        do: {holder, emit}
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
      Process.sleep(:infinity)
    end)

    receive do
      {:fake_controller_store, tid} -> tid
    after
      5_000 -> raise "FakeController store did not start"
    end
  end

  defp lookup(key, default) do
    case :ets.lookup(store(), key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end

defmodule Flezha.Service.Relay do
  @moduledoc "Stand-in for the published relay surface. See `FakeController`."
  use FakeController.Stub

  defstub list_namespaces(%{source: :ui} = ctx), do: {:ok, []}
  defstub list_relays(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub list(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub relay_rows(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub relay_plugins(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub registry(ns, %{source: :ui} = ctx), do: {:ok, %{}}
  defstub partition_groups(rows, %{source: :ui} = ctx), do: {:ok, []}
  defstub info(ns, %{source: :ui} = ctx), do: {:ok, %{namespace: ns, groups: [], relays: []}}
  defstub cell_state(ns, id, cell, %{source: :ui} = ctx), do: {:ok, "{}", 0}
  defstub overwatch_state(ns, id, %{source: :ui} = ctx), do: {:ok, %{}}

  defstub graph(ns, id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{relay: id, factory: "store_input", graph: nil, disagree: false, reason: "not_announced"}}

  defstub activity(ns, id, %{source: :ui} = ctx),
    do: {:ok, %{relay: id, runner: "runner-a", read_at_ms: 0, instance_seq: 1, tasklets: []}}

  # The id the relay runs under: the one asked for, or one the controller draws.
  defstub start(ns, relay, %{source: :ui} = ctx),
    do: {:ok, %{id: Keyword.get(relay, :id, "relay-generated"), outcome: :started}}

  defstub stop(ns, id, %{source: :ui} = ctx), do: {:ok, %{id: id, stopped: :stopped}}

  defstub diagnose(ns, id, %{source: :ui} = ctx),
    do: {:ok, %{relay: id, verdict: :ok, findings: []}}

  defstub api(ns, id, %{source: :ui} = ctx), do: {:ok, []}

  defstub send(ns, id, message, channel, opts, %{source: :ui} = ctx),
    do: {:ok, %{to: id, verdict: :delivered}}

  # The real one answers a 3-tuple, the answer's metadata keyed by text.
  defstub call(ns, id, message, channel, opts, %{source: :ui} = ctx),
    do: {:ok, message, %{"channel" => "out"}}

  defstub call_channel(ns, id, channel, value, opts, %{source: :ui} = ctx),
    do: {:ok, %{accepted: true}}

  defstub replay(ns, path, from, %{source: :ui} = ctx), do: {:ok, %{cell: path, from_seq: 0}}

  def listen(ns, id, direction, opts, %{source: :ui} = ctx),
    do:
      FakeController.stream({__MODULE__, :listen}, [ns, id, direction, opts, ctx], ctx, [
        :attached
      ])
end

defmodule Flezha.Service.Steps do
  @moduledoc "Stand-in for the published steps surface. See `FakeController`."
  use FakeController.Stub

  defstub cells(relay_class, %{source: :ui} = ctx),
    do: {:ok, %{relay_class: relay_class, history_retention_hours: 24, cells: []}}

  defstub time_travel(cell, target, %{source: :ui} = ctx),
    do:
      {:ok, %{cell: cell, target: target, terminal_seq: 0, snapshot_size: 0, change_log_size: 0}}

  defstub completed_retention_hours(relay_class, metadata, %{source: :ui} = ctx), do: {:ok, 24}
  # The real one answers a bare `:error` when there is no record.
  defstub completion(id, %{source: :ui} = ctx), do: :error

  defstub journal(id, %{source: :ui} = ctx),
    do: {:ok, %{instance: id, entries: [], leaf_tasks: [], complete: true}}

  defstub committed_iterations(id, %{source: :ui} = ctx), do: {:ok, []}
  defstub consumed_offset(id, %{source: :ui} = ctx), do: {:ok, nil}
  defstub undelivered(id, %{source: :ui} = ctx), do: {:ok, []}
  defstub last_offset(id, %{source: :ui} = ctx), do: {:ok, -1}
  defstub rescale(ns, group, target, opts, %{source: :ui} = ctx), do: {:ok, %{group: group}}
  defstub rewind(ns, relay_class, to_iter, %{source: :ui} = ctx), do: :ok

  defstub inbox(instance_id, %{source: :ui} = ctx),
    do: {:ok, %{instance: instance_id, floor: -1, entries: []}}

  defstub outbox(cell, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         cell: cell,
         last_persisted_seq: 0,
         outbox_durable_seq: 0,
         outbox_flushed_seq: 0,
         epoch: 0,
         pending: 0,
         held: 0,
         input_watermark: nil
       }}

  defstub rotate(cell, %{source: :ui} = ctx), do: {:ok, %{cell: cell}}
  defstub delete(cell, %{source: :ui} = ctx), do: {:ok, %{cell: cell}}

  defstub set_retention(relay_class, hours, %{source: :ui} = ctx),
    do: {:ok, %{relay_class: relay_class, hours: hours}}
end

defmodule Flezha.Service.Fleet do
  @moduledoc "Stand-in for the published fleet surface. See `FakeController`."
  use FakeController.Stub

  defstub runners(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub factories(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub runners_for_factory(ns, factory_id, %{source: :ui} = ctx), do: {:ok, []}

  defstub runner_caller_context(ns, %{source: :ui} = ctx),
    do: {:ok, %{source: :sdk, principal: "runner@#{ns}", namespace: ns, roles: [:runner]}}

  defstub installed_plugins(%{source: :ui} = ctx), do: {:ok, []}
  defstub providers(%{source: :ui} = ctx), do: {:ok, %{providers: [], refused: 0}}

  defstub provider(provider_id, %{source: :ui} = ctx),
    do: {:ok, %{provider: provider_id, help: nil, type: :relay, hooks: [], options: []}}

  defstub drop_runner(ns, runner_id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         namespace: ns,
         stable_id: "stable-#{runner_id}",
         incarnation: "inc-1",
         pid: 4242,
         node: :"flezha@node-a",
         dropped_at: 1_760_000_000,
         dropped_by: "ops@#{ns}"
       }}

  defstub readmit_runner(ns, stable_id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         namespace: ns,
         stable_id: stable_id,
         incarnation: "inc-1",
         pid: 4242,
         node: :"flezha@node-a",
         dropped_at: 1_760_000_000,
         dropped_by: "ops@#{ns}"
       }}

  defstub dropped_runners(ns, %{source: :ui} = ctx), do: {:ok, []}
end

defmodule Flezha.Service.Namespace do
  @moduledoc "Stand-in for the published namespace surface. See `FakeController`."
  use FakeController.Stub

  defstub list(%{source: :ui} = ctx), do: {:ok, []}
  defstub get(name, %{source: :ui} = ctx), do: FakeController.error("namespace.not_found")

  defstub create(name, opts, %{source: :ui} = ctx),
    do: {:ok, %{name: name, quotas: Keyword.get(opts, :quotas, %{})}}

  defstub delete(name, %{source: :ui} = ctx), do: :ok
  defstub set_quotas(name, quotas, %{source: :ui} = ctx), do: {:ok, %{name: name, quotas: quotas}}

  defstub quota_kinds(%{source: :ui} = ctx),
    do: {:ok, [:relays, :cells, :mailbox_bytes, :runners, :disk_bytes]}

  defstub quota(name, kind, %{source: :ui} = ctx), do: {:ok, 0}
  defstub roles(name, %{source: :ui} = ctx), do: {:ok, []}

  # Without `operations`, as a core older than that field answers, so every
  # control renders unless a test sets a list.
  defstub whoami(%{source: :ui} = ctx),
    do: {:ok, Map.take(ctx, [:principal, :namespace, :role])}

  defstub tokens(%{source: :ui} = ctx), do: {:ok, []}

  defstub issue_token(principal, namespace, role, opts, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         id: "tok-new",
         principal: principal,
         namespace: namespace,
         role: role,
         label: opts[:label],
         status: :active,
         token: "flzt_issued_secret_value"
       }}

  defstub revoke_token(id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         id: id,
         principal: "p",
         namespace: "default",
         role: :viewer,
         label: nil,
         status: :revoked
       }}

  defstub bind_role(principal, role, namespace, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         principal: principal,
         role: role,
         namespace: namespace,
         binding: %{principal: principal, namespace: namespace, roles: [role]}
       }}

  defstub unbind_role(principal, role, %{source: :ui} = ctx),
    do: {:ok, %{principal: principal, role: role, binding: nil}}

  defstub bootstrap(bootstrap_token, %{source: :ui} = ctx),
    do: {:ok, %{principal: "admin-claimed", minted_token: "flzt_minted_admin_secret"}}
end

defmodule Flezha.Service.Dlq do
  @moduledoc "Stand-in for the published dead-letter surface. See `FakeController`."
  use FakeController.Stub

  defstub list(relay_class, %{source: :ui} = ctx), do: {:ok, []}
  defstub get(entry_ref, %{source: :ui} = ctx), do: FakeController.error("dlq.not_found")
  defstub drop(entry_ref, %{source: :ui} = ctx), do: :ok

  defstub replay(entry_ref, %{source: :ui} = ctx),
    do: {:ok, %{outcome: :removed, generation: nil}}

  defstub tasklets(relay_class, %{source: :ui} = ctx), do: {:ok, []}
  defstub stats(%{source: :ui} = ctx), do: {:ok, []}
end

defmodule Flezha.Service.Schedule do
  @moduledoc "Stand-in for the published schedule surface. See `FakeController`."
  use FakeController.Stub

  defstub list(%{source: :ui} = ctx), do: {:ok, []}

  defstub add(fields, %{source: :ui} = ctx),
    do: {:ok, %{entry: Map.new(fields), next_fire: nil, runner_missing: false}}

  defstub remove(name, %{source: :ui} = ctx), do: :ok

  defstub run(name, %{source: :ui} = ctx),
    do: {:ok, %{relay_id: "#{name}@manual-1", outcome: :spawned}}
end

defmodule Flezha.Service.Controller do
  @moduledoc "Stand-in for the published controller surface. See `FakeController`."
  use FakeController.Stub

  defstub status(%{source: :ui} = ctx),
    do:
      {:ok,
       %{
         shutdown_in_progress: false,
         shutdown_phase: nil,
         signal_handler_status: :installed,
         graceful_shutdown_enabled: true,
         graceful_shutdown_timeout_ms: 60_000,
         durability_backend: :none,
         durability_posture: :local_only,
         durability_rpo_breaches: 0,
         durability_levels: %{},
         durability_superseded: 0,
         node: :"flezha@node-a",
         monotonic_us: System.monotonic_time(:microsecond)
       }}

  defstub boot_status(%{source: :ui} = ctx),
    do: {:ok, %{readiness: :ready, preconditions: [], namespaces: []}}

  defstub cluster_status(ns, %{source: :ui} = ctx),
    do: {:ok, %{namespace: ns, nodes: [], unplaced_relays: 0, relay_health: %{}}}

  defstub durability_breaches(%{source: :ui} = ctx), do: {:ok, []}
  defstub mem_top(%{source: :ui} = ctx), do: {:ok, %{}}
  defstub liveness_counters(%{source: :ui} = ctx), do: {:ok, %{channels: [], relays: []}}

  defstub shutdown_status(%{source: :ui} = ctx),
    do:
      {:ok,
       %{
         shutdown_in_progress: false,
         shutdown_phase: nil,
         signal_handler_status: :installed,
         graceful_shutdown_enabled: true,
         graceful_shutdown_timeout_ms: 60_000
       }}

  defstub durability_status(%{source: :ui} = ctx), do: {:ok, []}

  def stop(opts, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :stop}, [opts, ctx], ctx)
end

defmodule Flezha.Service.PluginManager do
  @moduledoc "Stand-in for the published plugin surface. See `FakeController`."
  use FakeController.Stub

  defstub enable(name, fields, %{source: :ui} = ctx),
    do: {:ok, %{name: name, outcome: :enabled, bound: fields[:relay_id], lacking: []}}

  defstub disable(name, fields, %{source: :ui} = ctx), do: {:ok, "plugin disabled"}
  defstub enabled(ns, %{source: :ui} = ctx), do: {:ok, []}
  defstub bind(name, fields, %{source: :ui} = ctx), do: :ok
  defstub unbind(name, fields, %{source: :ui} = ctx), do: :ok

  defstub update(name, fields, %{source: :ui} = ctx),
    do: {:ok, %{applied: :live, relays: []}}
end

defmodule Flezha.Service.Observability do
  @moduledoc "Stand-in for the published observability surface. See `FakeController`."
  use FakeController.Stub

  defstub query(params, %{source: :ui} = ctx), do: {:ok, []}
  defstub list_sources(%{source: :ui} = ctx), do: {:ok, []}
  defstub list_sinks(%{source: :ui} = ctx), do: {:ok, []}
  defstub enable_source(name, %{source: :ui} = ctx), do: :ok
  defstub disable_source(name, %{source: :ui} = ctx), do: :ok

  def tail(source, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :tail}, [source, ctx], ctx)
end

defmodule Flezha.AuthZ do
  @moduledoc "Stand-in for the context-free enforcement posture read. See `FakeController`."
  use FakeController.Stub

  defstub enforcement_posture(), do: :open
end

defmodule Flezha.AuthZ.TokenStore do
  @moduledoc "Stand-in for the context-free token verification. See `FakeController`."
  use FakeController.Stub

  defstub verify(token), do: FakeController.error("authz.token_unknown")
end
