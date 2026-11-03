# Records the shape of the dev controller's answer to every operation the
# console calls, and of every event its streams deliver, into
# `priv/controller_shapes.json`: the schema the console decodes the channel's
# JSON with, and what the fake controller's answers are checked against.
#
# Reads are made as `FlezhaConsole.Service.ControllerShapes.reads/0` lists
# them. Actions are made on relays, a plugin, schedules and a namespace this
# script starts or creates under `shapes_recorder` names and removes again,
# and events are provoked on them while their streams are held.
#
# Over Erlang distribution, as an operator helper of the dev stack, which
# holds the cookie (the `tools` service):
#
#     elixir --sname <unique> --hidden --cookie <cookie> priv/dev/record_shapes.exs [MODE]
#
#   (none)          record everything into the committed file
#   --check         record the reads into memory and fail, naming each one whose
#                   shape moved from the committed file
#   --check --keep  the same, leaving the scratch relays the reads need in place
#   --clean         remove the scratch relays and anything else this script made
#
#   FLEZHA_NODE        the controller node, e.g. flezha@flezha_controller
#   FLEZHA_TOKEN_FILE  the token whose principal the calls are made as
#
# Through the console's own channel, inside `fcon_web`, while the scratch
# relays of a `--check --keep` are in place:
#
#     FLEZHA_CONSOLE_DEV_SETUP=false mix run priv/dev/record_shapes.exs --channel
#
#   reads each recorded read through `NodeManager`, decoded by the shipped
#   schema, and fails naming each one whose decoded shape differs from the
#   committed file, with the path that differs.

unless Code.ensure_loaded?(FlezhaConsole.Service.ControllerShapes),
  do: Code.require_file("../../lib/flezha_console/service/controller_shapes.ex", __DIR__)

defmodule RecordShapes do
  alias FlezhaConsole.Service.ControllerShapes, as: Shapes

  # The channel mode runs inside the console, whose modules a helper node lacks.
  @compile {:no_warn_undefined,
            [
              FlezhaConsole.Accounts,
              FlezhaConsole.Service.NodeConnector,
              FlezhaConsole.Service.NodeManager
            ]}

  @committed Path.expand("../controller_shapes.json", __DIR__)
  @timeout_ms 30_000
  @ns "default"
  @scratch "shapes_recorder"

  def run(["--channel"]), do: channel()

  def run(argv) do
    controller = String.to_atom(env!("FLEZHA_NODE"))
    token = env!("FLEZHA_TOKEN_FILE") |> File.read!() |> String.trim()

    Node.connect(controller) || die("could not reach #{controller}")

    context =
      case :erpc.call(controller, Flezha.Service.Admin, :context, [:cli, token]) do
        {:ok, %{principal: principal} = context} when is_binary(principal) -> context
        other -> die("the token binds no identity: #{inspect(other)}")
      end

    call = fn module, function, args ->
      :erpc.call(controller, module, function, args ++ [context], @timeout_ms)
    end

    case argv do
      [] ->
        recorded =
          record(call, fn ->
            prepare(call, :fired)
            reads(call) ++ actions(call) ++ events(controller, context, call)
          end)

        File.write!(@committed, Shapes.encode(recorded))
        IO.puts("recorded #{map_size(recorded)} shapes into #{@committed}")

      ["--check" | keep] when keep in [[], ["--keep"]] ->
        work = fn ->
          prepare(call, :unfired)
          reads(call)
        end

        recorded = if keep == [], do: record(call, work), else: shapes(work.())
        check(recorded)

      ["--clean"] ->
        clean_up(call)

      _ ->
        die("usage: record_shapes.exs [--check [--keep] | --clean | --channel]")
    end
  end

  defp record(call, work), do: work |> cleaned(fn -> clean_up(call) end) |> shapes()

  defp shapes(recorded),
    do: Map.new(recorded, fn {label, answer} -> {label, Shapes.of(answer)} end)

  # ---- Through the console's channel ----

  defp channel do
    token =
      FlezhaConsole.Accounts.service_flezha_token() || die("the console has no service token")

    FlezhaConsole.Service.NodeConnector.reconnect() ||
      die("the console does not reach its controller over its channel")

    committed = committed()

    drift =
      for {label, module, function, args} <- Shapes.reads(),
          answer = FlezhaConsole.Service.NodeManager.read(module, function, args, token),
          line <- channel_drift(committed[label], answer),
          do: "#{label}#{line}"

    verdict(
      drift,
      "every read through the channel decodes to its committed shape",
      "reads through the console's channel decode to other shapes than the committed " <>
        "ones; the channel lost part of an answer, or the decoder misreads it"
    )
  end

  defp channel_drift(nil, _answer), do: [": not in the committed file"]

  defp channel_drift(committed, {:ok, _value} = answer),
    do: Shapes.diff(textual(committed), textual(Shapes.of(answer)))

  defp channel_drift(_committed, refused), do: [": answered #{inspect(refused)}"]

  # A name the console has no atom for decodes as text, and a pid crosses as
  # text, by design; what the check looks for is structure lost on the way.
  defp textual(shape) when shape in ["atom", "pid", "ref", "fun"], do: "string"
  defp textual(%{} = shape), do: Map.new(shape, fn {key, value} -> {key, textual(value)} end)
  defp textual(shapes) when is_list(shapes), do: shapes |> Enum.map(&textual/1) |> Enum.uniq()
  defp textual(shape), do: shape

  # A partition group, a parked dead letter and a chat relay with two turns,
  # so the reads carry what the stack does not hold by itself. A full recording
  # also waits for two schedules to fire, one starting its relay and one left
  # retrying, which only a cron fire records and which takes up to a minute.
  defp prepare(call, schedules) do
    group = "#{@scratch}_parts"
    poison = "#{@scratch}_poison"
    chat = "#{@scratch}_chat"

    for fields <- [
          [factory_id: "sleeping_counter", id: group, partitions: 2],
          [factory_id: "poison_probe", id: poison],
          [factory_id: "chat_loop_steps", id: chat]
        ],
        do: run!(call, fields)

    ok!("Relay.send poison", call.(Flezha.Service.Relay, :send, [@ns, poison, "poison", "", []]))

    for turn <- ["hello", "again"],
        do:
          ok!(
            "Relay.send #{turn}",
            call.(Flezha.Service.Relay, :send, [@ns, chat, turn, "in", []])
          )

    if schedules == :fired, do: fire_schedules(call)

    await_dead_letter(call, poison)
    await_cell(call, chat)
    await_committed(call, chat)
  end

  defp fire_schedules(call) do
    for {name, factory} <- [{"shapes_rec", "echo_steps"}, {"shapes_ret", "shapes_none"}] do
      ok!(
        "Schedule.add #{name}",
        call.(Flezha.Service.Schedule, :add, [schedule(name, factory, "* * * * *")])
      )
    end

    await_fired(call, ["shapes_rec", "shapes_ret"])
  end

  defp schedule(name, factory, cron),
    do: [
      name: name,
      namespace: @ns,
      factory_id: factory,
      cron: cron,
      timezone: "Etc/UTC",
      init_values: %{}
    ]

  defp await_fired(call, names) do
    await("#{Enum.join(names, ", ")} did not fire", 90, 1_000, fn ->
      {:ok, %{rows: rows}} = call.(Flezha.Service.Schedule, :list, [])
      fired? = &Enum.any?(rows, fn row -> row.name == &1 and row.last_fire != nil end)
      if Enum.all?(names, fired?), do: {:ok, :ok}, else: :retry
    end)
  end

  defp reads(call) do
    for {label, module, function, args} <- Shapes.reads() do
      {label, ok!(label, call.(module, function, args))}
    end
  end

  # What the dev stack does not hold by itself is made here and removed in
  # `clean_up/1`, so a recording run leaves the stack as it found it.
  defp actions(call) do
    relay = "#{@scratch}_orders"
    group = "#{@scratch}_parts"

    namespace = [
      {"Namespace.create",
       call.(Flezha.Service.Namespace, :create, [@scratch, [quotas: %{max_relays: 3}]])},
      {"Namespace.get", call.(Flezha.Service.Namespace, :get, [@scratch])},
      {"Namespace.set_quotas",
       call.(Flezha.Service.Namespace, :set_quotas, [@scratch, %{max_relays: 4}])},
      {"Namespace.tokens", call.(Flezha.Service.Namespace, :tokens, [])}
    ]

    started = [
      {"Relay.start",
       call.(Flezha.Service.Relay, :start, [
         @ns,
         [factory_id: "orders", init_values: %{}, opts: [], id: relay]
       ])},
      {"Relay.start partitions",
       call.(Flezha.Service.Relay, :start, [
         @ns,
         [factory_id: "sleeping_counter", init_values: %{}, opts: [], id: group, partitions: 2]
       ])}
    ]

    await_running(call, relay)

    relay_acts = [
      {"Relay.api", call.(Flezha.Service.Relay, :api, [@ns, relay])},
      {"Relay.diagnose", call.(Flezha.Service.Relay, :diagnose, [@ns, relay])},
      {"Relay.send",
       call.(Flezha.Service.Relay, :send, [@ns, relay, "audited", "audit", [key: "k"]])},
      {"Relay.call",
       call.(Flezha.Service.Relay, :call, [
         @ns,
         relay,
         ~s({"pair":"XAU/USD","amount":1}),
         "place",
         [deadline_ms: 10_000]
       ])},
      {"Relay.call_channel",
       call.(Flezha.Service.Relay, :call_channel, [
         @ns,
         relay,
         "place",
         %{"pair" => "XAU/USD", "amount" => 1},
         [deadline_ms: 10_000]
       ])},
      {"Relay.call_channel accepted",
       call.(Flezha.Service.Relay, :call_channel, [@ns, relay, "audit", "noted", []])},
      {"Relay.cell_state", call.(Flezha.Service.Relay, :cell_state, [@ns, "testnet_chain", nil])},
      {"Relay.replay", replay(call, "testnet_chain/static_entry_tasklet/a")}
    ]

    steps = steps(call, group)

    plugin = "#{@scratch}_filter"

    plugins = [
      {"PluginManager.enable",
       call.(Flezha.Service.PluginManager, :enable, [
         plugin,
         [provider: "relay_io_filter", opts: %{"regex_pattern" => "x"}, namespace: @ns]
       ])},
      {"PluginManager.bind",
       call.(Flezha.Service.PluginManager, :bind, [
         plugin,
         [namespace: @ns, relay_id: relay, hooks: ["on_input"]]
       ])},
      {"PluginManager.update",
       call.(Flezha.Service.PluginManager, :update, [
         plugin,
         [namespace: @ns, opts: %{"regex_pattern" => "y"}]
       ])},
      {"PluginManager.unbind",
       call.(Flezha.Service.PluginManager, :unbind, [plugin, [namespace: @ns, relay_id: relay]])},
      {"PluginManager.disable",
       call.(Flezha.Service.PluginManager, :disable, [plugin, [namespace: @ns]])}
    ]

    stopped = [{"Relay.stop", call.(Flezha.Service.Relay, :stop, [@ns, relay])}]

    schedule = "shapes_act"

    schedules = [
      {"Schedule.add",
       call.(Flezha.Service.Schedule, :add, [schedule(schedule, "echo_steps", "0 0 1 1 *")])},
      {"Schedule.run", call.(Flezha.Service.Schedule, :run, [schedule])},
      {"Schedule.remove", call.(Flezha.Service.Schedule, :remove, [schedule])}
    ]

    {:ok, %{rows: [controller | _]}} = call.(Flezha.Service.Controller, :controllers, [])

    fleet =
      [
        {"Fleet.runner_caller_context",
         call.(Flezha.Service.Fleet, :runner_caller_context, [@ns])},
        {"Fleet.dropped_runners", call.(Flezha.Service.Fleet, :dropped_runners, [@ns])},
        {"Logs.rotate",
         call.(Flezha.Service.Logs, :rotate, [
           [kind: "relay_history", node: to_string(controller.node)]
         ])}
      ] ++ drop_and_readmit(call) ++ toggle_source(call)

    labelled =
      namespace ++
        started ++
        relay_acts ++ steps ++ plugins ++ stopped ++ schedules ++ fleet ++ dead_letter(call)

    Enum.map(labelled, fn {label, answer} -> {label, ok!(label, answer)} end)
  end

  # From the earliest point the cell still keeps, which the refusal names.
  defp replay(call, cell) do
    case call.(Flezha.Service.Relay, :replay, [@ns, cell, "0"]) do
      {:error, %{code: "relay.outside_retention", details: %{"earliest" => earliest}}} ->
        call.(Flezha.Service.Relay, :replay, [@ns, cell, to_string(earliest)])

      answer ->
        answer
    end
  end

  # The chat relay `prepare/1` gave two turns, so its cell can be rewound,
  # rotated and deleted without touching what the stack runs, and a run-once
  # relay that finished, for its completion record.
  defp steps(call, group) do
    relay = "#{@scratch}_chat"
    cell = await_cell(call, relay)
    iterations = await_committed(call, relay)

    [
      {"Steps.completed_retention_hours",
       call.(Flezha.Service.Steps, :completed_retention_hours, [relay])},
      {"Steps.completion", finished(call)},
      {"Steps.consumed_offset", call.(Flezha.Service.Steps, :consumed_offset, [relay])},
      {"Steps.last_offset", call.(Flezha.Service.Steps, :last_offset, [relay])},
      {"Steps.time_travel", call.(Flezha.Service.Steps, :time_travel, [cell, "0"])},
      {"Steps.inbox", call.(Flezha.Service.Steps, :inbox, [relay])},
      {"Steps.outbox", call.(Flezha.Service.Steps, :outbox, [cell])},
      {"Steps.set_retention", call.(Flezha.Service.Steps, :set_retention, [relay, 24])},
      {"Steps.rotate", call.(Flezha.Service.Steps, :rotate, [cell])},
      {"Steps.rescale", call.(Flezha.Service.Steps, :rescale, [@ns, group, 3, []])},
      {"Steps.rewind",
       call.(Flezha.Service.Steps, :rewind, [@ns, relay, iterations |> List.last() |> iteration()])},
      {"Steps.delete", call.(Flezha.Service.Steps, :delete, [cell])}
    ]
  end

  defp finished(call) do
    relay = start!(call, factory_id: "echo_steps", id: "#{@scratch}_echo")
    ok!("Relay.send #{relay}", call.(Flezha.Service.Relay, :send, [@ns, relay, "hi", "in", []]))
    await_completion(call, relay)
  end

  defp await_completion(call, relay) do
    await("#{relay} recorded no completion", fn ->
      case call.(Flezha.Service.Steps, :completion, [relay]) do
        {:ok, %{}} = completion -> {:ok, completion}
        _not_yet -> :retry
      end
    end)
  end

  defp await_cell(call, relay) do
    await("#{relay} kept no cell state", fn ->
      case call.(Flezha.Service.Steps, :cells, [relay]) do
        {:ok, %{cells: [first | _] = cells}} ->
          %{relay_class: class, tasklet_id: tasklet, cell_key: key} =
            Enum.find(cells, first, &(&1.cell_key != "_task_journal"))

          {:ok, "#{class}/#{tasklet}/#{key}"}

        _none ->
          :retry
      end
    end)
  end

  defp await_committed(call, relay) do
    await("#{relay} committed no iteration", fn ->
      case call.(Flezha.Service.Steps, :committed_iterations, [relay]) do
        {:ok, [_ | _] = iterations} -> {:ok, iterations}
        _none -> :retry
      end
    end)
  end

  defp iteration(%{iteration: iteration}), do: iteration
  defp iteration(iteration), do: iteration

  # A runner is dropped and let back at once, so the stack keeps serving its
  # namespace; one of a side namespace when one runs there.
  defp drop_and_readmit(call) do
    served =
      Enum.find_value(~w(sandbox second default), fn namespace ->
        case call.(Flezha.Service.Fleet, :runners, [namespace]) do
          {:ok, [%{id: runner} | _]} -> {namespace, runner}
          _none -> nil
        end
      end) || die("no runner is connected, so drop_runner cannot be recorded")

    {namespace, runner} = served
    dropped = call.(Flezha.Service.Fleet, :drop_runner, [namespace, runner])
    {:ok, %{stable_id: stable_id}} = ok!("Fleet.drop_runner", dropped)

    [
      {"Fleet.drop_runner", dropped},
      {"Fleet.readmit_runner",
       call.(Flezha.Service.Fleet, :readmit_runner, [namespace, stable_id])}
    ]
  end

  # A source switched to the other state and back.
  defp toggle_source(call) do
    {:ok, %{rows: sources}} = call.(Flezha.Service.Observability, :list_sources, [])
    source = Enum.find(sources, &(&1.name == :flezha_shutdown)) || hd(sources)
    name = to_string(source.name)
    active? = Enum.any?(Map.values(source.statuses), &(&1 == :active))

    {first, second} =
      if active?, do: {:disable_source, :enable_source}, else: {:enable_source, :disable_source}

    [
      {"Observability.#{first}", call.(Flezha.Service.Observability, first, [name])},
      {"Observability.#{second}", call.(Flezha.Service.Observability, second, [name])}
    ]
  end

  # A poisoned input parks a dead letter, which is read, replayed and dropped.
  defp dead_letter(call) do
    relay = run!(call, factory_id: "poison_probe", id: "#{@scratch}_poison")
    ok!("Relay.send poison", call.(Flezha.Service.Relay, :send, [@ns, relay, "poison", "", []]))
    ref = await_dead_letter(call, relay)

    [
      {"Dlq.get", call.(Flezha.Service.Dlq, :get, [ref])},
      {"Dlq.replay", call.(Flezha.Service.Dlq, :replay, [ref])},
      {"Dlq.drop", call.(Flezha.Service.Dlq, :drop, [await_dead_letter(call, relay)])}
    ]
  end

  # ---- Events ----

  # Each stream held while something happens that it delivers, recording the
  # first event of each name.
  defp events(controller, context, call) do
    orders = "#{@scratch}_orders"
    parts = "#{@scratch}_part_echo"
    poison = "#{@scratch}_poison_events"

    for {relay, factory} <- [{orders, "orders"}, {parts, "part_echo"}, {poison, "poison_probe"}],
        do: run!(call, factory_id: factory, id: relay)

    held = [
      {"Relay.listen", Flezha.Service.Relay, :listen, [@ns, orders, :calls, []],
       fn ->
         call.(Flezha.Service.Relay, :call, [
           @ns,
           orders,
           ~s({"pair":"X","amount":1}),
           "place",
           [deadline_ms: 5_000]
         ])

         call.(Flezha.Service.Relay, :call, [
           @ns,
           orders,
           "unanswered",
           "audit",
           [deadline_ms: 300]
         ])

         call.(Flezha.Service.Relay, :call, [@ns, orders, "no", "nowhere", [deadline_ms: 300]])
       end},
      {"Relay.listen", Flezha.Service.Relay, :listen, [@ns, parts, :output, []],
       fn -> call.(Flezha.Service.Relay, :send, [@ns, parts, "2", "", []]) end},
      {"Relay.listen", Flezha.Service.Relay, :listen, [@ns, parts, :input, []],
       fn -> call.(Flezha.Service.Relay, :send, [@ns, parts, "1", "", []]) end},
      {"Relay.listen", Flezha.Service.Relay, :listen, [@ns, poison, :output, []],
       fn -> call.(Flezha.Service.Relay, :send, [@ns, poison, "poison", "", []]) end},
      {"Relay.listen", Flezha.Service.Relay, :listen, [@ns, "testnet_chain", :tally, []],
       fn -> :ok end},
      {"Observability.tail", Flezha.Service.Observability, :tail, ["flezha_relay"],
       fn -> call.(Flezha.Service.Relay, :stop, [@ns, parts]) end},
      {"Logs.tail", Flezha.Service.Logs, :tail, [[kind: "relay_history", filters: %{}]],
       fn -> call.(Flezha.Service.Relay, :stop, [@ns, poison]) end}
    ]

    held
    |> Enum.flat_map(fn {operation, module, function, args, provoke} ->
      operation |> hold(controller, context, module, function, args, provoke) |> Enum.to_list()
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  defp hold(operation, controller, context, module, function, args, provoke) do
    recorder = self()
    collector = spawn(fn -> collect(recorder, %{}) end)
    context = Map.put(context, :emit, collector)

    spawn(fn -> :erpc.call(controller, module, function, args ++ [context], :infinity) end)
    Process.sleep(500)
    provoke.()
    Process.sleep(3_000)

    send(collector, :done)

    receive do
      {:events, events} ->
        Process.exit(collector, :kill)

        Enum.map(events, fn {name, event} ->
          {"#{operation} event #{name}", wire(operation, event)}
        end)
    after
      5_000 -> die("the #{operation} collector did not answer")
    end
  end

  defp collect(recorder, events) do
    receive do
      {:flezha_emit, event} -> collect(recorder, Map.put_new(events, event_name(event), event))
      :done -> send(recorder, {:events, events})
    end
  end

  defp event_name(:attached), do: "attached"
  defp event_name({kind, _value, _meta}) when is_atom(kind), do: Atom.to_string(kind)
  defp event_name(%{__struct__: Flezha.Observability.Signal}), do: "signal"
  defp event_name(%{}), do: "log"

  # A signal crosses the channel as these of its fields.
  defp wire("Observability.tail", %{__struct__: _} = signal),
    do: Map.take(signal, [:kind, :source, :name, :node, :at_us, :measurements, :metadata])

  defp wire(_operation, event), do: event

  # ---- Scratch state ----

  # Starts the relay `fields` names, answering its id.
  defp start!(call, fields) do
    relay = Keyword.fetch!(fields, :id)
    ok!("Relay.start #{relay}", call.(Flezha.Service.Relay, :start, [@ns, fields]))
    relay
  end

  # Starts it and waits until it runs.
  defp run!(call, fields), do: await_running(call, start!(call, fields))

  defp await_running(call, relay) do
    await("#{relay} did not start running", fn ->
      case call.(Flezha.Service.Relay, :list, [@ns, [filter: [ids: [relay]]]]) do
        {:ok, %{rows: [%{health: :healthy} | _]}} -> {:ok, relay}
        _not_yet -> :retry
      end
    end)
  end

  defp await_dead_letter(call, relay) do
    await("#{relay} parked no dead letter", fn ->
      case call.(Flezha.Service.Dlq, :list, [relay]) do
        {:ok, %{rows: [entry | _]}} -> {:ok, dead_letter_ref(entry)}
        {:ok, %{rows: []}} -> :retry
      end
    end)
  end

  # Asks `ask` until it answers `{:ok, value}`, at most `attempts` times
  # `every_ms` apart, and dies saying `failure` after that.
  defp await(failure, attempts \\ 60, every_ms \\ 500, ask) do
    case ask.() do
      {:ok, value} ->
        value

      :retry when attempts > 1 ->
        Process.sleep(every_ms)
        await(failure, attempts - 1, every_ms, ask)

      :retry ->
        die(failure)
    end
  end

  # The `class/tasklet/id` the controller's dead-letter verbs take.
  defp dead_letter_ref(entry),
    do: "#{entry["relay_class"]}/#{entry["tasklet_id"]}/#{entry["id"]}"

  defp clean_up(call) do
    for suffix <- ~w(orders parts part_echo poison poison_events chat echo) do
      call.(Flezha.Service.Relay, :stop, [@ns, "#{@scratch}_#{suffix}"])
    end

    for relay <- ["#{@scratch}_poison", "#{@scratch}_poison_events"],
        {:ok, %{rows: entries}} = call.(Flezha.Service.Dlq, :list, [relay]),
        entry <- entries,
        do: call.(Flezha.Service.Dlq, :drop, [dead_letter_ref(entry)])

    call.(Flezha.Service.PluginManager, :disable, ["#{@scratch}_filter", [namespace: @ns]])

    for schedule <- ["shapes_rec", "shapes_ret", "shapes_act"],
        do: call.(Flezha.Service.Schedule, :remove, [schedule])

    {:ok, %{rows: fired}} =
      call.(Flezha.Service.Relay, :list, [@ns, [limit: 50, filter: [text: "shapes_"]]])

    for %{id: id} <- fired,
        String.contains?(id, "@"),
        do: call.(Flezha.Service.Relay, :stop, [@ns, id])

    call.(Flezha.Service.Namespace, :delete, [@scratch])
    :ok
  end

  defp cleaned(work, clean_up) do
    work.()
  after
    clean_up.()
  end

  # A recording is of what the console decodes, an answer, never a refusal.
  defp ok!(label, {:error, _reason} = refused),
    do: die("#{label} was refused: #{inspect(refused)}")

  defp ok!(_label, answer), do: answer

  # ---- Check ----

  defp check(recorded) do
    committed = committed()

    drift =
      for {label, shape} <- Enum.sort(recorded),
          line <- drift(Map.get(committed, label), shape),
          do: "#{label}#{line}"

    verdict(
      drift,
      "every recording has its committed shape",
      "the controller's answers moved from the committed shapes; re-record with " <>
        "priv/dev/record_shapes.exs and update FakeController to match"
    )
  end

  defp committed, do: @committed |> File.read!() |> JSON.decode!()

  defp verdict([], fine, _moved), do: IO.puts(fine)
  defp verdict(drift, _fine, moved), do: die(moved <> ":\n" <> Enum.join(drift, "\n"))

  defp drift(nil, _shape), do: [": not in the committed file"]

  # A key the controller added or dropped both show here; which alternatives a
  # union holds depends on what the stack happens to run, so only fit counts.
  defp drift(committed, shape), do: Shapes.diff(committed, shape)

  defp env!(name) do
    case System.get_env(name) do
      value when value in [nil, ""] -> die("#{name} is not set")
      value -> value
    end
  end

  # Raised rather than halted, so what the run started is removed on the way out.
  defp die(message), do: raise(RuntimeError, message)
end

try do
  RecordShapes.run(System.argv())
rescue
  error ->
    IO.puts(:stderr, "[record-shapes] #{Exception.message(error)}")
    System.halt(1)
end
