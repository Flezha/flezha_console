defmodule FlezhaConsoleWeb.Router do
  use FlezhaConsoleWeb, :router

  import FlezhaConsoleWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FlezhaConsoleWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Enable LiveDashboard, the Swoosh mailbox preview and the component kit
  # page in development
  if Application.compile_env(:flezha_console, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FlezhaConsoleWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end

    scope "/dev", FlezhaConsoleWeb do
      pipe_through [:browser, :require_authenticated_user]

      live_session :dev_kit,
        on_mount: [
          {FlezhaConsoleWeb.UserAuth, :ensure_authenticated},
          {FlezhaConsoleWeb.Layouts, :current_path}
        ] do
        live "/kit", KitLive
      end
    end
  end

  ## Authentication routes (public)

  scope "/", FlezhaConsoleWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Protected routes

  scope "/", FlezhaConsoleWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/", LandingController, :show
    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email
    get "/audit", LandingController, :audit

    live_session :authenticated,
      on_mount: [
        {FlezhaConsoleWeb.UserAuth, :ensure_authenticated},
        {FlezhaConsoleWeb.Layouts, :current_path},
        {FlezhaConsoleWeb.Live.Sections, :paging}
      ] do
      live "/namespaces", NamespaceLive.Index
      live "/relays", RelayIndexLive
      live "/factories", FactoryLive, :index
      live "/namespaces/:ns", NamespaceLive.Show
      # The same three screens as the platform routes below, scoped by the
      # path rather than by a filter control — same LiveView, so the filter
      # each of them already applies is the one doing the scoping.
      live "/namespaces/:ns/relays", RelayIndexLive
      live "/namespaces/:ns/factories", FactoryLive, :index
      live "/namespaces/:ns/factories/:id", FactoryLive, :show
      live "/namespaces/:ns/plugins", PluginLive
      live "/namespaces/:ns/schedules", ScheduleLive
      live "/namespaces/:ns/relays/:id", RelayLive
      live "/namespaces/:ns/relays/:id/listen", ListenLive
      live "/namespaces/:ns/relays/:id/state", RelayStateLive
      live "/observability", ObservabilityLive
      live "/controller", ControllerLive
      live "/plugins", PluginLive
      live "/cluster", ClusterLive
      live "/schedules", ScheduleLive
      live "/problems", ProblemsLive
      live "/dlq", DlqLive
      live "/logs", LogsLive
      live "/logs/:kind", LogsLive
    end
  end

  scope "/", FlezhaConsoleWeb do
    pipe_through [:browser]

    get "/*path", LandingController, :not_found
  end
end
