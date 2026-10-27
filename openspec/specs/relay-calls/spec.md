# relay-calls Specification

## Purpose
Talking to a relay from the console: the entry channels its factory announces, calling one
from a form generated from its schema, sending to or calling the relay directly without
freezing the screen, and replaying a flow relay's cell from a point in its past.
## Requirements
### Requirement: A relay's announced API is listed

The relay detail screen SHALL list the entry channels its factory announces, read from `Flezha.Service.Relay.api/3` for that relay. Each channel SHALL be shown with its name, its input format, whether it answers and in which format, its description, and its input and answer schemas. The API SHALL be read when the screen mounts and when the operator opens the API section, and SHALL NOT be read on the refresh tick.

#### Scenario: A factory announces channels

- **WHEN** an operator opens a relay whose factory announces entry channels
- **THEN** each channel is listed with its format, its description and whether it answers
- **AND** a channel with a schema shows that schema

#### Scenario: A factory announces no API

- **WHEN** the relay's factory announces no channels
- **THEN** the section states that the factory announces no API
- **AND** the raw send and call controls remain available

#### Scenario: Runners disagree about the API

- **WHEN** the answer marks the factory's runners as announcing different APIs
- **THEN** the section states that the runners disagree and that the latest announcement is shown

#### Scenario: The API is not read on the tick

- **WHEN** the relay detail screen refreshes on its timer
- **THEN** no `Relay.api/3` call is made

### Requirement: An entry channel is called from a form built from its schema

The call dialog SHALL let an operator pick an announced channel and enter its value through fields generated from the channel's schema, and SHALL call `Flezha.Service.Relay.call_channel/6` with that value. A top-level object schema SHALL produce one field per property: text for a string, a selection for an enum, a number field for a number or integer, and a true/false selection for a boolean, with the schema's required properties marked as required. Any other schema SHALL be entered as one JSON value in the JSON field. A channel that answers SHALL show the decoded answer and its format; a channel that does not SHALL show that the input was accepted.

#### Scenario: Calling a channel that answers

- **WHEN** an operator fills the generated fields of an answering channel and submits
- **THEN** `call_channel/6` is called with the channel and the value built from the fields
- **AND** the decoded answer is shown with its format

#### Scenario: Sending to a channel that does not answer

- **WHEN** an operator submits a value to a channel that does not answer
- **THEN** the dialog states that the relay accepted the input

#### Scenario: A required property is empty

- **WHEN** an operator submits with a required property left empty
- **THEN** the dialog names the empty field
- **AND** no call is made

#### Scenario: A schema the form cannot generate

- **WHEN** a channel's schema is not a flat object of the supported types
- **THEN** the value is entered as JSON in the JSON field
- **AND** invalid JSON is reported before any call is made

#### Scenario: The call is refused

- **WHEN** the controller refuses the call, for example with `api.channel_unknown`
- **THEN** the dialog shows the error with its code and hint

### Requirement: A relay is sent a message or called directly

The call dialog SHALL offer a raw mode, always available, that takes:

- a text payload;
- an optional input channel;
- an optional partition key;
- an optional message id.

Sending SHALL call `Flezha.Service.Relay.send/6`. It SHALL show the relay that took
the message and the controller's answer, in fixed words:

| Answer | Shown as |
|---|---|
| delivered | "Delivered" |
| `suspended` verdict | "Kept until it wakes" |
| `absorbed` verdict | "Already received" |
| a refusal, such as `not_ready` | the controller's error, with its code and hint |

Calling SHALL call `Flezha.Service.Relay.call/6` with a deadline in milliseconds and
show the answer payload and the channel it came on.

#### Scenario: Sending a message

- **WHEN** an operator sends a raw message to a running relay
- **THEN** `send/6` is called with that payload and channel
- **AND** the dialog shows the receiving relay and "Delivered"

#### Scenario: A repeated message id

- **WHEN** an operator sends a message whose id the relay's input log still holds
- **THEN** the dialog shows "Already received"

#### Scenario: Sending to a suspended relay

- **WHEN** an operator sends a message to a suspended relay
- **THEN** the dialog shows "Kept until it wakes"

#### Scenario: Calling with a deadline

- **WHEN** an operator calls a relay with a deadline
- **THEN** `call/6` is called with that `deadline_ms`
- **AND** the answer and its channel are shown when it comes

#### Scenario: No answer within the deadline

- **WHEN** the relay does not answer before the deadline
- **THEN** the dialog shows the controller's error with its code and hint

#### Scenario: The deadline is not a positive number

- **WHEN** an operator calls with an empty, zero or non-numeric deadline
- **THEN** the dialog names the deadline field
- **AND** no call is made

### Requirement: A waiting call does not freeze the screen

A send or call SHALL run without blocking the screen that started it. The controller call's timeout SHALL exceed the call's own deadline, so a slow answer is reported as the relay's error rather than as a lost controller. The dialog SHALL state that it is waiting, and closing it SHALL leave the screen usable.

#### Scenario: The screen keeps refreshing during a call

- **WHEN** a call is waiting for its answer
- **THEN** the relay detail screen continues to refresh
- **AND** the dialog shows that it is waiting

#### Scenario: The deadline outlasts the default timeout

- **WHEN** an operator calls with a deadline longer than the console's default controller timeout
- **THEN** the call is allowed its full deadline before the console gives up

### Requirement: A flow relay's cell is replayed from a point in the past

The state screen SHALL let an operator replay a selected cell of a flow relay from a sequence number or an ISO 8601 time through `Flezha.Service.Relay.replay/4`, after an explicit confirmation stating that the cell is rewound and its retained inputs are run again. The control SHALL NOT be offered for a steps relay. On success the screen SHALL show the cell and the sequence the replay started from.

#### Scenario: Replaying from a sequence

- **WHEN** an operator confirms a replay of a flow relay's cell from a sequence
- **THEN** `replay/4` is called with the namespace, the cell path and that sequence
- **AND** the cell and the starting sequence are shown

#### Scenario: Replaying from a time

- **WHEN** an operator supplies an ISO 8601 time instead of a sequence
- **THEN** that time is passed as the replay's starting point

#### Scenario: A steps relay

- **WHEN** an operator opens the state screen of a steps relay
- **THEN** no replay control is rendered

#### Scenario: The replay is not confirmed

- **WHEN** an operator opens the replay confirmation and dismisses it
- **THEN** no call is made

### Requirement: Calls to a relay are shown as they happen

The relay detail screen SHALL offer a folded Calls panel that, while open, lists the calls made to the relay from any source, as core reports them through `Flezha.Service.Relay.listen/5` with the direction `:calls`. Each call SHALL be shown with:
- the time it arrived;
- its source as a badge (UI, CLI, SDK, HTTP, MCP, plugin, relay or internal), and for a call from another relay, that relay;
- its entry channel and its payload;
- once its outcome arrives, the outcome (answered with the answer's channel and payload, timed out, or refused with the error's code) and the call's duration.

A call and its outcome SHALL be paired by their call id, an outcome completing the newest listed call of that id still waiting, so a retried call shows one row per attempt. A call whose outcome has not arrived SHALL be shown as waiting. Calls SHALL be listed newest first, and only the most recent fifty SHALL be kept. An outcome whose call is not listed SHALL be ignored. When the listen ends, is refused or the panel folds, a call still waiting SHALL be shown as having no outcome heard, and SHALL stay so when the panel listens again. The panel SHALL say it is listening only once the controller holds the listen. The panel SHALL be offered, and its listen opened, only when the operations the bound role is granted include `Relay.listen`. The panel SHALL NOT be offered for a relay that has finished.

#### Scenario: A call from the terminal

- **WHEN** the Calls panel is open and the relay is called through `flz`
- **THEN** a row appears with a CLI badge, the entry channel and the payload, shown as waiting
- **AND** when the relay answers, the row shows answered, the answer and the duration

#### Scenario: A call from the console

- **WHEN** the Calls panel is open and an operator calls the relay from the call dialog
- **THEN** a row appears with a UI badge

#### Scenario: A call that times out

- **WHEN** a call to the relay reaches its deadline without an answer
- **THEN** its row shows timed out and the duration

#### Scenario: A refused call

- **WHEN** core reports a call's outcome as refused
- **THEN** its row shows refused with the error's code

#### Scenario: A call from another relay

- **WHEN** another relay calls the relay
- **THEN** its row carries a relay badge and names the calling relay

#### Scenario: A retried call

- **WHEN** core reports two calls with the same call id, each followed by its outcome
- **THEN** two rows are listed, each with its own outcome

#### Scenario: Calls are listed newest first

- **WHEN** two calls arrive one after the other
- **THEN** the later one is listed above the earlier one

#### Scenario: The list is bounded

- **WHEN** more than fifty calls have arrived while the panel is open
- **THEN** only the most recent fifty are listed

#### Scenario: An outcome without its call

- **WHEN** an outcome arrives for a call id the panel does not list
- **THEN** no row is added or changed

#### Scenario: The listen ends with calls waiting

- **WHEN** the listen ends or is refused while a listed call is waiting
- **THEN** that call is shown as having no outcome heard
- **AND** the panel states that it is no longer listening and offers to listen again

#### Scenario: A role without listening

- **WHEN** the operations the bound role is granted do not include `Relay.listen`
- **THEN** no Calls panel is rendered and no listen with `:calls` is opened

### Requirement: The call dialog keeps this session's results

The call dialog SHALL keep the results of the sends, calls and channel calls made from it on the relay screen, each answer or failure as one entry, newest first, the most recent ten. Closing and reopening the dialog SHALL keep them, and leaving the screen SHALL drop them. A message that stops a request before it is sent, such as an invalid deadline or an empty required field, SHALL NOT be kept as a result.

#### Scenario: Two calls in a row

- **WHEN** an operator makes two calls from the dialog
- **THEN** both results are shown, the latest first

#### Scenario: The dialog is closed and reopened

- **WHEN** an operator closes the dialog after a call and opens it again
- **THEN** the earlier result is still shown

#### Scenario: A failed call

- **WHEN** a call from the dialog fails, for example by timing out
- **THEN** the failure is kept as a result with its code

#### Scenario: A request stopped before sending

- **WHEN** a submit is stopped by the dialog's own validation
- **THEN** the message is shown and no result is added

#### Scenario: The list is bounded

- **WHEN** more than ten results have been made from the dialog
- **THEN** only the most recent ten are shown

### Requirement: A relay nothing can run is sent to but not called

When no runner serves a relay's factory, the console SHALL keep Send enabled and show
a note beside it:

- for a suspended relay: "No runner serves `<factory>` yet; the message is kept until
  one connects";
- otherwise: "No runner serves `<factory>`; the controller keeps the message only if
  this relay journals its input".

The controller's answer SHALL stay the authority on what happened to the message.

Call, and a request to an API channel, which waits for the relay to accept it, SHALL
be disabled in that case, with the reason beside it. Nobody can answer a call before
its deadline when nothing runs the relay. The relay screen SHALL read the runners
serving the factory whenever no runner is bound or the relay is suspended, unbound,
failed or recovering, because a failed relay still names the runner that left. The server SHALL refuse a call
under the same condition, including through the `?do=talk` address. The Listen
screen's prompt SHALL follow the same rule: it offers Send and not Call.

While runner availability is unknown, nothing SHALL be disabled and no note shown.

#### Scenario: Sending to a relay no runner serves

- **WHEN** an operator opens a suspended relay whose factory `echo_steps` no runner
  serves
- **THEN** Send is enabled, with the note that the message is kept until a runner
  connects
- **AND** sending calls `send/6` and shows "Kept until it wakes"

#### Scenario: Calling a relay no runner serves

- **WHEN** an operator opens a relay whose factory no runner serves
- **THEN** Call is disabled and reads that no runner serves its factory, so nobody
  can answer
- **AND** no `call/6` is made

#### Scenario: The deep link to a relay nothing can run

- **WHEN** an operator opens `/relays/<id>?do=talk` for a relay whose factory no
  runner serves
- **THEN** the dialog opens with Send available and Call disabled with its reason

#### Scenario: A failed relay whose runner left

- **WHEN** an operator opens a failed relay that still names the runner that left, and
  no runner serves its factory
- **THEN** Handled by reads "You" and Call is disabled with its reason

#### Scenario: A runner connects

- **WHEN** a runner serving the factory connects while the relay screen is open
- **THEN** Call becomes enabled and the note leaves, without a reload

### Requirement: A refused listen is shown as one error statement

When a listen on a relay's outputs, inputs or calls is refused, the Listen tab and the Calls panel SHALL show the refusal as the console's shared error statement: its message, its next step and a link to its reference, with no extra spacing.

#### Scenario: The listen is refused

- **WHEN** the controller refuses a listen with an error code
- **THEN** the screen shows one error statement with the message, the next step and the reference link

