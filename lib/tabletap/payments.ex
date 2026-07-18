defmodule Tabletap.Payments do
  @moduledoc """
  Wallet payments (architecture.md "payments/"; build-plan.md Feature 09;
  supersedes the retired Stripe Connect design — design-qa.md Q57).

  Every function takes `%Scope{}` first, same as `Ordering`/`Catalog` —
  except the resolution path (`confirm_approved/2`, `confirm_failed/1`),
  which runs from Oban jobs or the pre-scope webhook controller and
  builds its own scope from the locked payment row's `org_id`/`venue_id`
  (library-docs.md "Oban jobs run without a request scope").

  **`confirm_approved/2` and `confirm_failed/1` are the single shared,
  idempotent resolution path** — the charge worker, the webhook job, and
  the reconciliation poller all funnel through them. Idempotency comes
  from locking the payment row and checking `status == :pending` inside
  one transaction; a payment already resolved is a no-op, never a
  double-charge or a double-release (code-standards.md "Confirmations
  reconcile, never trust").
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Order, OrderDiscount, OrderStateMachine}
  alias Tabletap.Payments.{Payment, PlatformFeeLedgerEntry, Refund, ZReport, ZReportCashCount}
  alias Tabletap.Payments.Workers.ChargeOrder
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Membership, Org, Venue}

  @doc "The configured Payments.Provider adapter — WaafiPay everywhere except test (config.exs/test.exs, mirrors Tabletap.Storage's adapter-swap pattern)."
  def provider, do: Application.fetch_env!(:tabletap, __MODULE__) |> Keyword.fetch!(:provider)

  ## Onboarding — credential verification (build-plan.md Feature 09)

  @doc """
  Pings WaafiPay with the venue's just-saved credentials and flips
  `charges_enabled` on any successful round-trip. A transaction-inquiry
  for a reference no order will ever use can't confirm the credentials
  are *correct* the way a real charge would (WaafiPay publishes no
  dedicated "verify merchant" endpoint) — this is a deliberately light
  reachability check, not a nominal charge-and-refund; flagged here
  rather than silently assumed.
  """
  def verify_credentials(%Scope{}, %Venue{} = venue) do
    case provider().lookup(credentials(venue), "verify-#{venue.id}") do
      {:ok, _result} -> Tenants.mark_charges_enabled(venue)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Extracts the `Payments.Provider` credentials shape from a loaded venue — the decrypted values are already on the struct (Cloak transparently decrypts on read)."
  def credentials(%Venue{} = venue) do
    %{
      merchant_uid: venue.waafipay_merchant_uid,
      api_user_id: venue.waafipay_api_user_id,
      api_key: venue.waafipay_api_key
    }
  end

  ## Checkout — kicking off a charge (build-plan.md Feature 09)

  @doc """
  Creates a `pending` payment row for `order` and enqueues the actual
  WaafiPay call on `Workers.ChargeOrder` — never inline, since the charge
  can block up to ~5 minutes waiting on the customer's PIN entry
  (research/somalia-payments-waafipay-zaad.md) and must never run in the
  calling LiveView process. Returns immediately with the `pending`
  payment; the tracker's existing "Confirming your payment…" state
  covers the wait.
  """
  def charge_order(%Scope{org: org, venue: venue}, %Order{} = order, wallet_msisdn) do
    cond do
      not venue.charges_enabled -> {:error, :charges_not_enabled}
      order.status != :pending_payment -> {:error, :not_pending_payment}
      true -> do_charge_order(org, venue, order, wallet_msisdn)
    end
  end

  defp do_charge_order(org, venue, order, wallet_msisdn) do
    attrs = %{
      org_id: org.id,
      venue_id: venue.id,
      order_id: order.id,
      provider: :waafipay,
      wallet_msisdn_masked: mask_msisdn(wallet_msisdn),
      amount: order.total,
      status: :pending
    }

    case %Payment{} |> Ecto.Changeset.change(attrs) |> Repo.insert() do
      {:ok, payment} ->
        %{payment_id: payment.id, org_id: org.id, wallet_msisdn: wallet_msisdn}
        |> ChargeOrder.new()
        |> Oban.insert()

        {:ok, payment}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp mask_msisdn(msisdn) do
    digits = String.replace(msisdn, ~r/\D/, "")
    length = String.length(digits)

    if length <= 7 do
      String.duplicate("*", length)
    else
      prefix = String.slice(digits, 0, 4)
      suffix = String.slice(digits, -3, 3)
      prefix <> String.duplicate("*", length - 7) <> suffix
    end
  end

  @doc "Builds the request the adapter's `charge/2` expects, from a loaded `payment` + its order."
  def charge_request(%Payment{} = payment, %Order{} = order, wallet_msisdn) do
    %{
      request_id: payment.id,
      reference_id: order.id,
      invoice_id: to_string(order.number),
      amount: order.total,
      wallet_msisdn: wallet_msisdn,
      description: "Order ##{order.number}"
    }
  end

  ## Resolution — the shared idempotent path (system-initiated: worker/webhook/poller)

  @definitive_failures [:timeout, :rejected, :insufficient_funds, :invalid_credentials]

  @doc """
  Dispatches a raw `Payments.Provider` result to the right resolution.
  Ambiguous failures (a dropped connection, an HTTP error) resolve to
  neither success nor failure — the payment stays `pending` and the
  reconciliation poller (`Workers.ReconcilePendingPayments`) is the
  guaranteed path from there (library-docs.md).
  """
  def resolve_charge_result(payment_id, {:ok, %{provider_txn_id: txn_id, state: :approved}}) do
    confirm_approved(payment_id, txn_id)
  end

  def resolve_charge_result(payment_id, {:error, reason}) when reason in @definitive_failures do
    confirm_failed(payment_id)
  end

  def resolve_charge_result(payment_id, {:error, {:provider, _code}}) do
    confirm_failed(payment_id)
  end

  def resolve_charge_result(_payment_id, {:error, _ambiguous}), do: :ok

  @doc """
  APPROVED confirmation — idempotent, callable from the charge worker,
  the webhook job, or the poller alike; whichever gets there first wins,
  the rest no-op. Converts the daily-limit hold (`pending_payment`) or,
  if the 12-min sweep already expired the order, re-reserves it first
  (Q21 late-success resurrection) before resurrecting to `placed`. If
  re-reservation fails (genuinely sold out in the interim), the customer
  *was* charged for food that can't be made — auto-refunds immediately
  rather than silently keeping their money (the iron rule, applied to
  the one path where charge-after-expiry is unavoidable).
  """
  def confirm_approved(payment_id, provider_txn_id) do
    with_locked_pending_payment(payment_id, fn payment, order, scope ->
      case order.status do
        :pending_payment -> place_and_settle(payment, order, scope, provider_txn_id)
        :expired -> resurrect_or_refund(payment, order, scope, provider_txn_id)
        _ -> {:ok, :already_resolved}
      end
    end)
  end

  defp place_and_settle(payment, order, scope, provider_txn_id) do
    with {:ok, order} <- OrderStateMachine.transition(scope, order, :placed),
         {:ok, payment} <- succeed_payment(payment, provider_txn_id),
         {:ok, _entry} <- accrue_platform_fee(scope, order) do
      {:ok, payment}
    end
  end

  defp resurrect_or_refund(payment, order, scope, provider_txn_id) do
    case Ordering.reserve_holds_for_order(order) do
      {:ok, :held} -> place_and_settle(payment, order, scope, provider_txn_id)
      {:error, :sold_out} -> auto_refund_unfulfillable(payment, scope, provider_txn_id)
    end
  end

  defp auto_refund_unfulfillable(payment, scope, provider_txn_id) do
    case provider().refund(credentials(scope.venue), provider_txn_id, payment.amount) do
      {:ok, %{provider_refund_id: provider_refund_id}} ->
        {:ok, payment} = succeed_then_refund_payment(payment, provider_txn_id)

        refund_attrs = %{
          org_id: payment.org_id,
          payment_id: payment.id,
          amount: payment.amount,
          reason: "Sold out before your payment could be confirmed (design-qa.md Q21)",
          provider_refund_id: provider_refund_id,
          status: :succeeded
        }

        case refund_attrs |> Refund.new_changeset() |> Repo.insert() do
          {:ok, _refund} ->
            :telemetry.execute([:tabletap, :payment, :late_success_refunded], %{}, %{
              payment_id: payment.id
            })

            {:ok, :refunded}

          {:error, changeset} ->
            {:error, changeset}
        end

      {:error, reason} ->
        :telemetry.execute([:tabletap, :payment, :late_success_refund_failed], %{}, %{
          payment_id: payment.id,
          reason: inspect(reason)
        })

        {:error, {:refund_failed, reason}}
    end
  end

  defp succeed_then_refund_payment(payment, provider_txn_id) do
    payment
    |> Ecto.Changeset.change(status: :refunded, provider_txn_id: provider_txn_id)
    |> Repo.update()
  end

  defp succeed_payment(payment, provider_txn_id) do
    payment
    |> Ecto.Changeset.change(status: :succeeded, provider_txn_id: provider_txn_id)
    |> Repo.update()
  end

  defp accrue_platform_fee(%Scope{org: org}, %Order{} = order) do
    %PlatformFeeLedgerEntry{}
    |> Ecto.Changeset.change(%{
      org_id: order.org_id,
      venue_id: order.venue_id,
      order_id: order.id,
      amount: Money.mult!(order.total, fee_rate(org)),
      accrued_at: DateTime.utc_now(:second)
    })
    |> Repo.insert()
  end

  # pricing.md — Essentials 2.5%, Growth 1.5%, Pro 1.0%; a trialing org
  # accrues at the Essentials rate (the trial waives the subscription
  # fee, never the per-order fee — pricing.md "Billing").
  defp fee_rate(%Org{subscription_status: :trialing}), do: Decimal.new("0.025")
  defp fee_rate(%Org{plan: :essentials}), do: Decimal.new("0.025")
  defp fee_rate(%Org{plan: :growth}), do: Decimal.new("0.015")
  defp fee_rate(%Org{plan: :pro}), do: Decimal.new("0.010")

  @doc """
  Definitive failure (a decline WaafiPay actually told us about, not a
  dropped connection) — releases the hold immediately rather than making
  the customer wait out the 12-minute sweep
  (research/somalia-payments-waafipay-zaad.md: "5306/5309/decline
  releases the hold immediately... keep the 12-min sweeper as backstop").
  """
  def confirm_failed(payment_id) do
    with_locked_pending_payment(payment_id, fn payment, order, scope ->
      {:ok, payment} = succeed_payment_as_failed(payment)
      cancel_if_still_pending(order, scope, payment)
    end)
  end

  defp succeed_payment_as_failed(payment) do
    payment |> Ecto.Changeset.change(status: :failed) |> Repo.update()
  end

  defp cancel_if_still_pending(%Order{status: :pending_payment} = order, scope, payment) do
    case OrderStateMachine.transition(scope, order, :cancelled) do
      {:ok, _order} -> {:ok, payment}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cancel_if_still_pending(_order, _scope, payment), do: {:ok, payment}

  # The shared lock-and-check-idempotency wrapper both confirm_* functions
  # use: loads the payment row for update inside one transaction and
  # no-ops (rather than re-running side effects) unless it's still
  # `pending` — the idempotency guarantee callbacks/pollers/workers all
  # depend on. `fun` must return `{:ok, _} | {:error, _}`; an `{:error,
  # _}` rolls the whole transaction back (Ecto only rolls back on an
  # explicit `Repo.rollback/1`, never on an ordinary returned value).
  defp with_locked_pending_payment(payment_id, fun) do
    Repo.transaction(fn ->
      query = from(p in Payment, where: p.id == ^payment_id, lock: "FOR UPDATE")

      case Repo.one(query, skip_org_id: true) do
        nil -> Repo.rollback(:not_found)
        %Payment{status: status} when status != :pending -> :already_resolved
        %Payment{} = payment -> resolve_locked_payment(payment, fun)
      end
    end)
    |> case do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_locked_payment(payment, fun) do
    Repo.put_org_id(payment.org_id)
    order = Repo.one(from(o in Order, where: o.id == ^payment.order_id))
    venue = Repo.one(from(v in Venue, where: v.id == ^payment.venue_id))
    org = Repo.one(from(o in Org, where: o.id == ^payment.org_id), skip_org_id: true)
    scope = %Scope{org: org, venue: venue, role: nil}

    case fun.(payment, order, scope) do
      {:ok, value} -> value
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  ## Refunds (build-plan.md Feature 09, design-qa.md Q4/Q22/Q23/Q35/Q37)

  @doc """
  Full or line-item-total partial refund, manager-initiated. Locks the
  payment row and validates `amount <= paid - already-refunded` inside
  one transaction (Q35's over-refund guard) — a violation is rejected,
  never clamped. `provider == :cash` records a cash refund (Q22) with no
  provider round-trip. Refund failures never fail silently (Q23) —
  always returned as `{:error, _}` for the caller to alert on loudly.
  """
  def refund(%Scope{} = scope, %Payment{} = payment, amount, reason, staff_user_id) do
    Repo.transaction(fn ->
      locked = Repo.one(from(p in Payment, where: p.id == ^payment.id, lock: "FOR UPDATE"))
      already_refunded = refunded_total(locked)

      cond do
        Money.compare!(Money.add!(already_refunded, amount), locked.amount) == :gt ->
          Repo.rollback(:over_refund)

        locked.provider == :cash ->
          insert_refund(locked, amount, reason, staff_user_id, nil, :succeeded)

        true ->
          provider_refund(scope, locked, amount, reason, staff_user_id)
      end
    end)
    |> case do
      # A provider failure still commits (never rolls back) the `failed`
      # refund row as an audit trail (Q23 "never fail silently") — the
      # transaction itself succeeded, so Repo.transaction wraps that
      # {:error, _} value as {:ok, {:error, _}}; unwrap it back to plain
      # {:error, _} for the caller.
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, %Refund{} = refund} -> {:ok, refund}
      {:error, reason} -> {:error, reason}
    end
  end

  defp refunded_total(%Payment{} = payment) do
    payment = Repo.preload(payment, :refunds, force: true)
    zero = Money.new!(payment.amount.currency, 0)

    payment.refunds
    |> Enum.filter(&(&1.status == :succeeded))
    |> Enum.reduce(zero, &Money.add!(&2, &1.amount))
  end

  defp insert_refund(payment, amount, reason, staff_user_id, provider_refund_id, status) do
    attrs = %{
      org_id: payment.org_id,
      payment_id: payment.id,
      staff_user_id: staff_user_id,
      amount: amount,
      reason: reason,
      provider_refund_id: provider_refund_id,
      status: status
    }

    case attrs |> Refund.new_changeset() |> Repo.insert() do
      {:ok, refund} -> refund
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp provider_refund(scope, payment, amount, reason, staff_user_id) do
    refund = insert_refund(payment, amount, reason, staff_user_id, nil, :pending)

    case provider().refund(credentials(scope.venue), payment.provider_txn_id, amount) do
      {:ok, %{provider_refund_id: provider_refund_id}} ->
        refund |> Refund.status_changeset(:succeeded, provider_refund_id) |> Repo.update!()

      {:error, reason} ->
        refund |> Refund.status_changeset(:failed) |> Repo.update!()

        :telemetry.execute([:tabletap, :payment, :refund_failed], %{}, %{
          payment_id: payment.id,
          reason: inspect(reason)
        })

        {:error, {:refund_failed, reason}}
    end
  end

  ## Cash & comp settlement (build-plan.md Feature 15; design-qa.md
  ## Q3/Q22/Q26/Q30). Neither path calls `accrue_platform_fee/2` — the
  ## per-order fee only rides wallet charges (design-qa.md Q24 "an
  ## acknowledged pricing decision, not an oversight"), and comp's total
  ## is zero regardless.

  @doc """
  The customer's own QR checkout choosing "Cash" (design-qa.md Q3,
  gated on `venue.pay_at_counter_enabled`) — parks a `pending` cash
  payment against the order; the order itself stays `pending_payment`
  under the same 12-minute hold TTL a wallet charge gets, until a
  cashier verifies it at the counter. No `cashier_membership_id` yet —
  nobody's handled the cash.
  """
  def record_cash_intent(%Scope{org: org, venue: venue}, %Order{status: :pending_payment} = order) do
    %{
      org_id: org.id,
      venue_id: venue.id,
      order_id: order.id,
      provider: :cash,
      amount: order.total,
      status: :pending
    }
    |> Payment.pos_changeset()
    |> Repo.insert()
  end

  @doc """
  The cashier's "Verify paid" action (Q3): takes the cash, marks the
  parked payment succeeded, fires the order. An `expired` order gets
  the **Revive** treatment first (Q26) — re-reserves the daily-limit
  holds the 12-minute sweep already released; `{:error, {:sold_out,
  item_name}}` (`item_name` may be `nil` — see
  `Ordering.first_sold_out_item_name/2`) if stock is genuinely gone in
  the interim, and nothing is mutated on that path.
  """
  def verify_cash_payment(
        %Scope{} = scope,
        %Order{status: :pending_payment} = order,
        %Membership{} = staff
      ) do
    settle_pending_cash(scope, order, staff)
  end

  def verify_cash_payment(
        %Scope{} = scope,
        %Order{status: :expired} = order,
        %Membership{} = staff
      ) do
    case Ordering.reserve_holds_for_order(order) do
      {:ok, :held} ->
        settle_pending_cash(scope, order, staff)

      {:error, :sold_out} ->
        {:error, {:sold_out, Ordering.first_sold_out_item_name(scope, order)}}
    end
  end

  defp settle_pending_cash(scope, order, staff) do
    case get_pending_cash_payment(order) do
      nil -> {:error, :no_pending_cash_payment}
      payment -> do_settle_cash(scope, order, payment, staff)
    end
  end

  defp get_pending_cash_payment(order) do
    Repo.one(
      from(p in Payment,
        where: p.order_id == ^order.id and p.provider == :cash and p.status == :pending
      )
    )
  end

  @doc """
  The POS's own "Cash" button (ui-rules.md "two big buttons — Cash...")
  — a cashier standing right there taking cash for a ticket they just
  rang up. Unlike `verify_cash_payment/3` there's no pre-existing parked
  payment to find; this creates one and settles it in the same breath.
  """
  def settle_cash_now(
        %Scope{org: org, venue: venue} = scope,
        %Order{status: :pending_payment} = order,
        %Membership{} = staff
      ) do
    attrs = %{
      org_id: org.id,
      venue_id: venue.id,
      order_id: order.id,
      provider: :cash,
      amount: order.total,
      status: :pending
    }

    case attrs |> Payment.pos_changeset() |> Repo.insert() do
      {:ok, payment} -> do_settle_cash(scope, order, payment, staff)
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp do_settle_cash(scope, order, payment, staff) do
    with {:ok, payment} <-
           payment
           |> Ecto.Changeset.change(status: :succeeded, cashier_membership_id: staff.id)
           |> Repo.update(),
         {:ok, _order} <- OrderStateMachine.transition(scope, order, :placed) do
      {:ok, payment}
    end
  end

  @doc """
  Zeroes `order` with a whole-order discount and settles it as
  `provider: :comp` in one atomic transaction (design-qa.md Q30) —
  manager/owner only (architecture.md "manager-permission-gated"; an
  ordinary partial discount, `Ordering.apply_discount/4`, needs no such
  gate). `{:error, :requires_manager}` for a cashier-only scope.
  """
  def charge_comp(
        %Scope{role: role} = scope,
        %Order{status: :pending_payment} = order,
        reason,
        %Membership{} = staff
      )
      when role in [:manager, :owner] do
    Ecto.Multi.new()
    |> Ecto.Multi.run(:discount, fn _repo, _changes ->
      Ordering.apply_discount(scope, order, %{amount: order.total, reason: reason}, staff)
    end)
    |> Ecto.Multi.run(:payment, fn _repo, %{discount: zeroed_order} ->
      %{
        org_id: order.org_id,
        venue_id: order.venue_id,
        order_id: order.id,
        cashier_membership_id: staff.id,
        provider: :comp,
        amount: zeroed_order.total,
        status: :succeeded
      }
      |> Payment.pos_changeset()
      |> Repo.insert()
    end)
    |> Ecto.Multi.run(:order, fn _repo, %{discount: zeroed_order} ->
      OrderStateMachine.transition(scope, zeroed_order, :placed)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{payment: payment}} -> {:ok, payment}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def charge_comp(%Scope{}, %Order{}, _reason, %Membership{}), do: {:error, :requires_manager}

  ## End-of-day close — the Z-report (build-plan.md Feature 15;
  ## design-qa.md's Gap Analysis "End-of-day close (Z-report)"). Money
  ## events (payments/refunds) are windowed by the business day's real
  ## cutoff-to-cutoff instants and count on the day they actually
  ## happened (Q37) — never on the underlying order's own business_date,
  ## which can differ for a late refund.

  defp business_date_bounds(venue, business_date) do
    {
      DateTime.new!(business_date, venue.business_day_cutoff, venue.timezone),
      DateTime.new!(Date.add(business_date, 1), venue.business_day_cutoff, venue.timezone)
    }
  end

  @doc """
  Everything a manager sees before closing a business day: order count,
  revenue/discount/refund totals, a per-payment-provider breakdown, and
  one expected-cash line per cashier who took cash that day — the
  human counts the real drawer against each of those before calling
  `close_z_report/3`. A pure read, safe to call repeatedly while
  deciding whether to close.
  """
  def z_report_preview(%Scope{venue: venue}, business_date) do
    zero = Money.new!(venue.currency, 0)
    succeeded_payments = succeeded_payments_for_day(venue, business_date)
    succeeded_refunds = succeeded_refunds_for_day(venue, business_date)

    by_provider =
      Enum.reduce(succeeded_payments, %{}, fn payment, acc ->
        Map.update(acc, payment.provider, payment.amount, &Money.add!(&1, payment.amount))
      end)

    refund_total =
      succeeded_refunds |> Enum.map(&elem(&1, 0).amount) |> Enum.reduce(zero, &Money.add!(&2, &1))

    gross_revenue = by_provider |> Map.values() |> Enum.reduce(zero, &Money.add!(&2, &1))

    %{
      business_date: business_date,
      order_count: order_count_for_day(venue, business_date),
      gross_revenue: gross_revenue,
      discount_total: discount_total_for_day(venue, business_date, zero),
      refund_total: refund_total,
      net_revenue: Money.sub!(gross_revenue, refund_total),
      by_provider: by_provider,
      cash_counts: expected_cash_by_cashier(succeeded_payments, succeeded_refunds, zero)
    }
  end

  defp order_count_for_day(venue, business_date) do
    Repo.aggregate(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.business_date == ^business_date and
            o.status not in [:pending_payment, :cancelled, :expired]
      ),
      :count
    )
  end

  defp succeeded_payments_for_day(venue, business_date) do
    {start_at, end_at} = business_date_bounds(venue, business_date)

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.status == :succeeded and p.inserted_at >= ^start_at and
            p.inserted_at < ^end_at
      )
    )
  end

  defp succeeded_refunds_for_day(venue, business_date) do
    {start_at, end_at} = business_date_bounds(venue, business_date)

    Repo.all(
      from(r in Refund,
        join: p in Payment,
        on: p.id == r.payment_id,
        where:
          p.venue_id == ^venue.id and r.status == :succeeded and r.inserted_at >= ^start_at and
            r.inserted_at < ^end_at,
        select: {r, p}
      )
    )
  end

  defp discount_total_for_day(venue, business_date, zero) do
    Repo.all(
      from(d in OrderDiscount,
        join: o in Order,
        on: o.id == d.order_id,
        where: o.venue_id == ^venue.id and o.business_date == ^business_date,
        select: d.amount
      )
    )
    |> Enum.reduce(zero, &Money.add!(&2, &1))
  end

  # Q22's per-cashier drawer number: cash taken, minus cash refunds netted
  # back against whichever cashier's payment they refund (the drawer that
  # gave the cash is the drawer it comes back out of), keyed by
  # `cashier_membership_id` — a `nil` key (shouldn't happen for a
  # succeeded cash payment, `do_settle_cash/4` always sets it) is dropped.
  defp expected_cash_by_cashier(payments, refunds, zero) do
    taken =
      payments
      |> Enum.filter(&(&1.provider == :cash))
      |> Enum.group_by(& &1.cashier_membership_id)
      |> Map.new(fn {id, ps} -> {id, Enum.reduce(ps, zero, &Money.add!(&2, &1.amount))} end)

    given_back =
      refunds
      |> Enum.filter(fn {_refund, payment} -> payment.provider == :cash end)
      |> Enum.group_by(fn {_refund, payment} -> payment.cashier_membership_id end)
      |> Map.new(fn {id, rs} ->
        {id, rs |> Enum.map(&elem(&1, 0).amount) |> Enum.reduce(zero, &Money.add!(&2, &1))}
      end)

    taken
    |> Map.keys()
    |> Enum.reject(&is_nil/1)
    |> Map.new(fn id ->
      expected = Money.sub!(Map.get(taken, id, zero), Map.get(given_back, id, zero))
      {id, expected}
    end)
  end

  @doc """
  Closes the business day — `{:error, changeset}` with a `:venue_id`
  "has already been taken" error (Ecto attaches a composite
  `unique_constraint/3` error to the first listed field) on a second
  attempt
  (`unique_index(:z_reports, [:venue_id, :business_date])`).
  Persists `z_report_preview/2`'s numbers as a point-in-time snapshot
  (Q38 "the original close stays visible as closed") plus one
  `ZReportCashCount` row per `{membership_id, counted_cash}` the caller
  supplies (the human-entered drawer count) — variance is derived and
  stored, never recomputed later.
  """
  def close_z_report(
        %Scope{org: org, venue: venue, membership: membership},
        business_date,
        counted_by_membership
      ) do
    preview = z_report_preview(%Scope{org: org, venue: venue}, business_date)

    changeset =
      %ZReport{}
      |> Ecto.Changeset.change(%{
        org_id: org.id,
        venue_id: venue.id,
        business_date: business_date,
        closed_by_membership_id: membership.id,
        closed_at: DateTime.utc_now(:second),
        totals: preview_totals_for_storage(preview)
      })
      |> Ecto.Changeset.unique_constraint([:venue_id, :business_date],
        name: :z_reports_venue_id_business_date_index
      )

    Ecto.Multi.new()
    |> Ecto.Multi.insert(:z_report, changeset)
    |> Ecto.Multi.run(:cash_counts, fn _repo, %{z_report: z_report} ->
      insert_cash_counts(z_report, org.id, preview.cash_counts, counted_by_membership)
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{z_report: z_report}} -> {:ok, Repo.preload(z_report, :cash_counts)}
      {:error, :z_report, changeset, _changes} -> {:error, changeset}
    end
  end

  # Raw decimal + currency, never `Money.to_string!/2` — that needs a
  # locale and this is storage, not display (the "so" locale has no CLDR
  # data and would raise; a known gap flagged in progress-tracker.md).
  defp money_for_storage(%Money{} = money) do
    %{
      "amount" => money |> Money.to_decimal() |> Decimal.to_string(),
      "currency" => to_string(money.currency)
    }
  end

  defp preview_totals_for_storage(preview) do
    %{
      "order_count" => preview.order_count,
      "gross_revenue" => money_for_storage(preview.gross_revenue),
      "discount_total" => money_for_storage(preview.discount_total),
      "refund_total" => money_for_storage(preview.refund_total),
      "net_revenue" => money_for_storage(preview.net_revenue),
      "by_provider" =>
        Map.new(preview.by_provider, fn {provider, amount} ->
          {to_string(provider), money_for_storage(amount)}
        end)
    }
  end

  defp insert_cash_counts(z_report, org_id, expected_by_cashier, counted_by_membership) do
    results =
      Enum.map(counted_by_membership, fn {membership_id, counted_cash} ->
        expected =
          Map.get(expected_by_cashier, membership_id, Money.new!(counted_cash.currency, 0))

        %ZReportCashCount{}
        |> Ecto.Changeset.change(%{
          org_id: org_id,
          z_report_id: z_report.id,
          membership_id: membership_id,
          expected_cash: expected,
          counted_cash: counted_cash,
          variance: Money.sub!(counted_cash, expected)
        })
        |> Repo.insert()
      end)

    if Enum.all?(results, &match?({:ok, _}, &1)) do
      {:ok, Enum.map(results, fn {:ok, row} -> row end)}
    else
      {:error, :cash_count_failed}
    end
  end

  @doc "A previously-closed business day's report, cash counts preloaded — `nil` if that day was never closed."
  def get_z_report(%Scope{venue: venue}, business_date) do
    Repo.one(
      from(z in ZReport,
        where: z.venue_id == ^venue.id and z.business_date == ^business_date,
        preload: :cash_counts
      )
    )
  end

  @doc """
  A cashier's own running total for `business_date` (default today) —
  build-plan.md's "shift summary" bullet: transactions taken + cash
  total, reachable from the POS in two taps. Live-computed (never
  waits for the day's Z-report to close).
  """
  def cashier_summary(
        %Scope{venue: venue} = scope,
        %Membership{} = membership,
        business_date \\ nil
      ) do
    business_date = business_date || Tenants.business_date(venue)
    {start_at, end_at} = business_date_bounds(venue, business_date)
    preview = z_report_preview(scope, business_date)

    cash_taken = Map.get(preview.cash_counts, membership.id, Money.new!(venue.currency, 0))

    transactions =
      Repo.all(
        from(p in Payment,
          where:
            p.venue_id == ^venue.id and p.cashier_membership_id == ^membership.id and
              p.status == :succeeded and p.inserted_at >= ^start_at and p.inserted_at < ^end_at,
          order_by: [desc: p.inserted_at],
          preload: :order
        )
      )

    %{
      business_date: business_date,
      transaction_count: length(transactions),
      cash_taken: cash_taken,
      transactions: transactions
    }
  end

  ## Reads

  def get_payment(%Scope{venue: venue}, id) do
    Repo.one(
      from(p in Payment, where: p.id == ^id and p.venue_id == ^venue.id, preload: :refunds)
    )
  end

  @doc """
  The most recent payment attempt for an order, or `nil` — the tracker
  uses this to tell a plain `expired` (never charged) apart from the
  Q21 late-success case (charged, then auto-refunded because the order
  expired and the last portion sold out before the charge confirmed).
  """
  def get_latest_payment_for_order(%Scope{venue: venue}, order_id) do
    Repo.one(
      from(p in Payment,
        where: p.order_id == ^order_id and p.venue_id == ^venue.id,
        order_by: [desc: p.inserted_at],
        limit: 1
      )
    )
  end
end
