defmodule TabletapWeb.Router do
  use TabletapWeb, :router

  import TabletapWeb.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TabletapWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # No pipeline: probes hit this before any session/CSRF machinery exists.
  get "/healthz", TabletapWeb.HealthController, :show

  # No pipeline: stands in for a real S3 presigned PUT (Storage.Local),
  # which has no session/CSRF token either. Only reachable when
  # Storage.Local is the active adapter (dev without Supabase, or test).
  put "/uploads/local/*path", TabletapWeb.LocalUploadController, :put

  scope "/", TabletapWeb do
    pipe_through :browser

    get "/", PageController, :home
  end

  # Other scopes may use custom stacks.
  # scope "/api", TabletapWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:tabletap, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: TabletapWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/", TabletapWeb do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{TabletapWeb.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password

    live_session :manager,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_manager}
      ] do
      live "/dashboard", Manager.DashboardLive, :show
      live "/menu", Manager.MenuLive, :index
      live "/menu/modifiers", Manager.ModifiersLive, :index
    end

    post "/venues/switch", VenueController, :switch
  end

  scope "/", TabletapWeb do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{TabletapWeb.UserAuth, :mount_current_scope}] do
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end

    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  # Public/customer routes — no auth. Temporary entry point for Feature
  # 04's verify step (build-plan.md); Feature 06 replaces the venue-slug
  # lookup with real `/t/:qr_token` → table resolution in front of the
  # same LiveView.
  scope "/", TabletapWeb do
    pipe_through [:browser]

    live_session :public_menu do
      live "/venues/:slug/menu", Public.MenuLive, :show
    end
  end
end
