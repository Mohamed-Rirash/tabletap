defmodule Tabletap.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      TabletapWeb.Telemetry,
      Tabletap.Repo,
      # Oban's own Repo (oban_jobs/oban_peers) — see oban_repo.ex.
      Tabletap.ObanRepo,
      # Cluster discovery (build-plan.md Feature 21 — "≥2 clustered nodes...
      # PubSub is cluster-wide", architecture.md's Availability table).
      # `:dns_cluster_query` is unset (`:ignore`) in dev/test/single-node
      # deploys; `config/runtime.exs`'s prod block reads `DNS_CLUSTER_QUERY`
      # from the environment — a real deploy sets it to the platform's
      # internal DNS name (Fly.io: "<app>.internal"; any Docker host with
      # real DNS-based service discovery works the same way). Once nodes
      # connect (however they discover each other — DNSCluster here, or a
      # manual `Node.connect/1`), `Phoenix.PubSub`'s default `:pg`-based
      # adapter needs no further config: verified locally by booting two
      # separate BEAM nodes, connecting them, and confirming a broadcast
      # fired on one is received by a subscriber on the other.
      {DNSCluster, query: Application.get_env(:tabletap, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Tabletap.PubSub},
      # Must start after PubSub, before the Endpoint (Phoenix.Presence's
      # own setup instructions) — waiter shift Presence, build-plan.md
      # Feature 10.
      TabletapWeb.Presence,
      {Oban, Application.fetch_env!(:tabletap, Oban)},
      Tabletap.Vault,
      TabletapWeb.RateLimiter,
      # Start to serve requests, typically the last entry
      TabletapWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tabletap.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    TabletapWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
