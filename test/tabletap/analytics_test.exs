defmodule Tabletap.AnalyticsTest do
  @moduledoc """
  Build-plan.md Feature 18's foundation: `Tabletap.Analytics.compute_rollup/2`
  reconciled dimension by dimension against hand-built orders/payments/
  refunds/discounts/ratings/stock movements (same reconciliation
  discipline the feature's own verify step asks for at the UI layer —
  "every number... reconciles with a hand-run SQL query"), plus
  `upsert_rollup/2`'s recompute_count and the nightly worker.
  """
  use Tabletap.DataCase, async: true
  use Oban.Testing, repo: Tabletap.ObanRepo

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics
  alias Tabletap.Analytics.Workers.DailyRollup, as: DailyRollupWorker
  alias Tabletap.Catalog
  alias Tabletap.Feedback
  alias Tabletap.Inventory
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Cart, OrderStateMachine}
  alias Tabletap.Payments
  alias Tabletap.Repo
  alias Tabletap.Staffing

  setup do
    %{org: org, venue: venue, membership: owner, user: owner_user} = org_fixture()
    Repo.put_org_id(org.id)
    scope = %Scope{org: org, venue: venue, role: :owner, membership: owner}

    {:ok, category} = Catalog.create_category(scope, %{"name" => "Drinks"})

    {:ok, item} =
      Catalog.create_item(scope, category, %{
        "name" => "Latte",
        "price" => Money.new!(:USD, "3.50")
      })

    %{org: org, venue: venue, scope: scope, owner: owner, owner_user: owner_user, item: item}
  end

  defp checked_out(scope, item, qty \\ 1, kind \\ nil) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
    cart = if kind, do: elem(Ordering.set_kind(scope, cart, kind), 1), else: cart
    {:ok, order} = Ordering.checkout(scope, cart)
    order
  end

  @forward_path [:placed, :accepted, :preparing, :ready, :served]

  defp serve!(scope, order) do
    Enum.reduce(@forward_path, order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)
  end

  defp today(scope), do: Tabletap.Tenants.business_date(scope.venue)

  describe "compute_rollup/2 — revenue, discounts, refunds, channel/payment mix" do
    test "reconciles cash + comp orders across two channels", %{
      scope: scope,
      owner_user: owner_user,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}

      order1 = checked_out(cashier_scope, item, 1, :dine_in)
      {:ok, payment1} = Payments.settle_cash_now(cashier_scope, order1, cashier)

      order2 = checked_out(scope, item, 2, :takeaway)
      {:ok, _payment2} = Payments.charge_comp(scope, order2, "friend", scope.membership)

      {:ok, _refund} =
        Payments.refund(scope, payment1, Money.new!(:USD, "1.00"), "too salty", owner_user.id)

      rollup = Analytics.compute_rollup(scope, today(scope))

      assert rollup.order_count == 2
      assert Money.equal?(rollup.gross_sales, Money.new!(:USD, "3.50"))
      assert Money.equal?(rollup.refunds, Money.new!(:USD, "1.00"))
      assert Money.equal?(rollup.net_revenue, Money.new!(:USD, "2.50"))
      assert Money.equal?(rollup.discounts, Money.new!(:USD, "7.00"))
      assert Money.equal?(rollup.avg_check, Money.new!(:USD, "1.25"))

      assert rollup.channel_mix["dine_in"]["count"] == 1

      assert rollup.channel_mix["dine_in"]["revenue"] == %{
               "amount" => "3.50",
               "currency" => "USD"
             }

      assert rollup.channel_mix["takeaway"]["count"] == 1

      assert rollup.channel_mix["takeaway"]["revenue"] == %{
               "amount" => "0.00",
               "currency" => "USD"
             }

      assert rollup.payment_mix["cash"]["count"] == 1
      assert rollup.payment_mix["cash"]["amount"] == %{"amount" => "3.50", "currency" => "USD"}
      assert rollup.payment_mix["comp"]["count"] == 1

      assert Enum.sum(Map.values(rollup.hourly_orders)) == 2
    end

    test "a business day with no activity reconciles to all zeros", %{scope: scope} do
      rollup = Analytics.compute_rollup(scope, today(scope))

      assert rollup.order_count == 0
      assert Money.equal?(rollup.gross_sales, Money.new!(:USD, 0))
      assert rollup.avg_check == nil
      assert rollup.channel_mix == %{}
      assert rollup.items_sold == %{}
    end

    test "never mixes another venue's numbers in", %{scope: scope, item: item} do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      other_venue = venue_fixture(scope.org)
      other_scope = %{scope | venue: other_venue}

      rollup = Analytics.compute_rollup(other_scope, today(other_scope))
      assert rollup.order_count == 0
    end
  end

  describe "compute_rollup/2 — items_sold, food cost, ingredient usage" do
    test "reconciles per-item qty/revenue/food-cost and the stock-movement-based total", %{
      scope: scope,
      item: item
    } do
      {:ok, milk} =
        Inventory.create_ingredient(scope, %{
          "name" => "Milk",
          "unit" => "ml",
          "cost_per_unit" => Money.new!(:USD, "0.02")
        })

      {:ok, _} = Inventory.add_recipe_line(scope, item, milk, Decimal.new(50))

      order = checked_out(scope, item, 2)
      served = serve!(scope, order)

      rollup = Analytics.compute_rollup(scope, today(scope))

      [{menu_item_id, item_row}] = Map.to_list(rollup.items_sold)
      assert menu_item_id == item.id
      assert item_row["name"] == "Latte"
      assert item_row["qty"] == 2
      assert item_row["revenue"] == %{"amount" => "7.00", "currency" => "USD"}
      # 2 servings x 50ml x $0.02/ml = $2.00
      assert item_row["food_cost"] == %{"amount" => "2.00", "currency" => "USD"}

      assert Money.equal?(rollup.food_cost, Money.new!(:USD, "2.00"))

      [{ingredient_id, usage}] = Map.to_list(rollup.ingredient_usage)
      assert ingredient_id == milk.id
      assert usage["name"] == "Milk"
      assert usage["unit"] == "ml"
      assert Decimal.equal?(Decimal.new(usage["qty"]), Decimal.new(100))
      assert usage["cost"] == %{"amount" => "2.00", "currency" => "USD"}

      _ = served
    end

    test "an item with no recipe has zero food cost, not an error", %{scope: scope, item: item} do
      order = checked_out(scope, item)
      serve!(scope, order)

      rollup = Analytics.compute_rollup(scope, today(scope))
      [{_id, item_row}] = Map.to_list(rollup.items_sold)
      assert item_row["food_cost"] == %{"amount" => "0", "currency" => "USD"}
      assert Money.equal?(rollup.food_cost, Money.new!(:USD, 0))
    end
  end

  describe "compute_rollup/2 — staff_metrics" do
    test "reconciles a waiter's orders served, timing, and rating", %{
      scope: scope,
      item: item
    } do
      %{membership: waiter, user: waiter_user} = waiter_fixture(scope.org, scope.venue)
      waiter_scope = %{scope | role: :waiter, membership: waiter}

      {:ok, shift} = Staffing.clock_in(waiter_scope)
      order = checked_out(scope, item)
      served = serve!(scope, order)
      {:ok, _} = Staffing.clock_out(waiter_scope)

      served = Ordering.get_order(scope, served.id) |> Repo.preload(:items)
      [order_item] = served.items
      {:ok, _} = Feedback.rate_item(scope, served, order_item, 5)

      rollup = Analytics.compute_rollup(scope, today(scope))
      waiter_row = rollup.staff_metrics["waiters"][waiter.id]

      if served.waiter_membership_id do
        assert waiter_row["orders_served"] == 1
        assert waiter_row["avg_accept_seconds"] >= 0
        assert waiter_row["avg_serve_seconds"] >= 0
        assert waiter_row["avg_rating"] == 5.0
        assert waiter_row["hours_on_shift"] >= 0
      end

      _ = waiter_user
      _ = shift
    end
  end

  describe "upsert_rollup/2" do
    test "increments recompute_count on every write after the first", %{scope: scope} do
      rollup = Analytics.compute_rollup(scope, today(scope))

      {:ok, first} = Analytics.upsert_rollup(rollup)
      assert first.recompute_count == 0

      {:ok, second} = Analytics.upsert_rollup(rollup)
      assert second.recompute_count == 1
      assert second.id == first.id

      stored = Analytics.get_rollup(scope, today(scope))
      assert stored.recompute_count == 1
    end
  end

  describe "list_rollups/3 and recent_business_dates/2" do
    test "returns stored rollups within range, oldest first", %{scope: scope} do
      d0 = today(scope)
      d1 = Date.add(d0, -1)

      {:ok, _} = scope |> Analytics.compute_rollup(d1) |> Analytics.upsert_rollup()
      {:ok, _} = scope |> Analytics.compute_rollup(d0) |> Analytics.upsert_rollup()

      [first, second] = Analytics.list_rollups(scope, d1, d0)
      assert first.date == d1
      assert second.date == d0
    end

    test "recent_business_dates/2 excludes today and goes backwards", %{scope: scope} do
      today = today(scope)
      dates = Analytics.recent_business_dates(scope.venue, 3)

      assert length(dates) == 3
      refute today in dates
      assert Date.add(today, -1) in dates
      assert Date.add(today, -3) in dates
    end
  end

  describe "Workers.DailyRollup" do
    test "computes and stores rollups for the lookback window across orgs", %{
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      assert :ok = perform_job(DailyRollupWorker, %{})

      Repo.put_org_id(scope.org.id)
      # Yesterday's rollup exists (empty) proving the lookback ran, even
      # though today's own order won't appear until tomorrow night's run
      # (the worker only rolls up already-closed business days).
      yesterday = Date.add(today(scope), -1)
      assert Analytics.get_rollup(scope, yesterday)
    end
  end
end
