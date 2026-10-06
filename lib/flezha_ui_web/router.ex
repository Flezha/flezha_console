defmodule FlezhaUiWeb.Router do
  use FlezhaUiWeb, :router

  import FlezhaUiWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FlezhaUiWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:flezha_ui, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: FlezhaUiWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes (public)

  scope "/", FlezhaUiWeb do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    get "/users/register", UserRegistrationController, :new
    post "/users/register", UserRegistrationController, :create
  end

  scope "/", FlezhaUiWeb do
    pipe_through [:browser]

    get "/users/log-in", UserSessionController, :new
    get "/users/log-in/:token", UserSessionController, :confirm
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  ## Protected routes

  scope "/", FlezhaUiWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/users/settings", UserSettingsController, :edit
    put "/users/settings", UserSettingsController, :update
    get "/users/settings/confirm-email/:token", UserSettingsController, :confirm_email

    live_session :authenticated,
      on_mount: [
        {FlezhaUiWeb.UserAuth, :ensure_authenticated},
        {FlezhaUiWeb.Layouts, :current_path}
      ] do
      live "/", DashboardLive
      live "/namespaces", NamespaceLive.Index
      live "/relays", RelayIndexLive
      live "/namespaces/:ns", NamespaceLive.Show
      # The same three screens as the platform routes below, scoped by the
      # path rather than by a filter control — same LiveView, so the filter
      # each of them already applies is the one doing the scoping.
      live "/namespaces/:ns/relays", RelayIndexLive
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
      live "/dlq", DlqLive
      live "/audit", AuditLive
    end
  end
end
