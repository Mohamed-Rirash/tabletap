defmodule TabletapWeb.Router do
  use TabletapWeb, :router

  import TabletapWeb.UserAuth
  import TabletapWeb.GuestToken
  import TabletapWeb.ApiAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug TabletapWeb.BrowserFloorPlug
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

  # build-plan.md Feature 23 — resolves Authorization: Bearer into
  # conn.assigns.current_api_user but never rejects on its own (mirrors
  # :browser's fetch_current_scope_for_user/enforcement split); routes
  # that need a signed-in caller add :require_api_auth on top.
  pipeline :api_auth do
    plug :fetch_bearer_user
  end

  pipeline :require_api_auth do
    plug :require_authenticated_api_user
  end

  pipeline :require_api_waiter do
    plug :assign_scope
    plug :require_api_role, [:waiter]
  end

  pipeline :require_api_manager do
    plug :assign_scope
    plug :require_api_role, [:manager, :owner]
  end

  # Restores an existing guest_token cookie into the session (build-plan.md
  # Feature 07) — scoped to public customer routes only, not staff pages.
  pipeline :guest_token do
    plug :fetch_guest_token
  end

  # No pipeline: probes hit this before any session/CSRF machinery exists.
  get "/healthz", TabletapWeb.HealthController, :show

  # Same no-pipeline reasoning — a real DB round-trip through the actual
  # QR→menu code path, against a dedicated synthetic venue, for an
  # external uptime monitor (build-plan.md Feature 21).
  get "/healthz/order-flow", TabletapWeb.OrderFlowHealthController, :show

  # No pipeline: stands in for a real S3 presigned PUT (Storage.Local),
  # which has no session/CSRF token either. Only reachable when
  # Storage.Local is the active adapter (dev without Supabase, or test).
  put "/uploads/local/*path", TabletapWeb.LocalUploadController, :put

  scope "/", TabletapWeb do
    pipe_through :browser

    get "/", PageController, :home
    get "/unsupported-browser", BrowserFloorController, :show
  end

  # WaafiPay's server posts here directly (build-plan.md Feature 09) — no
  # CSRF token, no session, no cookies exist on that request, so this
  # deliberately uses :api (`:accepts, ["json"]` only), never :browser
  # (whose `protect_from_forgery` would reject every real callback).
  scope "/webhooks", TabletapWeb do
    pipe_through :api

    post "/waafipay", Public.WaafiPayWebhookController, :create
  end

  # Mobile API (build-plan.md Feature 23). Login/refresh/logout need no
  # bearer token yet (that's what they mint/consume) — everything else
  # added by later commits stacks :api_auth + :require_api_auth.
  scope "/api/v1", TabletapWeb.Api do
    pipe_through :api

    post "/auth/request_magic_link", AuthController, :request_magic_link
    post "/auth/confirm", AuthController, :confirm
    post "/auth/refresh", AuthController, :refresh
    post "/auth/logout", AuthController, :logout

    # Customer flow (build-plan.md Feature 23 Commit 2) — guest-token
    # based, no bearer auth, same as the PWA (Feature 07/16).
    get "/venues/:slug/menu", MenuController, :show
    post "/venues/:slug/cart/items", CartController, :add_item
    post "/orders", OrderController, :create
    get "/orders/:guest_token", OrderController, :show
  end

  # Staff flow (build-plan.md Feature 23 Commit 4) — bearer-token
  # protected, scope built from the authenticated user's own membership.
  scope "/api/v1/waiter", TabletapWeb.Api do
    pipe_through [:api, :api_auth, :require_api_auth, :require_api_waiter]

    post "/orders/:id/accept", WaiterController, :accept
    post "/orders/:id/served", WaiterController, :served
  end

  scope "/api/v1/owner", TabletapWeb.Api do
    pipe_through [:api, :api_auth, :require_api_auth, :require_api_manager]

    get "/dashboard", OwnerController, :dashboard
  end

  # Expo push token registration (build-plan.md Feature 23 Commit 5) —
  # bearer-token protected, no scope needed (belongs to the user, not a
  # venue/membership).
  scope "/api/v1/devices", TabletapWeb.Api do
    pipe_through [:api, :api_auth, :require_api_auth]

    post "/", DeviceController, :create
    delete "/:token", DeviceController, :delete
  end

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
      live "/me/history", UserLive.History, :index
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
      live "/feedback", Manager.FeedbackLive, :index
      live "/analytics/revenue", Manager.Analytics.RevenueLive, :index
      live "/analytics/menu-performance", Manager.Analytics.MenuPerformanceLive, :index
      live "/analytics/customers", Manager.Analytics.CustomersLive, :index
      live "/analytics/staff", Manager.Analytics.StaffLive, :index
      live "/analytics/inventory-cost", Manager.Analytics.InventoryCostLive, :index
    end

    # Growth/Pro only (pricing.md) — split from :manager so PlanHooks can
    # gate it without touching the always-available manager routes above.
    live_session :manager_inventory,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_manager},
        {TabletapWeb.PlanHooks, :inventory}
      ] do
      live "/inventory", Manager.IngredientsLive, :index
      live "/inventory/restock", Manager.RestockReportLive, :index
      live "/inventory/restock/print", Manager.RestockPrintLive, :index
      live "/inventory/stocktake", Manager.StocktakeLive, :index
    end

    # Growth/Pro only (pricing.md "Full Report Center") — same split as
    # :manager_inventory above, own live_session so PlanHooks can gate
    # just this one route.
    live_session :manager_report_center,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_manager},
        {TabletapWeb.PlanHooks, :report_center}
      ] do
      live "/reports", Manager.Analytics.ReportsLive, :index
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
      live "/settings/billing", Manager.BillingLive, :show
    end

    # Pro only (pricing.md "Cross-venue comparison") — stacks both the
    # :require_owner role gate and the :org_comparison plan gate; a
    # manager (wrong role) and an Essentials/Growth owner (wrong plan)
    # both get redirected, for different reasons.
    live_session :owner_org_comparison,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_owner},
        {TabletapWeb.PlanHooks, :org_comparison}
      ] do
      live "/analytics/venues", Manager.Analytics.VenueComparisonLive, :index
    end

    live_session :waiter,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_waiter},
        {TabletapWeb.PwaHooks, :waiter}
      ] do
      live "/waiter", Waiter.QueueLive, :index
    end

    live_session :kitchen,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_kitchen_staff}
      ] do
      live "/kitchen", Kitchen.BoardLive, :index
    end

    live_session :cashier,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.ScopeHooks, :require_cashier_staff}
      ] do
      live "/pos", Cashier.PosLive, :index
      live "/pos/z-report", Cashier.ZReportLive, :index
    end

    post "/venues/switch", VenueController, :switch
  end

  # A raw CSV response, not a LiveView — own scope so `:require_manager`
  # (user_auth.ex's controller-plug equivalent of ScopeHooks) never leaks
  # onto the owner/waiter routes above or the public ones below.
  scope "/", TabletapWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_manager,
      :require_inventory_feature
    ]

    get "/inventory/restock.csv", Manager.RestockCsvController, :show
  end

  # Same raw-CSV-response reasoning as the restock export above —
  # gated behind :report_center same as its LiveView twin (/reports).
  scope "/", TabletapWeb do
    pipe_through [
      :browser,
      :require_authenticated_user,
      :require_manager,
      :require_report_center_feature
    ]

    get "/reports.csv", Manager.Analytics.ReportsCsvController, :show
  end

  # Deliberately ungated (pricing.md's feature table): the individual
  # Revenue & Sales / Menu Performance screens are part of the
  # always-available live dashboard every tier gets, not the tiered
  # Report Center — only /reports*/analytics/venues are plan-gated.
  scope "/", TabletapWeb do
    pipe_through [:browser, :require_authenticated_user, :require_manager]

    get "/analytics/revenue.csv", Manager.Analytics.RevenueCsvController, :show
    get "/analytics/menu-performance.csv", Manager.Analytics.MenuPerformanceCsvController, :show
  end

  # Owner-only (role-features.md "SaaS subscription" is owner
  # back-office) — the org data export, build-plan.md Feature 19.
  scope "/", TabletapWeb do
    pipe_through [:browser, :require_authenticated_user, :require_owner]

    get "/settings/billing/export.zip", Manager.OrgExportController, :show
  end

  # Platform admin (build-plan.md Feature 19; role-features.md "us
  # only") — own scope, `:require_authenticated_user` only (no
  # `:require_manager`: an admin isn't necessarily a member of any
  # tenant at all). `AdminAuth` is the real gate.
  scope "/admin", TabletapWeb.Admin do
    pipe_through [:browser, :require_authenticated_user]

    live_session :admin,
      on_mount: [
        {TabletapWeb.UserAuth, :require_authenticated},
        {TabletapWeb.AdminAuth, :require_platform_admin}
      ] do
      live "/", TenantsLive, :index
      live "/tenants/:id", TenantLive, :show
    end
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

    live_session :public_menu, on_mount: [{TabletapWeb.PwaHooks, :customer}] do
      live "/venues/:slug/menu", Public.MenuLive, :show
      live "/orders/:guest_token", Public.OrderTrackerLive, :show
    end
  end
end
