defmodule TabletapWeb.Api.GuestScope do
  @moduledoc """
  Guest-scope resolution shared by the customer-facing `/api/v1`
  controllers (build-plan.md Feature 23) — the exact same
  `%Scope{org:, venue:, role: :guest}` + `Repo.put_org_id/1` pattern
  `Public.MenuLive`/`Public.OrderTrackerLive` build inline in `mount/3`,
  replicated here since a plain controller has no `mount` to share it
  from.
  """

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Repo, Tenants}

  @doc "Resolves a venue slug into a guest scope, or `{:error, :not_found}`."
  def by_slug(slug) do
    case Tenants.get_venue_by_slug(slug) do
      nil -> {:error, :not_found}
      venue -> {:ok, guest_scope(venue.org, venue)}
    end
  end

  @doc """
  Resolves a guest_token into its order's guest scope — mirrors
  `Public.OrderTrackerLive`'s own mount exactly (`Tenants.
  get_order_by_guest_token/1` is intentionally cross-tenant: a bare
  guest_token carries no org context up front).
  """
  def by_order_guest_token(guest_token) do
    case Tenants.get_order_by_guest_token(guest_token) do
      nil -> {:error, :not_found}
      resolved -> {:ok, guest_scope(resolved.venue.org, resolved.venue), resolved}
    end
  end

  defp guest_scope(org, venue) do
    Repo.put_org_id(venue.org_id)
    %Scope{org: org, venue: venue, role: :guest}
  end
end
