# release-distribution Specification

## Purpose
What a release of the console carries, how each archive is checked on its own platform before
it is published, and which events start CI.
## Requirements
### Requirement: Only `master`, pull requests and release tags SHALL start CI

Nothing under `.github/workflows/` SHALL start on a push to a branch other than `master`.
Pushes to `master`, pull requests and `v*` tags SHALL be the only triggers.

#### Scenario: A push to dev starts nothing
- **GIVEN** the files under `.github/workflows/`
- **WHEN** their `on:` blocks are inspected
- **THEN** every `push` trigger names `branches: [master]` or `tags: ["v*"]`, and none names another branch

### Requirement: A release SHALL carry a console archive per platform, run on that platform first

A `v*` tag SHALL build the console release, with its own Erlang runtime and its compiled
assets, natively on Linux x86_64, macOS arm64 and macOS x86_64, and publish each as
`flezha_console-<version>-<platform>.tar.gz`, where `<version>` is the Mix project version and
`<platform>` is `linux-x86_64`, `macos-arm64` or `macos-x86_64`, together with a
`SHA256SUMS.txt` covering them. A tag whose version carries a `-` SHALL make a pre-release.

The release SHALL start with no Erlang distribution unless the operator sets
`RELEASE_DISTRIBUTION`, and SHALL need no cookie to start.

Before it is published, each archive SHALL be unpacked and smoke-tested on a runner of its own
platform by `scripts/smoke-release.sh`: it migrates a fresh database, starts with no
`RELEASE_COOKIE`, `RELEASE_NODE` or `RELEASE_DISTRIBUTION` set, answers `GET /users/log-in`
with 200, and stops. The smoke test SHALL remove its directory and its database on every exit
path. The release SHALL carry no asset until all three archives have passed.

`scripts/release-archive.sh` SHALL build and pack the archive for the host by the same steps.

#### Scenario: Each platform's archive has run on that platform
- **WHEN** a release tag is pushed and its run completes
- **THEN** the release carries the three archives and `SHA256SUMS.txt`, and the run shows each archive's smoke test passing on a runner of its platform

#### Scenario: One failing platform attaches nothing
- **WHEN** one platform's build or smoke test fails
- **THEN** the release carries no asset from that run

#### Scenario: The archive is built and checked locally
- **WHEN** a developer runs `scripts/release-archive.sh` and then `scripts/smoke-release.sh` on the archive it wrote, against a local Postgres
- **THEN** the archive for the host's platform is in `_build/dist/` and the smoke test passes

#### Scenario: The release starts without distribution
- **WHEN** the smoke test starts the release with no cookie and no distribution variable set
- **THEN** the release serves `GET /users/log-in` and the running VM reports that distribution is not started

