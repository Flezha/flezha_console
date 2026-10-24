# syntax=docker/dockerfile:1
# The console as a release, for production. Build it from the repository root, with the
# stylebook checkout its assets import as a second build context:
#
#   docker build -f deploy/Dockerfile --build-context stylebook=../flezha_stylebook -t flezha-console .
#
# The runtime stage is the build image's own Debian, so the release's ERTS and NIFs find the
# libraries they were linked against.
FROM elixir:1.18-otp-27 AS build

ENV MIX_ENV=prod
WORKDIR /app
RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod && mix deps.compile

COPY lib lib
COPY priv priv
COPY assets assets
COPY --from=stylebook . assets/node_modules/@flezha/stylebook
RUN mix assets.deploy && mix compile && mix release

FROM elixir:1.18-otp-27-slim

RUN useradd --uid 1000 --user-group --create-home flezha_console
WORKDIR /app
COPY --from=build --chown=flezha_console:flezha_console /app/_build/prod/rel/flezha_console ./
USER flezha_console

ENV PHX_SERVER=true PORT=4000
EXPOSE 4000
# Migrates, keeps the admin account the environment names, then serves.
CMD ["sh", "-c", "bin/flezha_console eval FlezhaConsole.Release.migrate && bin/flezha_console eval FlezhaConsole.Release.ensure_admin && exec bin/flezha_console start"]
