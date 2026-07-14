defmodule Tabletap.Ordering.Workers.SweepPickupNoShows do
  @moduledoc """
  Flags `ready` pickup-mode orders that have sat uncollected past the
  venue's `pickup_timeout_minutes` (build-plan.md Feature 11, design-qa.md
  Q32) — `:not_picked_up`, landing in the manager's work queue
  (`Ordering.list_flagged_orders/1`) to resolve from there.

  Cross-tenant, same shape as `SweepAbandonedCarts`: loops
  `Tenants.list_org_ids/0`, `Repo.put_org_id/1` per org, then a normal
  tenant-scoped read. Flagging itself goes through
  `Ordering.mark_not_picked_up/2` per order (not a bulk `update_all`) —
  it's the same broadcast-per-order discipline `mark_unserveable/2`
  already uses, so the manager's live board updates instantly rather
  than only on next mount.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Order
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Org, Venue}

  @impl Oban.Worker
  def perform(_job) do
    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + sweep_org(org_id)
      end)

    :telemetry.execute([:tabletap, :ordering, :pickup_no_shows_flagged], %{count: total}, %{})
    :ok
  end

  defp sweep_org(org_id) do
    now = DateTime.utc_now(:second)

    candidates =
      Repo.all(
        from(o in Order,
          join: v in Venue,
          on: v.id == o.venue_id,
          where:
            v.fulfillment_mode == :pickup and o.status == :ready and is_nil(o.flag) and
              datetime_add(o.ready_at, v.pickup_timeout_minutes, "minute") < ^now,
          select: {o, v}
        )
      )

    if candidates != [] do
      org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)

      Enum.each(candidates, fn {order, venue} ->
        Ordering.mark_not_picked_up(%Scope{org: org, venue: venue}, order)
      end)
    end

    length(candidates)
  end
end
