defmodule Tabletap.Analytics.ReportsTest do
  @moduledoc """
  Build-plan.md Feature 18's Report Center: each of the 13 report
  functions reconciled against hand-built orders/payments/discounts/
  ratings/stock movements — the same reconciliation discipline the
  feature's own verify step asks for. Every function here reuses
  `Tabletap.Analytics`'s own Screen 1-7 reads wherever the shape
  already exists (owner-dashboard.md's "no report may compute a number
  differently than its dashboard twin"), so most of these tests assert
  the report's *own* net-new detail rows, not numbers already covered
  by `analytics_test.exs`.
  """
  use Tabletap.DataCase, async: true

  import Tabletap.TenantsFixtures

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics.Reports
  alias Tabletap.{Catalog, Feedback, Inventory, Ordering, Payments, Repo, Staffing}
  alias Tabletap.Ordering.{Cart, OrderStateMachine}

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

  defp checked_out(scope, item, qty \\ 1) do
    token = Cart.generate_guest_token()
    {:ok, cart} = Ordering.add_to_cart(scope, token, nil, item, [], qty, nil)
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

  # `Payments.settle_cash_now/3` already fires the order to :placed —
  # this continues from there rather than re-attempting the (now
  # illegal) placed -> placed transition serve!/2's own @forward_path
  # would try first.
  defp serve_from_placed!(scope, order) do
    Enum.reduce([:accepted, :preparing, :ready, :served], order, fn status, acc ->
      {:ok, moved} = OrderStateMachine.transition(scope, acc, status)
      moved
    end)
  end

  defp today(scope), do: Tabletap.Tenants.business_date(scope.venue)

  describe "report_types/0 and generate/4" do
    test "dispatches to the matching *_report/3 function", %{scope: scope} do
      today = today(scope)

      assert Reports.generate(:customers, scope, today, today) ==
               Reports.customers_report(scope, today, today)
    end

    test "lists all 13 report types" do
      assert length(Reports.report_types()) == 13
      assert :profit in Reports.report_types()
    end
  end

  describe "revenue_report/3" do
    test "bundles range days with discounts/comps/refunds/platform fees", %{
      scope: scope,
      owner_user: owner_user,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, payment} = Payments.settle_cash_now(cashier_scope, order, cashier)
      {:ok, _} = Payments.refund(scope, payment, Money.new!(:USD, "1.00"), "cold", owner_user.id)

      today = today(scope)
      report = Reports.revenue_report(scope, today, today)

      assert length(report.days) == 1
      assert Money.equal?(report.refunds.total, Money.new!(:USD, "1.00"))
      assert Money.equal?(report.discounts.total, Money.new!(:USD, 0))
    end
  end

  describe "orders_report/3" do
    test "lists every order in range, optionally filtered by status", %{scope: scope, item: item} do
      order1 = checked_out(scope, item)
      {:ok, placed} = OrderStateMachine.transition(scope, order1, :placed)

      order2 = checked_out(scope, item)
      {:ok, _cancelled} = OrderStateMachine.transition(scope, order2, :cancelled)

      today = today(scope)
      all_orders = Reports.orders_report(scope, today, today)
      assert length(all_orders) == 2

      placed_only = Reports.orders_report(scope, today, today, :placed)
      assert [only] = placed_only
      assert only.id == placed.id
    end
  end

  describe "successful_orders_report/3" do
    test "served orders only, with their discounts and payment attached", %{
      scope: scope,
      item: item
    } do
      order = checked_out(scope, item)

      {:ok, _} =
        Ordering.apply_discount(
          scope,
          order,
          %{amount: Money.new!(:USD, "0.50"), reason: "loyalty"},
          scope.membership
        )

      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)
      served = serve_from_placed!(scope, Ordering.get_order(scope, order.id))

      pending_order = checked_out(scope, item)

      today = today(scope)
      [row] = Reports.successful_orders_report(scope, today, today)

      assert row.order.id == served.id
      assert [discount] = row.discounts
      assert Money.equal?(discount.amount, Money.new!(:USD, "0.50"))
      assert row.payment.provider == :cash
      _ = pending_order
    end
  end

  describe "payments_report/3" do
    test "nets refunds against each payment row", %{
      scope: scope,
      owner_user: owner_user,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, payment} = Payments.settle_cash_now(cashier_scope, order, cashier)
      {:ok, _} = Payments.refund(scope, payment, Money.new!(:USD, "1.00"), "cold", owner_user.id)

      today = today(scope)
      [row] = Reports.payments_report(scope, today, today)

      assert row.payment.id == payment.id
      assert Money.equal?(row.refunded, Money.new!(:USD, "1.00"))
      assert Money.equal?(row.net, Money.new!(:USD, "2.50"))
    end
  end

  describe "cashier_daily_cash_report/3" do
    test "reconciles cash taken live, and expected/counted/variance once a Z-report closes", %{
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = today(scope)
      [row_before_close] = Reports.cashier_daily_cash_report(scope, today, today)
      assert Money.equal?(row_before_close.cash_taken, Money.new!(:USD, "3.50"))
      assert row_before_close.closed == false
      assert row_before_close.variance == nil

      {:ok, _report} =
        Payments.close_z_report(scope, today, %{cashier.id => Money.new!(:USD, "3.00")})

      [row_after_close] = Reports.cashier_daily_cash_report(scope, today, today)
      assert row_after_close.closed == true
      assert Money.equal?(row_after_close.variance, Money.new!(:USD, "-0.50"))
    end
  end

  describe "assisted_orders_report/3" do
    test "counts orders a cashier placed on a customer's behalf, by channel", %{
      scope: scope,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = today(scope)
      [row] = Reports.assisted_orders_report(scope, today, today)

      assert row.membership_id == cashier.id
      assert row.count == 1
      assert Money.equal?(row.total, Money.new!(:USD, "3.50"))
    end
  end

  describe "inventory_report/3, menu_performance_report/3, customers_report/3" do
    test "inventory_report/3 is inventory_cost_summary/3 verbatim", %{scope: scope} do
      today = today(scope)

      assert Reports.inventory_report(scope, today, today) ==
               Tabletap.Analytics.inventory_cost_summary(scope, today, today)
    end

    test "menu_performance_report/3 adds a same-period-last-year comparison", %{
      scope: scope,
      item: item
    } do
      order = checked_out(scope, item)
      serve!(scope, order)

      today = today(scope)
      report = Reports.menu_performance_report(scope, today, today)

      assert length(report.rows) == 1
      assert report.last_year_rows == []
    end

    test "customers_report/3 bundles the summary and top spenders", %{scope: scope} do
      today = today(scope)
      report = Reports.customers_report(scope, today, today)
      assert report.summary.new_count == 0
      assert report.top_customers == []
    end
  end

  describe "feedback_report/3" do
    test "bundles trend, previous-period trend, distribution, per-item, per-waiter, and raw ratings",
         %{
           scope: scope,
           item: item
         } do
      order = checked_out(scope, item)
      served = serve!(scope, order)
      [order_item] = Repo.preload(served, :items).items
      {:ok, _} = Feedback.rate_item(scope, served, order_item, 5, comment: "Great")

      today = today(scope)
      report = Reports.feedback_report(scope, today, today)

      assert [%{avg: 5.0, count: 1}] = report.trend
      assert report.previous_trend == []
      assert report.distribution[5] == 1
      assert [ratings_row] = report.ratings
      assert ratings_row.comment == "Great"
    end
  end

  describe "employee_work_report/3" do
    test "bundles waiter/cashier metrics with shifts and discount/comp attribution", %{
      scope: scope,
      item: item
    } do
      %{membership: waiter} = waiter_fixture(scope.org, scope.venue)
      waiter_scope = %{scope | role: :waiter, membership: waiter}
      {:ok, _} = Staffing.clock_in(waiter_scope)
      order = checked_out(scope, item)
      served = serve!(waiter_scope, order)
      served |> Ecto.Changeset.change(waiter_membership_id: waiter.id) |> Repo.update!()
      {:ok, _} = Staffing.clock_out(waiter_scope)

      today = today(scope)
      report = Reports.employee_work_report(scope, today, today)

      assert [waiter_row] = report.waiters
      assert waiter_row.waiter_membership_id == waiter.id
      assert [shift] = report.shifts
      assert shift.membership_id == waiter.id
      refute shift.auto_closed
    end
  end

  describe "day_close_report/3" do
    test "flags a post-close adjustment when a late refund lands after close", %{
      scope: scope,
      owner_user: owner_user,
      item: item
    } do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, payment} = Payments.settle_cash_now(cashier_scope, order, cashier)

      today = today(scope)

      {:ok, _report} =
        Payments.close_z_report(scope, today, %{cashier.id => Money.new!(:USD, "3.50")})

      [row_before] = Reports.day_close_report(scope, today, today)
      assert row_before.adjustment == nil

      {:ok, _} =
        Payments.refund(scope, payment, Money.new!(:USD, "1.00"), "late refund", owner_user.id)

      [row_after] = Reports.day_close_report(scope, today, today)
      assert row_after.adjustment != nil
      assert Money.equal?(row_after.adjustment.stored_net_revenue, Money.new!(:USD, "3.50"))
      assert Money.equal?(row_after.adjustment.current_net_revenue, Money.new!(:USD, "2.50"))
    end
  end

  describe "profit_report/3 and org_profit_rollup/3" do
    test "gross profit = net revenue - food cost, with purchases/wastage/discounts/refunds bundled",
         %{
           scope: scope,
           item: item
         } do
      {:ok, flour} =
        Inventory.create_ingredient(scope, %{
          "name" => "Flour",
          "unit" => "g",
          "cost_per_unit" => Money.new!(:USD, "0.01")
        })

      {:ok, _} = Inventory.add_recipe_line(scope, item, flour, Decimal.new(100))
      {:ok, _} = Inventory.restock(scope, flour, Decimal.new(500), Money.new!(:USD, "0.01"), nil)

      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      order = checked_out(cashier_scope, item)
      {:ok, _} = Payments.settle_cash_now(cashier_scope, order, cashier)
      serve_from_placed!(scope, Ordering.get_order(scope, order.id))

      today = today(scope)
      report = Reports.profit_report(scope, today, today)

      assert Money.equal?(report.net_revenue, Money.new!(:USD, "3.50"))
      assert Money.equal?(report.food_cost, Money.new!(:USD, "1.00"))
      assert Money.equal?(report.gross_profit, Money.new!(:USD, "2.50"))
      assert Money.equal?(report.purchases_total, Money.new!(:USD, "5.00"))

      [rollup_row] = Reports.org_profit_rollup(scope, today, today)
      assert rollup_row.venue_name == scope.venue.name
      assert Money.equal?(rollup_row.net_revenue, report.net_revenue)
    end
  end

  describe "subscriptions" do
    test "subscribe/3, list_subscriptions/1, and unsubscribe/2 round-trip", %{scope: scope} do
      assert Reports.list_subscriptions(scope) == []

      assert {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)
      assert [listed] = Reports.list_subscriptions(scope)
      assert listed.id == subscription.id
      assert listed.report_type == :revenue
      assert listed.frequency == :daily

      assert {:error, _changeset} = Reports.subscribe(scope, :revenue, :daily)

      assert {:ok, _} = Reports.unsubscribe(scope, subscription.id)
      assert Reports.list_subscriptions(scope) == []
    end

    test "unsubscribe/2 refuses to remove another membership's subscription", %{scope: scope} do
      %{membership: cashier} = cashier_fixture(scope.org, scope.venue)
      cashier_scope = %{scope | role: :cashier, membership: cashier}
      {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)

      assert {:error, :not_found} = Reports.unsubscribe(cashier_scope, subscription.id)
      assert [_] = Reports.list_subscriptions(scope)
    end

    test "subscription_range/2 anchors on yesterday's business date", %{scope: scope} do
      yesterday = Date.add(today(scope), -1)

      assert Reports.subscription_range(scope.venue, :daily) == {yesterday, yesterday}

      assert Reports.subscription_range(scope.venue, :weekly) ==
               {Date.add(yesterday, -6), yesterday}

      assert Reports.subscription_range(scope.venue, :monthly) ==
               {Date.beginning_of_month(yesterday), yesterday}
    end

    test "due_subscriptions/1 filters by frequency against the given date", %{scope: scope} do
      {:ok, daily} = Reports.subscribe(scope, :revenue, :daily)
      {:ok, weekly} = Reports.subscribe(scope, :orders, :weekly)
      {:ok, monthly} = Reports.subscribe(scope, :profit, :monthly)

      monday = ~D[2026-07-20]
      due_on_monday = Reports.due_subscriptions(monday) |> Enum.map(& &1.id)
      assert daily.id in due_on_monday
      assert weekly.id in due_on_monday
      refute monthly.id in due_on_monday

      wednesday = ~D[2026-07-22]
      due_on_wednesday = Reports.due_subscriptions(wednesday) |> Enum.map(& &1.id)
      assert daily.id in due_on_wednesday
      refute weekly.id in due_on_wednesday
      refute monthly.id in due_on_wednesday

      first_of_month = ~D[2026-08-01]
      due_on_first = Reports.due_subscriptions(first_of_month) |> Enum.map(& &1.id)
      assert daily.id in due_on_first
      assert monthly.id in due_on_first
    end

    test "mark_sent/1 stamps last_sent_at", %{scope: scope} do
      {:ok, subscription} = Reports.subscribe(scope, :revenue, :daily)
      assert subscription.last_sent_at == nil

      assert {:ok, updated} = Reports.mark_sent(subscription)
      assert updated.last_sent_at != nil
    end
  end
end
