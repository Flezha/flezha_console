# namespace-administration Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Namespaces list declared and running together

The namespace listing SHALL take its namespaces from `Flezha.Service.Relay.list_namespaces/1`, which answers the controller's durable namespace catalog narrowed to what the caller may see, each with whether a hub runs for it, and SHALL state for each row whether it is running. A declared namespace with no running hub SHALL be listed, not omitted. Each namespace's declaration — its quotas and who created it — SHALL be read through `Flezha.Service.Namespace`: `list/1` where the caller may read every record, `get/2` for a single namespace otherwise.

#### Scenario: A namespace is declared and running

- **WHEN** the controller reports a namespace with a running hub
- **THEN** it is listed once and marked as running

#### Scenario: A namespace is declared but not running

- **WHEN** the controller reports a namespace with no running hub
- **THEN** it is listed and marked as declared with no hub
- **AND** its relay and runner counts read zero rather than being blank

#### Scenario: A caller bound to one namespace

- **WHEN** the controller refuses `Service.Namespace.list/1` because the caller is bound to a single namespace
- **THEN** the listing still shows the namespaces `list_namespaces/1` answered
- **AND** the caller's own namespace record is read with `get/2`

#### Scenario: Namespace records are not available

- **WHEN** the namespace record read answers `{:error, {:api_missing, ...}}`
- **THEN** the listing still shows the namespaces and states that declarations are unavailable on this controller

### Requirement: Quotas are shown against their live counters

For each namespace the UI SHALL show every quota kind `Flezha.Service.Namespace.quota_kinds/1` reports — `relays`, `cells`, `mailbox_bytes`, `runners`, and `disk_bytes` — pairing the current counter from `Flezha.Service.Namespace.quota/3` with the limit the namespace's record holds under the key that limits it (`max_relays`, `max_cells_per_relay`, `max_mailbox_bytes_total`, `max_runners`, and `max_state_bytes` respectively), and SHALL make the headroom readable at a glance. The namespace screen SHALL render quotas as a section that collapses. A namespace holding a breached quota SHALL open that section on a first visit regardless of the screen's declared defaults, so a breach is never hidden behind a click.

#### Scenario: A namespace with quotas set

- **WHEN** an operator opens a namespace with quota limits
- **THEN** each quota kind shows its current value against its limit

#### Scenario: Relays are metered against their limit

- **WHEN** a namespace's record holds `max_relays`
- **THEN** the `relays` counter is shown against that limit

#### Scenario: A quota is unset

- **WHEN** a quota kind has no limit configured
- **THEN** the row shows the current value and states that no limit applies
- **AND** no meter is drawn against an absent limit

#### Scenario: A quota is at or over its limit

- **WHEN** a counter has reached its limit
- **THEN** the row is marked as breached
- **AND** the breach is visible from the namespace listing without opening the namespace

#### Scenario: A breach outranks the collapse default

- **WHEN** an operator opens a namespace whose quota is breached
- **THEN** the quota section is open without the operator expanding it

### Requirement: Namespace creation, deletion, and quota edits

An operator SHALL be able to create a namespace with quota overrides, change an existing namespace's quotas, and delete a namespace, through `Flezha.Service.Namespace.create/3`, `set_quotas/3`, and `delete/2`. Deletion SHALL require an explicit confirmation naming the namespace. Because `set_quotas/3` replaces a namespace's overrides as a whole, a quota edit SHALL send every limit the namespace holds, with the edited ones changed.

#### Scenario: Creating a namespace

- **WHEN** an operator submits a namespace name with quota overrides
- **THEN** `Service.Namespace.create/3` is called with those overrides as `quotas`, keyed by the controller's quota fields
- **AND** the new namespace appears in the listing

#### Scenario: Creation is refused

- **WHEN** the controller refuses the create, for example `namespace.already_exists`, `namespace.invalid_name`, or a refusal of the caller's role
- **THEN** the error's message is shown on the form
- **AND** no namespace is created

#### Scenario: Changing quotas

- **WHEN** an operator changes one quota value and submits
- **THEN** `Service.Namespace.set_quotas/3` is called with the namespace's limits, that one changed
- **AND** the limits the operator did not edit keep their values
- **AND** the meters re-render against the new limits

#### Scenario: Deleting a namespace

- **WHEN** an operator confirms deletion by naming the namespace
- **THEN** `Service.Namespace.delete/2` is called

#### Scenario: Deletion is not confirmed

- **WHEN** an operator opens the delete confirmation and dismisses it
- **THEN** no delete call is made

### Requirement: Role bindings for a namespace are visible

The namespace screen SHALL list the principals bound to the namespace, from `Flezha.Service.Namespace.roles/2`, with every role each principal holds there. An operator SHALL be able to bind a principal to a role in the screen's namespace through `Flezha.Service.Namespace.bind_role/4`, and to unbind one role, or a principal's whole binding, through `Flezha.Service.Namespace.unbind_role/3` after an explicit confirmation that states what will be taken away. Role bindings SHALL be rendered as a section that collapses, whose header states how many principals are bound so the count is readable while the section is shut.

#### Scenario: A namespace has bound principals

- **WHEN** an operator opens a namespace with role bindings
- **THEN** each bound principal is listed with its roles

#### Scenario: A principal holds several roles

- **WHEN** a principal's binding holds more than one role, for example `ops` and `viewer`
- **THEN** the principal is listed once with all of its roles

#### Scenario: The count is readable while collapsed

- **WHEN** the role bindings section is collapsed
- **THEN** its header still states how many principals are bound

#### Scenario: A namespace has no bound principals

- **WHEN** no principal is bound to the namespace
- **THEN** an empty state says so and offers the bind control

#### Scenario: Binding a role

- **WHEN** an operator binds a principal to a role
- **THEN** `bind_role/4` is called with the principal, the role and the screen's namespace
- **AND** the principal is listed with that role on the next read

#### Scenario: An unknown role

- **WHEN** the controller refuses the bind with `authz.unknown_role`
- **THEN** the refusal is shown with its message, which names the roles there are

#### Scenario: Unbinding one role

- **WHEN** an operator confirms unbinding one role from a principal
- **THEN** `unbind_role/3` is called with the principal and that role
- **AND** the principal's other roles remain listed

#### Scenario: Unbinding a whole binding

- **WHEN** an operator confirms removing a principal's whole binding
- **THEN** `unbind_role/3` is called with the principal and no role
- **AND** the principal is no longer listed

#### Scenario: The unbind is not confirmed

- **WHEN** an operator opens the unbind confirmation and dismisses it
- **THEN** no call is made

