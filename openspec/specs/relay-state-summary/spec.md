# relay-state-summary Specification

## Purpose
A relay's condition is explained in one structured summary — state, why, runner, who can run it, what happens next and the diagnosis — that never contradicts itself or claims a wake no runner can make.

## Requirements
### Requirement: A relay's condition is shown as one structured summary

The console SHALL render one summary component wherever it explains a relay's
condition — an attention card, the relay screen and the relay inspector — as
labelled rows, in this order:

- **State:** the health word, with its glossary term;
- **Why:** the reason the controller reported, in words;
- **Runner:** the bound runner, or "None bound";
- **Who can run it:** how many runners serve the relay's factory, or that none does;
- **What happens next:** derived from the state and the runner availability;
- **Diagnosis:** the verdict and each finding with its message and hint, once
  diagnosed, with the finding's code as a small reference link rather than a line of
  its own.

A row whose fact the surface does not hold SHALL be omitted rather than guessed. No
surface SHALL explain a relay's condition in loose sentences outside this component.

#### Scenario: A suspended relay that a runner serves

- **WHEN** relay `orders` is suspended and two runners serve its factory
- **THEN** the summary reads State "Suspended", Runner "None bound", Who can run it
  "2 runners serve factory store_input", and What happens next "The next message
  wakes it on a runner"

#### Scenario: A suspended relay nothing can run

- **WHEN** relay `pwi4eosjk` is suspended and no runner serves its factory
- **THEN** What happens next reads that messages are kept but it cannot run until a
  runner for its factory connects
- **AND** no row says the next message wakes it

#### Scenario: A surface without runner reads

- **WHEN** the summary renders where no runner availability was read
- **THEN** the Who can run it row is absent and What happens next does not claim the
  relay will wake

### Requirement: What happens next never contradicts the runner availability

The What happens next row SHALL be derived from the state together with whether a
runner serves the relay's factory:

- suspended with a serving runner: the next message wakes it;
- suspended with none: it cannot run until a runner for its factory connects;
- unbound, failed or recovering with none serving: it waits until a runner for its
  factory connects;
- parked: it stays stopped until someone fixes it, and the loop does not touch it;
- unbound or failed otherwise: the loop is binding a runner;
- recovering otherwise: it is being rebound within its grace;
- degraded: it is being repaired in place.

Once diagnosed, a `diagnose.no_runner` or `diagnose.runner_mismatch` finding SHALL
outrank a count of serving runners: the row then says the relay cannot run until a
runner that can take it connects.

#### Scenario: Runners that cannot take the relay

- **WHEN** a suspended relay's factory is served by a runner, and Diagnose finds
  `diagnose.runner_mismatch`
- **THEN** What happens next says it cannot run until a runner that can take it
  connects, and does not say the next message wakes it

#### Scenario: A parked relay

- **WHEN** a relay is parked
- **THEN** What happens next says it stays stopped until someone fixes it

### Requirement: A diagnosis never calls an unrunnable relay healthy

The controller's diagnosis of a suspended relay SHALL be the `diagnose.no_runner`
problem when no runner serves its factory, and `diagnose.runner_mismatch` when runners
serve the factory but none can take the relay. The `diagnose.asleep` note SHALL be
returned only when a runner can take it, and its message SHALL say the relay is
suspended and that the next message wakes it on a runner.

#### Scenario: Diagnosing a suspended relay with no runner

- **WHEN** an operator diagnoses a suspended relay whose factory no runner serves
- **THEN** the verdict is a problem with the finding `diagnose.no_runner`
- **AND** the summary does not read "Nothing wrong"

#### Scenario: An ok diagnosis of a relay that is not running

- **WHEN** a suspended relay a runner can take is diagnosed and the controller answers ok
- **THEN** the verdict reads "No fault found", which agrees with a planned suspension, and
  never "Nothing wrong"

