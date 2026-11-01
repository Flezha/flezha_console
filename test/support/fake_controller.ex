defmodule FakeController.Stub do
  @moduledoc """
  Declares one stand-in controller function.

      use FakeController.Stub

      defstub list(ns, ctx), do: {:ok, []}

  Generates the function *and* the key `FakeController` files it under, so the
  two cannot drift. Written by hand they can: a key naming the wrong function
  makes `FakeController.calls/2` answer `[]`, which is exactly what an
  assertion like "nothing reached the controller" checks for — so the drift
  would make that assertion pass for the wrong reason.

  A paged read, which core declares with a trailing `opts`, names the read it
  pages as and calls its `opts` argument `opts`:

      defstub list(ns, opts, ctx), paged: :relay_list, do: FakeController.rows([])

  It answers the page `FakeController.page/3` cuts from whatever the read
  answers whole, so a test sets the whole collection and the screen reads it
  page by page, as from core.

  Only plain variables are recorded. An underscore-prefixed one is an argument
  the real API takes but no test asserts on, and a literal pattern is a
  constraint on the caller rather than a value worth asserting on. Both would
  be noise in what a test reads back from `FakeController.calls/2`.
  """

  defmacro __using__(_opts) do
    quote do: import(FakeController.Stub, only: [defstub: 2])
  end

  defmacro defstub(call, opts) do
    {name, _meta, params} = call
    recorded = params |> List.wrap() |> Enum.filter(&recorded?/1)
    default = Keyword.fetch!(opts, :do)

    answer =
      quote do
        FakeController.answer({__MODULE__, unquote(name)}, unquote(recorded), unquote(default))
      end

    answer =
      case Keyword.fetch(opts, :paged) do
        {:ok, read} ->
          page_opts =
            Enum.find(params, &match?({:opts, _meta, context} when is_atom(context), &1))

          quote do: FakeController.page(unquote(read), unquote(page_opts), unquote(answer))

        :error ->
          answer
      end

    quote do
      def unquote(call), do: unquote(answer)
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
  Canned answers for the published consumer API `NodeManager` calls.

  Every stand-in carries the name of a module on core's published surface —
  `Flezha.Service.*` — and every stub takes the caller context last and
  answers in the shape the core function answers. `Flezha.Service.Admin`
  stands in for core's door. `FlezhaConsole.FakeListener` serves them over the
  controller's channel in the test VM, so a LiveView is driven through the
  real HTTP transport and the real decoder against states a live controller
  cannot be asked to produce — an empty controller, a populated dead-letter
  queue, a refusal, a version-skewed API.

  A stub is applied to the arguments as they crossed the wire, decoded from
  JSON, and is handed `%{source: :http, token: token}` as its context: the
  bearer token the console sent. Every function here takes the listener's
  handle first, which holds its store:

      controller = FlezhaConsole.FakeListener.start!()
      FakeController.set(controller, {Flezha.Service.Relay, :list_namespaces}, FakeController.rows([]))

  A stream operation registers the context's `:emit` pid and holds the call
  open until that pid exits, as core does; `emit/3` hands it an event and
  `end_stream/3` makes the operation answer.

  Compiled only under `MIX_ENV=test`, via `elixirc_paths`.
  """

  @doc "Every stand-in module: the published modules the console calls, and core's door."
  def modules do
    [
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
      Flezha.Service.Admin
    ]
  end

  @doc """
  Makes `{module, function}` answer `value` on `controller`.

  For a controller that answers differently per call — a factory listing per
  namespace, the runners serving each factory — `value` may be
  `{:per_arg, index, by_arg, default}`: the answer looked up by the call's
  `index`-th recorded argument, or with `{index, field}` by that argument's
  `field`, such as the `kind` a logs call names.

      FakeController.set(controller, {Fleet, :runners_for_factory},
        {:per_arg, 1, %{"store_input" => {:ok, ["runner-a"]}}, {:ok, []}})

  It may also be a function, applied to the call's arguments.
  """
  def set(%{store: store}, key, value) do
    :ets.insert(store, {key, value})
    :ok
  end

  @doc """
  Holds every answer set as `{:gated, gate, value}` on `controller` until
  `open_gate/2`: a controller that is slow for as long as the test says. Each
  call the gate holds tells the caller of `close_gate/2`
  `{:gate_reached, gate}`, so a test can wait for a read to get that far.

      FakeController.close_gate(controller, :slow)
      FakeController.set(controller, {Relay, :list}, {:gated, :slow, FakeController.rows(rows)})
      assert_receive {:gate_reached, :slow}
  """
  def close_gate(controller, gate), do: set(controller, {:gate, gate}, {:closed, self()})

  @doc "Lets every answer held by `gate` on `controller` through, and every later one."
  def open_gate(%{store: store}, gate), do: open_here(store, gate)

  @doc """
  Clears every answer and call record on `controller`, and the identities this
  VM cached from earlier answers, so one test cannot leak into the next.
  """
  def reset(%{store: store}) do
    :ets.delete_all_objects(:flezha_console_authz_cache)
    for [gate] <- :ets.match(store, {{:gate, :"$1"}, {:closed, :_}}), do: open_here(store, gate)
    :ets.delete_all_objects(store)
    :ok
  end

  @doc "The argument lists `{module, function}` was called with, oldest first, each ending with its context."
  def calls(%{store: store}, key), do: lookup(store, {:calls, key}, [])

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

  # The sorts and filter keys each paged read declares, as core's
  # `Flezha.Cluster.Page.parse/3` is told them.
  @paged_reads %{
    relay_list: [
      sorts: [id: :asc, severity: :asc],
      filters: [:health, :factory, :runner, :node, :group, :ids, :text, :run]
    ],
    plugin_list: [sorts: [name: :asc], filters: [:provider, :relay, :text]],
    liveness_counters: [sorts: [relay: :asc], filters: [:relays, :namespace]],
    dlq_list: [sorts: [newest: :desc]],
    journal: [sorts: [seq: :desc]],
    committed_iterations: [sorts: [iteration: :desc]],
    undelivered: [sorts: [offset: :asc]],
    cells: [sorts: [key: :asc], filters: [:text]]
  }

  # The health words in core's rank order, worst last.
  @health_rank [
    :healthy,
    :unknown,
    :suspended,
    :degraded,
    :recovering,
    :unbound,
    :failed,
    :halted
  ]

  @doc """
  The page of `answer`, the whole collection a paged `read` answers without
  `opts`, that `opts` asks for: `%{rows:, total:, next:, unreachable:}` and
  what else core's page of that read carries — a relay list's `summary`, a
  plugin row's sample of 10 relays and `relay_count`. Opts core refuses are
  refused with core's codes, before anything is read. An answer that is
  already a page, or a refusal, is answered as it is.

  Each read cuts its page as core does: a relay list filters and sorts by
  `id` or `severity`, its summary counted over every row; liveness counters
  keep the named relays, or a namespace's, and with `limit: 0` only that
  namespace's `totals`.
  """
  def page(_read, opts, answer) when opts in [[], %{}], do: answer
  def page(_read, _opts, {:error, _reason} = refused), do: refused
  def page(_read, _opts, {:ok, %{total: _}} = page), do: page

  def page(read, opts, {:ok, whole}) do
    declared = Map.fetch!(@paged_reads, read)
    opts = Map.new(opts, fn {key, value} -> {page_key(key), value} end)

    case parse_page(opts, declared, read) do
      {:ok, page} -> {:ok, cut(read, whole, page)}
      refused -> refused
    end
  end

  defp parse_page(opts, declared, read) do
    keys =
      if read == :liveness_counters, do: [:filter, :limit], else: [:limit, :after, :sort, :filter]

    sorts = Keyword.fetch!(declared, :sorts)

    with :ok <- known_keys(Map.keys(opts), keys),
         {:ok, limit} <- page_limit(Map.get(opts, :limit, 50)),
         {:ok, sort} <- page_sort(Map.get(opts, :sort), sorts),
         {:ok, filter} <- page_filter(Map.get(opts, :filter, []), declared[:filters] || []),
         {:ok, offset} <- page_cursor(Map.get(opts, :after), read, sort) do
      {:ok, %{limit: limit, sort: sort, filter: filter, offset: offset}}
    end
  end

  # The JSON names a page's options cross the wire with.
  defp page_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp page_key(key), do: key

  defp known_keys(keys, allowed) do
    case Enum.find(keys, &(&1 not in allowed)) do
      nil -> :ok
      key -> error("control.unknown_parameter", "unknown parameter '#{key}'")
    end
  end

  defp page_limit(n) when is_integer(n) and n >= 0 and n <= 500, do: {:ok, n}
  defp page_limit(n), do: error("usage.invalid_number", "invalid limit value '#{inspect(n)}'")

  defp page_sort(nil, [{default, _direction} | _]), do: {:ok, default}

  defp page_sort(written, sorts) do
    case Enum.find(Keyword.keys(sorts), &(to_string(&1) == to_string(written))) do
      nil -> error("usage.unknown_word", "unknown sort '#{inspect(written)}'")
      sort -> {:ok, sort}
    end
  end

  defp page_filter(written, keys) do
    Enum.reduce_while(written, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case Enum.find(keys, &(to_string(&1) == to_string(key))) do
        nil -> {:halt, error("control.unknown_parameter", "unknown parameter 'filter.#{key}'")}
        key -> {:cont, {:ok, Map.put(acc, key, value)}}
      end
    end)
  end

  # A cursor is the offset of the page it continues, for the read and sort it
  # was issued for, as core refuses one issued for another.
  defp page_cursor(nil, _read, _sort), do: {:ok, 0}

  defp page_cursor(written, read, sort) when is_binary(written) do
    case String.split(written, ":") do
      ["fake", read_name, sort_name, offset] ->
        if read_name == to_string(read) and sort_name == to_string(sort),
          do: {:ok, String.to_integer(offset)},
          else: error("usage.invalid_number", "invalid after value '#{written}'")

      _other ->
        error("usage.invalid_number", "invalid after value '#{written}'")
    end
  end

  defp page_cursor(written, _read, _sort),
    do: error("usage.invalid_number", "invalid after value '#{inspect(written)}'")

  defp cut(:relay_list, %{rows: rows, unreachable: unreachable}, page) do
    listed = &(&1 |> Map.put_new(:run, :flow) |> Map.put_new(:plugins, 0))

    rows =
      Enum.map(rows, fn row ->
        if row[:members],
          do: %{listed.(row) | members: Enum.map(row.members, listed)},
          else: listed.(row)
      end)

    ids_only? = Map.keys(page.filter) == [:ids]

    rows
    |> Enum.filter(&relay_kept?(&1, page.filter))
    |> slice_page(page, :relay_list, relay_sort(page.sort))
    |> Map.merge(%{unreachable: unreachable, summary: if(!ids_only?, do: relay_summary(rows))})
  end

  defp cut(:plugin_list, plugins, page) do
    plugins
    |> Enum.filter(&plugin_kept?(&1, page.filter))
    |> slice_page(page, :plugin_list, &to_string(&1.name))
    |> Map.update!(:rows, fn rows ->
      Enum.map(rows, fn row ->
        relays = Map.get(row, :relays, [])
        %{row | relays: Enum.take(relays, 10)} |> Map.put(:relay_count, length(relays))
      end)
    end)
  end

  defp cut(:liveness_counters, %{relays: relays} = snapshot, page) do
    case page.filter do
      %{namespace: ns} ->
        relays = Enum.filter(relays, &(&1[:namespace] == ns))
        if page.limit == 0, do: totals(snapshot, relays), else: %{snapshot | relays: relays}

      %{relays: named} ->
        named = MapSet.new(named, &relay_pair/1)

        %{
          snapshot
          | relays: Enum.filter(relays, &MapSet.member?(named, {&1[:namespace], &1.relay_id}))
        }

      _none ->
        snapshot
    end
  end

  defp cut(:dlq_list, %{rows: rows, unreachable: unreachable}, page),
    do: rows |> slice_page(page, :dlq_list, nil) |> Map.put(:unreachable, unreachable)

  defp cut(:journal, %{entries: entries} = report, page) do
    report
    |> Map.delete(:entries)
    |> Map.merge(slice_page(entries, page, :journal, &(-Map.get(&1, :seq, 0))))
  end

  defp cut(:committed_iterations, iterations, page),
    do: slice_page(iterations, page, :committed_iterations, &(-&1))

  defp cut(:undelivered, records, page),
    do: slice_page(records, page, :undelivered, &Map.get(&1, :offset, 0))

  defp cut(:cells, %{cells: cells} = report, page) do
    text = page.filter |> Map.get(:text, "") |> to_string()

    report
    |> Map.delete(:cells)
    |> Map.merge(
      cells
      |> Enum.filter(&String.contains?(to_string(&1.cell_key), text))
      |> slice_page(page, :cells, &{to_string(&1.tasklet_id), to_string(&1.cell_key)})
    )
  end

  # A `{namespace, relay}` pair, which crosses the wire as a two-element array.
  defp relay_pair([namespace, relay]), do: {namespace, relay}
  defp relay_pair({_namespace, _relay} = pair), do: pair

  # A namespace's counters summed slot by slot, without its rows.
  defp totals(snapshot, relays) do
    totals =
      relays
      |> Enum.flat_map(&Map.to_list(Map.drop(&1, [:relay_id, :namespace, :node])))
      |> Enum.filter(fn {_slot, value} -> is_integer(value) end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {slot, values} -> {slot, Enum.sum(values)} end)

    %{snapshot | relays: [], channels: []} |> Map.put(:totals, totals)
  end

  # `rows` sorted by `key` (kept in order for none), the page after the
  # cursor's offset, and a cursor while rows remain.
  defp slice_page(rows, page, read, key) do
    sorted = if key, do: Enum.sort_by(rows, key), else: rows
    kept = sorted |> Enum.drop(page.offset) |> Enum.take(page.limit)
    shown = page.offset + length(kept)

    next =
      if kept != [] and shown < length(sorted), do: "fake:#{read}:#{page.sort}:#{shown}"

    %{rows: kept, total: length(sorted), next: next, unreachable: []}
  end

  defp relay_sort(:id), do: &to_string(&1.id)
  defp relay_sort(:severity), do: &{-health_rank(&1.health), to_string(&1.id)}

  defp health_rank(health), do: Enum.find_index(@health_rank, &(&1 == health)) || 1

  defp fault?(health), do: health_rank(health) >= health_rank(:degraded)

  defp relay_kept?(row, filter) do
    Enum.all?(filter, fn
      {:health, words} ->
        words = Enum.map(List.wrap(words), &to_string/1)
        to_string(row.health) in words or ("unhealthy" in words and fault?(row.health))

      {:ids, ids} ->
        to_string(row.id) in Enum.map(ids, &to_string/1)

      {:group, group} ->
        row[:members] != nil and to_string(row.id) == group

      {:text, text} ->
        text = String.downcase(text)

        Enum.any?(
          [row.id, row.factory],
          &(is_binary(&1) and String.contains?(String.downcase(&1), text))
        )

      {:run, run} ->
        to_string(row[:run]) == to_string(run)

      {key, value} when key in [:factory, :runner, :node] ->
        Enum.any?(row[:members] || [row], &(to_string(&1[key]) == to_string(value)))
    end)
  end

  defp relay_summary(rows) do
    relays = Enum.flat_map(rows, &(&1[:members] || [&1]))

    %{
      health: Enum.frequencies_by(rows, & &1.health),
      faulted_groups:
        for(
          %{members: [_ | _]} = group <- rows,
          fault?(group.health),
          do: %{group: group.id, health: group.health, complete: true}
        ),
      waiting:
        relays
        |> Enum.filter(&(&1.health in [:unbound, :recovering]))
        |> Enum.frequencies_by(&to_string(&1.factory))
        |> Enum.map(fn {factory, count} -> %{factory: factory, relays: count} end)
        |> Enum.sort_by(&{-&1.relays, &1.factory})
    }
  end

  defp plugin_kept?(row, filter) do
    Enum.all?(filter, fn
      {:provider, provider} -> provider in [row[:provider], row[:provider_id]]
      {:relay, relay} -> relay in Map.get(row, :relays, [])
      {:text, text} -> String.contains?(String.downcase(row.name), String.downcase(text))
    end)
  end

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
  A relay row shaped as `Flezha.Service.Relay.list/3` answers one, with
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
  A relay's row of `Controller.liveness_counters/2` in namespace `default` on
  `flezha@node-a`, every counter at 0, with `overrides` applied.
  """
  def relay_counters(id, overrides \\ %{}) do
    Map.merge(
      %{
        relay_id: id,
        namespace: "default",
        node: :"flezha@node-a",
        io_in_received: 0,
        forwarded: 0,
        filtered_nil: 0,
        bytes_in: 0,
        bytes_forwarded: 0,
        bytes_filtered: 0,
        halted_drops: 0,
        not_started_drops: 0
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
  reaches, and each namespace's relays as `list/3` pages them.

  `:rows` maps a namespace to its rows, `:plugins` is the `relay_plugins/2`
  answer's rows, from which each row's plugin count is taken, `:runs` maps a
  relay id to its run — every row defaults to `:flow` — and `:unreachable`
  names controllers the row reads lack.
  """
  def set_fleet(node, opts) do
    rows = Keyword.get(opts, :rows, %{})
    runs = Keyword.get(opts, :runs, %{})
    plugins = Keyword.get(opts, :plugins, [])
    unreachable = Keyword.get(opts, :unreachable, [])
    namespaces = Keyword.get(opts, :namespaces, Map.keys(rows))
    catalog = Enum.map(namespaces, &%{namespace: &1, running: true, nodes: [:"flezha@node-a"]})
    counts = Map.new(plugins, fn {id, bound} -> {to_string(id), length(bound)} end)

    listed = fn row ->
      # A group's run and bindings are its first member's, which every member shares.
      id = row |> Map.get(:members, [row]) |> hd() |> Map.fetch!(:id) |> to_string()

      row
      |> Map.put(:run, Map.get(runs, id, :flow))
      |> Map.put(:plugins, Map.get(counts, id, 0))
    end

    by_namespace =
      Map.new(rows, fn {namespace, ns_rows} ->
        {namespace, rows(Enum.map(ns_rows, listed), unreachable)}
      end)

    set(node, {Flezha.Service.Relay, :list_namespaces}, rows(catalog))
    set(node, {Flezha.Service.Relay, :list}, {:per_arg, 0, by_namespace, rows([])})
    set(node, {Flezha.Service.Relay, :relay_plugins}, rows(plugins))
  end

  @doc """
  Hands `event` to every open stream of `{module, function}` on `controller`,
  as `{:flezha_emit, event}` to the `:emit` pid its caller context named.
  """
  def emit(%{store: store}, key, event) do
    for {_holder, emit} <- holders(store, key), do: send(emit, {:flezha_emit, event})
    :ok
  end

  @doc """
  Makes every open stream of `{module, function}` on `controller` answer
  `answer`: `:overrun` cuts it as core cuts a client that fell behind, and
  `:drop` loses its connection.
  """
  def end_stream(%{store: store}, key, answer) do
    for {holder, _emit} <- holders(store, key), do: send(holder, {:end_stream, answer})
    :ok
  end

  @doc "The emit pids holding an open stream of `{module, function}` on `controller`."
  def streams(%{store: store}, key), do: Enum.map(holders(store, key), &elem(&1, 1))

  # ---- Run by the stand-ins, in the listener's request processes ----

  # The gate opens before its waiters are read, and a waiter registers before
  # it reads the gate, so no waiter misses its release.
  defp open_here(store, gate) do
    :ets.insert(store, {{:gate, gate}, :open})

    for [waiter] <- :ets.match(store, {{:gate_waiter, gate, :"$1"}, true}) do
      :ets.delete(store, {:gate_waiter, gate, waiter})
      send(waiter, {:gate_open, gate})
    end

    :ok
  end

  defp await_gate(store, gate) do
    :ets.insert(store, {{:gate_waiter, gate, self()}, true})

    case lookup(store, {:gate, gate}, :open) do
      {:closed, test} ->
        send(test, {:gate_reached, gate})

        receive do
          {:gate_open, ^gate} -> :ok
          # A listener's handler traps exits, so its stopping arrives as a
          # message: the call is lost, as on a controller that went away.
          {:EXIT, _from, _reason} -> FlezhaConsole.FakeListener.drop()
        end

      :open ->
        :ets.delete(store, {:gate_waiter, gate, self()})
    end
  end

  @doc """
  The answer for `key`, or `default` when the test did not set one.

  Records the arguments on the way through, so a test can assert what the
  screen actually asked the controller for, not merely what it rendered.
  Outside a listener's request, as when a stub is applied directly, it
  answers `default`.
  """
  def answer(key, args, default) do
    case Process.get(__MODULE__) do
      nil -> default
      store -> answer(store, key, args, default)
    end
  end

  defp answer(store, key, args, default) do
    record_call(store, key, args)

    case :ets.lookup(store, key) do
      [{^key, {:gated, gate, value}}] ->
        await_gate(store, gate)
        value

      [{^key, {:per_arg, {index, field}, by_arg, fallback}}] ->
        Map.get(by_arg, args |> Enum.at(index) |> Access.get(to_string(field)), fallback)

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
  A stream operation, as core runs one: the call is held open, the context's
  `:emit` pid is handed each event, and the call answers once that pid exits,
  or with what `end_stream/3` gives it. An answer set with `set/3` — a
  refusal — is answered at once instead.
  """
  def stream(key, args, %{emit: emit}, attached \\ []) when is_pid(emit) do
    store = Process.get(__MODULE__)
    record_call(store, key, args)

    case :ets.lookup(store, key) do
      [{^key, answer}] ->
        answer

      [] ->
        :ets.insert(store, {{:open_stream, key, self()}, emit})
        Enum.each(attached, &send(emit, {:flezha_emit, &1}))
        ref = Process.monitor(emit)

        receive do
          {:DOWN, ^ref, :process, ^emit, _reason} -> {:ok, :caller_down}
          {:end_stream, answer} -> answer
        after
          60_000 -> {:ok, :window_closed}
        end
        |> tap(fn _ -> forget(store, {:open_stream, key, self()}) end)
    end
  end

  # A stream outliving its test module finds the module's store gone.
  defp forget(store, key) do
    :ets.delete(store, key)
  rescue
    ArgumentError -> true
  end

  @doc """
  Polls `fun` until it returns true or the attempts run out.

  What the console does over the channel settles asynchronously — a stream
  opening or ending — so a bare assertion after the triggering call is flaky
  by construction.
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

  @doc """
  Waits for the end of the stream `request` the console opened, as
  `NodeManager.stream_result/2` recognises it, passing over every other
  message.
  """
  def await_stream_end(request) do
    import ExUnit.Assertions, only: [assert_receive: 1]
    assert_receive message

    case FlezhaConsole.Service.NodeManager.stream_result(message, request) do
      :no_response -> await_stream_end(request)
      ended -> ended
    end
  end

  defp record_call(store, key, args),
    do: :ets.insert(store, {{:calls, key}, lookup(store, {:calls, key}, []) ++ [args]})

  defp holders(store, key) do
    for [holder, emit] <- :ets.match(store, {{:open_stream, key, :"$1"}, :"$2"}),
        Process.alive?(holder),
        do: {holder, emit}
  end

  defp lookup(store, key, default) do
    case :ets.lookup(store, key) do
      [{^key, value}] -> value
      [] -> default
    end
  end
end

defmodule Flezha.Service.Relay do
  @moduledoc "Stand-in for the published relay surface. See `FakeController`."
  use FakeController.Stub

  defstub list_namespaces(ctx), do: FakeController.rows([])
  defstub list(ns, ctx), do: FakeController.rows([])

  defstub list(ns, opts, ctx),
    paged: :relay_list,
    do: FakeController.rows([])

  defstub relay_plugins(ns, ctx), do: FakeController.rows([])

  defstub cell_state(ns, id, cell, ctx), do: {:ok, "{}", 0}
  defstub overwatch_state(ns, id, ctx), do: {:ok, %{}}

  defstub graph(ns, id, ctx),
    do:
      {:ok,
       %{relay: id, factory: "store_input", graph: nil, disagree: false, reason: "not_announced"}}

  # Asked with `cells_of`, a runner keeping no per-Cell figures answers `nil`.
  defstub activity(ns, id, opts, ctx),
    do:
      {:ok,
       %{relay: id, runner: "runner-a", read_at_ms: 0, instance_seq: 1, tasklets: [], cells: nil}}

  # The id the relay runs under: the one asked for, or one the controller draws.
  defstub start(ns, relay, ctx),
    do: {:ok, %{id: Map.get(relay, "id", "relay-generated"), outcome: :started}}

  defstub stop(ns, id, ctx), do: {:ok, %{id: id, stopped: :stopped}}

  defstub diagnose(ns, id, ctx),
    do: {:ok, %{relay: id, verdict: :ok, findings: []}}

  defstub api(ns, id, ctx), do: {:ok, []}

  defstub send(ns, id, message, channel, opts, ctx),
    do: {:ok, %{to: id, verdict: :delivered}}

  # The real one answers a 3-tuple, the answer's metadata keyed by text.
  defstub call(ns, id, message, channel, opts, ctx),
    do: {:ok, message, %{"channel" => "out"}}

  defstub call_channel(ns, id, channel, value, opts, ctx),
    do: {:ok, %{accepted: true}}

  defstub replay(ns, path, from, ctx), do: {:ok, %{cell: path, from_seq: 0}}

  def listen(ns, id, direction, opts, ctx),
    do:
      FakeController.stream({__MODULE__, :listen}, [ns, id, direction, opts, ctx], ctx, [
        :attached
      ])
end

defmodule Flezha.Service.Steps do
  @moduledoc "Stand-in for the published steps surface. See `FakeController`."
  use FakeController.Stub

  defstub cells(relay_class, opts, ctx),
    paged: :cells,
    do: {:ok, %{relay_class: relay_class, history_retention_hours: 24, cells: []}}

  defstub cells(relay_class, ctx),
    do: {:ok, %{relay_class: relay_class, history_retention_hours: 24, cells: []}}

  defstub time_travel(cell, target, ctx),
    do:
      {:ok, %{cell: cell, target: target, terminal_seq: 0, snapshot_size: 0, change_log_size: 0}}

  defstub completed_retention_hours(relay_class, ctx), do: {:ok, 24}
  # The real one answers a bare `:error` when there is no record.
  defstub completion(id, ctx), do: :error

  defstub journal(id, ctx),
    do: {:ok, %{instance: id, entries: [], outcome: nil}}

  defstub journal(id, opts, ctx),
    paged: :journal,
    do: {:ok, %{instance: id, entries: [], outcome: nil}}

  defstub committed_iterations(id, ctx), do: {:ok, []}

  defstub committed_iterations(id, opts, ctx),
    paged: :committed_iterations,
    do: {:ok, []}

  defstub consumed_offset(id, ctx), do: {:ok, nil}
  defstub undelivered(id, ctx), do: {:ok, []}
  defstub undelivered(id, opts, ctx), paged: :undelivered, do: {:ok, []}
  defstub last_offset(id, ctx), do: {:ok, -1}
  defstub rescale(ns, group, target, opts, ctx), do: {:ok, %{group: group}}
  defstub rewind(ns, relay_class, to_iter, ctx), do: :ok

  defstub inbox(instance_id, ctx),
    do: {:ok, %{instance: instance_id, floor: -1, entries: []}}

  defstub outbox(cell, ctx),
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

  defstub rotate(cell, ctx), do: {:ok, %{cell: cell}}
  defstub delete(cell, ctx), do: {:ok, %{cell: cell}}

  defstub set_retention(relay_class, hours, ctx),
    do: {:ok, %{relay_class: relay_class, hours: hours}}
end

defmodule Flezha.Service.Fleet do
  @moduledoc "Stand-in for the published fleet surface. See `FakeController`."
  use FakeController.Stub

  defstub runners(ns, ctx), do: {:ok, []}
  defstub factories(ns, ctx), do: FakeController.rows([])

  defstub factory(ns, factory_id, ctx),
    do: FakeController.factory_answer(FakeController.factory_row(factory_id))

  defstub runners_for_factory(ns, factory_id, ctx), do: FakeController.rows([])

  defstub runner_caller_context(ns, ctx),
    do: {:ok, %{source: :sdk, principal: "runner@#{ns}", namespace: ns, roles: [:runner]}}

  defstub installed_plugins(ctx), do: FakeController.rows([])

  defstub providers(ctx),
    do: {:ok, %{rows: [], refused: %{"flezha@node-a": 0}, unreachable: []}}

  defstub provider(provider_id, ctx),
    do:
      {:ok,
       %{provider: provider_id, help: nil, type: :relay, feeds: false, hooks: [], options: []}}

  defstub drop_runner(ns, runner_id, ctx),
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

  defstub readmit_runner(ns, stable_id, ctx),
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

  defstub dropped_runners(ns, ctx), do: {:ok, []}
end

defmodule Flezha.Service.Namespace do
  @moduledoc "Stand-in for the published namespace surface. See `FakeController`."
  use FakeController.Stub

  defstub list(ctx), do: {:ok, []}
  defstub get(name, ctx), do: FakeController.error("namespace.not_found")

  defstub create(name, opts, ctx),
    do: {:ok, %{name: name, quotas: Map.get(opts, "quotas", %{})}}

  defstub set_quotas(name, quotas, ctx), do: {:ok, %{name: name, quotas: quotas}}

  defstub quota_kinds(ctx),
    do: {:ok, [:relays, :cells, :mailbox_bytes, :runners, :disk_bytes]}

  defstub quota(name, kind, ctx), do: FakeController.quota_usage(0)

  defstub roles(name, ctx), do: {:ok, []}

  # Any token binds an operator on an open controller, so every control
  # renders unless a test answers otherwise.
  defstub whoami(ctx),
    do:
      {:ok,
       %{
         principal: "operator",
         namespace: "default",
         role: :admin,
         operations: [],
         posture: :open
       }}

  defstub tokens(ctx), do: {:ok, []}
end

defmodule Flezha.Service.Dlq do
  @moduledoc "Stand-in for the published dead-letter surface. See `FakeController`."
  use FakeController.Stub

  defstub list(relay_class, ctx), do: FakeController.rows([])

  defstub list(relay_class, opts, ctx),
    paged: :dlq_list,
    do: FakeController.rows([])

  defstub get(entry_ref, ctx), do: FakeController.error("dlq.not_found")
  defstub drop(entry_ref, ctx), do: :ok

  defstub replay(entry_ref, ctx),
    do: {:ok, %{outcome: :removed, generation: nil}}

  defstub stats(ctx), do: FakeController.rows([])
end

defmodule Flezha.Service.Schedule do
  @moduledoc "Stand-in for the published schedule surface. See `FakeController`."
  use FakeController.Stub

  defstub list(ctx), do: FakeController.rows([])

  defstub add(fields, ctx),
    do: {:ok, %{entry: Map.new(fields), next_fire: nil, runner_missing: false}}

  defstub remove(name, ctx), do: :ok

  defstub run(name, ctx),
    do: {:ok, %{relay_id: "#{name}@manual-1", outcome: :spawned}}
end

defmodule Flezha.Service.Controller do
  @moduledoc "Stand-in for the published controller surface. See `FakeController`."
  use FakeController.Stub

  defstub status(ctx),
    do: FakeController.rows([FakeController.status_row("node-a")])

  defstub boot_status(ctx),
    do: FakeController.rows([FakeController.boot_row("node-a")])

  defstub cluster_status(ns, ctx),
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

  defstub controllers(ctx),
    do: FakeController.rows([FakeController.controller_row("node-a")])

  defstub durability_breaches(ctx), do: FakeController.rows([])
  defstub mem_top(ctx), do: FakeController.rows([])

  defstub liveness_counters(ctx),
    do: {:ok, %{channels: [], relays: [], unreachable: []}}

  defstub liveness_counters(opts, ctx),
    paged: :liveness_counters,
    do: {:ok, %{channels: [], relays: [], unreachable: []}}

  defstub durability_status(ctx), do: FakeController.rows([])
end

defmodule Flezha.Service.PluginManager do
  @moduledoc "Stand-in for the published plugin surface. See `FakeController`."
  use FakeController.Stub

  defstub enable(name, fields, ctx),
    do: {:ok, %{name: name, outcome: :enabled, bound: fields["relay_id"], lacking: []}}

  defstub disable(name, fields, ctx), do: {:ok, "plugin disabled"}
  defstub enabled(ns, ctx), do: {:ok, []}
  defstub enabled(ns, opts, ctx), paged: :plugin_list, do: {:ok, []}
  defstub bind(name, fields, ctx), do: :ok
  defstub unbind(name, fields, ctx), do: :ok

  defstub update(name, fields, ctx),
    do: {:ok, %{applied: :live, relays: []}}
end

defmodule Flezha.Service.Observability do
  @moduledoc "Stand-in for the published observability surface. See `FakeController`."
  use FakeController.Stub

  defstub query(params, ctx), do: FakeController.rows([])
  defstub list_sources(ctx), do: FakeController.rows([])
  defstub list_sinks(ctx), do: FakeController.rows([])

  defstub enable_source(name, ctx),
    do: {:ok, %{applied: [:"flezha@node-a"], unreachable: []}}

  defstub disable_source(name, ctx),
    do: {:ok, %{applied: [:"flezha@node-a"], unreachable: []}}

  def tail(source, ctx),
    do: FakeController.stream({__MODULE__, :tail}, [source, ctx], ctx)
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

  def run(name, args, context, :given),
    do: FakeController.answer({__MODULE__, :run}, [name], dispatch(name, args, context))

  defp dispatch(name, args, context) do
    [module, function] = String.split(name, ".", parts: 2)
    module = Module.concat(Flezha.Service, module)
    function = String.to_atom(function)

    if Code.ensure_loaded?(module) and function_exported?(module, function, length(args) + 1),
      do: module |> apply(function, args ++ [context]) |> answer(),
      else: FakeController.error("control.unknown_function")
  end

  defp answer({:error, _reason} = refused), do: refused
  defp answer({:ok, value}), do: {:ok, value}
  defp answer({:ok, value, more}), do: {:ok, [value, more]}
  defp answer(other), do: {:ok, other}
end
