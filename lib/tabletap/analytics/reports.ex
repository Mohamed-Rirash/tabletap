defmodule Tabletap.Analytics.Reports do
  @moduledoc """
  The Report Center (build-plan.md Feature 18; owner-dashboard.md
  "Report Center — every report, every period"). Every function here
  takes `(scope, from_date, to_date)` and returns a plain map — the
  on-screen renderer and the CSV exporter both call the *same*
  function, so a report can never show a different number on screen
  than in its own download (owner-dashboard.md's own rule: "no report
  may compute a number differently than its dashboard twin").

  Every report reuses `Tabletap.Analytics`'s own Screen 1-7 functions
  wherever the shape already exists — this module adds only the raw
  detail-list reports (orders, successful-orders-bills, payments,
  cashier-daily-cash, assisted-orders, day-close) that no dashboard
  screen already computes.

  **Two owner-dashboard.md asks are not implemented, both documented
  rather than silently missing:**
  - "Manual serve-confirm count" (Employee work report) — manual serve
    confirm only fires a transient telemetry event
    (`[:tabletap, :order, :serve_override]`), never a persisted column
    distinguishing it from a QR-scanned serve. Same class of gap as
    `Tabletap.Analytics`'s own documented "no escalation-rate counter."
  - Season/quarter grouping is not built as its own grouping mode —
    `same_period_last_year_range/2` covers the "this June vs last June"
    comparison owner-dashboard.md actually motivates it with; a
    dedicated quarter/season bucketing UI is a straightforward but
    separate addition on top of `range_summary/3`, left for whenever a
    real user asks for it rather than built speculatively now.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics
  alias Tabletap.Analytics.ReportSubscription
  alias Tabletap.Feedback
  alias Tabletap.Ordering.{Order, OrderDiscount}
  alias Tabletap.Payments
  alias Tabletap.Payments.{Payment, ZReport}
  alias Tabletap.Repo
  alias Tabletap.Staffing.Shift
  alias Tabletap.Tenants

  @report_types [
    :revenue,
    :orders,
    :successful_orders,
    :payments,
    :cashier_daily_cash,
    :assisted_orders,
    :inventory,
    :menu_performance,
    :feedback,
    :employee_work,
    :customers,
    :day_close,
    :profit
  ]

  def report_types, do: @report_types

  @history_statuses [:placed, :accepted, :preparing, :ready, :served, :closed, :refunded]
  @done_statuses [:served, :closed]

  @doc "Same-length window one year before `[from_date, to_date]` — the seasonal 'this period vs last year' comparison owner-dashboard.md's revenue/orders/menu-performance reports ask for."
  def same_period_last_year_range(from_date, to_date) do
    {Date.add(from_date, -365), Date.add(to_date, -365)}
  end

  @doc "Everything the given report type needs for `[from_date, to_date]`, dispatched to one of the functions below."
  def generate(type, %Scope{} = scope, from_date, to_date) when type in @report_types do
    apply(__MODULE__, :"#{type}_report", [scope, from_date, to_date])
  end

  @subscription_frequencies [:daily, :weekly, :monthly]

  @doc "Every recurring cadence a report subscription can be sent at."
  def subscription_frequencies, do: @subscription_frequencies

  @doc "Subscribe the current scope's membership to receive `report_type` by email at `frequency` — build-plan.md's scheduled report delivery. `Workers.SendScheduledReports` re-checks membership/role fresh at send time (design-qa.md Q52), so nothing about eligibility is cached here."
  def subscribe(%Scope{org: org, venue: venue, membership: membership}, report_type, frequency)
      when report_type in @report_types and frequency in @subscription_frequencies do
    %ReportSubscription{}
    |> ReportSubscription.changeset(%{
      org_id: org.id,
      venue_id: venue.id,
      membership_id: membership.id,
      report_type: report_type,
      frequency: frequency
    })
    |> Repo.insert()
  end

  @doc "Remove a report subscription — scoped to the current membership so one manager can't unsubscribe another's."
  def unsubscribe(%Scope{membership: membership}, subscription_id) do
    case Repo.get_by(ReportSubscription, id: subscription_id, membership_id: membership.id) do
      nil -> {:error, :not_found}
      subscription -> Repo.delete(subscription)
    end
  end

  @doc "Every report subscription belonging to the current scope's membership, newest first."
  def list_subscriptions(%Scope{membership: membership}) do
    Repo.all(
      from(s in ReportSubscription,
        where: s.membership_id == ^membership.id,
        order_by: [desc: s.inserted_at]
      )
    )
  end

  @doc """
  Every subscription due to send on `today`, within the current
  process's tenant. `Workers.SendScheduledReports` calls this after
  `Repo.put_org_id/1` for the org it's currently looping (same
  cross-tenant shape as `Workers.DailyRollup`), so the ambient org_id
  scopes this query same as any other tenant-owned read — no
  `skip_org_id: true` needed or allowed here (code-standards.md
  "Tenancy Rules" reserves that for `Accounts`/`Tenants`/platform-admin
  code). "Due" mirrors the daily-rollup worker's own fixed-schedule
  simplification: daily fires every day, weekly on Mondays, monthly on
  the 1st — no per-subscription anchor date. Preloads `:membership`
  (live `active`/`role`, Q52) and `:venue`; the recipient's `User` (for
  their email) isn't preloaded here — `users` has no `org_id` column,
  so the caller batch-fetches it separately with `skip_org_id: true`,
  same as `Tenants.list_memberships/2`.
  """
  def due_subscriptions(%Date{} = today) do
    is_monday = Date.day_of_week(today) == 1
    is_first_of_month = today.day == 1

    Repo.all(
      from(s in ReportSubscription,
        where:
          s.frequency == :daily or
            (s.frequency == :weekly and ^is_monday) or
            (s.frequency == :monthly and ^is_first_of_month),
        preload: [:membership, :venue]
      )
    )
  end

  @doc "The `[from_date, to_date]` a scheduled `frequency` delivery covers, anchored on `venue`'s business date — always full closed business days ending yesterday, never today's still-open one."
  def subscription_range(venue, frequency) do
    yesterday = Date.add(Tenants.business_date(venue), -1)

    case frequency do
      :daily -> {yesterday, yesterday}
      :weekly -> {Date.add(yesterday, -6), yesterday}
      :monthly -> {Date.beginning_of_month(yesterday), yesterday}
    end
  end

  @doc "Stamp a subscription as sent just now — `Workers.SendScheduledReports` calls this after a successful delivery."
  def mark_sent(%ReportSubscription{} = subscription) do
    subscription
    |> Ecto.Changeset.change(last_sent_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc "Revenue report: gross/discounts/comps/refunds/net by day, by payment method, by channel, platform fees — the Screen 2 numbers as a document."
  def revenue_report(%Scope{} = scope, from_date, to_date) do
    days = Analytics.range_summary(scope, from_date, to_date)

    %{
      days: days,
      discounts: Analytics.discounts_breakdown(scope, from_date, to_date),
      comps: Analytics.comps_breakdown(scope, from_date, to_date),
      refunds: Analytics.refunds_breakdown(scope, from_date, to_date),
      platform_fees: Analytics.platform_fees_paid(scope, from_date, to_date)
    }
  end

  @doc "Orders report: every order in the period with its status, per-stage timestamps, table, waiter, and total — optionally filtered to one `status`."
  def orders_report(%Scope{venue: venue}, from_date, to_date, status \\ nil) do
    Repo.all(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.business_date >= ^from_date and
            o.business_date <= ^to_date,
        where: ^if(status, do: dynamic([o], o.status == ^status), else: true),
        order_by: [desc: o.placed_at],
        preload: [:table, :waiter_membership]
      )
    )
  end

  @doc "Successful orders & bills report: served/closed orders only, each with its full bill — line items, modifiers, discounts, total, and who served it."
  def successful_orders_report(%Scope{venue: venue}, from_date, to_date) do
    orders =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and o.business_date >= ^from_date and
              o.business_date <= ^to_date and
              o.status in @done_statuses,
          order_by: [desc: o.served_at],
          preload: [:table, :waiter_membership, items: [:menu_item, :modifiers]]
        )
      )

    discounts_by_order = discounts_by_order_id(venue, from_date, to_date)
    payments_by_order = payments_by_order_id(venue, from_date, to_date)

    Enum.map(orders, fn order ->
      %{
        order: order,
        discounts: Map.get(discounts_by_order, order.id, []),
        payment: List.first(Map.get(payments_by_order, order.id, []))
      }
    end)
  end

  defp discounts_by_order_id(venue, from_date, to_date) do
    Repo.all(
      from(d in OrderDiscount,
        join: o in Order,
        on: o.id == d.order_id,
        where:
          o.venue_id == ^venue.id and o.business_date >= ^from_date and
            o.business_date <= ^to_date,
        select: {d.order_id, d}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp payments_by_order_id(venue, from_date, to_date) do
    {start_at, end_at} = business_date_bounds(venue, from_date, to_date)

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.status == :succeeded and p.inserted_at >= ^start_at and
            p.inserted_at < ^end_at,
        select: {p.order_id, p}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc "Payments (money-in) report: every payment as a row — wallet vs cash, amount, order link, who took cash, refunds netted."
  def payments_report(%Scope{venue: venue}, from_date, to_date) do
    {start_at, end_at} = business_date_bounds(venue, from_date, to_date)

    payments =
      Repo.all(
        from(p in Payment,
          where:
            p.venue_id == ^venue.id and p.status == :succeeded and p.inserted_at >= ^start_at and
              p.inserted_at < ^end_at,
          order_by: [desc: p.inserted_at],
          preload: [:order, :refunds, :cashier_membership]
        )
      )

    zero = Money.new!(venue.currency, 0)

    Enum.map(payments, fn payment ->
      refunded =
        payment.refunds
        |> Enum.filter(&(&1.status == :succeeded))
        |> Enum.map(& &1.amount)
        |> Enum.reduce(zero, &Money.add!(&2, &1))

      %{payment: payment, refunded: refunded, net: Money.sub!(payment.amount, refunded)}
    end)
  end

  @doc "Cashier daily cash report: per cashier per business day — cash orders rung, total cash taken, expected vs counted at close, variance. Reads Payments' own Z-report machinery directly (the only place 'counted' cash exists)."
  def cashier_daily_cash_report(%Scope{venue: venue} = scope, from_date, to_date) do
    from_date
    |> Date.range(to_date)
    |> Enum.flat_map(fn date -> cashier_day_rows(scope, venue, date) end)
  end

  defp cashier_day_rows(scope, venue, date) do
    zero = Money.new!(venue.currency, 0)
    z_report = Payments.get_z_report(scope, date)
    cash_counts = cash_counts_by_membership(z_report)

    venue
    |> cash_payments_by_membership(date)
    |> Enum.map(fn {membership_id, amounts} ->
      cashier_day_row(date, membership_id, amounts, zero, cash_counts[membership_id], z_report)
    end)
  end

  defp cash_payments_by_membership(venue, date) do
    {start_at, end_at} = business_date_bounds(venue, date, date)

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.provider == :cash and p.status == :succeeded and
            p.inserted_at >= ^start_at and p.inserted_at < ^end_at and
            not is_nil(p.cashier_membership_id),
        select: {p.cashier_membership_id, p.amount}
      )
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp cash_counts_by_membership(nil), do: %{}

  defp cash_counts_by_membership(z_report),
    do: Map.new(z_report.cash_counts, &{&1.membership_id, &1})

  defp cashier_day_row(date, membership_id, amounts, zero, count_row, z_report) do
    %{
      business_date: date,
      cashier_membership_id: membership_id,
      cash_orders_rung: length(amounts),
      cash_taken: Enum.reduce(amounts, zero, &Money.add!(&2, &1)),
      expected_cash: count_row && count_row.expected_cash,
      counted_cash: count_row && count_row.counted_cash,
      variance: count_row && count_row.variance,
      closed: z_report != nil
    }
  end

  @doc "Assisted orders report: orders a staff member placed on a customer's behalf (`placed_by_membership_id` set) — per cashier, count, value, dine-in vs takeaway, cash vs pay-link."
  def assisted_orders_report(%Scope{venue: venue}, from_date, to_date) do
    orders =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and o.business_date >= ^from_date and
              o.business_date <= ^to_date and
              not is_nil(o.placed_by_membership_id) and o.status in @history_statuses,
          select: %{
            placed_by_membership_id: o.placed_by_membership_id,
            kind: o.kind,
            total: o.total
          }
        )
      )

    zero = Money.new!(venue.currency, 0)

    orders
    |> Enum.group_by(& &1.placed_by_membership_id)
    |> Enum.map(fn {membership_id, rows} ->
      %{
        membership_id: membership_id,
        count: length(rows),
        total: rows |> Enum.map(& &1.total) |> Enum.reduce(zero, &Money.add!(&2, &1)),
        dine_in_count: Enum.count(rows, &(&1.kind == :dine_in)),
        takeaway_count: Enum.count(rows, &(&1.kind == :takeaway))
      }
    end)
  end

  @doc "Inventory report: stock on hand, consumption, restocks, wastage, stocktake variances — Screen 6's own summary as a document."
  def inventory_report(%Scope{} = scope, from_date, to_date) do
    Analytics.inventory_cost_summary(scope, from_date, to_date)
  end

  @doc "Menu performance report: the Screen 3 table as a document, optionally compared against the same period last year."
  def menu_performance_report(%Scope{} = scope, from_date, to_date) do
    rows = Analytics.menu_performance(scope, from_date, to_date)
    {ly_from, ly_to} = same_period_last_year_range(from_date, to_date)
    last_year_rows = Analytics.menu_performance(scope, ly_from, ly_to)

    %{rows: rows, last_year_rows: last_year_rows}
  end

  @doc "Feedback report: all ratings/comments in the period, per-item and per-waiter averages, trend vs the previous period."
  def feedback_report(%Scope{} = scope, from_date, to_date) do
    {prev_from, prev_to} = Analytics.previous_period_range(from_date, to_date)

    %{
      trend: Analytics.feedback_trend(scope, from_date, to_date),
      previous_trend: Analytics.feedback_trend(scope, prev_from, prev_to),
      distribution: Analytics.rating_distribution(scope, from_date, to_date),
      per_item: Analytics.worst_rated_items(scope),
      per_waiter: Analytics.per_waiter_ratings(scope, from_date, to_date),
      ratings: ratings_in_period(scope, from_date, to_date)
    }
  end

  defp ratings_in_period(%Scope{} = scope, from_date, to_date) do
    scope
    |> Feedback.list_venue_feedback()
    |> Enum.filter(
      &(&1.order_item.order.business_date >= from_date and
          &1.order_item.order.business_date <= to_date)
    )
  end

  @doc "Employee work report: per staff member, shifts + hours (auto-closed flagged), orders served/rung, avg accept & serve times, ratings, discounts + comps given, cash variance for cashiers."
  def employee_work_report(%Scope{venue: venue} = scope, from_date, to_date) do
    staff = Analytics.staff_summary(scope, from_date, to_date)
    shifts = shifts_in_range(venue, from_date, to_date)
    discounts = Analytics.discounts_breakdown(scope, from_date, to_date)
    comps = Analytics.comps_breakdown(scope, from_date, to_date)

    %{
      waiters: staff.waiters,
      cashiers: staff.cashiers,
      shifts: shifts,
      discounts_by_staff: discounts.by_staff,
      comps_by_staff: comps.by_staff
    }
  end

  defp shifts_in_range(venue, from_date, to_date) do
    {start_at, end_at} = business_date_bounds(venue, from_date, to_date)

    Repo.all(
      from(s in Shift,
        where: s.venue_id == ^venue.id and s.started_at >= ^start_at and s.started_at < ^end_at,
        order_by: [desc: s.started_at],
        preload: :membership
      )
    )
  end

  @doc "Customers report: new vs returning, repeat rate, top spenders — Screen 7's own summary as a document."
  def customers_report(%Scope{} = scope, from_date, to_date) do
    %{
      summary: Analytics.customers_summary(scope, from_date, to_date),
      top_customers: Analytics.top_customers(scope, from_date, to_date)
    }
  end

  @doc "Day-close (Z) reports: every closed business day in the period, with a post-close-adjustment addendum computed by diffing the stored (immutable) close against a fresh z_report_preview/2 run for the same date — design-qa.md Q38's 'original close stays visible as closed', never edited."
  def day_close_report(%Scope{venue: venue} = scope, from_date, to_date) do
    Repo.all(
      from(z in ZReport,
        where:
          z.venue_id == ^venue.id and z.business_date >= ^from_date and
            z.business_date <= ^to_date,
        order_by: [desc: z.business_date],
        preload: [:cash_counts, :closed_by_membership]
      )
    )
    |> Enum.map(fn z_report ->
      fresh = Payments.z_report_preview(scope, z_report.business_date)
      %{z_report: z_report, adjustment: post_close_adjustment(z_report, fresh)}
    end)
  end

  defp post_close_adjustment(z_report, fresh) do
    stored_net = money_from_totals(z_report.totals, "net_revenue")

    if stored_net && Money.equal?(stored_net, fresh.net_revenue) do
      nil
    else
      %{stored_net_revenue: stored_net, current_net_revenue: fresh.net_revenue}
    end
  end

  defp money_from_totals(
         %{"net_revenue" => %{"amount" => amount, "currency" => currency}},
         "net_revenue"
       ) do
    Money.new!(String.to_existing_atom(currency), amount)
  end

  defp money_from_totals(_totals, _key), do: nil

  @doc """
  Profit report (P&L-lite): net revenue - COGS = gross profit & margin,
  alongside purchases (valued from restock `unit_cost`), wastage cost,
  discounts given, refunds, platform fees. **Honest limit, stated on
  the report itself**: labor, rent, and utilities aren't tracked (no
  payroll module) — this is gross profit on food, not net profit.
  """
  def profit_report(%Scope{venue: venue} = scope, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    days = Analytics.range_summary(scope, from_date, to_date)
    net_revenue = days |> Enum.map(& &1.net_revenue) |> Enum.reduce(zero, &Money.add!(&2, &1))
    food_cost = days |> Enum.map(& &1.food_cost) |> Enum.reduce(zero, &Money.add!(&2, &1))
    gross_profit = Money.sub!(net_revenue, food_cost)

    inventory = Analytics.inventory_cost_summary(scope, from_date, to_date)

    purchases_total =
      inventory.purchases
      |> Enum.map(&Money.mult!(&1.unit_cost, &1.qty))
      |> Enum.reduce(zero, &Money.add!(&2, &1))

    wastage_total =
      inventory.wastage |> Enum.map(& &1.cost) |> Enum.reduce(zero, &Money.add!(&2, &1))

    %{
      net_revenue: net_revenue,
      food_cost: food_cost,
      gross_profit: gross_profit,
      gross_margin_pct: pct_of(gross_profit, net_revenue),
      purchases_total: purchases_total,
      wastage_total: wastage_total,
      discounts: Analytics.discounts_breakdown(scope, from_date, to_date),
      refunds: Analytics.refunds_breakdown(scope, from_date, to_date),
      platform_fees: Analytics.platform_fees_paid(scope, from_date, to_date)
    }
  end

  @doc "Every venue in the org, profit-reported side by side (Pro-tier org rollup) — per-venue rows only, never summed together (venues can run different currencies, design-qa.md Q53)."
  def org_profit_rollup(%Scope{org: org} = scope, from_date, to_date) do
    scope
    |> Tenants.list_venues()
    |> Enum.map(fn venue ->
      venue_scope = %Scope{org: org, venue: venue}
      Map.put(profit_report(venue_scope, from_date, to_date), :venue_name, venue.name)
    end)
  end

  defp pct_of(part, whole) do
    whole_decimal = Money.to_decimal(whole)

    if Decimal.equal?(whole_decimal, 0) do
      nil
    else
      part |> Money.to_decimal() |> Decimal.div(whole_decimal) |> Decimal.mult(100)
    end
  end

  defp business_date_bounds(venue, from_date, to_date) do
    {start_at, _} = business_date_single_bounds(venue, from_date)
    {_, end_at} = business_date_single_bounds(venue, to_date)
    {start_at, end_at}
  end

  defp business_date_single_bounds(venue, date) do
    {
      DateTime.new!(date, venue.business_day_cutoff, venue.timezone),
      DateTime.new!(Date.add(date, 1), venue.business_day_cutoff, venue.timezone)
    }
  end
end
