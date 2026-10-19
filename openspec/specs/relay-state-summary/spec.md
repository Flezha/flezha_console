# relay-state-summary Specification

## Purpose
A relay's condition is explained in one structured summary — state, cause, impact, runner, handled by, next step and the diagnosis — rendered by the shared condition component, that never contradicts itself or claims a wake no runner can make.
## Requirements
### Requirement: A relay's condition is shown as one structured summary

The console SHALL render a relay's condition with the shared condition component
wherever it explains it: an attention card, the relay screen and the relay inspector.
The component SHALL show labelled rows in this fixed order:

- **State:** the state word, with its glossary term and shape;
- **Cause:** what put the relay in that state;
- **Impact:** what the state means for its traffic;
- **Runner:** "`<runner>` bound" or "None bound", followed by
  "· N can run it (`<factory>`)" once the runners serving its factory were read;
- **Handled by:** Nobody, Flezha or You;
- **Next step:** what happens next, or what the operator does;
- **Diagnosis:** once asked, the verdict and each finding with its message and
  hint, with the finding's code as a small reference link.

Each value SHALL be a short phrase in sentence case, without a trailing full stop.
State and Handled by SHALL come from the console's fixed words. Cause, Impact and
Next step SHALL come from fixed templates that fill in only a read fact: a count,
an id or a factory.

A row whose fact the surface does not hold SHALL be omitted rather than guessed. No
surface SHALL explain a relay's condition in loose sentences outside this component.

#### Scenario: A suspended relay that a runner serves

- **WHEN** relay `pwi4eosjk` is suspended and one runner serves its factory
  `echo_steps`
- **THEN** the summary reads:
  - State "Suspended";
  - Cause "Stopped at a committed boundary on purpose";
  - Impact "Processes nothing until it wakes; its inputs are kept";
  - Runner "None bound · 1 can run it (echo_steps)";
  - Handled by "Nobody";
  - Next step "Wakes on the next message or its timer"

#### Scenario: A suspended relay nothing can run

- **WHEN** relay `pwi4eosjk` is suspended and no runner serves `echo_steps`
- **THEN** Runner reads "None bound · 0 can run it (echo_steps)"
- **AND** Handled by reads "You"
- **AND** Next step reads "Start a runner that serves echo_steps"
- **AND** no row says the next message wakes it

#### Scenario: A surface without runner reads

- **WHEN** the summary renders where no runner availability was read
- **THEN** the Runner row shows the bound runner only
- **AND** the Next step row does not claim the relay will wake

#### Scenario: The old row labels are gone

- **WHEN** any relay summary renders
- **THEN** no row is labelled "Why", "Who can run it" or "What happens next"

### Requirement: What happens next never contradicts the runner availability

The Handled by and Next step rows SHALL be derived in one function from the state
together with the number of runners serving the relay's factory:

- **healthy:** Nobody; no Next step;
- **suspended, with a serving runner:** Nobody; wakes on the next message or its
  timer;
- **suspended, unbound, failed or recovering, with none serving:** You; start a
  runner that serves the factory;
- **unbound, otherwise:** Flezha; bound to a runner by Flezha;
- **failed, otherwise:** Flezha; rebound to another runner by Flezha;
- **recovering, otherwise:** Flezha; rebound by Flezha within its grace;
- **degraded:** Flezha; repaired in place by Flezha;
- **unknown:** Flezha; checked on the next tick;
- **unplaced:** Flezha; placed by Flezha;
- **halted:** You; fix the cause; Flezha retries its bind with a growing delay;
- **partition coverage broken:** You; fix the group's key ranges.

A suspended relay whose runners were not read SHALL have neither row.

Once diagnosed, a `diagnose.no_runner` or `diagnose.runner_mismatch` finding SHALL
outrank a count of serving runners. Handled by then reads You, and Next step reads
"Start a runner that can take it".

#### Scenario: Runners that cannot take the relay

- **WHEN** a suspended relay's factory is served by a runner, and Diagnose finds
  `diagnose.runner_mismatch`
- **THEN** Handled by reads "You" and Next step reads "Start a runner that can take
  it"
- **AND** nothing says the next message wakes it

#### Scenario: A halted relay

- **WHEN** a relay is halted
- **THEN** Handled by reads "You" and Next step reads "Fix the cause; Flezha retries
  its bind with a growing delay"

#### Scenario: One derivation

- **WHEN** the codebase is inspected
- **THEN** the relay summary, the attention items and the relay inspector take
  Handled by from the same function

### Requirement: A diagnosis never calls an unrunnable relay healthy

The controller's diagnosis of a suspended relay SHALL be the `diagnose.no_runner`
problem when no runner serves its factory, and `diagnose.runner_mismatch` when runners
serve the factory but none can take the relay. The `diagnose.suspended` note SHALL be
returned only when a runner can take it, and its message SHALL say the relay is
suspended and that the next message wakes it on a runner. No diagnosis code SHALL be
named `diagnose.asleep` or `diagnose.parked`.

#### Scenario: Diagnosing a suspended relay with no runner

- **WHEN** an operator diagnoses a suspended relay whose factory no runner serves
- **THEN** the verdict is a problem with the finding `diagnose.no_runner`
- **AND** the summary does not read "Nothing wrong"

#### Scenario: An ok diagnosis of a relay that is not running

- **WHEN** a suspended relay that a runner can take is diagnosed, and the controller
  answers ok
- **THEN** the finding is `diagnose.suspended`
- **AND** the verdict reads "No fault found", which agrees with a planned suspension,
  and never "Nothing wrong"

#### Scenario: Diagnosing a halted relay

- **WHEN** a relay stopped by an init error is diagnosed
- **THEN** the finding is `diagnose.halted`, carrying the reason and how long it has
  been halted

### Requirement: One condition component renders every condition

The console SHALL have one condition component that renders labelled rows in a fixed
order and omits a row with no value. The relay summary and every attention item SHALL
render through it. No screen SHALL keep a second rendering of labelled condition
rows.

#### Scenario: The relay screen and a problem card agree

- **WHEN** the same suspended relay is shown on its relay screen and as an attention
  card
- **THEN** both render State, Cause, Impact, Runner, Handled by and Next step
  through the same component, with the same values

