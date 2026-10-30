#!/usr/bin/env bash
# Builds the console release for this machine and packs it as
# _build/dist/flezha_console-<version>-<platform>.tar.gz.
#
# Needs Elixir, Node with npm, and the flezha_stylebook checkout beside this
# repository. The release carries this machine's Erlang runtime, so it is built
# on the platform it is for. The same script runs in CI.
set -euo pipefail

cd "$(dirname "$0")/.."

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64) platform=linux-x86_64 ;;
  Darwin-arm64) platform=macos-arm64 ;;
  Darwin-x86_64) platform=macos-x86_64 ;;
  *)
    echo "release-archive: no release is built for $(uname -s) $(uname -m)" >&2
    exit 1
    ;;
esac

export MIX_ENV=prod

npm ci --prefix assets
mix deps.get --only prod
mix assets.deploy
mix release --overwrite
# The digested copies are in the release now; drop them so the working tree is
# left as it was.
mix phx.digest.clean --all

rel_root=_build/prod/rel
rel=$rel_root/flezha_console
version=$(cut -d' ' -f2 "$rel/releases/start_erl.data")
archive="_build/dist/flezha_console-$version-$platform.tar.gz"

mkdir -p _build/dist
# The cookie `mix release` generated is left out: every download would share
# it. A console takes its controller's cookie through RELEASE_COOKIE.
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$rel_root" --exclude flezha_console/releases/COOKIE flezha_console

echo "$archive"
