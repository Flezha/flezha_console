defmodule FakeController.Stub do
  @moduledoc """
  Declares one stand-in controller function.

      use FakeController.Stub

      defstub list(ns, %{source: :ui} = ctx), do: {:ok, []}

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
  `Flezha.Service.*`, plus the context-free posture read in `Flezha.AuthZ` —
  and every stub takes the caller context last and answers in the shape the
  core function answers. `Flezha.Service.Admin` stands in for core's door,
  which is how the code under test reaches them. Shipped onto a
  peer node, they let a LiveView be driven through the real `:erpc` transport
  against states a live controller cannot be asked to produce — an empty
  controller, a populated dead-letter queue, a refusal, a version-skewed API.

  Shipped to a peer and configured from the test:

      {peer, node} = PeerNode.start_controller!()
      FakeController.set(node, {Flezha.Service.Relay, :list_namespaces}, FakeController.rows([]))

  A stream operation registers the context's `:emit` pid and holds the call
  open until that pid exits, as core does; `emit/3` hands it an event and
  `end_stream/3` makes the operation answer.

  Compiled only under `MIX_ENV=test`, via `elixirc_paths`.
  """

  @table :fake_controller
  @owner :fake_controller_owner

  @doc """
  Every stand-in module, in the order a peer must load them.

  `FakeController` comes first because the rest call it. The logs stand-in
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
      Flezha.Service.Logs,
      Flezha.Service.Observability,
      Flezha.Service.Admin,
      Flezha.AuthZ
    ]
  end

  @doc """
  Makes `{module, function}` answer `value` on `node`.

  For a controller that answers differently per call — a factory listing per
  namespace, the runners serving each factory — `value` may be
  `{:per_arg, index, by_arg, default}`: the answer looked up by the call's
  `index`-th recorded argument, or with `{index, field}` by that argument's
  `field`, such as the `kind` a logs call names.

      FakeController.set(node, {FleetManager, :runners_for_factory},
        {:per_arg, 1, %{"store_input" => {:ok, ["runner-a"]}}, {:ok, []}})

  It may *not* be a closure written in a test module. The peer never loads that
  module, so applying one there raises `:undef` — which the seam then reports
  as a version-skewed controller, and the test passes or fails for the wrong
  reason. A function is applied only when it comes from a module the peer has.
  """
  def set(node, key, value), do: :erpc.call(node, __MODULE__, :put, [key, value])

  @doc """
  Holds every answer set as `{:gated, gate, value}` on `node` until
  `open_gate/2`: a controller that is slow for as long as the test says. Each
  call the gate holds tells the caller of `close_gate/2`
  `{:gate_reached, gate}`, so a test can wait for a read to get that far.

      FakeController.close_gate(node, :slow)
      FakeController.set(node, {Relay, :relay_rows}, {:gated, :slow, FakeController.rows(rows)})
      assert_receive {:gate_reached, :slow}
  """
  def close_gate(node, gate), do: set(node, {:gate, gate}, {:closed, self()})

  @doc "Lets every answer held by `gate` on `node` through, and every later one."
  def open_gate(node, gate), do: :erpc.call(node, __MODULE__, :open_here, [gate])

  @doc """
  Clears every answer and call record on `node`, and the identities and posture
  this VM cached from earlier answers, so one test cannot leak into the next.
  """
  def reset(node) do
    :ets.delete_all_objects(:flezha_console_authz_cache)
    :erpc.call(node, __MODULE__, :clear, [])
  end

  @doc "The argument lists `{module, function}` was called with, oldest first."
  def calls(node, key), do: :erpc.call(node, __MODULE__, :recorded, [key])

  @doc """
  An error as the controller answers it, `{:error, %Flezha.Error{}}`, for
  `code` with the class core's catalogue gives it.
  """
  def error(code, message \\ nil), do: {:error, Flezha.Error.new(code, message)}

  @doc """
  A cluster read's answer: `rows` from the controllers that answered, and
  the ones in `unreachable` that did not.

      FakeController.set(node, {Flezha.Service.Dlq, :list},
        FakeController.rows([entry], ["flezha@c3"]))
  """
  def rows(rows, unreachable \\ []),
    do: {:ok, %{rows: rows, unreachable: Enum.map(unreachable, &to_node/1)}}

  @doc """
  A logs read's answer: `records` newest first, the `next` cursor a further
  read continues from, and the controllers in `unreachable` that did not
  answer.
  """
  def log_page(records, next \\ nil, unreachable \\ []),
    do: {:ok, %{records: records, next: next, unreachable: Enum.map(unreachable, &to_node/1)}}

  @doc """
  `Namespace.quota/3`'s answer: the cluster's `total`, all on
  `flezha@node-a` unless `by_node` splits it, and the controllers that did not
  count.
  """
  def quota_usage(total, by_node \\ nil, unreachable \\ []) do
    {:ok,
     %{
       total: total,
       by_node: by_node || %{"flezha@node-a": total},
       unreachable: Enum.map(unreachable, &to_node/1)
     }}
  end

  defp to_node(node) when is_atom(node), do: node
  defp to_node(node) when is_binary(node), do: String.to_atom(node)

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
      call_create: nil,
      call_deadline_ms: nil,
      retry_max: nil,
      retry_backoff_ms: nil,
      overflow: "drop_nothing"
    }
  end

  @doc """
  A tasklet of an announced graph, with `overrides` applied: one Cell, a
  mailbox of 1024, and no `compensate` hook.
  """
  def graph_tasklet(name, overrides \\ %{}) do
    Map.merge(
      %{
        name: name,
        mode: "single",
        cell_keys: [],
        mailbox_capacity: 1024,
        compensates: false,
        idle_ttl_ms: nil,
        max_cells: nil
      },
      overrides
    )
  end

  @doc """
  The graph `Relay.graph/3` answers for `channels`, with one tasklet for each
  name a channel produces or consumes. `cell_keys` maps a tasklet name to its
  announced Cell keys, which makes it a static tasklet; `compensates` maps a
  tasklet name to its announced `compensates`.
  """
  def graph_answer(channels, opts \\ []) do
    cell_keys = Keyword.get(opts, :cell_keys, %{})
    compensates = Keyword.get(opts, :compensates, %{})

    names =
      channels
      |> Enum.flat_map(&[&1.producer | &1.consumers])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    %{
      relay: Keyword.get(opts, :relay, "relay_a"),
      factory: Keyword.get(opts, :factory, "static_cell"),
      disagree: false,
      reason: nil,
      graph: %{
        channels: channels,
        tasklets:
          for name <- names do
            keys = Map.get(cell_keys, name, [])
            mode = if keys == [], do: "single", else: "static"

            graph_tasklet(name, %{
              mode: mode,
              cell_keys: keys,
              compensates: Map.get(compensates, name, false)
            })
          end
      }
    }
  end

  @doc """
  A factory row as `Flezha.Service.Fleet.factories/2` answers one, with
  `overrides` applied: a steps factory run once per start and undone whole
  on failure, kept on its controller's disk, served by `runner-a` on
  `flezha@node-a`.
  """
  def factory_row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: to_string(id),
        description: nil,
        run: :steps,
        each: :once,
        on_failure: :undo_all,
        runners: ["runner-a"],
        nodes: [:"flezha@node-a"],
        api: [],
        api_at: System.os_time(),
        api_disagree: false,
        declarations: declarations(),
        declarations_disagree: false
      },
      overrides
    )
  end

  @doc """
  A factory's declarations as its row carries them, with `overrides` applied:
  a steps class kept on disk that sleeps after six idle hours and declares
  nothing else.
  """
  def declarations(overrides \\ %{}) do
    Map.merge(
      %{
        durable: :local,
        sleep_after_ms: 21_600_000,
        max_duration_ms: nil,
        effectively_once: nil,
        ack: nil,
        correction_ms: nil,
        keyed: nil,
        keep_finished: nil
      },
      overrides
    )
  end

  @doc """
  `Fleet.factory/3`'s answer for `row`: the row with its announced `graph`
  (`graph_answer/2`'s, or `nil`), `disagree` and the controllers that did not
  answer.
  """
  def factory_answer(row, graph \\ nil, opts \\ []) do
    {:ok,
     Map.merge(row, %{
       graph: graph && graph.graph,
       disagree: Keyword.get(opts, :disagree, false),
       unreachable: Keyword.get(opts, :unreachable, [])
     })}
  end

  @doc """
  `Relay.graph/3`'s answer for a relay of one tasklet, `work`, between an entry
  channel `input` and an output channel `out`: the smallest graph with a port on
  each edge.
  """
  def one_tasklet_graph(relay_id) do
    {:ok,
     graph_answer(
       [
         graph_channel("input", "entry", nil, ["work"]),
         graph_channel("out", "plugin_bound", "work", [], "output")
       ],
       relay: relay_id,
       factory: "store_input"
     )}
  end

  @doc "One tasklet's row of `Relay.activity/4`'s answer: `figures` over an idle tasklet."
  def activity_row(tasklet, figures \\ %{}),
    do:
      Map.merge(
        %{
          tasklet: tasklet,
          cells: 1,
          queued: 0,
          queued_max: 0,
          admitted_total: 0,
          blocked_total: 0,
          dropped_newest_total: 0,
          dropped_oldest_total: 0,
          dropped_capped_total: nil,
          cells_created_total: nil,
          cells_evicted_total: nil
        },
        figures
      )

  @doc """
  One Cell's row of `Relay.activity/4`'s `cells.rows`, asked with `cells_of`:
  `figures` over a Cell that has taken nothing.
  """
  def cell_row(key, figures \\ %{}),
    do:
      Map.merge(
        %{
          key: key,
          queued: 0,
          admitted_total: 0,
          blocked_total: 0,
          dropped_newest_total: 0,
          dropped_oldest_total: 0,
          last_admitted_ms: 0
        },
        figures
      )

  @doc """
  A provider of `Fleet.providers/1`'s listing: `feeds` says whether its
  plugins inject records into a relay, and `nodes` names the controllers that
  can enable it.
  """
  def provider_entry(id, module, feeds \\ false),
    do: %{id: id, module: module, type: :relay, feeds: feeds, nodes: [:"flezha@node-a"]}

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
  A controller row shaped as `Flezha.Service.Controller.controllers/1`
  answers one for the answering controller `flezha@<host>`, with `overrides`
  applied.
  """
  def controller_row(host, overrides \\ %{}) do
    Map.merge(
      %{
        node: :"flezha@#{host}",
        host: host,
        host_node: nil,
        version: "0.1.2",
        uptime_ms: 3_600_000,
        runners: 1,
        local?: true,
        reachable?: true
      },
      overrides
    )
  end

  @doc """
  A row of `Flezha.Service.Controller.status/1`'s answer for the controller
  `flezha@<host>`, with `overrides` applied.
  """
  def status_row(host, overrides \\ %{}) do
    Map.merge(
      %{
        shutdown_in_progress: false,
        shutdown_phase: nil,
        signal_handler_status: :ok,
        graceful_shutdown_enabled: true,
        graceful_shutdown_timeout_ms: 60_000,
        durability_backend: :none,
        durability_posture: :local_only,
        durability_rpo_breaches: 0,
        durability_levels: %{},
        durability_superseded: 0,
        node: :"flezha@#{host}",
        file_plugin_root: "/flezha/storage/app/files",
        state_root: "/flezha/storage/app/state",
        monotonic_us: System.monotonic_time(:microsecond)
      },
      overrides
    )
  end

  @doc """
  A row of `Flezha.Service.Controller.boot_status/1`'s answer for the
  controller `flezha@<host>`, ready, with `overrides` applied.
  """
  def boot_row(host, overrides \\ %{}),
    do:
      Map.merge(
        %{node: :"flezha@#{host}", readiness: :ready, preconditions: [], namespaces: []},
        overrides
      )

  @doc """
  A runner row shaped as `Flezha.Service.Fleet.runners/2` answers one, with
  `overrides` applied: connected two hours ago, heard from three seconds ago.
  """
  def runner_row(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: to_string(id),
        node: :"flezha@node-a",
        connected_at: System.system_time(:second) - 7_200,
        pid: nil,
        silent_ms: 3_000,
        late?: false
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

    {%{
       id: "relay",
       restart: :temporary,
       shutdown: 5_000,
       start: {Flezha.Relay, :start_link, [{"default", "runner-a", builder}]}
     }, [], %{}}
  end

  @doc """
  A log kind as `Flezha.Service.Logs.kinds/1` declares one, with
  `overrides` applied. `audit` and `relay_history` carry core's own filters
  and columns; any other id is a kind with one text filter, `name`, and the
  columns time, name and controller.
  """
  def log_kind(id, overrides \\ %{}) do
    {title, description, filters, columns} = kind_declaration(id)

    Map.merge(
      %{
        id: id,
        title: title,
        description: description,
        enabled: true,
        disabled_reason: nil,
        filters: filters,
        columns: columns
      },
      overrides
    )
  end

  defp kind_declaration("audit") do
    {"Audit log", "Who did what.",
     [
       log_filter("source", "Source"),
       log_filter("name", "Name"),
       log_filter("namespace", "Namespace")
     ], log_columns(~w(ts_iso source name caller namespace node))}
  end

  defp kind_declaration("relay_history") do
    {"Relay history", "Each relay run's start and end.",
     [
       log_filter("namespace", "Namespace"),
       log_filter("factory", "Factory"),
       log_filter("relay", "Relay"),
       log_filter("event", "Event", ~w(started ended start_failed)),
       log_filter(
         "outcome",
         "Outcome",
         ~w(completed undone failed stopped timed_out rescaled_away cancelled)
       )
     ],
     log_columns(
       ~w(ts_iso event namespace relay factory run origin outcome duration_ms halted error node)
     )}
  end

  defp kind_declaration(id) do
    {String.capitalize(id), "The #{id} log.", [log_filter("name", "Name")],
     log_columns(~w(ts_iso name node))}
  end

  defp log_filter(field, label, values \\ nil),
    do: %{field: field, label: label, type: if(values, do: "enum", else: "text"), values: values}

  defp log_columns(fields) do
    for field <- fields do
      label =
        case field do
          "ts_iso" -> "Time"
          "node" -> "Controller"
          "duration_ms" -> "Duration (ms)"
          other -> String.capitalize(other)
        end

      %{field: field, label: label, type: if(field == "ts_iso", do: "time", else: "text")}
    end
  end

  @doc """
  A relay history record as `Flezha.Service.Logs.read/2` answers one, keyed
  by string as decoded from its file: a `started` record of `relay` from
  `store_input`, started by an operator through the UI on `flezha@node-a`,
  with `overrides` applied. An `ended` record also carries `outcome`,
  `halted`, `duration_ms` and `error`, which `overrides` give.
  """
  def history_record(relay, overrides \\ %{}) do
    ts_us = System.os_time(:microsecond)

    Map.merge(
      %{
        "ts_us" => ts_us,
        "ts_iso" => ts_us |> DateTime.from_unix!(:microsecond) |> DateTime.to_iso8601(),
        "event" => "started",
        "namespace" => "default",
        "relay" => relay,
        "factory" => "store_input",
        "run" => "steps",
        "origin" => %{"kind" => "operator", "principal" => "ops@acme", "source" => "ui"},
        "first_started_at" => div(ts_us, 1_000),
        "node" => "flezha@node-a"
      },
      overrides
    )
  end

  @doc """
  One controller's row of `Flezha.Service.Logs.stats/2`, with `overrides`
  applied: a current file of 12 records on `node`.
  """
  def log_stats_row(node, overrides \\ %{}) do
    Map.merge(
      %{
        node: node,
        current_file: "storage/app/logs/relay_history-current.jsonl",
        current_file_bytes: 2_048,
        record_count: 12,
        total_bytes: 2_048,
        total_files: 1,
        oldest_ts_us: nil,
        fsync_mode: :group_commit,
        closed: false,
        dropped_count: 0,
        timeout_count: 0,
        post_close_dropped: 0
      },
      overrides
    )
  end

  @doc """
  One rotated file as `Flezha.Service.Logs.files/2` lists it on `node`, with
  `overrides` applied.
  """
  def log_file_row(node, filename, overrides \\ %{}) do
    Map.merge(
      %{
        node: node,
        filename: filename,
        first_ts_us: 1_793_270_000_000_000,
        last_ts_us: 1_793_271_000_000_000,
        record_count: 40,
        size_bytes: 8_192,
        sha256: String.duplicate("a", 64)
      },
      overrides
    )
  end

  @doc """
  Answers the calls every relay listing makes: which namespaces the token
  reaches, each namespace's rows (as both `list/2` and `relay_rows/2`), its
  plugin pairs and its registry.

  `:rows` maps a namespace to its rows, `:plugins` is the `relay_plugins/2`
  answer's rows, `:runs` maps a relay id to its run — every row defaults to
  `:flow` — and `:unreachable` names controllers the row reads lack. The registry also carries a `{:plugin, name}` entry, as a real one
  does, so the decoder that skips it is exercised by every listing test.
  """
  def set_fleet(node, opts) do
    rows = Keyword.get(opts, :rows, %{})
    runs = Keyword.get(opts, :runs, %{})
    unreachable = Keyword.get(opts, :unreachable, [])
    namespaces = Keyword.get(opts, :namespaces, Map.keys(rows))
    catalog = Enum.map(namespaces, &%{namespace: &1, running: true, nodes: [:"flezha@node-a"]})

    registry =
      Map.new(rows, fn {namespace, ns_rows} ->
        entries =
          Map.new(ns_rows, fn row ->
            {to_string(row.id), registry_entry(Map.get(runs, to_string(row.id), :flow))}
          end)

        {namespace, {:ok, Map.put(entries, {:plugin, "fixture-plugin"}, {%{}, [], %{}})}}
      end)

    by_namespace =
      Map.new(rows, fn {namespace, ns_rows} -> {namespace, rows(ns_rows, unreachable)} end)

    set(node, {Flezha.Service.Relay, :list_namespaces}, rows(catalog))
    set(node, {Flezha.Service.Relay, :list}, {:per_arg, 0, by_namespace, rows([])})
    set(node, {Flezha.Service.Relay, :relay_rows}, {:per_arg, 0, by_namespace, rows([])})
    set(node, {Flezha.Service.Relay, :relay_plugins}, rows(Keyword.get(opts, :plugins, [])))
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
  # A reset lets held answers through, so no call outlives its test.
  def clear do
    for [gate] <- :ets.match(store(), {{:gate, :"$1"}, {:closed, :_}}), do: open_here(gate)
    :ets.delete_all_objects(store())
    :ok
  end

  @doc false
  # The gate opens before its waiters are read, and a waiter registers before
  # it reads the gate, so no waiter misses its release.
  def open_here(gate) do
    :ets.insert(store(), {{:gate, gate}, :open})

    for [waiter] <- :ets.match(store(), {{:gate_waiter, gate, :"$1"}, true}) do
      :ets.delete(store(), {:gate_waiter, gate, waiter})
      send(waiter, {:gate_open, gate})
    end

    :ok
  end

  defp await_gate(gate) do
    :ets.insert(store(), {{:gate_waiter, gate, self()}, true})

    case lookup({:gate, gate}, :open) do
      {:closed, test} ->
        send(test, {:gate_reached, gate})

        receive do
          {:gate_open, ^gate} -> :ok
        end

      :open ->
        :ets.delete(store(), {:gate_waiter, gate, self()})
    end
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
      [{^key, {:gated, gate, value}}] ->
        await_gate(gate)
        value

      [{^key, {:per_arg, {index, field}, by_arg, fallback}}] ->
        Map.get(by_arg, args |> Enum.at(index) |> Access.get(field), fallback)

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

  defstub list_namespaces(%{source: :ui} = ctx), do: FakeController.rows([])
  defstub list(ns, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub relay_rows(ns, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub relay_plugins(ns, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub registry(ns, %{source: :ui} = ctx), do: {:ok, %{}}
  defstub partition_groups(rows, %{source: :ui} = ctx), do: {:ok, []}

  defstub cell_state(ns, id, cell, %{source: :ui} = ctx), do: {:ok, "{}", 0}
  defstub overwatch_state(ns, id, %{source: :ui} = ctx), do: {:ok, %{}}

  defstub graph(ns, id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{relay: id, factory: "store_input", graph: nil, disagree: false, reason: "not_announced"}}

  # Asked with `cells_of`, a runner keeping no per-Cell figures answers `nil`.
  defstub activity(ns, id, opts, %{source: :ui} = ctx),
    do:
      {:ok,
       %{relay: id, runner: "runner-a", read_at_ms: 0, instance_seq: 1, tasklets: [], cells: nil}}

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

  defstub completed_retention_hours(relay_class, %{source: :ui} = ctx), do: {:ok, 24}
  # The real one answers a bare `:error` when there is no record.
  defstub completion(id, %{source: :ui} = ctx), do: :error

  defstub journal(id, %{source: :ui} = ctx),
    do: {:ok, %{instance: id, entries: [], outcome: nil}}

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
  defstub factories(ns, %{source: :ui} = ctx), do: FakeController.rows([])

  defstub factory(ns, factory_id, %{source: :ui} = ctx),
    do: FakeController.factory_answer(FakeController.factory_row(factory_id))

  defstub runners_for_factory(ns, factory_id, %{source: :ui} = ctx), do: FakeController.rows([])

  defstub runner_caller_context(ns, %{source: :ui} = ctx),
    do: {:ok, %{source: :sdk, principal: "runner@#{ns}", namespace: ns, roles: [:runner]}}

  defstub installed_plugins(%{source: :ui} = ctx), do: FakeController.rows([])

  defstub providers(%{source: :ui} = ctx),
    do: {:ok, %{rows: [], refused: %{"flezha@node-a": 0}, unreachable: []}}

  defstub provider(provider_id, %{source: :ui} = ctx),
    do:
      {:ok,
       %{provider: provider_id, help: nil, type: :relay, feeds: false, hooks: [], options: []}}

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

  defstub set_quotas(name, quotas, %{source: :ui} = ctx), do: {:ok, %{name: name, quotas: quotas}}

  defstub quota_kinds(%{source: :ui} = ctx),
    do: {:ok, [:relays, :cells, :mailbox_bytes, :runners, :disk_bytes]}

  defstub quota(name, kind, %{source: :ui} = ctx), do: FakeController.quota_usage(0)

  defstub roles(name, %{source: :ui} = ctx), do: {:ok, []}

  # Without `operations`, as a core older than that field answers, so every
  # control renders unless a test sets a list.
  defstub whoami(%{source: :ui} = ctx),
    do: {:ok, Map.take(ctx, [:principal, :namespace, :role])}

  defstub tokens(%{source: :ui} = ctx), do: {:ok, []}
end

defmodule Flezha.Service.Dlq do
  @moduledoc "Stand-in for the published dead-letter surface. See `FakeController`."
  use FakeController.Stub

  defstub list(relay_class, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub get(entry_ref, %{source: :ui} = ctx), do: FakeController.error("dlq.not_found")
  defstub drop(entry_ref, %{source: :ui} = ctx), do: :ok

  defstub replay(entry_ref, %{source: :ui} = ctx),
    do: {:ok, %{outcome: :removed, generation: nil}}

  defstub tasklets(relay_class, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub stats(%{source: :ui} = ctx), do: FakeController.rows([])
end

defmodule Flezha.Service.Schedule do
  @moduledoc "Stand-in for the published schedule surface. See `FakeController`."
  use FakeController.Stub

  defstub list(%{source: :ui} = ctx), do: FakeController.rows([])

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
    do: FakeController.rows([FakeController.status_row("node-a")])

  defstub boot_status(%{source: :ui} = ctx),
    do: FakeController.rows([FakeController.boot_row("node-a")])

  defstub cluster_status(ns, %{source: :ui} = ctx),
    do:
      {:ok,
       %{
         namespace: ns,
         nodes: [],
         unplaced_relays: 0,
         relay_health: %{},
         answered_by: :"flezha@node-a",
         unreachable: []
       }}

  defstub controllers(%{source: :ui} = ctx),
    do: FakeController.rows([FakeController.controller_row("node-a")])

  defstub durability_breaches(%{source: :ui} = ctx), do: FakeController.rows([])
  defstub mem_top(%{source: :ui} = ctx), do: FakeController.rows([])

  defstub liveness_counters(%{source: :ui} = ctx),
    do: {:ok, %{channels: [], relays: [], unreachable: []}}

  defstub durability_status(%{source: :ui} = ctx), do: FakeController.rows([])
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

  defstub query(params, %{source: :ui} = ctx), do: FakeController.rows([])
  defstub list_sources(%{source: :ui} = ctx), do: FakeController.rows([])
  defstub list_sinks(%{source: :ui} = ctx), do: FakeController.rows([])

  defstub enable_source(name, %{source: :ui} = ctx),
    do: {:ok, %{applied: [:"flezha@node-a"], unreachable: []}}

  defstub disable_source(name, %{source: :ui} = ctx),
    do: {:ok, %{applied: [:"flezha@node-a"], unreachable: []}}

  def tail(source, %{source: :ui} = ctx),
    do: FakeController.stream({__MODULE__, :tail}, [source, ctx], ctx)
end

defmodule Flezha.AuthZ do
  @moduledoc "Stand-in for the context-free enforcement posture read. See `FakeController`."
  use FakeController.Stub

  defstub enforcement_posture(), do: :open
end

defmodule Flezha.Service.Admin do
  @moduledoc """
  Stand-in for core's door. See `FakeController`.

  `run/4` records the operation's name, applies the stand-in it names with the
  caller context appended, and answers as core's door does: `{:ok, value, more}` as
  `{:ok, [value, more]}`, and any other answer that is not `{:ok, _}` or an
  error wrapped in `{:ok, _}`. An operation no stand-in defines is refused with
  `control.unknown_function`, as core refuses one it does not publish.
  """
  use FakeController.Stub

  defstub context(source, token), do: FakeController.error("authz.token_unknown")

  def run(name, args, context, :given),
    do: FakeController.answer({__MODULE__, :run}, [name], dispatch(name, args, context))

  defp dispatch(name, args, context) do
    [module, function] = String.split(name, ".", parts: 2)
    module = Module.concat(Flezha.Service, module)
    function = String.to_atom(function)

    if function_exported?(module, function, length(args) + 1),
      do: module |> apply(function, args ++ [context]) |> answer(),
      else: FakeController.error("control.unknown_function")
  end

  defp answer({:error, _reason} = refused), do: refused
  defp answer({:ok, value}), do: {:ok, value}
  defp answer({:ok, value, more}), do: {:ok, [value, more]}
  defp answer(other), do: {:ok, other}
end
