import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/tabletap start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :tabletap, TabletapWeb.Endpoint, server: true
end

config :tabletap, TabletapWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Object storage (Feature 04 — Catalog photos). Supabase Storage is
# S3-compatible, so this just points ex_aws at Supabase's endpoint
# instead of AWS's (library-docs.md "ex_aws_s3 (photos)"). Test always
# uses the local adapter — network-free, deterministic. Dev falls back
# to it too when `.env` isn't populated (see .env.example), so building
# this feature never requires a provisioned Supabase project. `dotenvy`
# is dev/test only; prod reads real environment variables directly.
env =
  case config_env() do
    :prod -> System.get_env()
    _ -> Dotenvy.source!([".env", System.get_env()])
  end

supabase_bucket = Map.get(env, "SUPABASE_S3_BUCKET")
supabase_endpoint = Map.get(env, "SUPABASE_S3_ENDPOINT")
supabase_region = Map.get(env, "SUPABASE_S3_REGION", "us-east-1")
supabase_access_key_id = Map.get(env, "SUPABASE_S3_ACCESS_KEY_ID")
supabase_secret_access_key = Map.get(env, "SUPABASE_S3_SECRET_ACCESS_KEY")

supabase_configured? =
  is_binary(supabase_bucket) && supabase_bucket != "" &&
    is_binary(supabase_endpoint) && supabase_endpoint != "" &&
    is_binary(supabase_access_key_id) && supabase_access_key_id != "" &&
    is_binary(supabase_secret_access_key) && supabase_secret_access_key != ""

cond do
  config_env() == :test ->
    config :tabletap, Tabletap.Storage, adapter: Tabletap.Storage.Local

  supabase_configured? ->
    uri = URI.parse(supabase_endpoint)

    config :ex_aws,
      access_key_id: supabase_access_key_id,
      secret_access_key: supabase_secret_access_key,
      region: supabase_region,
      s3: [
        scheme: "#{uri.scheme}://",
        host: uri.host,
        port: uri.port || 443,
        region: supabase_region
      ]

    config :tabletap, Tabletap.Storage,
      adapter: Tabletap.Storage.S3,
      bucket: supabase_bucket,
      public_url_base: "#{uri.scheme}://#{uri.host}/storage/v1/object/public/#{supabase_bucket}"

  config_env() == :prod ->
    raise """
    Supabase Storage is not configured. Set SUPABASE_S3_ENDPOINT, SUPABASE_S3_REGION,
    SUPABASE_S3_ACCESS_KEY_ID, SUPABASE_S3_SECRET_ACCESS_KEY, and SUPABASE_S3_BUCKET.
    """

  true ->
    config :tabletap, Tabletap.Storage, adapter: Tabletap.Storage.Local
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :tabletap, Tabletap.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # Same database as Tabletap.Repo above — see lib/tabletap/oban_repo.ex.
  config :tabletap, Tabletap.ObanRepo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("OBAN_POOL_SIZE") || "5"),
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :tabletap, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :tabletap, TabletapWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :tabletap, TabletapWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :tabletap, TabletapWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :tabletap, Tabletap.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.

  # Cloak — encrypts per-venue wallet merchant credentials at rest
  # (design-qa.md Q57/Q58). Generate with:
  #   elixir -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
  cloak_key =
    System.get_env("CLOAK_KEY") ||
      raise """
      environment variable CLOAK_KEY is missing.
      Generate one with: elixir -e 'IO.puts(:crypto.strong_rand_bytes(32) |> Base.encode64())'
      """

  config :tabletap, Tabletap.Vault,
    ciphers: [
      default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: Base.decode64!(cloak_key)}
    ]

  # WaafiPay — our own platform merchant account, used to collect the
  # monthly subscription + accrued platform fee via push prompt
  # (design-qa.md Q59). Per-venue merchant credentials live encrypted in
  # the database, not here — see Payments.Provider / the WaafiPay adapter.
  # NOTE: no default api_url — the exact prod hostname is UNVERIFIED
  # (research/somalia-payments-waafipay-zaad.md flags conflicting .com/.net
  # sources); confirm directly with WaafiPay before Feature 09 and set it
  # via env rather than trusting a guessed default here.
  config :tabletap, :waafipay,
    api_url: System.fetch_env!("WAAFIPAY_API_URL"),
    platform_merchant_uid: System.fetch_env!("WAAFIPAY_PLATFORM_MERCHANT_UID"),
    platform_api_user_id: System.fetch_env!("WAAFIPAY_PLATFORM_API_USER_ID"),
    platform_api_key: System.fetch_env!("WAAFIPAY_PLATFORM_API_KEY")

  # Real transactional email provider — magic-link auth depends on
  # deliverability (design-qa.md Q47). Swap the adapter below for
  # whichever provider is set up (Postmark shown; SES also approved).
  #
  #     config :tabletap, Tabletap.Mailer,
  #       adapter: Swoosh.Adapters.Postmark,
  #       api_key: System.fetch_env!("POSTMARK_API_KEY")
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
end
