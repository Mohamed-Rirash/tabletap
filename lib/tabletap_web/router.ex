defmodule TabletapWeb.Router do
  use TabletapWeb, :router

  import TabletapWeb.UserAuth
  import TabletapWeb.GuestToken

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {TabletapWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    # Read-only for guest_token (build-plan.md Feature 07) — restoring an
    # existing cookie into the session; minting a fresh one happens in the
    # LiveView, not here. Harmless on every route, not just public ones.
    plug :fetch_cookies
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # Restores an existing guest_token cookie into the session (build-plan.md
  # Feature 07) — scoped to public customer routes only, not staff pages.
  pipeline :guest_token do
    plug :fetch_guest_token
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

  # WaafiPay's server posts here directly (build-plan.md Feature 09) — no
  # CSRF token, no session, no cookies exist on that request, so this
  # deliberately uses :api (`:accepts, ["json"]` only), never :browser
  # (whose `protect_from_forgery` would reject every real callback).
  scope "/webhooks", TabletapWeb do
    pipe_through :api

    post "/waafipay", Public.WaafiPayWebhookController, :create
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
      live "/orders", Manager.OrdersLive, :index
      live "/menu", Manager.MenuLive, :index
      live "/menu/modifiers", Manager.ModifiersLive, :index
      live "/tables", Manager.TablesLive, :index
      live "/tables/print", Manager.TablePrintLive, :index
    end

    # role-features.md: "Payment account" is Owner back-office, not
    # Manager — a separate live_session so a manager (no :owner role)
    # gets the same deny-by-default redirect ScopeHooks already gives
    # every other role-gated page, not just a hidden nav link.
    live_session :owner,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_owner}
      ] do
      live "/settings/payments", Manager.PaymentSettingsLive, :show
    end

    live_session :waiter,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_waiter}
      ] do
      live "/waiter", Waiter.QueueLive, :index
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

  # Public/customer routes — no auth. `/t/:qr_token` is the real scanned
  # entry point (Feature 06): it resolves the table into the session and
  # redirects to the venue menu LiveView. `/venues/:slug/menu` remains the
  # direct menu surface both the QR redirect and Feature 04's verify step
  # land on.
  scope "/", TabletapWeb do
    pipe_through [:browser, :guest_token]

    get "/t/:qr_token", Public.TableController, :show

    live_session :public_menu do
      live "/venues/:slug/menu", Public.MenuLive, :show
      live "/orders/:guest_token", Public.OrderTrackerLive, :show
    end
  end
end
