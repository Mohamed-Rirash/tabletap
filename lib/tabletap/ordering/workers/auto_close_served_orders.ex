defmodule Tabletap.Ordering.Workers.AutoCloseServedOrders do
  @moduledoc """
  `served -> closed` after the 24h rating window (build-plan.md Feature
  11) — cross-tenant, the same `Tenants.list_org_ids/0` loop
  `SweepAbandonedCarts`/`SweepPickupNoShows` use. Status changes still
  only ever go through `OrderStateMachine.transition/3`
  (code-standards.md "Status changes only via ...") — never a bulk
  `update_all` on `status`, unlike a plain flag/timestamp sweep.
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering.{Order, OrderStateMachine}
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Org, Venue}

  @rating_window_seconds 60 * 60 * 24

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@rating_window_seconds, :second)

    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + close_org(org_id, cutoff)
      end)

    :telemetry.execute([:tabletap, :ordering, :orders_auto_closed], %{count: total}, %{})
    :ok
  end

  defp close_org(org_id, cutoff) do
    orders = Repo.all(from(o in Order, where: o.status == :served and o.served_at < ^cutoff))

    if orders != [] do
      org = Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)

      Enum.each(orders, fn order ->
        venue = Repo.one(from(v in Venue, where: v.id == ^order.venue_id))
        {:ok, _} = OrderStateMachine.transition(%Scope{org: org, venue: venue}, order, :closed)
      end)
    end

    length(orders)
  end
end
