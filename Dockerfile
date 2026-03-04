# Use the official Elixir image as a base
FROM elixir:1.18

# Install inotify-tools for Phoenix live-reload
RUN apt-get update && apt-get install -y inotify-tools && rm -rf /var/lib/apt/lists/*

# Accept UID and GID as build arguments
ARG UID=1000
ARG GID=1000

# Create a non-root user and its home directory
RUN addgroup --gid 1000 flezha_ui && adduser --uid 1000 --gid 1000 --home /home/flezha_ui flezha_ui

# Create home directory for the flezha_ui user
RUN mkdir -p /home/flezha_ui && \
    chown flezha_ui:flezha_ui /home/flezha_ui

# Set home directory for the flezha_ui user
ENV HOME=/home/flezha_ui

# Set the working directory
WORKDIR /flezha_ui

# Copy the application code
COPY . .

# Change ownership of the working directory
RUN chown -R flezha_ui:flezha_ui /flezha_ui

# Change ownership of the /tmp directory
RUN chown -R flezha_ui:flezha_ui /tmp

# Switch to the non-root user
USER flezha_ui

# Install Hex and Rebar
RUN mix local.hex --force && \
    mix local.rebar --force

# Install dependencies
RUN mix deps.get

# Compile the application
RUN mix compile

# Expose the port Phoenix will run on
EXPOSE 4000

# Keep the container running in development mode
CMD ["tail", "-f", "/dev/null"]

# Start the Phoenix server
# CMD ["mix", "phx.server"]
