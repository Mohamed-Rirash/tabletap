defmodule Tabletap.Ordering.Workers.SweepExpiredHolds do
  @moduledoc """
  Expires `pending_payment` orders whose 12-minute hold has run out
  (design-qa.md Q1: "Holds expire after 12 minutes ... abandonment
  never strands stock"). Runs every 2 minutes — frequent enough that the
  worst-case time a customer sees a falsely "sold out" item (because
  someone abandoned checkout) stays close to the nominal 12 minutes,
  never hours.

  Goes through `OrderStateMachine.transition/3`, not a raw
  `Repo.update_all` on `status` (code-standards.md "Status changes only
  via `Ordering.OrderStateMachine.transition/3`") — expiring an order
  also has to release its `daily_item_limits.reserved_qty` hold, which
  is the state machine's job, not this worker's.

  Same cross-tenant pattern as `Ordering.Workers.SweepAbandonedCarts`:
  loops `Tenants.list_org_ids/0` + `Repo.put_org_id/1` per org rather
  than reaching for `ObanRepo` (scoped to Oban's own bookkeeping only —
  see that worker's moduledoc for the full reasoning).
  """
  use Oban.Worker, queue: :default, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering.{Order, OrderStateMachine}
  alias Tabletap.{Repo, Tenants}

  @hold_ttl_seconds 60 * 12

  @impl Oban.Worker
  def perform(_job) do
    cutoff = DateTime.add(DateTime.utc_now(), -@hold_ttl_seconds, :second)

    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + expire_stale_holds(cutoff)
      end)

    :telemetry.execute([:tabletap, :ordering, :holds_expired], %{count: total}, %{})

    :ok
  end

  defp expire_stale_holds(cutoff) do
    stale =
      Repo.all(from(o in Order, where: o.status == :pending_payment and o.inserted_at < ^cutoff))

    # No human actor — scope.role stays nil, which OrderStateMachine's
    # telemetry reports honestly as a system-initiated transition.
    scope = %Scope{}

    Enum.count(stale, fn order ->
      match?({:ok, _}, OrderStateMachine.transition(scope, order, :expired))
    end)
  end
end
