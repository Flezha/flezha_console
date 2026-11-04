# Running a release

Each GitHub release carries the console for Linux x86_64, macOS on Apple Silicon
and macOS on Intel, with its own Erlang runtime, and a `SHA256SUMS.txt` over
them. Download your platform's archive and the checksums, check, and unpack:

```bash
gh release download v0.1.0 -R Flezha/flezha_console \
  -p 'flezha_console-*-linux-x86_64.tar.gz' -p SHA256SUMS.txt
sha256sum -c --ignore-missing SHA256SUMS.txt     # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS.txt
tar -xzf flezha_console-0.1.0-linux-x86_64.tar.gz
```

A macOS archive is signed ad hoc, not notarized. Fetched with `gh` or `curl` it
runs as it is; one downloaded through a browser needs
`xattr -dr com.apple.quarantine flezha_console` first.

The release takes its settings from the environment: `DATABASE_URL` (an
existing database), `SECRET_KEY_BASE` (`openssl rand -base64 48`), `PHX_HOST`,
`PHX_SERVER=true`, the admin account `FLEZHA_CONSOLE_ADMIN_EMAIL` and
`FLEZHA_CONSOLE_ADMIN_PASSWORD`, and the channel to the controllers:

- `FLEZHA_CONTROLLER_URL` — the controllers' HTTP API, `https://host:port`, where
  `host` may be one DNS name for every controller: the console pins one that
  answers. Plain `http://` is taken only for `127.0.0.1` or `[::1]`. A flezha
  token works only on the controllers that issued it, so a name must not span
  clusters.
- `FLEZHA_CONTROLLER_CA` — the authority the controllers' server certificates
  chain to; each must name the URL's host.
- `FLEZHA_CLIENT_CERT` and `FLEZHA_CLIENT_KEY` — the console's client
  certificate, from the authority the controllers' `http_api` plugin names as
  `tls_client_cacertfile`.
- A flezha token, as `FLEZHA_TOKEN` or `FLEZHA_TOKEN_FILE`, or stored per user
  in Settings: the HTTP API refuses every request without one, even on a
  controller whose authorization is open.

The release and the image carry `bin/certs`, which makes these certificates from
a self-signed authority of its own: `bin/certs channel --name <shared name>
<controller host>...` writes the authority, a server certificate per controller
and the console's client certificate into `$CHANNEL_TLS_DIR` (default
`/channel_tls`), and keeps the ones still valid on later runs.

The controllers need Flezha 0.1.1 or later, with the `http_api` plugin
enabled in `_system` over TLS with `tls_client_cacertfile`. The console starts
no Erlang distribution and needs no cookie; without the URL, or with an `https`
URL and a missing or unreadable file, it refuses to start, naming the variable.
Console replicas that cluster among themselves (`DNS_CLUSTER_QUERY`) set
`RELEASE_DISTRIBUTION=name` and a `RELEASE_COOKIE` of their own, never the
controllers'. The flezha repository's console guide
(`docs/public/console/console.md`) lists every setting. Then:

```bash
flezha_console/bin/flezha_console eval FlezhaConsole.Release.migrate
flezha_console/bin/flezha_console eval FlezhaConsole.Release.ensure_admin
flezha_console/bin/flezha_console start          # or `daemon`, and `stop` to stop it
```

On another platform, build it yourself: `scripts/release-archive.sh` ([Releasing](releasing.md)),
or the Docker image `deploy/Dockerfile` describes.
