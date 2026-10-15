defmodule FlezhaUiWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :flezha_ui

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_flezha_ui_key",
    signing_salt: "R0b/XVXt",
    same_site: "Lax"
  ]

  # A socket connect skips the code reloader's whole-project check: the page
  # request before it already ran one, and an edited file reloads the page.
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options], code_reloader: false],
    longpoll: [connect_info: [session: @session_options], code_reloader: false]

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :flezha_ui,
    gzip: false,
    only: FlezhaUiWeb.static_paths()

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket,
      websocket: [code_reloader: false]
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :flezha_ui
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FlezhaUiWeb.Router
end
