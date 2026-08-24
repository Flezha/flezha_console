# namespace-administration Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Namespaces list declared and running together

The namespace listing SHALL union the declared namespaces from `Flezha.AuthZ.NamespaceStore.list/0` with the running hubs from `Flezha.list_namespaces/0`, and SHALL state which of the two each row is. A declared namespace with no running hub SHALL be listed, not omitted.

#### Scenario: A namespace is declared and running

- **WHEN** a namespace appears in both sources
- **THEN** it is listed once and marked as running

#### Scenario: A namespace is declared but not running

- **WHEN** a namespace is declared but has no live hub
- **THEN** it is listed and marked as declared with no hub
- **AND** its operative and runner counts read zero rather than being blank

#### Scenario: A hub is running for an undeclared namespace

- **WHEN** a running hub has no declared record
- **THEN** it is listed and marked as running without a declaration

#### Scenario: The namespace store is not available

- **WHEN** `NamespaceStore.list/0` answers `{:error, {:api_missing, ...}}`
- **THEN** the listing falls back to running hubs and states that declarations are unavailable on this controller

### Requirement: Quotas are shown against their live counters

For each namespace the UI SHALL show every quota kind `Flezha.AuthZ.QuotaCounters.kinds/0` reports, pairing the effective limit from `Flezha.AuthZ.Quotas` with the current counter value, and SHALL make the headroom readable at a glance.

#### Scenario: A namespace with quotas set

- **WHEN** an operator opens a namespace with quota overrides
- **THEN** each quota kind shows its current value against its limit

#### Scenario: A quota is unset

- **WHEN** a quota kind has no limit configured
- **THEN** the row shows the current value and states that no limit applies
- **AND** no meter is drawn against an absent limit

#### Scenario: A quota is at or over its limit

- **WHEN** a counter has reached its limit
- **THEN** the row is marked as breached
- **AND** the breach is visible from the namespace listing without opening the namespace

### Requirement: Namespace creation, deletion, and quota edits

An operator SHALL be able to create a namespace with quota overrides, change an existing namespace's quotas, and delete a namespace. Deletion SHALL require an explicit confirmation naming the namespace.

#### Scenario: Creating a namespace

- **WHEN** an operator submits a namespace name with quota overrides
- **THEN** `Flezha.AuthZ.NamespaceStore.create/2` is called with those overrides
- **AND** the new namespace appears in the listing

#### Scenario: Creation is refused

- **WHEN** the controller refuses the create, for example a duplicate name or an unauthorized principal
- **THEN** the controller's reason is shown on the form
- **AND** no namespace is created

#### Scenario: Changing quotas

- **WHEN** an operator submits changed quota values
- **THEN** `Flezha.AuthZ.NamespaceStore.set_quotas/2` is called with only the changed kinds
- **AND** the meters re-render against the new limits

#### Scenario: Deleting a namespace

- **WHEN** an operator confirms deletion by naming the namespace
- **THEN** `Flezha.AuthZ.NamespaceStore.delete/1` is called

#### Scenario: Deletion is not confirmed

- **WHEN** an operator opens the delete confirmation and dismisses it
- **THEN** no delete call is made

### Requirement: Role bindings for a namespace are visible

The namespace screen SHALL list the principals bound to the namespace, from `Flezha.AuthZ.RoleStore.list_for_namespace/1`, with each principal's role. The UI SHALL NOT bind or unbind roles.

#### Scenario: A namespace has bound principals

- **WHEN** an operator opens a namespace with role bindings
- **THEN** each bound principal and its role is listed

#### Scenario: A namespace has no bound principals

- **WHEN** no principal is bound to the namespace
- **THEN** an empty state says so and names `flz role bind` as the way to add one

