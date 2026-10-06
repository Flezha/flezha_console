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

The call dialog SHALL offer a raw mode, always available, that takes a text payload, an optional input channel, an optional partition key and an optional message id. Sending SHALL call `Flezha.Service.Relay.send/6` and show the relay that took the message and its verdict: delivered, absorbed as a duplicate, or suspended until the instance wakes. Calling SHALL call `Flezha.Service.Relay.call/6` with a deadline in milliseconds and show the answer payload and the channel it came on.

#### Scenario: Sending a message

- **WHEN** an operator sends a raw message to a running relay
- **THEN** `send/6` is called with that payload and channel
- **AND** the dialog shows the receiving relay and the verdict

#### Scenario: A repeated message id

- **WHEN** an operator sends a message whose id the relay's input log still holds
- **THEN** the dialog shows the verdict as absorbed

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

