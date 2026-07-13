defmodule Tabletap.Payments.Workers.ChargeOrder do
  @moduledoc """
  Runs the actual `Payments.Provider.charge/2` call (build-plan.md
  Feature 09) — never inline in the calling LiveView process, since a
  WaafiPay push-PIN charge can block up to ~5 minutes waiting on the
  customer (research/somalia-payments-waafipay-zaad.md). The Oban job
  args carry `org_id` explicitly (set at enqueue time, when
  `Payments.charge_order/3` already has it) so this job never needs an
  unscoped read just to resolve its own tenant (library-docs.md "Oban
  jobs run without a request scope: they build their own scope from the
  args' org").
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 1

  import Ecto.Query

  alias Tabletap.Ordering.Order
  alias Tabletap.Payments
  alias Tabletap.Payments.Payment
  alias Tabletap.Repo
  alias Tabletap.Tenants.Venue

  # A single attempt, deliberately — retrying a `charge/2` call blind
  # would risk a second real PIN prompt for a payment that may have
  # already gone through; the reconciliation poller (not Oban retries)
  # is this feature's designed recovery path for an ambiguous outcome.
  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"payment_id" => payment_id, "org_id" => org_id, "wallet_msisdn" => wallet_msisdn}
      }) do
    Repo.put_org_id(org_id)

    payment = Repo.one(from(p in Payment, where: p.id == ^payment_id))

    case payment do
      # Already resolved by a beaten-us-to-it callback/poll — nothing to do.
      %Payment{status: status} when status != :pending ->
        :ok

      %Payment{} = payment ->
        order = Repo.one(from(o in Order, where: o.id == ^payment.order_id))
        venue = Repo.one(from(v in Venue, where: v.id == ^payment.venue_id))
        request = Payments.charge_request(payment, order, wallet_msisdn)
        result = Payments.provider().charge(Payments.credentials(venue), request)

        case Payments.resolve_charge_result(payment.id, result) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
          :ok -> :ok
        end
    end
  end
end
