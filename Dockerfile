# Use the official Elixir image as a base
FROM elixir:1.20.4-otp-28

# Install inotify-tools for Phoenix live-reload
RUN apt-get update && apt-get install -y inotify-tools && rm -rf /var/lib/apt/lists/*

# Accept UID and GID as build arguments
ARG UID=1000
ARG GID=1000

# Create a non-root user and its home directory
RUN addgroup --gid 1000 flezha_console && adduser --uid 1000 --gid 1000 --home /home/flezha_console flezha_console

# Create home directory for the flezha_console user
RUN mkdir -p /home/flezha_console && \
    chown flezha_console:flezha_console /home/flezha_console

# Set home directory for the flezha_console user
ENV HOME=/home/flezha_console

# Set the working directory
WORKDIR /flezha_console

# Copy the application code
COPY . .

# Change ownership of the working directory
RUN chown -R flezha_console:flezha_console /flezha_console

# Change ownership of the /tmp directory
RUN chown -R flezha_console:flezha_console /tmp

# Switch to the non-root user
USER flezha_console

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Expose the port Phoenix will run on
EXPOSE 4000

# Refuse to start without a distribution cookie, rather than run under a
# well-known one. Then fetch deps, replace an esbuild binary of another version
# (its path has no version in it, unlike Tailwind's), and compile at startup so
# volume-mounted code changes are picked up automatically, then migrate and
# seed, so a fresh database can log in at once.
CMD ["sh", "-c", ": \"${ERLANG_COOKIE:?ERLANG_COOKIE must be set}\" && mix deps.get && mix esbuild.install --if-missing && mix compile && mix ecto.migrate && mix run --no-start priv/repo/seeds.exs && exec elixir --sname flezha_console --hidden --cookie \"$ERLANG_COOKIE\" -S mix phx.server"]
