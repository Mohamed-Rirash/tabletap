# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :tabletap, :scopes,
  user: [
    default: false,
    module: Tabletap.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :binary_id,
    schema_table: :users,
    test_data_fixture: Tabletap.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ],
  # Default generator scope as of Feature 03 (Tenancy Core) — almost every
  # future schema (menu_items, orders, ingredients, ...) is org-scoped, not
  # user-scoped, so `mix phx.gen.*` should thread org_id by default.
  # library-docs.md "Phoenix 1.8 Scopes".
  org: [
    default: true,
    module: Tabletap.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:org, :id],
    schema_key: :org_id,
    schema_type: :binary_id,
    schema_table: :orgs,
    test_data_fixture: Tabletap.TenantsFixtures,
    test_setup_helper: :register_and_log_in_owner
  ]

config :tabletap,
  ecto_repos: [Tabletap.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Real IANA time zone database — needed by DateTime.shift_zone!/2
# (Tenants.business_date/2) for any venue timezone besides Etc/UTC.
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

# Configure the endpoint
config :tabletap, TabletapWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: TabletapWeb.ErrorHTML, json: TabletapWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Tabletap.PubSub,
  live_view: [signing_salt: "0NNbABhp"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :tabletap, Tabletap.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  tabletap: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  tabletap: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Oban — background jobs, webhook processing, escalations, rollups
# (queue names + concurrency per architecture.md; escalations is low-volume
# but must never queue behind a rollups backlog, hence the split)
config :tabletap, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  # Tabletap.ObanRepo, not Tabletap.Repo: Oban's own bookkeeping tables
  # (oban_jobs, oban_peers) aren't tenant-owned and run outside any
  # request's org_id context — see oban_repo.ex.
  repo: Tabletap.ObanRepo,
  queues: [default: 10, webhooks: 20, notifications: 10, rollups: 2, escalations: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    # Oban.Plugins.Cron entries are added as the workers they reference
    # land — Cron validates the module exists at boot, so an entry here
    # for a not-yet-written worker (e.g. Tabletap.Analytics.Workers.DailyRollup,
    # Feature 18) would crash the server. Add each cron line in the same
    # commit as its worker.
    {Oban.Plugins.Cron,
     crontab: [
       # Hourly is plenty for a 24h staleness threshold (design-qa.md Q50).
       {"0 * * * *", Tabletap.Ordering.Workers.SweepAbandonedCarts},
       # Every 2 minutes keeps the worst-case "falsely sold out" window
       # close to the nominal 12-minute hold TTL (design-qa.md Q1).
       {"*/2 * * * *", Tabletap.Ordering.Workers.SweepExpiredHolds},
       # Every minute — closest practical granularity to the ~30s target
       # (build-plan.md Feature 09); WaafiPay callbacks aren't retried, so
       # this poll is the guaranteed confirmation path, not a fallback.
       {"* * * * *", Tabletap.Payments.Workers.ReconcilePendingPayments}
     ]}
  ]

# ex_money v6+ dropped the compile-time Cldr backend module in favor of
# :localize (hexdocs.pm/ex_money — "Delete your CLDR backend module").
# Every amount is still an explicit Money.new/2 — this only sets locale
# defaults for display formatting.
config :localize,
  default_locale: :en,
  supported_locales: [:en, :ar, :so]

# No exchange-rate polling: currencies never convert or sum across each
# other by design (venue.currency locks at first order — design-qa.md Q53).
config :ex_money,
  auto_start_exchange_rate_service: false,
  custom_currencies: []

# Cloak — encrypts per-venue wallet merchant credentials at rest
# (design-qa.md Q57/Q58; key comes from env at runtime, see runtime.exs)
config :tabletap, Tabletap.Vault,
  json_library: Jason,
  ciphers: [
    default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: nil}
  ]

# Payments.Provider adapter selection (mirrors Tabletap.Storage's
# adapter-swap pattern) — real WaafiPay adapter everywhere except test,
# where test.exs swaps in Tabletap.Payments.ProviderMock (Mox;
# code-standards.md: no test ever hits a real provider API).
config :tabletap, Tabletap.Payments, provider: Tabletap.Payments.Adapters.WaafiPay

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
