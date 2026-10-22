#!/bin/sh
# Places two plugin packages in the dev controller's plugin root before it
# boots, so the console's plugin screens have a loaded and a refused package to
# show: `flezha_http`, built from the core checkout with the controller's own
# toolchain (a package loads only on the runtime it was built on), and
# `flezha_http_tampered`, the same archive under another id with its manifest
# changed after it was checksummed, which the loader refuses.
#
# The build writes to its own volumes, never to the checkout's `_build/` or
# `deps/`, which belong to builds on the host.
set -eu

root=/flezha/storage/app/plugins
build=/home/flezha/_build/plugins
out=$build/out

export MIX_ENV=prod
export MIX_BUILD_ROOT=$build/build
export MIX_DEPS_PATH=$build/deps
export RUSTLER_SKIP_COMPILATION=true

cd /flezha/plugins/flezha_http_plugin
mix deps.get --only prod
rm -rf "$out"
mix flezha.plugin.package --output "$out"

mkdir -p "$root"
cp "$out"/flezha_http-*.fpz "$root/flezha_http.fpz"

work=$(mktemp -d)
tar xzf "$root/flezha_http.fpz" -C "$work"
sed -i 's/id: "flezha_http"/id: "flezha_http_tampered"/' "$work/manifest.exs"
tar czf "$root/flezha_http_tampered.fpz" -C "$work" manifest.exs CHECKSUMS.sha256 lib
rm -rf "$work"

ls -l "$root"
