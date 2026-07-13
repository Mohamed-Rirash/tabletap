defmodule Tabletap.PaymentsTest do
  @moduledoc """
  `Tabletap.Payments` — charge kickoff, the shared idempotent resolution
  path (`confirm_approved/2`/`confirm_failed/1`), the Q21 late-success
  resurrection, and refunds. Provider calls are mocked via
  `Tabletap.Payments.ProviderMock` (Mox) — no test hits a real provider
  API (code-standards.md).
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Ecto.Query
  import Mox
  import Tabletap.TenantsFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Payments
  alias Tabletap.Payments.{Payment, PlatformFeeLedgerEntry, ProviderMock, Refund}
  alias Tabletap.Payments.Workers.ChargeOrder
  alias Tabletap.Repo

  setup :verify_on_exit!

  setup do
    %{org: org, venue: venue} = org_fixture()
    venue = charges_enabled_venue_fixture(venue)
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{scope: scope, org: org, venue: venue, item: item}
  end

  defp pending_order(scope, item, qty \\ 1) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  describe "charge_order/3" do
    test "creates a pending payment and enqueues ChargeOrder", %{scope: scope, item: item} do
      order = pending_order(scope, item)

      assert {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      assert payment.status == :pending
      assert payment.provider == :waafipay
      assert payment.wallet_msisdn_masked =~ "*"
      refute payment.wallet_msisdn_masked == "252611111111"

      assert_enqueued(worker: ChargeOrder, args: %{"payment_id" => payment.id})
    end

    test "rejects when the venue isn't payment-ready", %{scope: scope, item: item, venue: venue} do
      {:ok, venue} = venue |> Ecto.Changeset.change(charges_enabled: false) |> Repo.update()
      scope = %{scope | venue: venue}
      order = pending_order(scope, item)

      assert {:error, :charges_not_enabled} = Payments.charge_order(scope, order, "252611111111")
    end

    test "rejects an order that isn't pending_payment", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :cancelled)

      assert {:error, :not_pending_payment} = Payments.charge_order(scope, order, "252611111111")
    end
  end

  describe "confirm_approved/2 — happy path" do
    test "converts the hold and places the order", %{scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 5)
      order = pending_order(scope, item, 2)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, updated} = Payments.confirm_approved(payment.id, "waafi-txn-1")
      assert updated.status == :succeeded
      assert updated.provider_txn_id == "waafi-txn-1"

      order = Ordering.get_order(scope, order.id)
      assert order.status == :placed

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 0
      assert limit.sold_qty == 2
    end

    test "accrues the platform fee at the org's rate (trialing = Essentials rate)", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item, 1)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, _} = Payments.confirm_approved(payment.id, "waafi-txn-2")

      entry = Repo.one(from(e in PlatformFeeLedgerEntry, where: e.order_id == ^order.id))
      expected = Money.mult!(order.total, Decimal.new("0.025"))

      assert Money.equal?(entry.amount, expected)
      assert entry.accrued_at
    end

    test "idempotent — a second confirm_approved call is a safe no-op, not a crash", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, %Payment{}} = Payments.confirm_approved(payment.id, "txn-a")
      assert {:ok, :already_resolved} = Payments.confirm_approved(payment.id, "txn-a")

      order = Ordering.get_order(scope, order.id)
      assert order.status == :placed
    end
  end

  describe "confirm_approved/2 — Q21 late-success resurrection" do
    test "re-reserves stock and resurrects to placed when there's still room", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 5)
      order = pending_order(scope, item, 2)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, expired} = OrderStateMachine.transition(scope, order, :expired)
      assert expired.status == :expired

      assert {:ok, _} = Payments.confirm_approved(payment.id, "late-txn")

      order = Ordering.get_order(scope, order.id)
      assert order.status == :placed

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.sold_qty == 2
      assert limit.reserved_qty == 0
    end

    test "auto-refunds when the item sold out before the late confirmation arrived", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 2)
      order = pending_order(scope, item, 2)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, _} = OrderStateMachine.transition(scope, order, :expired)

      # A different guest takes the last portion in the interim.
      _other_order = pending_order(scope, item, 2)

      expect(ProviderMock, :refund, fn _creds, "late-txn-2", _amount ->
        {:ok, %{provider_refund_id: "refund-1"}}
      end)

      assert {:ok, :refunded} = Payments.confirm_approved(payment.id, "late-txn-2")

      payment = Repo.get(Payment, payment.id)
      assert payment.status == :refunded
      assert payment.provider_txn_id == "late-txn-2"

      order = Ordering.get_order(scope, order.id)
      assert order.status == :expired

      refund = Repo.get_by(Refund, payment_id: payment.id)
      assert refund.status == :succeeded
      assert refund.provider_refund_id == "refund-1"
    end

    test "a failed auto-refund is reported, never silent", %{scope: scope, item: item} do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
      order = pending_order(scope, item, 1)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, _} = OrderStateMachine.transition(scope, order, :expired)
      _other_order = pending_order(scope, item, 1)

      expect(ProviderMock, :refund, fn _creds, _txn, _amount -> {:error, :declined} end)

      assert {:error, {:refund_failed, :declined}} =
               Payments.confirm_approved(payment.id, "late-txn-3")

      # Nothing silently marked succeeded — still pending, still visible as unresolved.
      assert Repo.get(Payment, payment.id).status == :pending
    end
  end

  describe "confirm_failed/1" do
    test "cancels a pending_payment order immediately, releasing the hold", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 5)
      order = pending_order(scope, item, 3)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, updated} = Payments.confirm_failed(payment.id)
      assert updated.status == :failed

      order = Ordering.get_order(scope, order.id)
      assert order.status == :cancelled

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.reserved_qty == 0
      assert limit.sold_qty == 0
    end

    test "idempotent — a second confirm_failed call is a safe no-op", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, %Payment{}} = Payments.confirm_failed(payment.id)
      assert {:ok, :already_resolved} = Payments.confirm_failed(payment.id)
    end
  end

  describe "resolve_charge_result/2 dispatch" do
    test "approved dispatches to confirm_approved", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, _} =
               Payments.resolve_charge_result(
                 payment.id,
                 {:ok, %{provider_txn_id: "t1", state: :approved}}
               )

      assert Repo.get(Payment, payment.id).status == :succeeded
    end

    test "a definitive decline dispatches to confirm_failed", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, _} = Payments.resolve_charge_result(payment.id, {:error, :rejected})
      assert Repo.get(Payment, payment.id).status == :failed
    end

    test "a provider-reported failure code also dispatches to confirm_failed", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert {:ok, _} = Payments.resolve_charge_result(payment.id, {:error, {:provider, "5206"}})
      assert Repo.get(Payment, payment.id).status == :failed
    end

    test "an ambiguous network error leaves the payment pending for the poller", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")

      assert :ok =
               Payments.resolve_charge_result(payment.id, {:error, {:request_failed, "timeout"}})

      assert Repo.get(Payment, payment.id).status == :pending
    end
  end

  describe "callback vs poller race (code-standards.md: exactly one transition wins)" do
    test "two concurrent confirm_approved calls for the same payment settle exactly once", %{
      scope: scope,
      org: org,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 5)
      order = pending_order(scope, item, 1)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      parent = self()

      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            Sandbox.allow(Repo, parent, self())
            Repo.put_org_id(org.id)
            Payments.confirm_approved(payment.id, "race-txn")
          end,
          max_concurrency: 2
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.count(results, &match?({:ok, %Payment{}}, &1)) == 1
      assert Enum.count(results, &match?({:ok, :already_resolved}, &1)) == 1

      limit = Catalog.get_daily_limit(scope, item)
      assert limit.sold_qty == 1
      assert limit.reserved_qty == 0
    end
  end

  describe "verify_credentials/2" do
    test "flips charges_enabled on a successful lookup", %{scope: scope, venue: venue} do
      {:ok, venue} = venue |> Ecto.Changeset.change(charges_enabled: false) |> Repo.update()

      expect(ProviderMock, :lookup, fn _creds, _ref ->
        {:ok, %{provider_txn_id: nil, state: :pending}}
      end)

      assert {:ok, updated} = Payments.verify_credentials(scope, venue)
      assert updated.charges_enabled
    end

    test "leaves charges_enabled false on a failed lookup", %{scope: scope, venue: venue} do
      {:ok, venue} = venue |> Ecto.Changeset.change(charges_enabled: false) |> Repo.update()

      expect(ProviderMock, :lookup, fn _creds, _ref -> {:error, :invalid_credentials} end)

      assert {:error, :invalid_credentials} = Payments.verify_credentials(scope, venue)
      refute Repo.get(Tabletap.Tenants.Venue, venue.id).charges_enabled
    end
  end

  describe "refund/5" do
    test "a cash payment's refund records with no provider round-trip", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, payment} = Payments.confirm_approved(payment.id, "txn-cash")
      # Simulates a cash payment row (Feature 15's real writer doesn't
      # exist yet) — refund/5's cash branch only cares about `.provider`.
      {:ok, cash_payment} = payment |> Ecto.Changeset.change(provider: :cash) |> Repo.update()

      assert {:ok, refund} =
               Payments.refund(scope, cash_payment, cash_payment.amount, "goodwill", nil)

      assert refund.status == :succeeded
      assert refund.provider_refund_id == nil
    end

    test "a wallet refund calls the provider adapter and records its id", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, payment} = Payments.confirm_approved(payment.id, "txn-refund-1")

      expect(ProviderMock, :refund, fn _creds, "txn-refund-1", _amount ->
        {:ok, %{provider_refund_id: "wf-refund-1"}}
      end)

      assert {:ok, refund} = Payments.refund(scope, payment, payment.amount, "wrong item", nil)
      assert refund.status == :succeeded
      assert refund.provider_refund_id == "wf-refund-1"
    end

    test "over-refund is rejected, never clamped (design-qa.md Q35)", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, payment} = Payments.confirm_approved(payment.id, "txn-over")

      too_much = Money.add!(payment.amount, Money.new!(:USD, "1.00"))
      assert {:error, :over_refund} = Payments.refund(scope, payment, too_much, "oops", nil)
    end

    test "a second refund can't push the total past what was paid", %{scope: scope, item: item} do
      order = pending_order(scope, item, 2)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, payment} = Payments.confirm_approved(payment.id, "txn-partial")

      half = Money.mult!(payment.amount, Decimal.new("0.5"))

      expect(ProviderMock, :refund, fn _creds, _txn, _amount ->
        {:ok, %{provider_refund_id: "r1"}}
      end)

      assert {:ok, _} = Payments.refund(scope, payment, half, "first half", nil)

      assert {:error, :over_refund} =
               Payments.refund(scope, payment, payment.amount, "greedy", nil)
    end

    test "a failed provider refund is marked failed and never fails silently (design-qa.md Q23)",
         %{
           scope: scope,
           item: item
         } do
      order = pending_order(scope, item)
      {:ok, payment} = Payments.charge_order(scope, order, "252611111111")
      {:ok, payment} = Payments.confirm_approved(payment.id, "txn-fail-refund")

      expect(ProviderMock, :refund, fn _creds, _txn, _amount -> {:error, :declined} end)

      assert {:error, {:refund_failed, :declined}} =
               Payments.refund(scope, payment, payment.amount, "test", nil)

      refund = Repo.get_by(Refund, payment_id: payment.id)
      assert refund.status == :failed
    end
  end
end
