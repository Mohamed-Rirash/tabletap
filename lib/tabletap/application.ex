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
