defmodule Tabletap.Offboarding do
  @moduledoc """
  Tenant offboarding — the hard-delete side of build-plan.md Feature
  19 / design-qa.md Q15/Q31/Q54. Cross-tenant by design (`skip_org_id:
  true` throughout — "platform-admin code" on code-standards.md's
  allow-list, same as `Tabletap.Admin`).

  **Two-stage, but not by surgically deleting two dozen child tables
  while trying to keep an org half-alive for 90 more days.** Instead:
  at the 90-day mark, everything worth keeping (Q31's customer order
  history, Q54's payment/dispute-evidence subset) is copied out into
  its own flat, denormalized table with no FK back to the org — then
  the **entire org is hard-deleted in one step**, letting the existing
  `on_delete: :delete_all` cascade (already correct for every other
  table in the schema) do the actual cleanup instead of hand-enumerating
  it. The copied-out `payment_dispute_records` rows carry their own
  `retain_until` (90 more days out, i.e. 180 total from the original
  offboarding request) and get purged by `purge_expired_dispute_records/0`
  on the same nightly sweep.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Offboarding.{PaymentDisputeRecord, PlatformOrderArchive}
  alias Tabletap.Ordering.Order
  alias Tabletap.Payments.Payment
  alias Tabletap.Repo
  alias Tabletap.Tenants.{Org, Venue}

  @doc """
  Archives account-holding customers' order history (Q31) and every
  succeeded payment's dispute-evidence snapshot (Q54), then
  hard-deletes the org. Called once, at the org's 90-day offboarding
  mark, by `Workers.PurgeOffboardedTenants`.
  """
  def archive_and_hard_delete(%Org{} = org) do
    Repo.transaction(fn ->
      archive_customer_orders(org)
      snapshot_payments_for_dispute_window(org)
      Repo.delete!(org)
    end)
  end

  defp archive_customer_orders(org) do
    venue_names =
      Repo.all(from(v in Venue, where: v.org_id == ^org.id, select: {v.id, v.name}),
        skip_org_id: true
      )
      |> Map.new()

    Repo.all(
      from(o in Order,
        where: o.org_id == ^org.id and not is_nil(o.customer_user_id),
        preload: [:items]
      ),
      skip_org_id: true
    )
    |> Enum.each(fn order ->
      %PlatformOrderArchive{}
      |> Ecto.Changeset.change(%{
        customer_user_id: order.customer_user_id,
        venue_name_snapshot: Map.get(venue_names, order.venue_id, "(closed venue)"),
        order_date: order.business_date,
        items: %{
          "items" => Enum.map(order.items, &%{"name" => &1.name_snapshot, "qty" => &1.qty})
        },
        total: order.total
      })
      |> Repo.insert!()
    end)
  end

  defp snapshot_payments_for_dispute_window(org) do
    retain_until = DateTime.add(DateTime.utc_now(:second), 90, :day)

    Repo.all(
      from(p in Payment,
        where: p.org_id == ^org.id and p.status == :succeeded,
        preload: [:order]
      ),
      skip_org_id: true
    )
    |> Enum.each(fn payment ->
      %PaymentDisputeRecord{}
      |> Ecto.Changeset.change(%{
        org_name_snapshot: org.name,
        order_number: payment.order.number,
        order_placed_at: payment.order.placed_at,
        served_at: payment.order.served_at,
        provider: to_string(payment.provider),
        provider_txn_id: payment.provider_txn_id,
        amount: payment.amount,
        retain_until: retain_until
      })
      |> Repo.insert!()
    end)
  end

  @doc "180 days post-offboarding (90 days after the snapshot above was written): purges the dispute-evidence subset itself — the last trace of an offboarded org."
  def purge_expired_dispute_records do
    now = DateTime.utc_now(:second)

    Repo.delete_all(from(r in PaymentDisputeRecord, where: r.retain_until <= ^now),
      skip_org_id: true
    )
  end
end
