import Config

# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :tabletap, Tabletap.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tabletap_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Same database as Tabletap.Repo above — see lib/tabletap/oban_repo.ex.
# Oban itself never runs jobs in test (testing: :manual below), but this
# still needs to exist so the Repo can start under the app supervisor.
config :tabletap, Tabletap.ObanRepo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "tabletap_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tabletap, TabletapWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "z2rjGrEPqbQoTztXyW/q0nxb+2T7cApW+3VlrfsvOkMcjbPfljKD3JXZiv/3qGre",
  server: false

# In test we don't send emails
config :tabletap, Tabletap.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# Oban: jobs never auto-execute in test — tests call Oban.Testing helpers
# (perform_job/2, assert_enqueued/1) explicitly instead (code-standards.md:
# every worker re-checks state and is idempotent, so this is safe to assert against directly)
config :tabletap, Oban, testing: :manual

# Off in test (build-plan.md Feature 21) — see TabletapWeb.Telemetry's
# own comment on periodic_measurements/0 for why.
config :tabletap, :poll_oban_queue_depth, false

# Cloak test key — same reasoning as dev.exs, not a production secret
config :tabletap, Tabletap.Vault,
  ciphers: [
    default:
      {Cloak.Ciphers.AES.GCM,
       tag: "AES.GCM.V1", key: Base.decode64!("5GcxCAF62/hDzxUOn9Q8I2I/4Uwz9XIv24zXFMDLoSQ=")}
  ]

# No test ever calls the real WaafiPay adapter (code-standards.md —
# Tabletap.Payments.ProviderMock stands in via Mox, config.exs). This
# fixed value only backs the adapter's own HMAC unit tests, which need a
# known, stable secret to sign fixture payloads against. The platform_*
# trio backs Tabletap.Billing's credential lookup (design-qa.md Q59) —
# tests exercise it through ProviderMock too, never a real call.
config :tabletap, :waafipay,
  api_url: "https://sandbox.waafipay.example/asm",
  webhook_secret: "test-webhook-secret",
  platform_merchant_uid: "test-platform-merchant",
  platform_api_user_id: "test-platform-api-user",
  platform_api_key: "test-platform-api-key"

# Same dev-only VAPID pair as dev.exs (build-plan.md Feature 20) — only
# needed so WebPushEx.request/2 can sign a JWT; no test ever lets the
# resulting request actually reach a network (Req.Test stub, mirrors
# code-standards.md's "no test hits a real provider API").
config :web_push_ex, :vapid, private_key: "lTSTKeCYxZ_MFHF69n3pfu6PQITXj78AIXGYbWWJ9DE"

config :tabletap, Tabletap.Payments, provider: Tabletap.Payments.ProviderMock

# Routes Notifications.send_push/2's Req.post/2 call through a Req.Test
# stub instead of the real network (build-plan.md Feature 20) — same
# "no test hits a real provider" discipline as the WaafiPay mock above,
# via Req's own built-in test plug rather than a hand-rolled Mox
# behaviour (no adapter-swap seam exists for a single function like
# this the way Payments.provider/0 has for the whole WaafiPay client).
config :tabletap, :web_push_req_options, plug: {Req.Test, Tabletap.Notifications}
