defmodule Tabletap.Billing.Workers.CollectMonthlyInvoices do
  @moduledoc """
  Nightly subscription billing sweep (build-plan.md Feature 19) —
  cross-tenant, same loop shape as `Analytics.Workers.DailyRollup`:
  `Tenants.list_org_ids/0` + `Repo.put_org_id/1` per org, then one
  dispatch per org based on its current `subscription_status`.

  A `:trialing` org with no `billing_wallet_msisdn` on file converts
  straight to `:canceled` once its trial has ended
  (`Billing.expire_unpaid_trial/1` — design-qa.md Q29, no `past_due`
  grace for a trial that just ran out unattended). Every other org
  (`:trialing` with a wallet on file, `:active`, `:past_due`) goes
  through `Billing.collect_invoice/1`, which is itself a safe no-op
  (`{:error, :not_due}`) on any night that isn't its actual billing
  date — this worker doesn't duplicate that check, just dispatches.
  `:canceled` orgs are left alone; reactivation is the owner's own
  manual action on the billing screen, not something this sweep
  resurrects automatically.

  Runs at a fixed, off-peak UTC time (`config/config.exs`'s cron
  entry) rather than computing each venue's own business-day cutoff
  (design-qa.md Q40) — the same "good enough" simplification
  `Workers.DailyRollup`'s own cron comment already establishes for
  this codebase's two launch timezones: a UTC run well past midnight
  everywhere this app currently operates satisfies "never mid-dinner"
  without per-venue cutoff math for an org-wide (not venue-wide)
  status transition.
  """
  use Oban.Worker, queue: :webhooks, max_attempts: 1

  import Ecto.Query

  alias Tabletap.Billing
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Org

  @impl Oban.Worker
  def perform(_job) do
    Tenants.list_org_ids()
    |> Enum.each(fn org_id ->
      Repo.put_org_id(org_id)
      org_id |> load_org() |> handle_org()
    end)

    :ok
  end

  defp load_org(org_id) do
    Repo.one(from(o in Org, where: o.id == ^org_id), skip_org_id: true)
  end

  defp handle_org(%Org{subscription_status: :trialing, billing_wallet_msisdn: nil} = org) do
    if Billing.due?(org), do: Billing.expire_unpaid_trial(org)
  end

  defp handle_org(%Org{subscription_status: status} = org)
       when status in [:trialing, :active, :past_due] do
    Billing.collect_invoice(org)
  end

  defp handle_org(%Org{subscription_status: :canceled}), do: :ok
end
