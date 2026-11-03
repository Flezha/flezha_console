#!/usr/bin/env bash
# Publishes the console image to Docker Hub as flezha/flezha_console.
#
# Run it once on an amd64 machine and once on an arm64 one, logged in as
# flezha (`docker login -u flezha`), with the flezha_stylebook checkout beside
# this repository (or STYLEBOOK=<path>). Each run builds natively for its own
# CPU, pushes `:<version>-<arch>` and `:latest-<arch>`, and rebuilds the
# `:<version>` and `:latest` manifests from whichever per-arch tags exist, so
# the second run completes them. The version comes from mix.exs, and a
# published `:<version>-<arch>` is never overwritten unless REPUBLISH=1.
set -euo pipefail

IMAGE="flezha/flezha_console"

cd "$(dirname "$0")/.."

stylebook="${STYLEBOOK:-../flezha_stylebook}"
[ -f "$stylebook/package.json" ] || { echo "ERROR: no stylebook checkout at $stylebook" >&2; exit 1; }

case "$(uname -m)" in
  aarch64|arm64) arch="arm64" ;;
  x86_64|amd64)  arch="amd64" ;;
  *) echo "ERROR: unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac

version=$(sed -n 's/^ *version: "\([^"]*\)",$/\1/p' mix.exs | head -1)
[ -n "$version" ] || { echo "ERROR: no version in mix.exs" >&2; exit 1; }

build_tag="$IMAGE:$version-$arch"
if [ "${REPUBLISH:-0}" != "1" ] && docker manifest inspect "$build_tag" >/dev/null 2>&1; then
  echo "ERROR: $build_tag is already published; bump the version or set REPUBLISH=1." >&2
  exit 1
fi

echo "==> Building $build_tag"
# --provenance and --sbom off keep each push a plain image, which
# `docker manifest create` accepts.
DOCKER_BUILDKIT=1 docker build --pull --provenance=false --sbom=false \
  -f deploy/Dockerfile --build-context "stylebook=$stylebook" -t "$build_tag" .

for family in "$version" latest; do
  docker tag "$build_tag" "$IMAGE:$family-$arch"
  echo "==> Pushing $IMAGE:$family-$arch"
  docker push "$IMAGE:$family-$arch"

  members=()
  for a in amd64 arm64; do
    if docker manifest inspect "$IMAGE:$family-$a" >/dev/null 2>&1; then
      members+=("$IMAGE:$family-$a")
    fi
  done
  docker manifest rm "$IMAGE:$family" >/dev/null 2>&1 || true
  docker manifest create "$IMAGE:$family" "${members[@]}"
  docker manifest push "$IMAGE:$family"
  echo "Done. $IMAGE:$family -> ${members[*]}"
done
