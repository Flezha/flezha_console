# controller-identity Specification

## Purpose
TBD - created by archiving change resync-with-flezha-platform. Update Purpose after archive.
## Requirements
### Requirement: Identity is resolved from a verified token

The UI SHALL derive its flezha principal only from the controller's `Namespace.whoami` answer, called over the channel with the token as its bearer token. The principal, namespace, role, granted operations and enforcement posture the UI shows SHALL be the values that answer carried. A principal, namespace, role, or list of roles supplied by a UI user, or assembled by the UI itself, SHALL NOT be sent to the controller. Every controller call SHALL carry the token as its bearer token, and the controller SHALL judge it by the principal that token proves. Without a token, no controller call SHALL be made. The role SHALL be shown as the controller names it: one of `viewer`, `app`, `ops`, `admin`, `runner`, `spawner`, `stopper`.

#### Scenario: A valid token binds an identity

- **WHEN** a token verifies successfully
- **THEN** the UI holds the `principal`, `namespace`, `role`, `operations` and `posture` from the `whoami` answer

#### Scenario: An ops token is shown as ops

- **WHEN** the bound token's role is `ops`
- **THEN** the top bar and the settings screen name the role `ops`

#### Scenario: A principal bound to several roles

- **WHEN** the token's principal holds several roles in its namespace
- **THEN** the UI shows only the `role` the token verified with
- **AND** the controller judges each call by that role

#### Scenario: An invalid token binds nothing

- **WHEN** verification answers an error with code `authz.token_malformed`, `authz.token_unknown`, `authz.token_revoked` or `authz.token_expired`
- **THEN** no identity is bound
- **AND** the error's message is shown to the operator

#### Scenario: The token registry is not open yet

- **WHEN** verification answers an error with code `authz.registry_unavailable`
- **THEN** no identity is bound for that call
- **AND** the answer is not cached, so the next call verifies again

#### Scenario: Every call carries the token

- **WHEN** any controller call is made through `NodeManager`
- **THEN** the request carries the token as `Authorization: Bearer <token>`

#### Scenario: No token

- **WHEN** neither the user nor the service has a token
- **THEN** no request is sent to the controller
- **AND** the screen shows that a flezha token is needed

#### Scenario: A typed principal is not trusted

- **WHEN** a user supplies a principal name through any form field
- **THEN** it is not sent to the controller as the caller's principal

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

Token verification SHALL be cached, keyed by a digest of the token, for a short period, so a screen does not spend one remote call establishing identity per remote call that does work. A verification failure with an `authz.token_*` code SHALL be cached for the same short period; a transport failure or `authz.registry_unavailable` SHALL NOT be cached. A refusal from any call — `{:error, %Flezha.Error{class: :denied}}` — SHALL evict the cached entry for the token that made it. A verification that times out or answers `authz.registry_unavailable` SHALL be reported as that failure, and the call SHALL NOT be made with an unbound caller context.

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

The UI SHALL read the enforcement posture from the verified identity's `whoami` answer on the same tick that refreshes the controller's status, and SHALL render the posture in the application layout.

#### Scenario: The bootstrap has not been claimed

- **WHEN** the posture is `:bootstrap_pending`
- **THEN** a banner states that authorization is enforced but unclaimed and names `flz auth bootstrap`

#### Scenario: No token is bound

- **WHEN** no token binds an identity
- **THEN** a banner states that the console needs a flezha token to reach the controller and links to the settings screen

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

### Requirement: Tokens are listed on the namespace screen

The namespace screen SHALL list the tokens of that namespace from `Flezha.Service.Namespace.tokens/1`. Each token SHALL be shown with:

- its id, principal, role, label and status (active, revoked or expired);
- when it was issued and which principal issued it;
- when it expires, or that it never expires;
- for a revoked token, when it was revoked.

The token itself SHALL never be shown. Times SHALL be shown relative to now, with the absolute time beside them.

The listing SHALL offer a status filter of Active, Revoked, Expired and All, each with its count. The filter SHALL default to Active. Rows SHALL be ordered by soonest expiry first, and tokens that never expire SHALL come last.

The console SHALL NOT issue or revoke tokens: the controller keeps those operations off the network, and an operator issues and revokes tokens with `flz`.

#### Scenario: Tokens are listed

- **WHEN** an operator opens a namespace screen
- **THEN** each active token of that namespace is listed with its id, principal, role, label, status, issue time, issuer and expiry
- **AND** no token value appears in the rendered page

#### Scenario: A token expires soon

- **WHEN** an active token expires within three days
- **THEN** its expiry is shown with the warning tone

#### Scenario: A token never expires

- **WHEN** a token's `expires_at` is `never`
- **THEN** its expiry reads "never" and it is listed after every token that expires

#### Scenario: Filtering by status

- **WHEN** an operator chooses Revoked in the status filter
- **THEN** only revoked tokens are listed, each with the time it was revoked
- **AND** each filter choice shows how many tokens it holds

#### Scenario: The controller answers no times

- **WHEN** a token row carries no `created_at`, `expires_at` or `created_by`
- **THEN** those cells show a placeholder and the row is still listed

#### Scenario: No token is issued or revoked here

- **WHEN** an operator opens a namespace screen, whatever its role
- **THEN** no issue or revoke control is rendered

### Requirement: The bootstrap is claimed with flz

The console SHALL NOT claim the bootstrap: the controller keeps that operation off the network. While the enforcement posture is `:bootstrap_pending`, the settings screen SHALL offer no claim, and the posture banner names `flz auth bootstrap`.

#### Scenario: A pending bootstrap

- **WHEN** the posture is `:bootstrap_pending`
- **THEN** the settings screen renders no bootstrap claim control

### Requirement: Controls follow the operations the caller's role grants

The console SHALL read, once per verified token and cached with that verification, the `operations` list that `Flezha.Service.Namespace.whoami/1` answers: the names of the published operations the caller's role grants. A control that performs an operation SHALL be rendered only when that operation's name is in the list. When the answer carries no `operations` list, or the enforcement posture is `:open`, every control SHALL be rendered. The controller's own judgement of each call, and the console's display of a refusal, SHALL apply unchanged.

#### Scenario: A viewer token

- **WHEN** the bound role is `viewer`
- **THEN** no start, stop, send, call, replay, bind, rotate or delete control is rendered
- **AND** the read-only panels still render

#### Scenario: An ops token

- **WHEN** the bound role is `ops`
- **THEN** state rotation and replay controls are rendered
- **AND** state delete and retention controls are not

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

