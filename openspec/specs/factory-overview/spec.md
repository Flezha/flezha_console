# factory-overview Specification

## Purpose
The Factories screens: every registered factory listed, running or not, and a page per factory explaining how it runs, what it declares, whether it can undo a failed run, its still graph, its entry API and its last runs, reached from wherever a factory is named.
## Requirements
### Requirement: Every registered factory is listed, running or not

The console SHALL list a namespace's registered factories at `/namespaces/:ns/factories`, from the same one-read factory catalog every screen that names a factory uses. Every factory any runner in the cluster announces SHALL be listed, whether or not an instance of it runs. Each row SHALL show the factory's id, its description, its run in words, and how many runners serve it, or that no runner serves it, with the controllers those runners are connected to. Each row SHALL link to the factory's page.

`/factories` SHALL list the factories of every namespace the operator's token reaches, grouped by namespace. Both listings SHALL page like every listing and SHALL show the shared partial-answer notice when the catalog is partial. A namespace with no registered factory SHALL say that factories appear here when a runner announces them.

#### Scenario: An idle factory is listed

- **WHEN** a runner announces the factory `fan_trade` and no instance of it runs
- **THEN** the namespace's Factories screen lists `fan_trade` with its description, its run and its runner

#### Scenario: A factory with no runner

- **WHEN** a factory is registered but no runner currently serves it
- **THEN** its row says that no runner serves it

#### Scenario: Factories across namespaces

- **WHEN** an operator opens `/factories` with a token reaching two namespaces
- **THEN** each namespace's factories are listed under its name

### Requirement: A factory's page says how it runs

The factory page at `/namespaces/:ns/factories/:id` SHALL open on one sentence saying how the factory runs, built from its run, `each` and `on_failure` in words:

| Field | Value | Words |
|---|---|---|
| run | `flow` | records stream through its tasklets for as long as it runs |
| run | `steps` | each pass works through its steps in order, committing each one |
| each | `once` | one pass over its first message, then the run ends |
| each | `per_input` | one pass per message, for as long as the run lives |
| each | `chained` | each pass feeds the next, and the run ends when a pass hands nothing on |
| on_failure | `undo_all` | a failed run undoes every finished step by its compensation |
| on_failure | `keep_progress` | a failed run keeps its committed passes and undoes only the one in flight |

The words follow core's steps documentation, where a run is one instance and a pass one iteration: a `per_input` run does not end after one input, and a `chained` run feeds each pass's last handoff into the next. `each` follows the run after a colon, and `on_failure` is a sentence of its own. The listing shows the run and `each` alone.

The words SHALL agree with the glossary's definitions of `each` and `on_failure`, and those terms SHALL explain themselves in place. A field the factory does not announce SHALL be left out of the sentence. The page SHALL show the description and the shared partial-answer notice when its read is partial. A factory no runner announces SHALL be reported as not found, with a link back to the listing.

#### Scenario: A steps factory that undoes its work

- **WHEN** `fan_trade` is a steps factory with `each: once` and `on_failure: undo_all`
- **THEN** its page opens saying each pass works through its steps in order, committing each one: one pass over its first message, then the run ends, and that a failed run undoes every finished step by its compensation

#### Scenario: A flow factory

- **WHEN** a flow factory is opened
- **THEN** its page says records stream through its tasklets for as long as it runs, and says nothing of `each` or `on_failure`

### Requirement: A factory's declarations are stated in words

The factory page SHALL list the declarations its factory announces, each as a short sentence. Each sentence SHALL carry its glossary term where the console has one.

| Declaration | Words |
|---|---|
| durable `memory` | keeps state in memory only, so a crash starts it over |
| durable `local` | keeps state on its controller's disk |
| durable `remote` | keeps state on its controller's disk and in remote storage |
| `sleep_after_ms` | sleeps after that long without work |
| `max_duration_ms` | cancels a run that long after it first starts |
| `effectively_once` true | delivers each output effectively once |
| `effectively_once` false | delivers each output at least once |
| `ack` `checkpoint` | acknowledges its input at checkpoints |
| `ack` `per_input` | acknowledges each input as it is handled |
| `correction_ms` | accepts corrections for that long |
| `keyed` true | can be partitioned by key |
| `keyed` false | cannot be partitioned |
| `keep_finished` hours | keeps a finished run's state for that many hours |
| `keep_finished` the controller's window | keeps a finished run's state for the controller's retention window |
| `keep_finished` absent | does not keep a finished run's state |

Each sentence reads after "It". Core's `max_duration_ms` is a wall-clock stop counted from the run's first bind that ends the run `cancelled`, so its words say cancels rather than stops.

A declaration the factory does not announce SHALL be left out. When the factory's runners announced no declarations, because they are older than the declaration announcement, the page SHALL say that its runners do not describe its settings.

#### Scenario: A durable factory that keeps no finished state

- **WHEN** a factory announces `durable: local` and no `keep_finished`
- **THEN** its page states that it keeps state on its controller's disk and that it does not keep a finished run's state

#### Scenario: Runners that describe nothing

- **WHEN** a factory's row carries no declarations
- **THEN** the page says its runners do not describe its settings, and shows its run and diagram as announced

### Requirement: A factory says whether it can undo a failed run

For a steps factory, the page SHALL say whether it supports compensation and SHALL name the tasklets that compensate, from the announced graph's per-tasklet `compensates`:

- **Some tasklets compensate:** the page SHALL say it supports compensation and name those tasklets.
- **No tasklet compensates:** the page SHALL say that no tasklet compensates. When `on_failure` is `undo_all`, the page SHALL also warn that a failed run cannot undo the work of its completed steps.
- **The graph does not say:** when no tasklet carries `compensates`, the page SHALL say that its runners do not report compensation, not that nothing compensates.

A flow factory's page SHALL make no compensation statement.

#### Scenario: Two tasklets compensate

- **WHEN** `fan_trade`'s graph marks `open_position` and `reserve_funds` as compensating
- **THEN** its page says it supports compensation and names `open_position` and `reserve_funds`

#### Scenario: Undo-all with nothing to undo

- **WHEN** a steps factory declares `on_failure: undo_all` and no tasklet compensates
- **THEN** its page warns that a failed run cannot undo the work of its completed steps

#### Scenario: Runners that do not report compensation

- **WHEN** no tasklet in the graph carries `compensates`
- **THEN** the page says its runners do not report compensation

### Requirement: A factory page draws its graph and its entry API

The factory page SHALL draw the factory's announced graph with the relay pipeline graph in its still mode (see `topology-graph`): entry channels, tasklets and outputs, with compensating tasklets marked. It SHALL list the factory's entry API, its entry channels with their schemas and answers, with the same rendering the relay screen uses for a relay's API. When the factory's runners announce different graphs or APIs, the page SHALL say so and show the newest announcement, as the relay screen does. A factory that announced no graph SHALL say its runners do not announce a graph, and the rest of the page SHALL render.

#### Scenario: The graph of an idle factory

- **WHEN** an operator opens a factory with no running instance
- **THEN** its graph is drawn with its entry channels, tasklets and outputs, and no live figures

#### Scenario: Runners disagree

- **WHEN** the factory's answer carries `disagree: true`
- **THEN** the page says its runners announce different graphs and shows the newest

### Requirement: A factory page lists its last runs

The factory page SHALL list the factory's last 10 runs: its `ended` history records in its namespace, newest first, each as its history sentence (see `relay-history`) with its outcome's tone and its time. Each run SHALL link to that run's records on the Logs screen. The list SHALL link to all of the factory's runs on the Logs screen. When the factory has no ended run, the list SHALL say that runs appear here when one ends. A refused or partial read SHALL be stated in the list without disturbing the rest of the page.

#### Scenario: A factory with runs

- **WHEN** `fan_trade` has 14 ended runs
- **THEN** the page lists its 10 newest, each linking to `/logs/relay_history?relay=<id>` with its namespace
- **AND** a link opens `/logs/relay_history?factory=fan_trade` with its namespace

#### Scenario: A factory that never ran

- **WHEN** a factory has no ended run
- **THEN** the list says runs appear here when one ends

### Requirement: Factories are reached from where they are named

The launcher's factory picker SHALL offer a link to the chosen factory's page. The relay screen SHALL link its factory to the factory's page. The Cluster screen's factory lookup SHALL link each factory to its page. The command palette SHALL reach a factory by its id.

#### Scenario: From a relay to its factory

- **WHEN** an operator activates the factory named on a relay's screen
- **THEN** the factory's page opens

#### Scenario: From the launcher

- **WHEN** an operator chooses `fan_trade` in the launcher
- **THEN** a link to `fan_trade`'s page is offered beside the choice

