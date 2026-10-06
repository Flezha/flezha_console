# controller-identity Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Identity is resolved from a verified token

The UI SHALL derive its flezha principal only from `Flezha.AuthZ.TokenStore.verify/1`. The principal, namespace, and role in the caller context SHALL be the values that call returned. A principal, namespace, role, or list of roles supplied by a UI user, or assembled by the UI itself, SHALL NOT be placed in a caller context. Every other controller call SHALL carry this caller context as its last argument; `Flezha.AuthZ.TokenStore.verify/1` and `Flezha.AuthZ.enforcement_posture/0` are the only calls made without one. The role SHALL be shown as the controller names it — one of `viewer`, `app`, `ops`, `admin`, `runner`, `spawner`, `stopper`.

#### Scenario: A valid token binds an identity

- **WHEN** a token verifies successfully
- **THEN** the caller context carries `source: :ui` plus the `principal`, `namespace`, and `role` from the verification result

#### Scenario: An ops token is shown as ops

- **WHEN** the bound token's role is `ops`
- **THEN** the top bar and the settings screen name the role `ops`

#### Scenario: A principal bound to several roles

- **WHEN** the token's principal holds several roles in its namespace
- **THEN** the caller context still carries only the `role` the token verified with, and no `roles` list
- **AND** the controller judges each call by that role

#### Scenario: An invalid token leaves the context unbound

- **WHEN** verification answers `{:error, %Flezha.Error{}}` with code `authz.token_malformed`, `authz.token_unknown`, `authz.token_revoked` or `authz.token_expired`
- **THEN** the caller context carries `source: :ui` and no principal
- **AND** the error's message is shown to the operator

#### Scenario: The token registry is not open yet

- **WHEN** verification answers `{:error, %Flezha.Error{code: "authz.registry_unavailable"}}`
- **THEN** the caller context is unbound for that call
- **AND** the answer is not cached, so the next call verifies again

#### Scenario: Every call carries the context

- **WHEN** any controller call other than the two context-free reads is made through `NodeManager`
- **THEN** its last argument is the caller context `NodeManager.caller_context/1` built

#### Scenario: A typed principal is not trusted

- **WHEN** a user supplies a principal name through any form field
- **THEN** it is not used as the caller context's principal

### Requirement: Token precedence and storage

The UI SHALL use the signed-in user's own flezha token when they have stored one, and otherwise the service token from the `FLEZHA_TOKEN` environment variable. A stored user token SHALL be encrypted at rest and SHALL NOT be rendered back to any screen.

#### Scenario: A user has stored a personal token

- **WHEN** a user with a stored token loads any screen
- **THEN** their token is the one verified, so controller-side audit entries name their principal

#### Scenario: A user has stored no token

- **WHEN** a user without a stored token loads any screen
- **THEN** the service token from `FLEZHA_TOKEN` is used

#### Scenario: Neither token exists

- **WHEN** no user token is stored and `FLEZHA_TOKEN` is unset
- **THEN** the caller context is unbound and the operator is told which screens will be refused

#### Scenario: The settings screen never echoes the secret

- **WHEN** a user opens settings with a token stored
- **THEN** the screen shows the bound principal, its namespace, its role, and its expiry
- **AND** the token value itself is not present in the rendered page

### Requirement: Verification results are cached

Token verification SHALL be cached, keyed by a digest of the token, for a period no longer than the token's own `expires_at`, so a screen does not spend one remote call establishing identity per remote call that does work. A verification failure with an `authz.token_*` code SHALL be cached for the same short period; a transport failure or `authz.registry_unavailable` SHALL NOT be cached. A refusal from any call — `{:error, %Flezha.Error{class: :denied}}` — SHALL evict the cached entry for the token that made it. A verification that times out or answers `authz.registry_unavailable` SHALL be reported as that failure, and the call SHALL NOT be made with an unbound caller context.

#### Scenario: Repeated calls reuse one verification

- **WHEN** a screen makes several controller calls on one refresh tick
- **THEN** at most one token verification call is made

#### Scenario: A revoked token stops working within the cache period

- **WHEN** a cached token is revoked on the controller
- **THEN** calls keep the cached identity until its entry expires, because the controller sees only the principal
- **AND** the first call after expiry re-verifies and finds the token revoked

#### Scenario: A refused call evicts the cached verification

- **WHEN** a call made with a cached token is refused, because the principal's binding was removed
- **THEN** the cache entry is evicted and the next call re-verifies

#### Scenario: The token store cannot answer

- **WHEN** token verification answers `authz.registry_unavailable` or times out
- **THEN** the call is not made and the screen shows that failure rather than a refusal

#### Scenario: A failure that is not about the token

- **WHEN** a call fails with a class other than `:denied`, such as `:not_found` or `:unavailable`
- **THEN** the cached verification is kept

### Requirement: Authorization posture is stated on every screen

The UI SHALL read `Flezha.AuthZ.enforcement_posture/0` on the same tick that refreshes node status, and SHALL render the posture in the application layout.

#### Scenario: The bootstrap has not been claimed

- **WHEN** the posture is `:bootstrap_pending`
- **THEN** a banner states that authorization is enforced but unclaimed and names `flz auth bootstrap`

#### Scenario: Enforced with no bound principal

- **WHEN** the posture is `:enforced` and no token binds an identity
- **THEN** a banner states that calls will be refused and links to the settings screen

#### Scenario: Enforced with a bound principal

- **WHEN** the posture is `:enforced` and a token binds an identity
- **THEN** the top bar shows the bound principal, its namespace scope, and its role

#### Scenario: Authorization is switched off

- **WHEN** the posture is `:open`
- **THEN** no banner is shown on ordinary screens
- **AND** the controller-health screen states that authorization is disabled

### Requirement: Refusals are a distinct, explained outcome

A refused call — one answering `{:error, %Flezha.Error{class: :denied}}` — SHALL surface as a refusal naming the action, the error's code, and its message, never as an empty section. A screen SHALL continue to render the sections whose calls succeeded.

#### Scenario: One panel on a screen is refused

- **WHEN** one call on a screen answers `{:error, %Flezha.Error{class: :denied, code: "authz.role_insufficient"}}`
- **THEN** that panel states it was refused and gives the code and the controller's message
- **AND** the other panels still render their data

#### Scenario: A refusal for want of an identity

- **WHEN** a call answers `{:error, %Flezha.Error{code: "authz.principal_not_bound"}}` or `{:error, %Flezha.Error{code: "authz.no_role_binding"}}`
- **THEN** the refusal links to the settings screen where a token is stored

#### Scenario: A mutation is refused

- **WHEN** a start, stop, plugin enable or disable, or quota change is refused
- **THEN** the form states the refusal with the error's code and message
- **AND** no success message is shown

### Requirement: The UI's reach matches its token's scope

The namespace switcher SHALL offer only namespaces the bound token can reach. A token scoped to a single namespace SHALL select that namespace and state the scope rather than offering namespaces whose reads the controller will refuse.

#### Scenario: A namespace-scoped token

- **WHEN** the bound token's namespace is a single namespace
- **THEN** that namespace is selected and the switcher states the token's scope

#### Scenario: A system-scoped token

- **WHEN** the bound token's namespace is `_system`
- **THEN** every namespace is offered

