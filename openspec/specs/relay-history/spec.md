# relay-history Specification

## Purpose
How the console presents the relay history: each record as one plain sentence with its outcome's tone, the history's filters, a relay's recent activity on its screen, a namespace's recent runs on Home, and a finished relay's page read from its last ended record.
## Requirements
### Requirement: A history record reads as one sentence

Every relay history record SHALL be shown as one plain sentence built from its fields. The sentence depends on the event:

- **started:** the relay, the factory it started from, and its origin, as "fan_trade-7f3a started from fan_trade, spawned by ma_fan".
- **ended:** the relay, its outcome in words, its duration, its origin, and its error when it carries one, as "fan_trade-7f3a finished: undone after 41 s, spawned by ma_fan".
- **start_failed:** the relay, the factory, and the error, as "fan_trade-7f3a could not start from fan_trade: no runner serves it".

The relay and the factory SHALL link to the relay's screen and to the factory. A parent relay named in an origin SHALL link to that relay's screen. Each sentence SHALL carry its outcome's tone, and the record's time and controller SHALL be shown beside it.

Outcomes SHALL be said, with their tones, as:

| Outcome | Words | Tone |
|---|---|---|
| `completed` | completed | positive |
| `undone` | undone: its completed steps were compensated | warning |
| `failed` | failed | negative |
| `cancelled` | cancelled | neutral |
| `timed_out` | ran out of time | warning |
| `stopped` | stopped (by the principal, when the record names one) | neutral |
| `rescaled_away` | removed by a rescale | neutral |

A record marked `halted` SHALL add that it had halted before it ended.

Origins SHALL be said as:

| Origin | Words |
|---|---|
| `operator` | started by the principal, through its source |
| `schedule` | started by the named schedule |
| `spawn` | spawned by the parent relay |
| `call` | started by a call from the parent relay |
| `group` | started with its partition group |
| `rescale` | started by a rescale |
| `reconcile` | started again by the controller |

A field a record lacks SHALL be left out of the sentence, never shown as a placeholder. No raw atom SHALL reach the text.

#### Scenario: A spawned run that was undone

- **WHEN** an `ended` record carries relay `fan_trade-7f3a`, outcome `undone`, `duration_ms: 41000` and origin `{kind: spawn, parent_relay: ma_fan}`
- **THEN** it reads "fan_trade-7f3a finished: undone after 41 s, spawned by ma_fan", in the warning tone
- **AND** `ma_fan` links to that relay's screen

#### Scenario: An operator stop

- **WHEN** an `ended` record carries outcome `stopped` and origin `{kind: operator, principal: "ops@acme"}`
- **THEN** its sentence says it was stopped and started by ops@acme, in the neutral tone

#### Scenario: A record with no duration

- **WHEN** an `ended` record carries no `duration_ms`
- **THEN** its sentence says its outcome with no duration and shows no placeholder

### Requirement: The relay history is filtered by what an operator looks for

The relay history tab SHALL offer the filters its kind declares: namespace, factory, relay, event and outcome. Event and outcome SHALL be offered as choices of their words. A namespace in scope SHALL be preselected when the screen is reached from a namespace's screen.

#### Scenario: The undone runs of one factory

- **WHEN** an operator filters the relay history by factory `fan_trade` and outcome undone
- **THEN** only the `ended` records of `fan_trade` runs that were undone are listed, newest first

### Requirement: A relay's screen shows its recent activity

The relay screen SHALL show a "Recent activity" strip with the relay's latest history records, at most five, newest first, each as its sentence. It SHALL read them once when the screen opens. It SHALL then keep them live through a tail of the relay history narrowed to this relay, which the screen holds only while it is visible, and SHALL NOT poll. The strip SHALL link to the Logs screen filtered to this relay. When the relay has no history record, the strip SHALL say that nothing was recorded for it yet. A refused read SHALL be stated in the strip without disturbing the rest of the screen.

#### Scenario: A relay with history

- **WHEN** an operator opens a relay that has a `started` record
- **THEN** the strip lists that record's sentence and links to `/logs/relay_history?relay=<id>` with its namespace

#### Scenario: The relay ends while its screen is open

- **WHEN** the relay on display ends
- **THEN** its `ended` record appears at the top of the strip without a reload and without a timed read

#### Scenario: The tab is hidden

- **WHEN** the relay screen's tab is hidden
- **THEN** the strip's tail is released, and it is opened again with a fresh read when the tab is shown

### Requirement: Home lists the namespace's recent runs

The namespace's Home SHALL list its recent runs under a collapsible section titled "Recent runs": the namespace's `ended` history records, newest first, each as its sentence with its outcome's tone and its time. The section SHALL page like every listing, reading older records through the history's cursor. Its title SHALL count how many of the shown runs did not complete. When the namespace has no ended run, the section SHALL say that runs appear here when a relay finishes. The section SHALL read in the background, like Home's other reads.

#### Scenario: Recent runs are listed

- **WHEN** three relays of the namespace ended, one of them undone
- **THEN** the section lists three runs, newest first, and its title counts one run that did not complete

#### Scenario: Growing the listing

- **WHEN** the operator asks for more runs and the history answers a next cursor
- **THEN** the next older runs are appended

### Requirement: A finished relay opens on its last record

When a relay is neither in the registry nor running, the relay screen SHALL read its latest `ended` record from the relay history and show it as the finished relay: outcome in words and tone, when it started and ended, its duration, its origin, and its error. Actions that need a live relay SHALL be absent. The screen SHALL say whether the relay's state was kept:

- when the controller answers that it was, until when, with a link to the State tab;
- when not, that it was not kept, and that a factory keeps the state of its finished runs by declaring `keep_finished`.

A relay with no `ended` record and no live row SHALL be reported as not found.

#### Scenario: A finished run whose state was not kept

- **WHEN** an operator opens a relay that ended undone and whose state was not kept
- **THEN** the screen shows its outcome, times, duration and origin, and says its state was not kept and how a factory keeps it
- **AND** no Stop or Send action is offered

#### Scenario: A finished run whose state was kept

- **WHEN** the controller answers that the relay's state is kept until a time
- **THEN** the screen says until when and links to its State tab

