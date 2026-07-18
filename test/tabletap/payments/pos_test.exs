defmodule Tabletap.Payments.PosTest do
  @moduledoc """
  Build-plan.md Feature 15's `Tabletap.Payments` additions: cash intent/
  verify/revive (design-qa.md Q3/Q26), the POS's own immediate cash
  tender, comp settlement (Q30), and the Z-report (Q22/Q37/Q38 windowing).
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Payments
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue, membership: owner_membership} = org_fixture()
    Repo.put_org_id(org.id)
    owner_scope = %Scope{org: org, venue: venue, role: :owner, membership: owner_membership}

    {:ok, category} = Catalog.create_category(owner_scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(owner_scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{membership: cashier} = cashier_fixture(org, venue)
    cashier_scope = %Scope{org: org, venue: venue, role: :cashier, membership: cashier}

    %{
      org: org,
      venue: venue,
      item: item,
      owner_scope: owner_scope,
      owner_membership: owner_membership,
      cashier: cashier,
      cashier_scope: cashier_scope
    }
  end

  defp pending_order(scope, item, qty \\ 1) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  describe "record_cash_intent/2 + verify_cash_payment/3 (Q3)" do
    test "parks a pending cash payment, then a cashier verifies and fires it", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(owner_scope, item)

      assert {:ok, payment} = Payments.record_cash_intent(owner_scope, order)
      assert payment.status == :pending
      assert payment.provider == :cash
      assert payment.cashier_membership_id == nil

      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :pending_payment

      assert {:ok, verified} = Payments.verify_cash_payment(cashier_scope, order, cashier)
      assert verified.status == :succeeded
      assert verified.cashier_membership_id == cashier.id

      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :placed
    end

    test "verifying never accrues a platform fee (Q24 — cash is fee-free)", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(owner_scope, item)
      {:ok, _} = Payments.record_cash_intent(owner_scope, order)
      {:ok, _} = Payments.verify_cash_payment(cashier_scope, order, cashier)

      assert Repo.aggregate(Tabletap.Payments.PlatformFeeLedgerEntry, :count) == 0
    end

    test "Revive: an expired cash order re-reserves stock and fires (Q26)", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(owner_scope, item, 5)
      order = pending_order(owner_scope, item, 2)
      {:ok, _} = Payments.record_cash_intent(owner_scope, order)
      {:ok, expired} = OrderStateMachine.transition(owner_scope, order, :expired)

      assert {:ok, _payment} = Payments.verify_cash_payment(cashier_scope, expired, cashier)

      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :placed

      limit = Catalog.get_daily_limit(owner_scope, item)
      assert limit.sold_qty == 2
    end

    test "Revive names the item that sold out in the meantime (Q26)", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(owner_scope, item, 2)
      order = pending_order(owner_scope, item, 2)
      {:ok, _} = Payments.record_cash_intent(owner_scope, order)
      {:ok, expired} = OrderStateMachine.transition(owner_scope, order, :expired)

      # A different guest (via a wallet order) takes the last portion.
      _other = pending_order(owner_scope, item, 2)

      assert {:error, {:sold_out, item_name}} =
               Payments.verify_cash_payment(cashier_scope, expired, cashier)

      assert item_name == "Latte"

      # Nothing mutated on the failed Revive path.
      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :expired
    end
  end

  describe "settle_cash_now/3 — the POS's own immediate tender" do
    test "creates a succeeded cash payment and fires the order in one step", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(cashier_scope, item)

      assert {:ok, payment} = Payments.settle_cash_now(cashier_scope, order, cashier)
      assert payment.status == :succeeded
      assert payment.cashier_membership_id == cashier.id

      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :placed
      assert order.placed_by_membership_id == cashier.id
    end
  end

  describe "charge_comp/4 (Q30)" do
    test "manager/owner zeroes the order with an attributed discount and fires it", %{
      owner_scope: owner_scope,
      owner_membership: staff,
      item: item
    } do
      order = pending_order(owner_scope, item)

      assert {:ok, payment} = Payments.charge_comp(owner_scope, order, "Owner's friend", staff)
      assert payment.provider == :comp
      assert payment.status == :succeeded
      assert Money.compare!(payment.amount, Money.new!(:USD, 0)) == :eq

      order = Ordering.get_order(owner_scope, order.id)
      assert order.status == :placed
      assert Money.compare!(order.total, Money.new!(:USD, 0)) == :eq

      [discount] = Ordering.list_discounts(owner_scope, order)
      assert discount.reason == "Owner's friend"
      assert Money.equal?(discount.amount, Money.new!(:USD, "3.50"))
    end

    test "a plain cashier cannot comp (manager-gated)", %{
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(cashier_scope, item)

      assert {:error, :requires_manager} =
               Payments.charge_comp(cashier_scope, order, "Nice try", cashier)

      order = Ordering.get_order(cashier_scope, order.id)
      assert order.status == :pending_payment
    end
  end

  describe "z_report_preview/2 and close_z_report/3 (Q22/Q37/Q38)" do
    test "totals cash + comp, and per-cashier expected cash", %{
      owner_scope: owner_scope,
      owner_membership: owner_membership,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order1 = pending_order(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order1, cashier)

      order2 = pending_order(owner_scope, item)
      {:ok, _} = Payments.charge_comp(owner_scope, order2, "Test comp", owner_membership)

      today = Tabletap.Tenants.business_date(owner_scope.venue)
      preview = Payments.z_report_preview(owner_scope, today)

      assert preview.order_count == 2
      assert Money.equal?(preview.by_provider[:cash], Money.new!(:USD, "3.50"))
      assert Money.equal?(preview.cash_counts[cashier.id], Money.new!(:USD, "3.50"))
    end

    test "close_z_report/3 persists a snapshot and refuses a second close for the same day", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = Tabletap.Tenants.business_date(owner_scope.venue)

      assert {:ok, report} =
               Payments.close_z_report(owner_scope, today, %{
                 cashier.id => Money.new!(:USD, "3.50")
               })

      assert report.business_date == today
      [count] = report.cash_counts
      assert Money.equal?(count.expected_cash, Money.new!(:USD, "3.50"))
      assert Money.equal?(count.counted_cash, Money.new!(:USD, "3.50"))
      assert Money.equal?(count.variance, Money.new!(:USD, 0))

      assert {:error, %Ecto.Changeset{} = changeset} =
               Payments.close_z_report(owner_scope, today, %{})

      assert "has already been taken" in errors_on(changeset).venue_id
    end

    test "a discrepancy shows as a non-zero variance", %{
      owner_scope: owner_scope,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order = pending_order(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = Tabletap.Tenants.business_date(owner_scope.venue)

      {:ok, report} =
        Payments.close_z_report(owner_scope, today, %{cashier.id => Money.new!(:USD, "3.00")})

      [count] = report.cash_counts
      assert Money.equal?(count.variance, Money.new!(:USD, "-0.50"))
    end
  end

  describe "cashier_summary/3" do
    test "counts only this cashier's own transactions and cash", %{
      owner_scope: owner_scope,
      owner_membership: owner_membership,
      cashier_scope: cashier_scope,
      cashier: cashier,
      item: item
    } do
      order1 = pending_order(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order1, cashier)

      order2 = pending_order(owner_scope, item)
      {:ok, _} = Payments.charge_comp(owner_scope, order2, "Not this cashier", owner_membership)

      summary = Payments.cashier_summary(owner_scope, cashier)

      assert summary.transaction_count == 1
      assert Money.equal?(summary.cash_taken, Money.new!(:USD, "3.50"))
    end
  end
end
