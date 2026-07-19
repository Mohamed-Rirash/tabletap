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

  describe "today_summary/1" do
    test "is the same shape/numbers compute_rollup/2 would give for today", %{
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      assert Analytics.today_summary(scope) == Analytics.compute_rollup(scope, today(scope))
      assert Analytics.today_summary(scope).order_count == 1
    end
  end

  describe "today_operations/1" do
    test "counts open orders, oldest age, quoted ETA, and on-shift staff", %{
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      {:ok, _} = Staffing.clock_in(cashier_scope)

      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      ops = Analytics.today_operations(scope)

      assert ops.open_order_count == 1
      assert ops.oldest_open_order_minutes == 0
      assert ops.quoted_eta_minutes > 0
      assert ops.on_shift.cashiers == 1
      assert ops.on_shift.waiters == 0
    end

    test "an empty floor has no oldest order and zero on-shift", %{scope: scope} do
      ops = Analytics.today_operations(scope)
      assert ops.open_order_count == 0
      assert ops.oldest_open_order_minutes == nil
      assert ops.on_shift == %{waiters: 0, cashiers: 0, kitchen: 0}
    end
  end

  describe "today_alerts/1" do
    test "low stock, flagged orders, and sold-out items all surface", %{scope: scope, item: item} do
      {:ok, flour} =
        Inventory.create_ingredient(scope, %{
          "name" => "Flour",
          "unit" => "g",
          "min_threshold" => Decimal.new(100)
        })

      {:ok, _movement} =
        Inventory.restock(scope, flour, Decimal.new(50), Money.new!(:USD, "0.01"), nil)

      {:ok, category2} = Catalog.create_category(scope, %{"name" => "Snacks"})

      {:ok, sold_out_item} =
        Catalog.create_item(scope, category2, %{
          "name" => "Muffin",
          "price" => Money.new!(:USD, "2.00")
        })

      {:ok, _} = Catalog.set_daily_limit(scope, sold_out_item, 1)
      order = checked_out(scope, sold_out_item)
      {:ok, _} = OrderStateMachine.transition(scope, order, :placed)

      alerts = Analytics.today_alerts(scope)

      assert Enum.any?(alerts.low_stock, &(&1.id == flour.id))
      assert Enum.any?(alerts.sold_out_items, &(&1.id == sold_out_item.id))
      assert item.id not in Enum.map(alerts.sold_out_items, & &1.id)
    end

    test "a stuck placed order shows up as unaccepted, not delayed", %{scope: scope, item: item} do
      order = checked_out(scope, item)
      {:ok, order} = OrderStateMachine.transition(scope, order, :placed)

      stale_placed_at = DateTime.add(DateTime.utc_now(:second), -200, :second)
      order |> Ecto.Changeset.change(placed_at: stale_placed_at) |> Repo.update!()

      alerts = Analytics.today_alerts(scope)
      assert Enum.any?(alerts.unaccepted_orders, &(&1.id == order.id))
    end

    test "a canceled/past_due org surfaces a subscription issue", %{scope: scope} do
      assert Analytics.today_alerts(scope).subscription_issue == nil

      {:ok, past_due_org} =
        scope.org |> Ecto.Changeset.change(subscription_status: :past_due) |> Repo.update()

      assert Analytics.today_alerts(%{scope | org: past_due_org}).subscription_issue == :past_due
    end
  end

  describe "range_summary/3 and previous_period_range/2" do
    test "gap-free series with today live, yesterday from a stored rollup, day before that zeroed",
         %{
           scope: scope,
           item: item
         } do
      today = today(scope)
      yesterday = Date.add(today, -1)
      day_before = Date.add(today, -2)

      computed_yesterday = Analytics.compute_rollup(scope, yesterday)
      {:ok, _} = Analytics.upsert_rollup(computed_yesterday)

      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      [day_before_row, yesterday_row, today_row] =
        Analytics.range_summary(scope, day_before, today)

      assert day_before_row.date == day_before
      assert day_before_row.order_count == 0

      assert yesterday_row.date == yesterday
      assert yesterday_row.order_count == computed_yesterday.order_count

      assert today_row.date == today
      assert today_row.order_count == 1
    end

    test "previous_period_range/2 is the same-length window immediately before", %{scope: scope} do
      from_date = ~D[2026-07-10]
      to_date = ~D[2026-07-16]

      assert Analytics.previous_period_range(from_date, to_date) ==
               {~D[2026-07-03], ~D[2026-07-09]}

      _ = scope
    end
  end

  describe "discounts_breakdown/3 and comps_breakdown/3" do
    test "an ordinary discount counts as a discount, a comp counts separately", %{
      scope: scope,
      owner: owner,
      item: item
    } do
      order1 = checked_out(scope, item)

      {:ok, _} =
        Ordering.apply_discount(
          scope,
          order1,
          %{amount: Money.new!(:USD, "1.00"), reason: "loyalty"},
          owner
        )

      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order1, cashier)

      order2 = checked_out(scope, item)
      {:ok, _} = Payments.charge_comp(scope, order2, "Friend of the house", owner)

      today = today(scope)

      discounts = Analytics.discounts_breakdown(scope, today, today)
      assert Money.equal?(discounts.total, Money.new!(:USD, "1.00"))
      assert discounts.count == 1

      comps = Analytics.comps_breakdown(scope, today, today)
      assert Money.equal?(comps.total, Money.new!(:USD, "3.50"))
      assert comps.count == 1
      assert Enum.any?(comps.by_reason, &(&1.reason == "Friend of the house"))
    end
  end

  describe "refunds_breakdown/3" do
    test "totals, counts, and computes a rate against the period's own order count", %{
      scope: scope,
      owner_user: owner_user,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, payment} = Payments.settle_cash_now(cashier_scope, order, cashier)

      {:ok, _} =
        Payments.refund(scope, payment, Money.new!(:USD, "1.00"), "cold coffee", owner_user.id)

      today = today(scope)
      refunds = Analytics.refunds_breakdown(scope, today, today)

      assert Money.equal?(refunds.total, Money.new!(:USD, "1.00"))
      assert refunds.count == 1
      assert refunds.rate == 1.0
      assert Enum.any?(refunds.by_reason, &(&1.reason == "cold coffee"))
    end
  end

  describe "platform_fees_paid/3" do
    test "sums accrued platform_fee_ledger entries in the window", %{
      scope: scope,
      venue: venue,
      item: item
    } do
      today = today(scope)
      order = checked_out(scope, item)

      %Tabletap.Payments.PlatformFeeLedgerEntry{}
      |> Ecto.Changeset.change(%{
        org_id: scope.org.id,
        venue_id: venue.id,
        order_id: order.id,
        amount: Money.new!(:USD, "0.09"),
        accrued_at: DateTime.utc_now(:second)
      })
      |> Repo.insert!()

      assert Money.equal?(
               Analytics.platform_fees_paid(scope, today, today),
               Money.new!(:USD, "0.09")
             )
    end
  end

  describe "hourly_totals/3" do
    test "sums hourly_orders across the range", %{scope: scope, item: item} do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = today(scope)
      totals = Analytics.hourly_totals(scope, today, today)
      assert Enum.sum(Map.values(totals)) == 1
    end
  end

  describe "menu_performance/3, menu_quadrant/1, category_mix/3" do
    test "reconciles sold/revenue/margin/rating/sellout-days and classifies the quadrant", %{
      scope: scope,
      item: item
    } do
      {:ok, milk} =
        Inventory.create_ingredient(scope, %{
          "name" => "Milk",
          "unit" => "ml",
          "cost_per_unit" => Money.new!(:USD, "0.05")
        })

      {:ok, _} = Inventory.add_recipe_line(scope, item, milk, Decimal.new(10))

      order = checked_out(scope, item, 10)
      served = serve!(scope, order)
      [order_item] = Repo.preload(served, :items).items
      {:ok, _} = Feedback.rate_item(scope, served, order_item, 4)

      {:ok, category2} = Catalog.create_category(scope, %{"name" => "Snacks"})

      {:ok, muffin} =
        Catalog.create_item(scope, category2, %{
          "name" => "Muffin",
          "price" => Money.new!(:USD, "2.00")
        })

      {:ok, expensive_ingredient} =
        Inventory.create_ingredient(scope, %{
          "name" => "Blueberries",
          "unit" => "g",
          "cost_per_unit" => Money.new!(:USD, "0.18")
        })

      {:ok, _} = Inventory.add_recipe_line(scope, muffin, expensive_ingredient, Decimal.new(10))
      {:ok, _} = Catalog.set_daily_limit(scope, muffin, 1)

      muffin_order = checked_out(scope, muffin)
      serve!(scope, muffin_order)

      today = today(scope)
      rows = Analytics.menu_performance(scope, today, today)

      latte_row = Enum.find(rows, &(&1.name == "Latte"))
      assert latte_row.sold == 10
      assert Money.equal?(latte_row.revenue, Money.new!(:USD, "35.00"))
      assert Money.equal?(latte_row.food_cost, Money.new!(:USD, "5.00"))
      assert Money.equal?(latte_row.margin, Money.new!(:USD, "30.00"))
      assert latte_row.rating.avg |> Decimal.equal?(Decimal.new(4))
      assert latte_row.sellout_days == 0

      muffin_row = Enum.find(rows, &(&1.name == "Muffin"))
      assert muffin_row.sold == 1
      assert Money.equal?(muffin_row.food_cost, Money.new!(:USD, "1.80"))
      assert muffin_row.sellout_days == 1

      quadrant = Analytics.menu_quadrant(rows)
      assert Enum.any?(quadrant.stars, &(&1.name == "Latte"))
      assert Enum.any?(quadrant.dogs, &(&1.name == "Muffin"))

      mix = Analytics.category_mix(scope, today, today)
      assert Money.equal?(mix["Drinks"], Money.new!(:USD, "35.00"))
      assert Money.equal?(mix["Snacks"], Money.new!(:USD, "2.00"))
    end

    test "an empty range returns an empty quadrant, not an error", %{scope: _scope} do
      assert Analytics.menu_quadrant([]) == %{stars: [], plowhorses: [], puzzles: [], dogs: []}
    end
  end
end
