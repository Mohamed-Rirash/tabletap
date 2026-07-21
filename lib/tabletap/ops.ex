defmodule Tabletap.Ops do
  @moduledoc """
  Operational tooling outside the product itself (build-plan.md
  Feature 21) — currently just the synthetic order-flow health check an
  external uptime monitor polls, run against one dedicated org/venue
  that never belongs to a real tenant (`orgs.synthetic`, excluded from
  `Tabletap.Admin.list_tenants/0`).
  """

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Catalog.{Category, MenuItem}
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  @synthetic_slug "tabletap-synthetic-healthcheck"

  @doc """
  Exercises the real QR→menu code path (`Tenants.get_venue_by_slug/1` +
  `Catalog.list_menu/1` — exactly what `Public.MenuLive` itself calls)
  against the dedicated synthetic venue, creating it on first call if it
  doesn't exist yet (idempotent — safe to call from `priv/repo/seeds.exs`
  once, or lazily from the health-check endpoint itself). `:ok`, or
  `{:error, reason}` for an external uptime monitor to alert on. Never
  touches a real tenant's data — checkout/payment aren't exercised here
  at all (an automated probe can't approve a real wallet PIN prompt
  anyway), just the read path a real customer's QR scan takes first.
  """
  def check_order_flow do
    venue = ensure_synthetic_venue!()
    Repo.put_org_id(venue.org_id)
    scope = %Scope{org: venue.org, venue: venue, role: :guest}

    case Catalog.list_menu(scope) do
      [{%Category{}, [%MenuItem{} | _]} | _] -> :ok
      _ -> {:error, :menu_empty}
    end
  end

  defp ensure_synthetic_venue! do
    case Repo.get_by(Venue, [slug: @synthetic_slug], skip_org_id: true) do
      %Venue{} = venue -> attach_org(venue)
      nil -> create_synthetic_fixture!()
    end
  end

  # A plain two-query fetch, not `Repo.preload/2` — `Org` has no
  # `org_id` column (an org *is* the tenant), and `Repo.prepare_query/3`
  # would inject one into the preload's own generated query the moment
  # ambient `Repo.put_org_id/1` is set (`Tenants.list_memberships/2`'s
  # own comment is the canonical writeup of this exact gotcha).
  defp attach_org(%Venue{} = venue) do
    org = Repo.one(from(o in Org, where: o.id == ^venue.org_id), skip_org_id: true)
    %{venue | org: org}
  end

  defp create_synthetic_fixture! do
    org =
      case Repo.get_by(Org, [slug: @synthetic_slug], skip_org_id: true) do
        %Org{} = org ->
          org

        nil ->
          %Org{}
          |> Ecto.Changeset.change(%{
            name: "TableTap Synthetic Health Check",
            slug: @synthetic_slug,
            synthetic: true,
            subscription_status: :active,
            trial_ends_at: DateTime.utc_now(:second)
          })
          |> Repo.insert!()
      end

    Repo.put_org_id(org.id)

    venue =
      %Venue{org_id: org.id}
      |> Ecto.Changeset.change(%{
        name: "Synthetic Health Check Venue",
        slug: @synthetic_slug,
        currency: "USD",
        timezone: "Africa/Mogadishu"
      })
      |> Repo.insert!()

    category =
      %Category{org_id: org.id, venue_id: venue.id}
      |> Ecto.Changeset.change(%{name: "Health Check"})
      |> Repo.insert!()

    %MenuItem{org_id: org.id, venue_id: venue.id, category_id: category.id}
    |> Ecto.Changeset.change(%{name: "Synthetic Item", price: Money.new!(:USD, "1.00")})
    |> Repo.insert!()

    %{venue | org: org}
  end
end
