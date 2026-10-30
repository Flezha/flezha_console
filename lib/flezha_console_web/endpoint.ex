defmodule FlezhaConsoleWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :flezha_console

  # The session will be stored in the cookie and signed,
  # this means its contents can be read but not tampered with.
  # Set :encryption_salt if you would also like to encrypt it.
  @session_options [
    store: :cookie,
    key: "_flezha_console_key",
    signing_salt: "R0b/XVXt",
    same_site: "Lax"
  ]

  # A socket connect skips the code reloader: the page request before it
  # reloads changed code, and an edited file reloads the page. Every page
  # connects, with its CSRF token in the params, so connects log at debug.
  @live_transport [connect_info: [session: @session_options], code_reloader: false, log: :debug]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: @live_transport,
    longpoll: @live_transport

  # Serve at "/" the static files from "priv/static" directory.
  #
  # You should set gzip to true if you are running phx.digest
  # when deploying your static files in production.
  plug Plug.Static,
    at: "/",
    from: :flezha_console,
    gzip: false,
    only: FlezhaConsoleWeb.static_paths(),
    # A release digests the root favicon to favicon-<hash>.svg, which `only`'s
    # exact names miss.
    only_matching: ~w(favicon)

  # Code reloading can be explicitly enabled under the
  # :code_reloader configuration of your endpoint.
  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket,
      websocket: [code_reloader: false]

    plug Phoenix.LiveReloader
    plug :reload_changed_code
    plug Phoenix.Ecto.CheckRepoStatus, otp_app: :flezha_console

    # Phoenix's reloader checks the whole project, a quarter of a CPU-second,
    # so it runs once code has changed rather than on every request. A request
    # that skips it still waits out a reload already running.
    defp reload_changed_code(conn, _opts) do
      if FlezhaConsole.Service.ConfigWatcher.code_changed?() do
        conn = Phoenix.CodeReloader.call(conn, Phoenix.CodeReloader.init([]))
        if conn.halted, do: FlezhaConsole.Service.ConfigWatcher.code_changed!()
        conn
      else
        Phoenix.CodeReloader.sync()
        conn
      end
    end
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint], log: {__MODULE__, :log_level, []}

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug FlezhaConsoleWeb.Router

  @doc false
  # A path carrying a login or confirmation token logs at debug, so the token
  # stays out of the logs; the dev stack's webhook receiver logs nothing.
  def log_level(%{path_info: ["users", "log-in", _token]}), do: :debug
  def log_level(%{path_info: ["users", "settings", "confirm-email", _token]}), do: :debug
  def log_level(%{path_info: ["dev", "null"]}), do: false
  def log_level(_conn), do: :info
end
