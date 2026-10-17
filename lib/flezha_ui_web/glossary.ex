defmodule FlezhaUiWeb.Glossary do
  @moduledoc """
  The flezha terms the console uses, what each means, and what every screen is
  for.

  One source for three readers: `term/1` explains a term where a screen first
  uses it, the help overlay lists a screen's purpose and its terms, and the
  README's vocabulary table is checked against `terms/0` by a test, so the
  table and the console cannot come to disagree.
  """

  # Core's role set is closed in v1 and not on its published surface, so the
  # console names it here, with what each role allows.
  @roles [
    {"viewer", "Reads everything in the namespace and changes nothing."},
    {"app",
     "An application running its namespace: starts, stops, sends to and listens to relays, and enables plugins. Also connects runners."},
    {"ops",
     "An operator: what app may do, plus replays, rewinds, rescales, dead-letters, schedules and dropping runners."},
    {"admin",
     "Everything ops may do, plus tokens, role bindings, namespaces and quotas, and stopping the controller."},
    {"runner", "Connects a runner process, and nothing else."},
    {"spawner", "Connects a runner that starts relays and sends to them, and nothing else."},
    {"stopper", "Connects a runner that stops relays, and nothing else."}
  ]

  @role_names Enum.map(@roles, &elem(&1, 0))

  @terms [
    {"namespace", "Namespace",
     "An isolated control-plane scope. Every relay, runner, plugin and schedule lives in one."},
    {"relay", "Relay",
     "A running unit of work, started from a factory and bound to a runner that executes it."},
    {"run", "Run",
     "How a relay runs: flow processes each input as it arrives; steps is a durable, journaled sequence of iterations. It is the factory's, never chosen at start."},
    {"runner", "Runner",
     "An SDK-side process that serves factories. A relay is bound to one runner and runs on it."},
    {"factory", "Factory",
     "What a runner registers and a relay is started from. Its runners announce its run."},
    {"tasklet", "Tasklet", "A step inside a relay."},
    {"source plugin", "Source plugin",
     "A plugin whose provider feeds a relay, such as a websocket or a poll. It injects records on the entry channel it names, or on the relay's first one."},
    {"input filter", "Input filter",
     "A plugin bound on on_input: the controller runs it before a record enters the relay, and a record it skips never reaches a tasklet."},
    {"entry channel", "Entry channel",
     "A named channel records enter a relay on. A plugin feeding the relay, or acting on its input, names the entry it attaches to."},
    {"output channel", "Output channel",
     "A channel that leaves a relay for its plugins: each output plugin takes the records of the channels it names."},
    {"no plugin bound", "No plugin bound",
     "An output channel no plugin takes from: its records leave the relay, and only a listener, such as a tap, sees them."},
    {"folded run", "Folded run",
     "Four or more tasklets in a row, each reading only the one before it, drawn as one node until it is expanded."},
    {"backlog", "Backlog",
     "Inputs queued at a tasklet faster than it takes them, marked once its deepest Cell has held a queue for two readings."},
    {"shed", "Shed",
     "Inputs a tasklet dropped: its mailbox was full and its channel's overflow policy drops, or a new key found its Cell cap reached."},
    {"cell", "Cell",
     "A keyed unit of state inside a tasklet. A tasklet's Cells are listed, busiest first, when it is selected on the relay's graph."},
    {"output", "Output",
     "Where a relay's results leave it: a plugin on its output, or the runner's stream."},
    {"task journal", "Task journal",
     "A durable steps relay's record of committed tasklets and iterations — the only points it can be rewound to."},
    {"input log", "Input log",
     "A durable steps relay's journaled inputs, consumed iteration by iteration."},
    {"plugin", "Plugin",
     "A provider enabled by name in a namespace and bound to a relay on one or more hooks."},
    {"provider", "Provider",
     "What implements a plugin, such as relay_websocket or relay_stdout. It declares its options and the hooks it supports."},
    {"hook", "Hook",
     "A point a plugin is bound on, such as on_input before a relay sees a record or on_output after it forwards one."},
    {"hub", "Hub", "The per-namespace supervision root, placed on one or more cluster nodes."},
    {"posture", "Posture",
     "The controller's authorization stance: open, bootstrap pending, or enforced."},
    {"principal", "Principal",
     "The identity a call is made as. The console's comes only from a verified flezha token."},
    {"role", "Role",
     "What a principal may do in a namespace: " <>
       Enum.join(Enum.drop(@role_names, -1), ", ") <> " or " <> List.last(@role_names) <> "."},
    {"quota", "Quota",
     "A per-namespace limit, such as the number of relays, paired with a live counter."},
    {"partition group", "Partition group",
     "A set of relays that split one keyspace between them, each owning a range of key groups."},
    {"coverage", "Coverage",
     "Whether a partition group's members own every key group exactly once. A gap or an overlap is a fault."},
    {"health", "Health",
     "How the Convergence Loop classified a relay: healthy, unknown, suspended, degraded, recovering, unbound, failed or parked."},
    {"suspended", "Suspended",
     "A relay stopped at a committed boundary on purpose, not by a fault. The next message wakes it, if a runner serves its factory."},
    {"parked", "Parked",
     "A relay stopped by a fault nothing in the system owns. It stays stopped until someone fixes it; the Convergence Loop does not touch it."},
    {"unbound", "Unbound",
     "A relay no runner is bound to. The Convergence Loop binds it once a runner serving its factory can take it."},
    {"failed", "Failed",
     "A relay whose runner is gone past its grace. The Convergence Loop rebinds it to another runner."},
    {"recovering", "Recovering",
     "A relay that is unbound or whose runner went away, still inside its grace while the Convergence Loop rebinds it."},
    {"degraded", "Degraded",
     "A relay that runs but not as declared; the Convergence Loop repairs it in place."},
    {"dead letter", "Dead letter",
     "A record a tasklet could not process, kept in the dead-letter queue so it can be inspected, replayed or dropped."},
    {"schedule", "Schedule",
     "A cron expression that starts a relay from a factory each time it fires."},
    {"source", "Source",
     "A stream of observability signals the controller can emit, switched on or off one by one."}
  ]

  @by_key Map.new(@terms, fn {key, name, definition} ->
            {key, %{key: key, name: name, definition: definition}}
          end)

  @doc "Every term, as `%{key:, name:, definition:}`, in reading order."
  def terms, do: Enum.map(@terms, fn {key, _name, _definition} -> Map.fetch!(@by_key, key) end)

  @doc "Every role a principal can be bound to or issued, as `{role, what it allows}`."
  def roles, do: @roles

  @doc "One term by its key, or `nil`."
  def term(key), do: Map.get(@by_key, String.downcase(key))

  @doc "One term by its key; raises for a key the glossary does not hold."
  def term!(key), do: Map.fetch!(@by_key, key)

  # Per screen kind: what it shows, what it is for, and the terms it marks.
  @screens %{
    home: {
      "Home sums up everything you can reach, then this namespace, in tiles: how many relays, runners, plugins and schedules there are, how healthy they are, what is flowing and how close each limit is. This namespace's problems sit below its tiles; the river below them lists what happened while you watched.",
      ["namespace", "runner", "relay", "factory", "health", "quota"]
    },
    relays: {
      "Every relay you can reach, or one namespace's, with its health, run, runner and measured rate. Activate a row to inspect it in place; start a relay from a factory here too.",
      ["relay", "health", "run", "runner", "factory"]
    },
    relay_live: {
      "What one relay is doing: its graph, from the sources feeding it through its tasklets to the plugins its output channels end at, with records drawn as they pass, live rates, each tasklet's Cells, a payload tap, and on request a diagnosis, its calls, its API and its plugin bindings.",
      [
        "relay",
        "runner",
        "factory",
        "run",
        "plugin",
        "hook",
        "source plugin",
        "input filter",
        "tasklet",
        "cell",
        "entry channel",
        "output channel",
        "no plugin bound",
        "folded run",
        "backlog",
        "shed"
      ]
    },
    relay_listen: {
      "The records one relay emits or receives, as they happen. Listening holds a live subscription only while this view is open.",
      ["relay", "output"]
    },
    relay_state: {
      "What one relay has kept: its cells and their durability, and for a durable steps relay its task journal, its input log and its steps facts.",
      ["relay", "cell", "tasklet", "task journal", "input log"]
    },
    plugins: {
      "The plugins enabled in a namespace, what each provider does and the hooks it supports, and the relays bound to each.",
      ["plugin", "provider", "hook", "relay"]
    },
    schedules: {
      "Cron schedules that start a relay from a factory each time they fire, with their status and next fire.",
      ["schedule", "factory", "relay"]
    },
    problems: {
      "Every open problem in the namespaces you can reach, worst first. A relay's card states its state, why, its runner, who can run it and what happens next; Diagnose adds the controller's findings. Problems leave on their own once they clear.",
      ["relay", "health", "suspended", "parked", "quota", "dead letter", "partition group"]
    },
    dlq: {
      "Dead letters: records a tasklet could not process, grouped by tasklet. Inspect one in place, replay it into its relay, or drop it.",
      ["dead letter", "tasklet", "relay"]
    },
    cluster: {
      "The controller nodes, each namespace's hub and where it runs, and the runners connected to each namespace.",
      ["hub", "runner", "factory", "namespace"]
    },
    controller: {
      "Whether this controller is healthy: readiness, authorization posture, durability and shutdown. Drain and stop it from here.",
      ["posture", "principal", "hub"]
    },
    observability: {
      "The controller's observability sources and sinks, grouped by area. Switch a source on or off and tail its signals live.",
      ["source"]
    },
    audit: {
      "The controller's audit log: who did what, when, and with which outcome. Open a file to read its records, filter them, open one to see the whole of it, or tail the log live.",
      ["principal", "role"]
    },
    namespaces: {
      "Every namespace the controller declares or runs, with its health and how close it is to its quotas.",
      ["namespace", "quota", "hub"]
    },
    settings: {
      "Your console account: its email and password, and the flezha token every controller call is made with.",
      ["principal", "role"]
    },
    kit: {
      "Every component of the console's kit in every variant and state, for checking the look in both themes.",
      []
    }
  }

  @doc "The screen kinds that have a purpose paragraph."
  def screen_kinds, do: Map.keys(@screens)

  @doc """
  A screen's help: `%{purpose:, terms:}`, its one paragraph and the glossary
  entries for the terms it marks. A kind with no entry answers `nil`.
  """
  def screen(kind) do
    case Map.fetch(@screens, kind) do
      {:ok, {purpose, keys}} -> %{purpose: purpose, terms: Enum.map(keys, &term!/1)}
      :error -> nil
    end
  end

  @doc "The keyboard shortcuts, as `{keys, what they do}`."
  def shortcuts do
    [
      {["?"], "Open this help"},
      {["g", "h"], "Go to the namespace's Home"},
      {["g", "r"], "Go to Relays"},
      {["g", "p"], "Go to Open problems"},
      {["g", "c"], "Go to Cluster"},
      {["Ctrl", "K"], "Search or run a command"},
      {["Esc"], "Close the topmost overlay"}
    ]
  end
end
