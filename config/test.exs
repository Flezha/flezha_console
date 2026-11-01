import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :flezha_console, FlezhaConsole.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "flezha_console_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :flezha_console, FlezhaConsoleWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "gO6QhiE+RBgz86hvUure0YWCrREZhKUhn2B9azL2AhAZa+ZLhJ+bm8SFvbw9JzWy",
  server: false

# In test we don't send emails
config :flezha_console, FlezhaConsole.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Re-open an ended feed promptly, so a reconnect test does not wait out the
# production backoff.
config :flezha_console, :event_feed_retry_interval_ms, 100
config :flezha_console, :event_feed_settle_interval_ms, 50

# A test drives a screen's refresh by sending it the tick, so a timer must
# never fire one in its place; a tap shows what it heard almost at once.
config :flezha_console, :refresh_interval_ms, :timer.hours(1)
config :flezha_console, :tap_flush_ms, 5

# An event's read is made at once, so a test sees it without waiting out the
# coalescing window.
config :flezha_console, :refresh_coalesce_ms, 0

# Tests tick faster than tabs share a liveness read or a dead-letter count,
# so each tick reads anew; the tests of the sharing set a window of their own.
config :flezha_console, :liveness_ttl_ms, 0
config :flezha_console, :dead_letter_seen_ttl_ms, 0

# Probe a lost controller promptly, for the same reason as the feed.
config :flezha_console, :node_connector_retry_interval_ms, 20

# Nothing listens here: a test that needs a controller serves the fake one and
# points the channel at it.
config :flezha_console, :controller, url: "http://127.0.0.1:1"

# Tests start their own feeds against the fake controller; a supervised
# singleton would tail it and race the test that owns it.
config :flezha_console, :start_event_feed, false
