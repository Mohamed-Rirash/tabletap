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
  alias Tabletap.Ordering.{Order, OrderStateMachine}
  alias Tabletap.Payments.{Payment, PlatformFeeLedgerEntry, Refund}
  alias Tabletap.Payments.Workers.ChargeOrder
  alias Tabletap.Repo
  alias Tabletap.Tenants
  alias Tabletap.Tenants.{Org, Venue}

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
