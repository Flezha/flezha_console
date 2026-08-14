# FlezhaUI — connection troubleshooting

How this UI reaches the controller, and what to check when a screen comes up
empty.

## Architecture

Two nodes over Erlang distribution:

```
[fui_web container]                       [flezha_controller container]
  flezha_ui Phoenix app                     flezha iex node
  NodeConnector      ───── connect ──────>  (regular node)
  NodeManager.erpc_call/4  ─── :erpc ────>  Flezha.list_namespaces/0
                                            Flezha.list_operatives/1
                                            Flezha.list_runners/1
  EventBridge  ── ships EventRelay source ─> EventRelay (a process there)
               <──── relayed events ───────
```

`NodeManager` is the only module that names a `Flezha.*` module. Every other
part of the app calls `NodeManager`.

## When a screen is empty

Screens no longer fail silently — each renders a banner naming the problem. The
banner text maps to a cause:

| Banner | Cause | Check |
| --- | --- | --- |
| "Not connected to a flezha controller" | Distribution is down or the node name is wrong | `docker logs fui_web \| grep NodeConnector` |
| "This UI and the flezha controller have diverged: … does not export …" | The controller renamed or removed that function | Compare against `../flezha`; the fix belongs in `NodeManager` |
| "The flezha controller did not answer in time" | The controller is up but wedged | `docker attach flezha_controller` and look at it |
| "The flezha controller reported an error: …" | The call reached the controller and it refused | Read the reason; it is the controller's own |

## No namespaces listed

A namespace exists only once a runner has connected and registered. An empty
list usually means the runner is not up, not that the controller is broken.

```bash
docker compose -f docker-compose.dev.yml ps        # is flezha_rust_runner up?
docker logs flezha_rust_runner
docker exec flezha_controller ls app_data/sockets/ # control socket present?
```

The runner exits when its stdin reaches EOF — that is how a controller owning
its port shuts it down. Its compose service therefore sets `stdin_open: true`;
without it Docker hands the runner `/dev/null` and it exits immediately at
startup, silently and with status 0.

## Events not arriving live

The controller's event bus registers the *calling* process
(`pg:join(scope, event, self())`), and `pg` refuses a non-local pid. An `:erpc`
call runs in a process that dies when the call returns, so it can never hold a
subscription. `EventBridge` therefore ships `EventRelay`'s source to the
controller, compiles it there, and spawns it.

```bash
docker logs fui_web 2>&1 | grep EventBridge
```

- "Relay established on …" — working.
- "Could not establish relay: …" — the reason is in the message. A compile
  failure usually means the controller lacks a module the relay calls.

Screens that subscribe to events also refresh on a timer, so a failed relay
costs liveness, not correctness.

## Container does not pick up code changes

The container has its own `_build` volume. After editing `.ex` files:

```bash
docker exec fui_web mix compile
```

`.heex` changes are picked up by live reload.
