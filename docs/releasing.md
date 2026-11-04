# Releasing

## Build and check an archive

```bash
scripts/release-archive.sh       # _build/dist/flezha_console-<version>-<platform>.tar.gz
scripts/smoke-release.sh _build/dist/flezha_console-0.1.0-linux-x86_64.tar.gz \
  ecto://postgres:postgres@localhost:5432/flezha_console_smoke
```

`release-archive.sh` needs Elixir, Node and the stylebook checkout, and builds
for the machine it runs on. `smoke-release.sh` unpacks the archive into a
temporary directory, creates the database the URL names (it must not exist
yet), migrates it, starts the release on a free port, wants 200 from
`/users/log-in` and stops it. It removes the directory and the database however
it ends, and a failure names the step that failed. No controller is needed.

## CI and cutting a release

`.github/workflows/ci.yml` runs on every push to `main` and every pull
request: `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix test` against a Postgres service, and `mix assets.deploy`. Pushes to `dev`
and other branches start nothing, and the browser suite does not run in CI.

A release is cut by pushing a `v*` tag from `main`.
`.github/workflows/release.yml` then builds the archive on Linux and on both
macOS runners with `scripts/release-archive.sh`, smoke-tests each on the runner
that built it with `scripts/smoke-release.sh`, and only when all three passed
attaches them and `SHA256SUMS.txt` to the tag's release. A tag with a `-`
(`v0.1.0-rc.1`) makes a pre-release.

The image `flezha/flezha_console` is published by hand: `scripts/publish-image.sh`, run
once on an amd64 machine and once on an arm64 one, each with the stylebook checkout beside
this repository, pushes that machine's image and joins both under `:<version>` and
`:latest`.

Both files check out `flezha/flezha_stylebook` beside the console, and `ci.yml`
also the parts of `flezha/flezha` that
`test/flezha_console/service/published_surface_test.exs` reads. Both
repositories are public, so no token is needed.
