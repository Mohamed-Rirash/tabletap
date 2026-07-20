defmodule Tabletap.Billing do
  @moduledoc """
  Subscription billing without Stripe (build-plan.md Feature 19;
  design-qa.md Q59) — a monthly, itemized, org-wide invoice (plan price
  + every unsettled `platform_fee_ledger` row) collected via a single
  PIN-approved push-prompt charge from the **platform's own** WaafiPay
  merchant account (`config/runtime.exs`'s `platform_*` credentials,
  separate from any venue's own) against the org's own
  `billing_wallet_msisdn`. No recurring-mandate API exists on these
  rails, so every cycle is a fresh prompt — there is no "subscribe
  once" mechanism to build.

  **Billing period**: a fixed 30-day cycle billed in advance, starting
  the day the trial ends (then every 30 days after), not a calendar
  month — this codebase has no month-arithmetic helper and a 30-day
  cycle is exactly as defensible as "the 1st of each month" for
  pricing.md's own "monthly, itemized" ask, without needing one.

  **Multi-currency orgs (Pro tier can run venues in different
  currencies, design-qa.md Q53)**: only fee-ledger rows in the plan's
  own billing currency (USD — `Plans.monthly_price/2`'s only currency
  today) are folded into the charge and settled by it. A Jigjiga/ETB
  venue's accrued fees stay unsettled until Jigjiga billing itself is
  built (pricing.md: "Jigjiga pricing deliberately not set" — that
  phase isn't live yet, so this is a documented non-issue today, not a
  silent bug).

  **Subscription state machine** (`Org.subscription_status`): a
  successful collection sets `:active`. A failed one sets `:past_due`
  on the first miss — architecture.md's own rule is explicit that
  ordering *keeps working* during `past_due` grace — and `:canceled`
  on a **second consecutive** miss (no explicit grace-day count exists
  anywhere in design-qa.md/pricing.md; two strikes is this feature's
  own reasoned interpretation of "past_due grace," flagged here rather
  than picked silently). A trialing org whose trial has ended converts
  straight to `:canceled` if it never set a `billing_wallet_msisdn`
  (design-qa.md Q29: expiry without payment is "the billing wall,
  QR ordering shows temporarily unavailable — same as canceled") —
  there's no failed *attempt* to grade as `past_due` when no wallet was
  ever on file to attempt against.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Billing.Invoice
  alias Tabletap.Payments
  alias Tabletap.Payments.PlatformFeeLedgerEntry
  alias Tabletap.Plans
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Org

  @period_days 30

  @doc """
  The `{period_start, period_end}` this org's next invoice covers —
  billed **in advance**, same shape a typical SaaS cycle uses: the
  first period starts the day the trial ends (that's the moment the
  free ride stops), every following period starts the day after the
  previous one's own start (not its end — a period is always billed
  at its start, so "next period" always begins exactly `@period_days`
  after the last one began).
  """
  def next_period(%Org{} = org) do
    start =
      case last_invoice(org) do
        nil -> DateTime.to_date(org.trial_ends_at)
        %Invoice{period_start: period_start} -> Date.add(period_start, @period_days)
      end

    {start, Date.add(start, @period_days - 1)}
  end

  @doc "Whether `org`'s next billing period has started as of `today` — the collection worker's own due-check. Doubles as \"has this org's trial ended\" for an org that's never been billed, since the first period always starts at `trial_ends_at`."
  def due?(%Org{} = org, %Date{} = today \\ Date.utc_today()) do
    {period_start, _period_end} = next_period(org)
    Date.compare(period_start, today) != :gt
  end

  defp last_invoice(%Org{id: org_id}) do
    Repo.one(
      from(i in Invoice,
        where: i.org_id == ^org_id,
        order_by: [desc: i.period_end],
        limit: 1
      )
    )
  end

  @doc """
  Attempts to collect one org's next invoice, if it's due. Inserts a
  `pending` `Invoice` row first (the idempotency guard — the unique
  `(org_id, period_start)` index blocks a second attempt for the same
  period outright, same shape `Payments.charge_order/3` uses for a
  venue's own charges), then a single WaafiPay push-prompt against the
  platform's own credentials. `{:error, :not_due}`/`{:error,
  :no_wallet_on_file}` are expected, routine outcomes for the nightly
  worker's sweep — most orgs on most nights aren't due yet.
  """
  def collect_invoice(%Org{billing_wallet_msisdn: nil}), do: {:error, :no_wallet_on_file}

  def collect_invoice(%Org{} = org) do
    if due?(org) do
      {period_start, period_end} = next_period(org)
      do_collect(org, period_start, period_end)
    else
      {:error, :not_due}
    end
  end

  defp do_collect(org, period_start, period_end) do
    scope = %Scope{org: org}
    plan_amount = Plans.monthly_price(org.plan, billable_venue_count(scope))

    attrs = %{
      org_id: org.id,
      plan: org.plan,
      plan_amount: plan_amount,
      period_start: period_start,
      period_end: period_end
    }

    case %Invoice{} |> Invoice.changeset(attrs) |> Repo.insert() do
      {:ok, invoice} -> attempt_charge(scope, org, invoice)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp billable_venue_count(scope), do: scope |> Tenants.list_venues() |> length()

  defp attempt_charge(scope, org, invoice) do
    invoice = invoice |> Invoice.attempted_changeset() |> Repo.update!()
    fee_amount = matching_currency_fees(scope, invoice.plan_amount.currency)
    charge_amount = Money.add!(invoice.plan_amount, fee_amount)

    request = %{
      request_id: invoice.id,
      reference_id: invoice.id,
      invoice_id: to_string(invoice.id),
      amount: charge_amount,
      wallet_msisdn: org.billing_wallet_msisdn,
      description:
        "TableTap subscription — #{Date.to_string(invoice.period_start)} to #{Date.to_string(invoice.period_end)}"
    }

    Payments.provider().charge(Payments.platform_credentials(), request)
    |> resolve_charge(scope, org, invoice)
  end

  defp matching_currency_fees(scope, currency) do
    scope
    |> Payments.unsettled_platform_fees_by_currency()
    |> Enum.find(&(&1.currency == currency))
    |> case do
      nil -> Money.new!(currency, 0)
      row -> row.amount
    end
  end

  defp resolve_charge({:ok, %{provider_txn_id: txn_id, state: :approved}}, scope, org, invoice) do
    {:ok, invoice} = invoice |> Invoice.succeed_changeset(txn_id) |> Repo.update()
    settle_ledger_rows(scope, invoice)
    {:ok, org} = org |> Ecto.Changeset.change(subscription_status: :active) |> Repo.update()
    {:ok, %{invoice: invoice, org: org}}
  end

  defp resolve_charge({:error, reason}, _scope, org, invoice) do
    {:ok, invoice} = invoice |> Invoice.fail_changeset(reason) |> Repo.update()

    {:ok, org} =
      org
      |> Ecto.Changeset.change(subscription_status: next_status_on_failure(org))
      |> Repo.update()

    {:error, %{invoice: invoice, org: org, reason: reason}}
  end

  defp next_status_on_failure(%Org{subscription_status: :past_due}), do: :canceled
  defp next_status_on_failure(%Org{}), do: :past_due

  defp settle_ledger_rows(scope, invoice) do
    currency = invoice.plan_amount.currency
    now = DateTime.utc_now(:second)

    ids =
      from(e in PlatformFeeLedgerEntry, where: e.org_id == ^scope.org.id and is_nil(e.settled_at))
      |> Repo.all()
      |> Enum.filter(&(&1.amount.currency == currency))
      |> Enum.map(& &1.id)

    Repo.update_all(from(e in PlatformFeeLedgerEntry, where: e.id in ^ids),
      set: [settled_at: now, invoice_id: invoice.id]
    )
  end

  @doc """
  Trial expiry with no payment method ever set — converts straight to
  `:canceled`, no `past_due` grace (design-qa.md Q29: there was no
  billing *attempt* to fail, just a trial that ran out unattended).
  Called by `Workers.CollectMonthlyInvoices` for a trialing org whose
  `trial_ends_at` has passed and has no `billing_wallet_msisdn` on
  file; a trialing org that *does* have one goes through
  `collect_invoice/1` instead (its first real invoice).
  """
  def expire_unpaid_trial(%Org{} = org) do
    org |> Ecto.Changeset.change(subscription_status: :canceled) |> Repo.update()
  end
end
