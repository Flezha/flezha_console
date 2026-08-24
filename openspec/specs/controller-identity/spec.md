# controller-identity Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Identity is resolved from a verified token

The UI SHALL derive its flezha principal only from `Flezha.AuthZ.TokenStore.verify/1`. The principal, namespace, and role in the caller context SHALL be the values that call returned. A principal, namespace, or role supplied by a UI user SHALL NOT be placed in a caller context.

#### Scenario: A valid token binds an identity

- **WHEN** a token verifies successfully
- **THEN** the caller context carries `source: :ui` plus the `principal`, `namespace`, and `role` from the verification result

#### Scenario: An invalid token leaves the context unbound

- **WHEN** verification answers `{:error, :malformed | :unknown | :token_revoked | :token_expired}`
- **THEN** the caller context carries `source: :ui` and no principal
- **AND** the reason is shown to the operator

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

Token verification SHALL be cached, keyed by the token, for a period no longer than the token's own `expires_at`, so a screen does not spend one remote call establishing identity per remote call that does work. A `{:error, {:forbidden, _}}` answer from any call SHALL evict the cached entry for the token that made it.

#### Scenario: Repeated calls reuse one verification

- **WHEN** a screen makes several controller calls on one refresh tick
- **THEN** at most one token verification call is made

#### Scenario: A revoked token stops working promptly

- **WHEN** a cached token is revoked on the controller and a subsequent call is refused
- **THEN** the cache entry is evicted
- **AND** the next call re-verifies and finds the token revoked

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

A refused call SHALL surface as a refusal naming the action and the reason, never as an empty section. A screen SHALL continue to render the sections whose calls succeeded.

#### Scenario: One panel on a screen is refused

- **WHEN** one call on a screen answers `{:error, {:forbidden, reason}}`
- **THEN** that panel states it was refused and why
- **AND** the other panels still render their data

#### Scenario: A mutation is refused

- **WHEN** a start, stop, attach, detach, or quota change is refused
- **THEN** the form states the refusal and the required role
- **AND** no success message is shown

### Requirement: The UI's reach matches its token's scope

The namespace switcher SHALL offer only namespaces the bound token can reach. A token scoped to a single namespace SHALL select that namespace and state the scope rather than offering namespaces whose reads the controller will refuse.

#### Scenario: A namespace-scoped token

- **WHEN** the bound token's namespace is a single namespace
- **THEN** that namespace is selected and the switcher states the token's scope

#### Scenario: A system-scoped token

- **WHEN** the bound token's namespace is `_system`
- **THEN** every namespace is offered

