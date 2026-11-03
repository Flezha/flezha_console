# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :flezha_console, :scopes,
  user: [
    default: true,
    module: FlezhaConsole.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: FlezhaConsole.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :flezha_console,
  ecto_repos: [FlezhaConsole.Repo],
  generators: [timestamp_type: :utc_datetime]

# How long a page's websocket may take to answer before Phoenix falls back to
# long polling, as it must behind a proxy that blocks websockets.
config :flezha_console, :longpoll_fallback_ms, 2_500

# Where a controller error's code links to: core's errors reference, one
# section per code family.
config :flezha_console, :core_docs_url, "https://docs.flezha.com"

# Configures the endpoint
config :flezha_console, FlezhaConsoleWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: FlezhaConsoleWeb.ErrorHTML, json: FlezhaConsoleWeb.ErrorJSON],
    root_layout: [html: {FlezhaConsoleWeb.Layouts, :root}],
    layout: false
  ],
  pubsub_server: FlezhaConsole.PubSub,
  live_view: [signing_salt: "Hv743/Pp"]

# Configures the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :flezha_console, FlezhaConsole.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  flezha_console: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.19",
  flezha_console: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# `secret` is the param a plugin's transient options are posted under, and
# `token` matches login links and the CSRF token, so their values are logged
# as [FILTERED] like passwords.
config :phoenix, :filter_parameters, ["password", "secret", "token"]

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
