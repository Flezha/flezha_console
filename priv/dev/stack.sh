#!/usr/bin/env bash
# Starts, stops, restarts and updates the dev stack (docker-compose.dev.yml).
#
#   priv/dev/stack.sh up                   start every container, and wait until it is ready
#   priv/dev/stack.sh stop                 drain the controllers, then stop every container
#   priv/dev/stack.sh status               the containers, and how ready each controller is
#   priv/dev/stack.sh restart-controllers  drain and restart each controller in turn
#   priv/dev/stack.sh restart-web          restart the console and wait for it to answer
#   priv/dev/stack.sh update               fetch and compile the console's deps and code,
#                                          then restart the controllers onto ../flezha
#
# Nothing here runs `docker compose down`: the database keeps its data inside
# its container, and `down` discards it.
set -euo pipefail
cd "$(dirname "$0")/../.."

CONTROLLERS=(flezha_controller flezha_controller_2)

compose() { docker compose -f docker-compose.dev.yml "$@"; }

# priv/dev/controller.exs, run as a hidden node inside fcon_web.
controller() {
  docker exec fcon_web sh -c \
    'cd /flezha_console && exec elixir --sname "stack_$$" --hidden --cookie "$ERLANG_COOKIE" priv/dev/controller.exs "$@"' \
    sh "$@"
}

# A controller's container restarts its VM 3 s after the VM stops, so it is
# drained first and its container stopped inside that pause; `docker stop`
# alone would kill the VM after 10 s, leaving its DETS files to repair.
stop_controllers() {
  for container in "${CONTROLLERS[@]}"; do
    controller stop "flezha@$container"
    docker stop "$container" >/dev/null
  done
}

# One at a time: both controllers compile ../flezha into one shared build
# volume, and two compiles at once leave one of them without its modules.
restart_controllers() {
  for container in "${CONTROLLERS[@]}"; do
    controller stop "flezha@$container"
    controller await "flezha@$container"
  done
}

await_web() {
  for _ in $(seq 1 120); do
    if curl -fs -o /dev/null http://localhost:4000/users/log-in; then
      echo "fcon_web answers on http://localhost:4000"
      return
    fi
    sleep 2
  done
  echo "fcon_web did not answer within 240 s" >&2
  exit 1
}

case "${1:-}" in
  up)
    # `up` places the plugin packages again, and a controller that was already
    # running lists them as pending until it restarts.
    running=()
    for container in "${CONTROLLERS[@]}"; do
      if [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = true ]; then
        running+=("$container")
      fi
    done
    compose up -d
    for container in "${CONTROLLERS[@]}"; do
      if [[ " ${running[*]} " == *" $container "* ]]; then
        controller stop "flezha@$container"
      fi
      controller await "flezha@$container"
    done
    await_web
    ;;
  stop)
    stop_controllers
    compose stop
    ;;
  status)
    compose ps --format 'table {{.Name}}\t{{.Status}}'
    for container in "${CONTROLLERS[@]}"; do controller status "flezha@$container"; done
    ;;
  restart-controllers)
    restart_controllers
    ;;
  restart-web)
    docker restart fcon_web >/dev/null
    await_web
    ;;
  update)
    docker exec fcon_web sh -c 'cd /flezha_console && mix deps.get && mix compile'
    restart_controllers
    ;;
  *)
    sed -n '2,13p' "$0" | sed 's/^# \{0,1\}//'
    exit 2
    ;;
esac
