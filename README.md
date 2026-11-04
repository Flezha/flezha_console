# Flezha Console

[![CI](https://github.com/Flezha/flezha_console/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/Flezha/flezha_console/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/Flezha/flezha_console)](https://github.com/Flezha/flezha_console/releases/latest)
[![Docker](https://img.shields.io/docker/v/flezha/flezha_console?label=docker&sort=semver)](https://hub.docker.com/r/flezha/flezha_console)
[![License](https://img.shields.io/badge/license-MPL--2.0-blue)](LICENSE)

The web console for operating [Flezha](https://github.com/Flezha/flezha) controllers: a
Phoenix LiveView application that reads and drives a cluster through the controller's HTTP
API.

> Flezha Console is an early release, made for Flezha 0.1.1: screens and settings may still
> change between versions until 1.0.

![A tour of the console: from the namespace dashboard, a relay is started from a factory, found in the relays list, given a plugin that writes its board channel to a file, and shown in its full-screen graph with records flowing into that plugin](docs/console-tour.webp)

## Overview

The console covers the day-to-day operations of `flz`, per namespace and across the
cluster: relays (start, send, call, listen, stop, inspect state, rewind a steps relay), the
live pipeline graph with per-tasklet rates and Cells, plugins and providers, schedules, dead
letters, quotas, access, runners, controllers, logs and observability. Issuing and revoking
tokens, deleting a namespace and stopping a controller stay with `flz`. [Using the
console](docs/guide.md) describes every screen.

It holds no domain state. Every screen is the answer to a controller call made when the
screen reads, and the only data it stores is its own: user accounts, sessions and the
tokens users save, in Postgres.

## How it reaches the controller

- **Transport.** HTTP/2 over mutual TLS to the controller's `http_api` plugin. A call is
  `POST /v1/call/<Module.function>` with its arguments as a JSON array; a live stream
  (`Relay.listen`, `Logs.tail`, `Observability.tail`) is `POST /v1/stream/<Module.function>`,
  read as server-sent events. Plain HTTP is accepted only for a controller on loopback.
- **Surface.** Only operations on core's published consumer API are called, all through
  `FlezhaConsole.Service.NodeManager`, and a test holds the console to core's published
  list. Answers are decoded by shapes recorded from a real controller
  (`priv/controller_shapes.json`).
- **Identity.** Every call carries a Flezha token as its bearer token: the console's own, or
  one a user saved under Settings so the audit log names that user. The console reads the
  principal, role and granted operations from `Namespace.whoami` and renders only the
  controls the role grants; the controller still judges each call.
- **Cluster.** `FLEZHA_CONTROLLER_URL` may name several controllers behind one DNS name. The
  console pins the first address that answers, moves when it stops answering, and reads
  the whole cluster through it.
- **No distribution.** The console starts no Erlang distribution toward the controllers and
  holds no cookie, so it sits outside the cluster's trust boundary.

[How the console is built](docs/architecture.md) has the details.

## Requirements

| Component | Version |
|---|---|
| Flezha controller | 0.1.1 or later, with `http_api` enabled in `_system` |
| PostgreSQL | 16, as CI and the dev stack run |
| Elixir and Erlang, to build | Elixir 1.20.4 on OTP 28, as the images and CI use |
| Node.js, to build | 26 |

Off loopback, `http_api` must serve TLS with `tls_client_cacertfile`, the authority the
console's client certificate is issued from. Building from source also needs a checkout of
[`flezha_stylebook`](https://github.com/Flezha/flezha_stylebook), the design system, beside
this repository.

## Installation

### Docker

The image `flezha/flezha_console` (amd64 and arm64) migrates its database, makes sure the
admin account exists, and starts the server:

```sh
docker run -d --name flezha_console -p 4000:4000 \
  -e DATABASE_URL=ecto://console:secret@db.example/console \
  -e SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  -e PHX_HOST=console.example -e PHX_URL_SCHEME=https -e PHX_URL_PORT=443 \
  -e FLEZHA_CONTROLLER_URL=https://controllers.example:8765 \
  -e FLEZHA_CONTROLLER_CA=/channel_tls/ca.pem \
  -e FLEZHA_CLIENT_CERT=/channel_tls/console.pem \
  -e FLEZHA_CLIENT_KEY=/channel_tls/console.key \
  -e FLEZHA_TOKEN=flzt_... \
  -e FLEZHA_CONSOLE_ADMIN_EMAIL=admin@example.com \
  -e FLEZHA_CONSOLE_ADMIN_PASSWORD='a passphrase of 12 to 72 characters' \
  -v /etc/flezha/channel_tls:/channel_tls:ro \
  flezha/flezha_console:0.1.0
```

### Release archive

Each [GitHub release](https://github.com/Flezha/flezha_console/releases) carries a
self-contained archive for Linux x86_64, macOS on Apple Silicon and macOS on Intel, with
`SHA256SUMS.txt`. [Running a release](docs/running.md) covers checking, configuring and
starting it.

### Deployment guides

The Flezha documentation has complete walkthroughs, including enabling `http_api` and
issuing the console's token:
[Docker Compose](https://github.com/Flezha/flezha/blob/main/docs/public/console/console_docker.md),
[Kubernetes](https://github.com/Flezha/flezha/blob/main/docs/public/console/console_kubernetes.md)
(this repository's manifest is `deploy/kubernetes/console.yaml`) and
[bare metal with systemd](https://github.com/Flezha/flezha/blob/main/docs/public/console/console_bare_metal.md).

## Configuration

| Variable | Required | Meaning |
|---|---|---|
| `DATABASE_URL` | yes | `ecto://user:pass@host/db`; `POOL_SIZE` (10) and `ECTO_IPV6` tune it |
| `SECRET_KEY_BASE` | yes | Signs sessions; `openssl rand -base64 48` |
| `PHX_HOST`, `PHX_URL_SCHEME`, `PHX_URL_PORT` | yes | The address browsers use (default scheme `https`, port 443); LiveView checks origins against it |
| `PORT` | no | The port the server listens on (4000) |
| `PHX_SERVER` | release only | `true` to serve; the image sets it |
| `FLEZHA_CONTROLLER_URL` | yes | The controllers' HTTP API, `https://host:port` |
| `FLEZHA_CONTROLLER_CA` | with `https` | The authority the controllers' server certificates chain to |
| `FLEZHA_CLIENT_CERT`, `FLEZHA_CLIENT_KEY` | with `https` | The console's client certificate and key |
| `FLEZHA_TOKEN` or `FLEZHA_TOKEN_FILE` | yes | The console's Flezha token, or a file holding it |
| `FLEZHA_CONSOLE_ADMIN_EMAIL`, `FLEZHA_CONSOLE_ADMIN_PASSWORD` | release start | The admin account `Release.ensure_admin` keeps in place |
| `DNS_CLUSTER_QUERY` | no | Clusters console replicas; they then need `RELEASE_DISTRIBUTION=name` and a cookie of their own |

The console refuses to start without the controller URL, or with an `https` URL and a
missing or unreadable certificate file, and names the variable.

`bin/certs channel --name <shared name> <controller host>...`, shipped in the release and the
image, makes a self-signed authority, a server certificate per controller and the console's
client certificate, for setups without a CA of their own.

## Development

The dev stack runs two controllers built from a sibling `flezha` checkout, a runner on
each, the console with code reloading, Postgres and Kafka:

```sh
mix assets.setup                                     # npm install and the stylebook's assets, once
docker compose -f docker-compose.dev.yml up --build  # http://localhost:4000, admin@flezha.com / admin
priv/dev/stack.sh status                             # containers and controller readiness
```

[Development](docs/development.md) covers the services, resetting the controller,
distribution over TLS and running without Docker.

## Testing

```sh
mix test        # ExUnit against a fake controller, about a minute
npm run e2e     # Playwright against the dev stack, about a minute
npm run tokens  # design tokens, and WCAG AA contrast in both themes
```

CI runs the format check, a warnings-as-errors compile, `mix test` and the asset build on
every push to `main` and every pull request. [Testing](docs/testing.md) has the rules every
test follows.

## Project layout

| Path | Contents |
|---|---|
| `lib/flezha_console/service/` | The controller channel: connector, calls, streams, answer shapes |
| `lib/flezha_console/` | Accounts, dead-letter seen marks, release tasks |
| `lib/flezha_console_web/live/` | One LiveView per screen, and the shared screen behaviours |
| `lib/flezha_console_web/components/` | The component kit and the relay pipeline graph |
| `assets/` | CSS on the stylebook's tokens, and the JavaScript hooks |
| `test/`, `e2e/` | The ExUnit and Playwright suites |
| `priv/dev/` | Dev stack scripts and controller helpers |
| `rel/`, `deploy/` | Release overlays, the image's Dockerfile and the Kubernetes manifest |

## Documentation

| Page | Contents |
|---|---|
| [Using the console](docs/guide.md) | Vocabulary, every screen, navigation, phone and tablet layout |
| [Running a release](docs/running.md) | Download, verification, settings and start |
| [How the console is built](docs/architecture.md) | Design system, relay graph, controller channel and live data |
| [Development](docs/development.md) | The dev stack and its tools |
| [Testing](docs/testing.md) | Test layers, rules and gates |
| [Releasing](docs/releasing.md) | Archives, CI, tagging a release and publishing the image |

## License

Flezha Console is licensed under the [Mozilla Public License 2.0](LICENSE), the same license
as the Flezha controller. If you distribute a modified copy, publish your changes to its
files under the same license. It is provided "AS IS", without warranty of any kind (MPL-2.0
§6-7). The license grants no trademark rights: a fork, derived work or hosted service must
not use the name "Flezha" or one confusingly similar.
