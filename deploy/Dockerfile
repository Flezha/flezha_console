# syntax=docker/dockerfile:1
# The console as a release, for production. Build it from the repository root, with the
# stylebook checkout its assets import as a second build context:
#
#   docker build -f deploy/Dockerfile --build-context stylebook=../flezha_stylebook -t flezha-console .
#
# The runtime stage is the build image's own Debian, so the release's ERTS and NIFs find the
# libraries they were linked against.
#
# The container reaches its controllers over HTTPS and starts no Erlang distribution. It
# needs FLEZHA_CONTROLLER_URL, the controllers' HTTP API, and the paths of three files,
# mounted from a secret: FLEZHA_CONTROLLER_CA, the authority the controllers' certificates
# chain to, and FLEZHA_CLIENT_CERT and FLEZHA_CLIENT_KEY, the console's client certificate.
# Without them it refuses to start, naming the variable.
FROM elixir:1.20.4-otp-28 AS build

ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
COPY rel rel
COPY assets assets
COPY --from=stylebook . assets/node_modules/@flezha/stylebook
RUN mix assets.deploy && mix compile && mix release

FROM elixir:1.20.4-otp-28-slim

RUN useradd --uid 1000 --user-group --create-home flezha_console
WORKDIR /app
COPY --from=build --chown=flezha_console:flezha_console /app/_build/prod/rel/flezha_console ./
USER flezha_console

ENV PHX_SERVER=true PORT=4000
EXPOSE 4000
# Migrates, keeps the admin account the environment names, then serves.
CMD ["sh", "-c", "bin/flezha_console eval FlezhaConsole.Release.migrate && bin/flezha_console eval FlezhaConsole.Release.ensure_admin && exec bin/flezha_console start"]
