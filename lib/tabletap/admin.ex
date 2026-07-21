defmodule Tabletap.Admin do
  @moduledoc """
  Platform-admin reads (build-plan.md Feature 19; role-features.md
  "Platform Admin (us) — Admin panel: all orgs/venues, subscription
  states, order volumes"). Every function here is cross-tenant by
  design — `skip_org_id: true` throughout, one of the few places
  code-standards.md's "Tenancy Rules" allows it (`Accounts`, `Tenants`,
  and platform-admin code). Nothing here writes: this context backs a
  strictly **read-only** admin panel — build-plan.md's own
  "impersonation guard (read-only)" means an admin can look at a
  tenant's data through these functions, never act as that tenant.
  There is no session-swap/sudo mechanism anywhere in this module.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Billing.Invoice
  alias Tabletap.Ordering.Order
  alias Tabletap.Payments.Payment
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  @doc "Every org, newest first, each with its active venue count and lifetime order count — the admin tenants list."
  def list_tenants do
    Repo.all(
      from(o in Org, where: o.synthetic == false, order_by: [desc: o.inserted_at]),
      skip_org_id: true
    )
    |> Enum.map(&tenant_summary/1)
  end

  defp tenant_summary(%Org{} = org) do
    %{
      org: org,
      venue_count: count(from(v in Venue, where: v.org_id == ^org.id and is_nil(v.archived_at))),
      order_count: count(from(o in Order, where: o.org_id == ^org.id))
    }
  end

  defp count(query), do: Repo.aggregate(query, :count, skip_org_id: true)

  @doc "One org for the admin detail view, or nil."
  def get_tenant(org_id), do: Repo.get(Org, org_id, skip_org_id: true)

  @doc "Every active venue for a tenant — the detail view's per-venue breakdown."
  def list_venues(%Org{} = org) do
    Repo.all(from(v in Venue, where: v.org_id == ^org.id and is_nil(v.archived_at)),
      skip_org_id: true
    )
  end

  @doc """
  Cash share per venue (design-qa.md Q24) — "the platform earns zero
  per-order fee on cash orders... platform admin metrics track cash
  share per venue so systematic steering is at least visible." One row
  per active venue: succeeded cash payments vs every succeeded payment.
  """
  def cash_share_by_venue(%Org{} = org) do
    org
    |> list_venues()
    |> Enum.map(fn venue ->
      counts =
        Repo.all(
          from(p in Payment,
            where: p.venue_id == ^venue.id and p.status == :succeeded,
            group_by: p.provider,
            select: {p.provider, count(p.id)}
          ),
          skip_org_id: true
        )
        |> Map.new()

      cash_count = Map.get(counts, :cash, 0)
      total_count = counts |> Map.values() |> Enum.sum()

      %{
        venue: venue,
        cash_count: cash_count,
        total_count: total_count,
        cash_share_pct: cash_share_pct(cash_count, total_count)
      }
    end)
  end

  defp cash_share_pct(_cash_count, 0), do: nil

  defp cash_share_pct(cash_count, total_count) do
    Decimal.new(cash_count) |> Decimal.mult(100) |> Decimal.div(Decimal.new(total_count))
  end

  @doc "A tenant's billing history, newest period first — the detail view's subscription-state timeline."
  def list_invoices(%Org{} = org) do
    Repo.all(from(i in Invoice, where: i.org_id == ^org.id, order_by: [desc: i.period_start]),
      skip_org_id: true
    )
  end
end
