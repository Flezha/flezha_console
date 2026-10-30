#!/usr/bin/env bash
# Smoke-tests a console archive: unpacks it, creates and migrates a fresh
# database, starts the release, wants 200 from its sign-in page, and stops it.
# The directory and the database are removed on every exit path.
#
#   scripts/smoke-release.sh <archive> <database url>
#
# The database in the URL must not exist yet; it is created here and dropped
# afterwards. No controller is needed. The same script runs in CI.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <archive> <database url>" >&2
  exit 2
fi

archive=$1
step=""
dir=""
pid=""
created_db=""

begin() {
  step=$1
  echo "==> $step"
}

# Every eval goes through the release and its runtime config, as an operator's would.
db() {
  "$bin" eval "Application.load(:flezha_console)
    repo = FlezhaConsole.Repo
    case repo.__adapter__().$1(repo.config()) do
      :ok -> :ok
      other -> raise \"$1: #{inspect(other)}\"
    end"
}

finish() {
  rc=$?
  set +e
  if [ -n "$pid" ]; then
    "$bin" stop >/dev/null 2>&1 || kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
  fi
  [ -n "$created_db" ] && db storage_down >/dev/null 2>&1
  if [ "$rc" -ne 0 ]; then
    echo "smoke test failed at: $step" >&2
    [ -s "$dir/console.log" ] && tail -n 40 "$dir/console.log" >&2
  fi
  [ -n "$dir" ] && rm -rf "$dir"
  exit "$rc"
}
trap finish EXIT

begin "unpack $archive"
dir=$(mktemp -d)
tar -xzf "$archive" -C "$dir"
bin="$dir/flezha_console/bin/flezha_console"
[ -x "$bin" ]

port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')

export DATABASE_URL=$2
export SECRET_KEY_BASE
SECRET_KEY_BASE=$(openssl rand -base64 48)
export RELEASE_COOKIE
RELEASE_COOKIE=$(openssl rand -hex 32)
export RELEASE_DISTRIBUTION=name
export RELEASE_NODE="flezha_console_smoke_$$@127.0.0.1"
export FLEZHA_NODE="flezha_smoke_$$@127.0.0.1"
export FLEZHA_CONSOLE_ADMIN_EMAIL=smoke@flezha.invalid
export FLEZHA_CONSOLE_ADMIN_PASSWORD
FLEZHA_CONSOLE_ADMIN_PASSWORD=$(openssl rand -hex 16)
export PHX_SERVER=true PHX_HOST=localhost PHX_URL_SCHEME=http PORT=$port PHX_URL_PORT=$port

begin "create the database"
db storage_up
created_db=yes

begin "migrate"
"$bin" eval FlezhaConsole.Release.migrate

begin "ensure the admin account"
"$bin" eval FlezhaConsole.Release.ensure_admin

begin "start on port $port"
# A child of this script rather than a daemon, so `wait` knows when it is gone.
"$bin" start >"$dir/console.log" 2>&1 &
pid=$!

begin "GET /users/log-in"
status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --retry 30 --retry-delay 1 --retry-connrefused --retry-max-time 60 \
  "http://127.0.0.1:$port/users/log-in")
if [ "$status" != 200 ]; then
  echo "wanted 200 from GET /users/log-in, got $status" >&2
  exit 1
fi

begin "stop"
"$bin" stop
wait "$pid"
pid=""

echo "smoke test passed: $archive"
