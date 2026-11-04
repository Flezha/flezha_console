# Development

The compose file brings up a cluster of two controllers, a Rust runner on each,
this console, Postgres and Kafka in one command. The console connects to the
first controller; the second joins it with storage of its own, and its runner
serves the namespace `second`, so every screen has a relay, a runner and
signals on a controller it is not connected to. It expects two sibling
checkouts alongside this one:

| Path | Why |
| --- | --- |
| `../flezha` | The controller, built and bind-mounted into its container |
| `../flezha_stylebook` | The design system. Its tokens, component recipes, fonts and brand lockups are what this console is skinned with. |

The stylebook is an npm `file:` dependency, so install the asset dependencies
once on the host — the `web` container has no Node, and the relative symlink
`npm install` writes travels into it through the repository bind mount:

```bash
mix assets.setup                 # npm install + copy fonts, lockups, favicons
docker compose -f docker-compose.dev.yml up --build
```

Without the stylebook, `mix assets.stylebook` stops with a message naming it
and where it is expected, rather than producing an unstyled build.

Saving `config/config.exs`, `config/dev.exs`, `mix.exs` or `mix.lock` restarts
the `web` container by itself (`FLEZHA_CONSOLE_RESTART_ON_CONFIG_CHANGE` on
`fcon_web`), so the console picks up the change instead of showing Phoenix's "You
must restart your server" page. Only the VM serving the console watches: an
`iex -S mix` in the container, or a `mix phx.server` on the host, is never
stopped this way.

The controller enforces authorization by default, so the stack claims its own
bootstrap: a one-shot `bootstrap` service waits for the controller node, claims
the bootstrap, issues a `_system` token and writes it to a shared volume. The
console reads it through `FLEZHA_TOKEN_FILE` — a file rather than an env var because
the token does not exist until the controller has booted. A restart reuses the
token already written; nothing is re-claimed.

The same step enables the `http_api` plugin in `_system`, the channel the
console reaches the controllers through, over mutual TLS. A one-shot `certs`
step (`rel/overlays/bin/certs channel`) makes a dev authority for it, apart from any
distribution one: a server certificate per controller and the console's client
certificate, into the `fcon_channel_tls` volume, kept across restarts. The
plugin listens only on the controllers that hold `_system`, so both controllers
answer to a shared name, `flezha_controllers`, which each server certificate
names too, and the console's `FLEZHA_CONTROLLER_URL` names it: the console pins
whichever controller answers and moves when it stops answering.

`FLEZHA_AUTHZ_ENABLED` is set to `true` on the controller deliberately. A dev
stack that switched enforcement off would leave the console's whole identity path —
token, principal, refusals — untested locally.

A signed-in user may store their own flezha token under **Settings**, which then
rides their calls so the controller's audit log names the human rather than the
app. It is encrypted at rest and never rendered back.

The `web` container migrates the database and runs `priv/repo/seeds.exs` each
time it starts, so even after a `docker compose down` — the `db` service keeps
its data in the container, so `down` discards it — the next `up` can log in at
once. Log in at http://localhost:4000 with:

- **Email:** `admin@flezha.com`
- **Password:** `admin`

The seed runs only in dev. There is no registration page: an operator makes
every other account with

```bash
docker exec -it fcon_web mix flezha_console.create_user someone@example.com
```

which asks for a password of 12 to 72 characters (or takes `--password`) and
creates the account confirmed, ready to log in.

In dev the console seeds testnet relays — flow and steps, `orders`, the runner's
relay API fixture, and `testnet_showcase`, whose graph holds every shape the
relay graph draws, with its sources, an input filter and output plugins —
websocket plugins and a `hook_webhook` controller plugin once the controller is
reachable, so Dashboard's tiles count them on arrival. A runner that does not
announce `showcase` skips that relay with one log line. See
`:dev_setup` in `config/dev.exs`. Before the controller boots, the
`plugin_packages` service builds the `flezha_http` plugin package with the
controller's toolchain and places it in the plugin root with a copy the loader
refuses, so the plugin screens show a loaded and a refused package
(`priv/dev/plugin_packages.sh`).

## Starting, stopping and restarting the stack

`priv/dev/stack.sh` runs the stack once it has been built:

```bash
priv/dev/stack.sh up                   # start every container, and wait until it is ready
priv/dev/stack.sh stop                 # drain the controllers, then stop every container
priv/dev/stack.sh status               # the containers, and how ready each controller is
priv/dev/stack.sh restart-controllers  # drain and restart each controller in turn
priv/dev/stack.sh restart-web          # restart the console and wait for it to answer
priv/dev/stack.sh update               # fetch and compile the console, restart the controllers onto ../flezha
```

A controller is drained and stopped the way `flz controller stop` stops it,
never killed, so its next boot has no files to repair. The two controllers
restart one after the other, because they compile `../flezha` into one shared
build volume. `up` restarts a controller that was already running, since it
lists the plugin packages `up` places again as pending until it restarts.
Nothing in the script runs `docker compose down`, which discards the
database's data.

## Resetting the dev controller

Controller state written by an older controller is not migrated. To start over
— this **discards all dev controller state**: relays, plugins, schedules,
dead letters, the audit log and the authorization bootstrap — stop the stack,
clear the controller's durable state, drop the console's token volume so the
bootstrap is claimed again, and bring the stack up:

```bash
docker compose -f docker-compose.dev.yml down
../flezha/_build/.target/release/flz reset --yes --include-dlq --include-schedules \
  --include-auth --include-audit --storage-root ../flezha/storage
docker volume rm flezha_console_fcon_auth_data
docker compose -f docker-compose.dev.yml up
```

A cold start then seeds cleanly in the current vocabulary.

## Services

| Container | Role |
| --- | --- |
| `fcon_plugin_packages` | One-shot: builds and places the plugin packages the controller loads at boot. Any `docker compose up`, even of one service, runs it again, and the controller lists the re-placed packages as pending until `priv/dev/stack.sh restart-controllers` (`stack.sh up` does it) |
| `flezha_controller` | The controller, built from `../flezha/deploy/docker/dev/Dockerfile.toolchain` |
| `flezha_rust_runner` | `test/apps/rust_runner`, waits for the control socket then connects |
| `fcon_certs` | One-shot: makes the channel's authority, the controllers' server certificates and the console's client certificate |
| `fcon_bootstrap` | One-shot: claims the authorization bootstrap, issues the console's token and enables `http_api` |
| `fcon_web` | This app, reaching the controllers over HTTPS; it holds no cookie |
| `fcon_tools` | The operator helpers that stand in for `flz` on a controller's host — `priv/dev/stack.sh`, CLI calls, shape recording — holding the cookie; run with `docker exec` |
| `flezha_console_db` | Postgres |
| `fcon_kafka`, `fcon_kafka_ui` | Kafka, for the Kafka provider |

Useful commands:

```bash
docker exec fcon_web mix compile                      # after editing .ex files
docker logs fcon_web 2>&1 | grep EventFeed            # signal feed status
docker logs fcon_web 2>&1 | grep ConfigWatcher        # why the console restarted itself
docker attach flezha_controller                      # controller iex (detach: Ctrl+P Ctrl+Q)
docker exec fcon_tools sh -c 'exec elixir --sname cli1 --hidden --cookie "$ERLANG_COOKIE" "$@"' _ \
  /flezha_console/priv/dev/cli_call.exs Relay.call_channel \
  '["default","orders","place",{"pair":"BTC-EUR","amount":1},{}]'   # call as flz does
```

## Distribution over TLS

The controllers, the bootstrap steps and the tools service talk over Erlang
distribution; the console takes no part in it. By default that is plain TCP,
guarded only by the cookie (`ERLANG_COOKIE`, declared once at the top of
`docker-compose.dev.yml`). To run every link over TLS 1.3 instead, layer the
overlay on:

```bash
docker compose -f docker-compose.dev.yml -f docker-compose.dev-tls.yml up
```

A one-shot `fcon_dist_tls_certs` (`rel/overlays/bin/certs dist`) makes a private
distribution authority, apart from the channel's, and a key, certificate and
option file per distributed host, into the `fcon_dist_tls` volume. Later runs keep them, and remake only what is missing,
expires within 30 days, or was signed by an earlier CA. The option files are
written anew on every run, so a change to their options reaches each node at
the next `up`. Each node then starts
with `ELIXIR_ERL_OPTIONS="-proto_dist inet_tls -ssl_dist_optfile
/dist_tls/<host>.conf"`.

- **Protected:** traffic between nodes is encrypted, and both sides of a link
  check the other's certificate. A node needs a certificate from the stack's CA
  *and* the cookie: a plain-TCP node, a node with another CA's certificate, and
  a node with the wrong cookie are all refused.
- **Not protected:** EPMD, which only reports node names and ports, still runs
  in clear. The cookie is still required.
- **Helper nodes:** `docker exec` inherits the container's
  `ELIXIR_ERL_OPTIONS`, so the commands above and the browser suite's helper
  nodes run over TLS unchanged. A node started any other way needs the same
  two flags and a certificate whose subject alternative name is its host
  name, because `inet_tls_dist` checks a peer against the host part of its node
  name.
- **Outside dev:** a deployment brings its own CA and certificates and keeps
  the CA key off the nodes. The controller's release takes
  `FLEZHA_DIST_TLS_OPTFILE`.

`docker compose … down` followed by `up` without the overlay goes back to plain
TCP. `docker volume rm flezha_console_fcon_dist_tls` discards the CA and the
certificates, and the next overlay `up` makes new ones.

## Without Docker

```bash
# Controller, from the flezha repo, then `flz plugin enable api http_api
# --namespace _system`, which listens on 127.0.0.1:8765
iex -S mix

# Console: plain HTTP is taken for a controller on loopback, with a token
FLEZHA_CONTROLLER_URL=http://127.0.0.1:8765 FLEZHA_TOKEN=<token> mix phx.server
```

A controller on another machine serves `http_api` over TLS with a client
authority, and the console is given `https://…` and its three files as above.
