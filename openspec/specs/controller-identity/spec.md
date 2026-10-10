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

### Requirement: Tokens are administered from the namespace screen

The namespace screen SHALL list the tokens of that namespace from `Flezha.Service.Namespace.tokens/1`, each with its id, principal, role, label and status (active, revoked or expired), and never the token itself. An operator SHALL be able to issue a token for a principal and role in that namespace through `Flezha.Service.Namespace.issue_token/5`, with an optional label and a lifetime in seconds or `never`, and to revoke a listed token through `Flezha.Service.Namespace.revoke_token/2` after an explicit confirmation.

#### Scenario: Tokens are listed

- **WHEN** an operator opens a namespace screen
- **THEN** each token of that namespace is listed with its id, principal, role, label and status
- **AND** no token value appears in the rendered page

#### Scenario: Issuing a token

- **WHEN** an operator issues a token for a principal and role
- **THEN** `issue_token/5` is called with the principal, the screen's namespace, the role and the lifetime and label given
- **AND** the new token is listed on the next read

#### Scenario: An invalid lifetime

- **WHEN** an operator enters a lifetime that is neither a positive number of seconds nor `never`
- **THEN** the form names the lifetime field
- **AND** no call is made

#### Scenario: Revoking a token

- **WHEN** an operator confirms revoking a listed token
- **THEN** `revoke_token/2` is called with its id
- **AND** the token is listed as revoked

#### Scenario: The revocation is not confirmed

- **WHEN** an operator opens the revoke confirmation and dismisses it
- **THEN** no call is made

### Requirement: An issued token is shown once and kept nowhere

The token value `issue_token/5` answers SHALL be shown once, in the dialog that issued it, with a control to copy it and a statement that it will not be shown again. It SHALL be dropped from the screen's state when the dialog closes and SHALL NOT be written to a flash message, a log line, a URL, or any store.

#### Scenario: The token is shown after issue

- **WHEN** a token is issued
- **THEN** its value is shown in the issue dialog with a copy control and a show-once notice

#### Scenario: The dialog is closed

- **WHEN** the operator closes the issue dialog
- **THEN** the token value is no longer present in the rendered page or the LiveView's assigns

#### Scenario: The token does not leak into logs

- **WHEN** a token is issued
- **THEN** the console's log output for that request does not contain the token value

### Requirement: The bootstrap is claimed from settings without showing the token

While the enforcement posture is `:bootstrap_pending`, the settings screen SHALL offer to claim the bootstrap with the one-time bootstrap token through `Flezha.Service.Namespace.bootstrap/2`. When the claim answers a minted token, it SHALL be stored as the signed-in user's own flezha token through the same encrypted path a pasted token uses, and SHALL NOT be rendered. The claim SHALL NOT be offered under any other posture, so the console never performs a recovery claim that would invalidate an existing admin.

#### Scenario: Claiming a pending bootstrap

- **WHEN** the posture is `:bootstrap_pending` and an operator submits the bootstrap token
- **THEN** `bootstrap/2` is called with it
- **AND** the settings screen shows the principal now bound as `admin@_system`

#### Scenario: The minted token is stored, not shown

- **WHEN** the claim answers a minted token
- **THEN** it becomes the signed-in user's stored token
- **AND** its value does not appear in the rendered page

#### Scenario: The posture is not pending

- **WHEN** the posture is `:enforced` or `:open`
- **THEN** no bootstrap claim control is rendered

#### Scenario: A wrong bootstrap token

- **WHEN** the controller refuses the presented token
- **THEN** the refusal is shown with its code and hint
- **AND** no token is stored

### Requirement: Controls follow the operations the caller's role grants

The console SHALL read, once per verified token and cached with that verification, the `operations` list that `Flezha.Service.Namespace.whoami/1` answers: the names of the published operations the caller's role grants. A control that performs an operation SHALL be rendered only when that operation's name is in the list. When the answer carries no `operations` list, or the enforcement posture is `:open`, every control SHALL be rendered. The controller's own judgement of each call, and the console's display of a refusal, SHALL apply unchanged.

#### Scenario: A viewer token

- **WHEN** the bound role is `viewer`
- **THEN** no start, stop, send, call, replay, bind, rotate, delete, issue or revoke control is rendered
- **AND** the read-only panels still render

#### Scenario: An ops token

- **WHEN** the bound role is `ops`
- **THEN** state rotation and replay controls are rendered
- **AND** state delete, retention, token and role-binding controls are not

#### Scenario: An older controller

- **WHEN** `whoami/1` answers without an `operations` list
- **THEN** every control is rendered as before

#### Scenario: One read per token

- **WHEN** a screen refreshes several times with the same token
- **THEN** `whoami/1` is called at most once for that token until its verification expires or is evicted

#### Scenario: A rendered control is still refused

- **WHEN** a rendered control's call is refused by the controller
- **THEN** the refusal is shown as before

### Requirement: A token that does not verify is explained in words

When a stored flezha token does not verify, the settings screen's statement SHALL give the controller's message and error code, and SHALL NOT render a raw error structure.

#### Scenario: Storing a token the controller does not recognise

- **WHEN** an operator saves a token the controller does not recognise
- **THEN** the statement says the token was stored but did not verify, with the controller's message and its `authz.token_*` code
- **AND** no raw error structure appears on the page

