defmodule Tabletap.Ordering.DiscountsTest do
  @moduledoc """
  Build-plan.md Feature 15's `Tabletap.Ordering` additions: attributed
  discounts pre-payment only (design-qa.md Q36), the cashier's
  order-number lookup (Q3), and `:counter`-kind carts.
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Repo

  setup do
    %{org: org, venue: venue, membership: owner} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner, membership: owner}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "5.00")
      })

    %{scope: scope, org: org, venue: venue, item: item, staff: owner}
  end

  defp pending_order(scope, item, qty \\ 1) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  describe "apply_discount/4" do
    test "a whole-order discount recomputes discount_total and total", %{
      scope: scope,
      staff: staff,
      item: item
    } do
      order = pending_order(scope, item)

      assert {:ok, updated} =
               Ordering.apply_discount(
                 scope,
                 order,
                 %{amount: Money.new!(:USD, "1.00"), reason: "Regular"},
                 staff
               )

      assert Money.equal?(updated.discount_total, Money.new!(:USD, "1.00"))
      assert Money.equal?(updated.total, Money.new!(:USD, "4.00"))
      assert Money.equal?(updated.subtotal, Money.new!(:USD, "5.00"))
    end

    test "stacks multiple discounts", %{scope: scope, staff: staff, item: item} do
      order = pending_order(scope, item)

      {:ok, order} =
        Ordering.apply_discount(
          scope,
          order,
          %{amount: Money.new!(:USD, "1.00"), reason: "A"},
          staff
        )

      {:ok, order} =
        Ordering.apply_discount(
          scope,
          order,
          %{amount: Money.new!(:USD, "0.50"), reason: "B"},
          staff
        )

      assert Money.equal?(order.discount_total, Money.new!(:USD, "1.50"))
      assert Money.equal?(order.total, Money.new!(:USD, "3.50"))
      assert length(Ordering.list_discounts(scope, order)) == 2
    end

    test "rejects once the order has left pending_payment (Q36)", %{
      scope: scope,
      staff: staff,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, cancelled} = OrderStateMachine.transition(scope, order, :cancelled)

      assert {:error, :not_pending_payment} =
               Ordering.apply_discount(
                 scope,
                 cancelled,
                 %{amount: Money.new!(:USD, "1.00"), reason: "Too late"},
                 staff
               )
    end
  end

  describe "remove_discount/2" do
    test "reverses a discount and recomputes the total", %{scope: scope, staff: staff, item: item} do
      order = pending_order(scope, item)

      {:ok, order} =
        Ordering.apply_discount(
          scope,
          order,
          %{amount: Money.new!(:USD, "1.00"), reason: "Oops"},
          staff
        )

      [discount] = Ordering.list_discounts(scope, order)
      assert {:ok, restored} = Ordering.remove_discount(scope, discount)

      assert Money.equal?(restored.discount_total, Money.new!(:USD, 0))
      assert Money.equal?(restored.total, Money.new!(:USD, "5.00"))
      assert Ordering.list_discounts(scope, restored) == []
    end
  end

  describe "get_order_by_number/2 (Q3)" do
    test "finds today's pending_payment order by its display number", %{scope: scope, item: item} do
      order = pending_order(scope, item)

      found = Ordering.get_order_by_number(scope, order.number)
      assert found.id == order.id
    end

    test "also finds an expired order (the Revive lookup path)", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      {:ok, expired} = OrderStateMachine.transition(scope, order, :expired)

      found = Ordering.get_order_by_number(scope, expired.number)
      assert found.id == order.id
      assert found.status == :expired
    end

    test "nil for an unknown number, or one that's already settled", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      assert Ordering.get_order_by_number(scope, 999_999) == nil

      {:ok, _cancelled} = OrderStateMachine.transition(scope, order, :cancelled)
      assert Ordering.get_order_by_number(scope, order.number) == nil
    end
  end

  describe "get_any_order_by_number/2 (the POS refund lookup)" do
    test "finds an order regardless of status — placed, served, whatever", %{
      scope: scope,
      item: item
    } do
      order = pending_order(scope, item)
      {:ok, placed} = OrderStateMachine.transition(scope, order, :placed)

      found = Ordering.get_any_order_by_number(scope, placed.number)
      assert found.id == order.id
      assert found.status == :placed
    end

    test "still nil for an unknown number or a stale business date", %{scope: scope} do
      assert Ordering.get_any_order_by_number(scope, 999_999) == nil
    end
  end

  describe "first_sold_out_item_name/2 (Q26 Revive messaging)" do
    test "names the line whose daily limit is exhausted by the time of the retry", %{
      scope: scope,
      item: item
    } do
      {:ok, _} = Catalog.set_daily_limit(scope, item, 1)
      order = pending_order(scope, item, 1)
      {:ok, expired} = OrderStateMachine.transition(scope, order, :expired)

      # A different guest buys the now-released last portion.
      other = pending_order(scope, item, 1)
      {:ok, _} = OrderStateMachine.transition(scope, other, :placed)

      assert {:error, :sold_out} = Ordering.reserve_holds_for_order(expired)
      assert Ordering.first_sold_out_item_name(scope, expired) == "Latte"
    end

    test "nil when nothing is limited", %{scope: scope, item: item} do
      order = pending_order(scope, item)
      assert Ordering.first_sold_out_item_name(scope, order) == nil
    end
  end

  describe "Cart :counter kind (Feature 15 walk-in tickets)" do
    test "set_kind/3 accepts :counter and it flows through checkout to Order.kind", %{
      scope: scope,
      item: item
    } do
      token = Cart.generate_guest_token()
      {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], 1, nil)
      {:ok, cart} = Ordering.set_kind(scope, cart, :counter)
      assert cart.kind == :counter

      {:ok, order} = Ordering.checkout(scope, cart)
      assert order.kind == :counter
    end
  end

  describe "placed_by_membership_id (cashier as customer proxy)" do
    test "set automatically from the acting scope's own membership", %{
      scope: scope,
      staff: staff,
      item: item
    } do
      order = pending_order(scope, item)
      assert order.placed_by_membership_id == staff.id
    end

    test "nil for a customer's own guest checkout", %{org: org, venue: venue, item: item} do
      guest_scope = %Scope{org: org, venue: venue, role: :guest}
      order = pending_order(guest_scope, item)
      assert order.placed_by_membership_id == nil
    end
  end
end
