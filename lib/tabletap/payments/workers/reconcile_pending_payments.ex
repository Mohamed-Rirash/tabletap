defmodule Tabletap.Payments.Workers.ReconcilePendingPayments do
  @moduledoc """
  Polls WaafiPay's transaction-inquiry API for every payment still
  `pending` (build-plan.md Feature 09) — the **guaranteed** confirmation
  path, since WaafiPay does not retry webhook deliveries
  (library-docs.md: "callbacks are an optimization, never the
  mechanism"). Runs every minute — the closest practical Oban Cron
  granularity to the docs' "~30s cadence" target, comfortably inside
  both the ~5-minute PIN-entry window and the 12-minute stock hold.

  Success and failure resolve through the exact same idempotent path as
  the charge worker and the webhook callback
  (`Payments.confirm_approved/2`/`confirm_failed/1`) — whichever path
  gets there first wins, this one safely no-ops on an already-resolved
  payment.

  Same cross-tenant pattern as `Ordering.Workers.SweepExpiredHolds`:
  loops `Tenants.list_org_ids/0` + `Repo.put_org_id/1` per org rather
  than reaching for `ObanRepo` (scoped to Oban's own bookkeeping only).
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 3

  import Ecto.Query

  alias Tabletap.Ordering.Order
  alias Tabletap.Payments
  alias Tabletap.Payments.Payment
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Venue

  @impl Oban.Worker
  def perform(_job) do
    total =
      Tenants.list_org_ids()
      |> Enum.reduce(0, fn org_id, acc ->
        Repo.put_org_id(org_id)
        acc + reconcile_org()
      end)

    :telemetry.execute([:tabletap, :payments, :reconciled], %{count: total}, %{})
    :ok
  end

  defp reconcile_org do
    from(p in Payment, where: p.status == :pending)
    |> Repo.all()
    |> Enum.count(&reconcile_payment/1)
  end

  defp reconcile_payment(payment) do
    order = Repo.one(from(o in Order, where: o.id == ^payment.order_id))
    venue = Repo.one(from(v in Venue, where: v.id == ^payment.venue_id))

    case Payments.provider().lookup(Payments.credentials(venue), order.id) do
      {:ok, %{state: :approved, provider_txn_id: txn_id}} ->
        match?({:ok, _}, Payments.confirm_approved(payment.id, txn_id, :poller))

      {:ok, %{state: :failed}} ->
        match?({:ok, _}, Payments.confirm_failed(payment.id, :poller))

      # Still waiting on the customer, or the lookup itself failed
      # (network blip) — leave it pending, try again next minute.
      _other ->
        false
    end
  end
end
