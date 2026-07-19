defmodule Tabletap.Analytics do
  @moduledoc """
  Daily rollups (build-plan.md Feature 18; architecture.md's documented
  `analytics/` module). `compute_rollup/2` is a pure read mirroring
  `Payments.z_report_preview/2`'s own shape (per-dimension private
  helpers, business-day windowing) — the venue's real cutoff-to-cutoff
  instants via `Tenants.business_date/2`, never a naive midnight split.

  **Rollups are never a "closed" document** the way `Payments.ZReport`
  is: `Analytics.Workers.DailyRollup` recomputes the last several
  business days every night, so a late-landing payment/refund/order
  self-heals within days without threading an explicit recompute
  trigger through every `Ordering`/`Payments` write path (a reasoned,
  documented interpretation of design-qa.md Q37/Q38 — see the worker's
  own moduledoc). `upsert_rollup/2` increments `recompute_count` on
  every write after the first, the only signal a reader needs to show
  "this day's numbers moved since it first closed."

  **Payment mix is grouped by `Payment.provider` only** (`:waafipay`,
  `:edahab`, `:chapa`, `:stripe`, `:cash`, `:comp`) — owner-dashboard.md
  additionally asks for a per-wallet split (ZAAD / EVC Plus / Sahal /
  WAAFI), but those all route through the single `:waafipay` provider
  value in our schema (no wallet-network column exists). Per
  owner-dashboard.md's own stated principle ("if a metric can't be
  derived from those tables, it doesn't belong on the dashboard"), that
  finer split is out of scope until a wallet-network field exists.

  **`items_sold`'s per-item `food_cost` is a recipe-base estimate**
  (`RecipeLine.qty_per_serving × ingredient.cost_per_unit`, current
  cost, no modifier ingredient deltas) — the rollup's own top-level
  `food_cost` field is the accurate figure, computed from actual
  `stock_movements` (`reason: :sale`) deductions, which *do* include
  modifier effects. Per-item margin is therefore an estimate; documented
  here rather than silently precise-looking.

  **`staff_metrics` covers what's actually attributable per person**:
  orders served / avg accept & serve time / unserveable flags / tables
  covered / avg rating / hours on shift, keyed by `waiter_membership_id`
  (the only staff role an order is individually attributed to).
  Kitchen prep time has no per-person attribution in our schema (no
  `kitchen_membership_id` on `Order`), so it's venue-wide, not
  per-membership. Cashier cash variance already lives in `z_reports` /
  `Payments.cashier_summary/3` — not duplicated here.
  """

  import Ecto.Query, warn: false

  alias Tabletap.Accounts.Scope
  alias Tabletap.Analytics.DailyRollup
  alias Tabletap.Catalog
  alias Tabletap.Catalog.DailyItemLimit
  alias Tabletap.Feedback
  alias Tabletap.Feedback.ItemRating
  alias Tabletap.Inventory
  alias Tabletap.Inventory.{Ingredient, RecipeLine, StockMovement}
  alias Tabletap.Ordering
  alias Tabletap.Ordering.{Order, OrderDiscount, OrderItem}
  alias Tabletap.Payments.{Payment, Refund}
  alias Tabletap.Repo
  alias Tabletap.Staffing.Shift
  alias Tabletap.Tenants
  alias Tabletap.Tenants.Membership

  @done_statuses [:served, :closed]
  @counted_statuses [:placed, :accepted, :preparing, :ready, :served, :closed, :refunded]

  defp business_date_bounds(venue, date) do
    {
      DateTime.new!(date, venue.business_day_cutoff, venue.timezone),
      DateTime.new!(Date.add(date, 1), venue.business_day_cutoff, venue.timezone)
    }
  end

  @doc """
  Every number `daily_rollups` stores for one venue's one business day —
  a pure read, safe to call repeatedly (the worker's own recompute loop
  does exactly that). Money fields are `Money` structs; jsonb-bound
  fields are plain maps with string keys and raw decimal-string amounts
  (never `Money.to_string!/2` — storage needs no locale).
  """
  def compute_rollup(%Scope{org: org, venue: venue}, date) do
    zero = Money.new!(venue.currency, 0)
    orders = orders_for_day(venue, date)
    succeeded_payments = succeeded_payments_for_day(venue, date)
    succeeded_refunds = succeeded_refunds_for_day(venue, date)

    gross_sales = succeeded_payments |> Enum.map(& &1.amount) |> money_sum(zero)
    refund_total = succeeded_refunds |> Enum.map(&elem(&1, 0).amount) |> money_sum(zero)
    net_revenue = Money.sub!(gross_sales, refund_total)
    order_count = length(orders)

    %{
      org_id: org.id,
      venue_id: venue.id,
      date: date,
      gross_sales: gross_sales,
      discounts: discount_total_for_day(venue, date, zero),
      refunds: refund_total,
      net_revenue: net_revenue,
      order_count: order_count,
      avg_check: avg_check(net_revenue, order_count),
      food_cost: food_cost_for_day(venue, date, zero),
      channel_mix: channel_mix(orders, zero),
      payment_mix: payment_mix(succeeded_payments, zero),
      hourly_orders: hourly_orders(orders, venue),
      items_sold: items_sold_for_day(org, venue, date, zero),
      ingredient_usage: ingredient_usage_for_day(org, venue, date),
      staff_metrics: staff_metrics_for_day(org, venue, date, orders)
    }
  end

  defp orders_for_day(venue, date) do
    Repo.all(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.business_date == ^date and o.status in @counted_statuses
      )
    )
  end

  defp succeeded_payments_for_day(venue, date) do
    {start_at, end_at} = business_date_bounds(venue, date)

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.status == :succeeded and p.inserted_at >= ^start_at and
            p.inserted_at < ^end_at
      )
    )
  end

  defp succeeded_refunds_for_day(venue, date) do
    {start_at, end_at} = business_date_bounds(venue, date)

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

  defp discount_total_for_day(venue, date, zero) do
    Repo.all(
      from(d in OrderDiscount,
        join: o in Order,
        on: o.id == d.order_id,
        where: o.venue_id == ^venue.id and o.business_date == ^date,
        select: d.amount
      )
    )
    |> money_sum(zero)
  end

  defp avg_check(_net_revenue, 0), do: nil
  defp avg_check(net_revenue, order_count), do: Money.div!(net_revenue, order_count)

  defp channel_mix(orders, zero) do
    orders
    |> Enum.group_by(& &1.kind)
    |> Map.new(fn {kind, kind_orders} ->
      {to_string(kind),
       %{
         "count" => length(kind_orders),
         "revenue" =>
           kind_orders |> Enum.map(& &1.total) |> money_sum(zero) |> money_for_storage()
       }}
    end)
  end

  defp payment_mix(succeeded_payments, zero) do
    succeeded_payments
    |> Enum.group_by(& &1.provider)
    |> Map.new(fn {provider, payments} ->
      {to_string(provider),
       %{
         "count" => length(payments),
         "amount" => payments |> Enum.map(& &1.amount) |> money_sum(zero) |> money_for_storage()
       }}
    end)
  end

  defp hourly_orders(orders, venue) do
    orders
    |> Enum.reject(&is_nil(&1.placed_at))
    |> Enum.group_by(fn order ->
      order.placed_at |> DateTime.shift_zone!(venue.timezone) |> Map.fetch!(:hour)
    end)
    |> Map.new(fn {hour, hour_orders} -> {to_string(hour), length(hour_orders)} end)
  end

  defp items_sold_for_day(org, venue, date, zero) do
    rows =
      Repo.all(
        from(oi in OrderItem,
          join: o in Order,
          on: o.id == oi.order_id,
          where:
            o.venue_id == ^venue.id and o.business_date == ^date and o.status in @counted_statuses,
          select: {oi.menu_item_id, oi.name_snapshot, oi.qty, oi.line_total}
        )
      )

    rows
    |> Enum.group_by(fn {menu_item_id, _name, _qty, _total} -> menu_item_id end)
    |> Map.new(fn {menu_item_id, item_rows} ->
      {_id, name, _qty, _total} = hd(item_rows)
      qty = item_rows |> Enum.map(fn {_, _, qty, _} -> qty end) |> Enum.sum()
      revenue = item_rows |> Enum.map(fn {_, _, _, total} -> total end) |> money_sum(zero)
      food_cost = recipe_food_cost(org.id, menu_item_id, qty, zero)

      {menu_item_id,
       %{
         "name" => name,
         "qty" => qty,
         "revenue" => money_for_storage(revenue),
         "food_cost" => money_for_storage(food_cost)
       }}
    end)
  end

  defp recipe_food_cost(org_id, menu_item_id, qty, zero) do
    Repo.all(
      from(r in RecipeLine,
        join: i in Ingredient,
        on: i.id == r.ingredient_id,
        where: r.org_id == ^org_id and r.menu_item_id == ^menu_item_id,
        select: {r.qty_per_serving, i.cost_per_unit}
      )
    )
    |> Enum.reduce(zero, fn {qty_per_serving, cost_per_unit}, acc ->
      line_qty = Decimal.mult(qty_per_serving, Decimal.new(qty))
      Money.add!(acc, Money.mult!(cost_per_unit, line_qty))
    end)
  end

  defp food_cost_for_day(venue, date, zero) do
    {start_at, end_at} = business_date_bounds(venue, date)

    Repo.all(
      from(m in StockMovement,
        join: i in Ingredient,
        on: i.id == m.ingredient_id,
        where:
          m.venue_id == ^venue.id and m.reason == :sale and m.inserted_at >= ^start_at and
            m.inserted_at < ^end_at,
        select: {m.qty_delta, i.cost_per_unit}
      )
    )
    |> Enum.reduce(zero, fn {qty_delta, cost_per_unit}, acc ->
      Money.add!(acc, Money.mult!(cost_per_unit, Decimal.abs(qty_delta)))
    end)
  end

  defp ingredient_usage_for_day(org, venue, date) do
    {start_at, end_at} = business_date_bounds(venue, date)

    Repo.all(
      from(m in StockMovement,
        join: i in Ingredient,
        on: i.id == m.ingredient_id,
        where:
          m.venue_id == ^venue.id and m.reason == :sale and m.inserted_at >= ^start_at and
            m.inserted_at < ^end_at,
        select: {m.ingredient_id, i.name, i.unit, m.qty_delta, i.cost_per_unit}
      )
    )
    |> Enum.group_by(fn {ingredient_id, _, _, _, _} -> ingredient_id end)
    |> Map.new(fn {ingredient_id, rows} ->
      {_id, name, unit, _qty, cost_per_unit} = hd(rows)

      qty =
        rows
        |> Enum.map(fn {_, _, _, qty_delta, _} -> Decimal.abs(qty_delta) end)
        |> Enum.reduce(&Decimal.add/2)

      cost = Money.mult!(cost_per_unit, qty)

      {ingredient_id,
       %{
         "name" => name,
         "unit" => to_string(unit),
         "qty" => Decimal.to_string(qty),
         "cost" => money_for_storage(cost),
         "org_id" => org.id
       }}
    end)
  end

  defp staff_metrics_for_day(org, venue, date, orders) do
    %{
      "waiters" => waiter_metrics(orders, org.id, venue, date),
      "kitchen_avg_prep_seconds" => kitchen_avg_prep_seconds(orders)
    }
  end

  defp waiter_metrics(orders, org_id, venue, date) do
    orders
    |> Enum.reject(&is_nil(&1.waiter_membership_id))
    |> Enum.group_by(& &1.waiter_membership_id)
    |> Map.new(fn {membership_id, waiter_orders} ->
      {membership_id,
       %{
         "orders_served" => Enum.count(waiter_orders, &(&1.status in @done_statuses)),
         "avg_accept_seconds" => avg_seconds(waiter_orders, :placed_at, :accepted_at),
         "avg_serve_seconds" => avg_seconds(waiter_orders, :accepted_at, :served_at),
         "unserveable_count" => Enum.count(waiter_orders, &(&1.flag == :unserveable)),
         "tables_covered" =>
           waiter_orders
           |> Enum.map(& &1.table_id)
           |> Enum.reject(&is_nil/1)
           |> Enum.uniq()
           |> length(),
         "avg_rating" => avg_rating_for_waiter(org_id, waiter_orders),
         "hours_on_shift" => hours_on_shift(membership_id, venue, date)
       }}
    end)
  end

  defp avg_seconds(orders, from_field, to_field) do
    diffs =
      orders
      |> Enum.map(&{Map.get(&1, from_field), Map.get(&1, to_field)})
      |> Enum.reject(fn {a, b} -> is_nil(a) or is_nil(b) end)
      |> Enum.map(fn {a, b} -> DateTime.diff(b, a, :second) end)

    case diffs do
      [] -> nil
      _ -> Enum.sum(diffs) / length(diffs)
    end
  end

  defp avg_rating_for_waiter(org_id, waiter_orders) do
    order_ids = Enum.map(waiter_orders, & &1.id)

    ratings =
      Repo.all(
        from(r in ItemRating,
          join: oi in OrderItem,
          on: oi.id == r.order_item_id,
          where: r.org_id == ^org_id and oi.order_id in ^order_ids,
          select: r.stars
        )
      )

    case ratings do
      [] -> nil
      _ -> Enum.sum(ratings) / length(ratings)
    end
  end

  defp hours_on_shift(membership_id, venue, date) do
    {start_at, end_at} = business_date_bounds(venue, date)

    Repo.all(
      from(s in Shift,
        where:
          s.membership_id == ^membership_id and not is_nil(s.ended_at) and
            s.started_at < ^end_at and s.ended_at > ^start_at
      )
    )
    |> Enum.reduce(0, fn shift, acc ->
      overlap_start = latest(shift.started_at, start_at)
      overlap_end = earliest(shift.ended_at, end_at)
      acc + max(DateTime.diff(overlap_end, overlap_start, :second), 0)
    end)
    |> Kernel./(3600)
  end

  defp latest(a, b), do: if(DateTime.compare(a, b) == :gt, do: a, else: b)
  defp earliest(a, b), do: if(DateTime.compare(a, b) == :lt, do: a, else: b)

  defp kitchen_avg_prep_seconds(orders) do
    avg_seconds(orders, :accepted_at, :ready_at)
  end

  defp money_sum(monies, zero), do: Enum.reduce(monies, zero, &Money.add!(&2, &1))

  # Same discipline `Payments.money_for_storage/1` established: raw
  # decimal + currency strings, never `Money.to_string!/2` in storage.
  defp money_for_storage(%Money{} = money) do
    %{
      "amount" => money |> Money.to_decimal() |> Decimal.to_string(),
      "currency" => to_string(money.currency)
    }
  end

  @doc """
  Persists `compute_rollup/2`'s output — an atomic upsert-increment via
  `Repo.insert_all/3`, the same shape `Ordering.reserve_order_number/3`
  already established for `(venue_id, date)`-keyed counters. Never
  read-then-written: `recompute_count` increments in the same statement
  that replaces every other field, so two concurrent recomputes for the
  same day can't race each other into an inconsistent count.
  """
  def upsert_rollup(rollup) do
    now = DateTime.utc_now(:second)

    entry =
      rollup
      |> Map.merge(%{
        id: Ecto.UUID.generate(),
        inserted_at: now,
        updated_at: now,
        recompute_count: 0
      })

    replace_fields =
      rollup
      |> Map.keys()
      |> Kernel.--([:org_id, :venue_id, :date])
      |> Kernel.++([:updated_at])

    {1, [result]} =
      Repo.insert_all(DailyRollup, [entry],
        on_conflict: [
          set: Enum.map(replace_fields, &{&1, Map.fetch!(entry, &1)}),
          inc: [recompute_count: 1]
        ],
        conflict_target: [:venue_id, :date],
        returning: [:id, :recompute_count]
      )

    {:ok, result}
  end

  @doc "The stored rollup for one venue/date, or `nil` if it hasn't been computed yet (e.g. today, or a very new venue)."
  def get_rollup(%Scope{venue: venue}, date) do
    Repo.one(from(r in DailyRollup, where: r.venue_id == ^venue.id and r.date == ^date))
  end

  @doc "Stored rollups for a venue across an inclusive date range, oldest first."
  def list_rollups(%Scope{venue: venue}, from_date, to_date) do
    Repo.all(
      from(r in DailyRollup,
        where: r.venue_id == ^venue.id and r.date >= ^from_date and r.date <= ^to_date,
        order_by: [asc: r.date]
      )
    )
  end

  @doc "Every business date a venue could have a rollup for, given `Tenants.business_date/2`'s own cutoff math — the worker's own iteration helper."
  def recent_business_dates(venue, count) do
    today = Tenants.business_date(venue)
    Enum.map(0..(count - 1), &Date.add(today, -&1 - 1))
  end

  ## Screen 1 — Today (build-plan.md Feature 18; owner-dashboard.md's own
  ## "walk in the door and know everything" view). Live queries only —
  ## today isn't a closed business day, so nothing here is ever read
  ## from `daily_rollups`.

  @doc """
  Today's revenue/order/channel/payment numbers — reuses `compute_rollup/2`
  outright rather than a second hand-written query, since "today" is
  just an in-progress business day with the identical shape. The
  dashboard and the eventual rollup for the same day can never disagree
  because they're the same function call.
  """
  def today_summary(%Scope{venue: venue} = scope) do
    compute_rollup(scope, Tenants.business_date(venue))
  end

  @doc """
  The operational tiles that only make sense live and are never rolled
  up: open order count + oldest order's age, the ETA a new order would
  be quoted right now, and who's on shift. Waiter presence is
  Presence-confirmed (`TabletapWeb.Presence`, the same liveness source
  `Ordering`'s own assignment algorithm trusts); cashier/kitchen "on
  shift" falls back to the DB-backed `Shift` row, since neither role's
  LiveView tracks Presence today — a real gap, not silently hidden.
  """
  def today_operations(%Scope{venue: venue}) do
    open = open_orders(venue)

    %{
      open_order_count: length(open),
      oldest_open_order_minutes: oldest_age_minutes(open),
      quoted_eta_minutes: quoted_eta_minutes(venue),
      on_shift: %{
        waiters: TabletapWeb.Presence.alive_membership_ids(venue.id) |> length(),
        cashiers: count_open_shifts(venue.id, :cashier),
        kitchen: count_open_shifts(venue.id, :kitchen)
      }
    }
  end

  @open_statuses [:placed, :accepted, :preparing, :ready]

  defp open_orders(venue) do
    Repo.all(from(o in Order, where: o.venue_id == ^venue.id and o.status in @open_statuses))
  end

  defp oldest_age_minutes([]), do: nil

  defp oldest_age_minutes(orders) do
    case orders |> Enum.map(& &1.placed_at) |> Enum.reject(&is_nil/1) do
      [] -> nil
      placed_ats -> div(DateTime.diff(DateTime.utc_now(), Enum.min(placed_ats, DateTime)), 60)
    end
  end

  # Mirrors `Ordering.estimated_minutes/2`'s own formula, but for a
  # not-yet-placed order — the same 10-minute default
  # `Ordering.expected_prep_minutes/1` falls back to for an order with
  # no items yet.
  defp quoted_eta_minutes(venue) do
    queue_depth =
      max(
        Repo.aggregate(
          from(o in Order,
            where: o.venue_id == ^venue.id and o.status in [:placed, :accepted, :preparing]
          ),
          :count
        ),
        1
      )

    inflation = venue.eta_inflation_factor || Decimal.new(1)

    (10 * queue_depth)
    |> Decimal.new()
    |> Decimal.mult(inflation)
    |> Decimal.round(0, :up)
    |> Decimal.to_integer()
  end

  defp count_open_shifts(venue_id, role) do
    Repo.aggregate(
      from(s in Shift,
        join: m in Membership,
        on: m.id == s.membership_id,
        where: s.venue_id == ^venue_id and is_nil(s.ended_at) and m.role == ^role and m.active
      ),
      :count
    )
  end

  @doc """
  The Today screen's alert feed — every check owner-dashboard.md's
  Screen 1 lists, reusing each concern's own existing context function
  rather than a parallel query (`Inventory.list_low_stock/1`,
  `Ordering.list_flagged_orders/1`). Delayed/unaccepted orders reuse
  `Ordering.expected_prep_minutes/1` and the same 90s accept window
  `Ordering`'s own assignment algorithm uses. `sold_out_items` has no
  "time it happened" (owner-dashboard.md asks for one) — no timestamp
  is recorded anywhere for a limit being hit or an item being toggled
  off, so that detail is out of scope until one exists, matching
  owner-dashboard.md's own "if a metric can't be derived, it doesn't
  belong" principle.
  """
  def today_alerts(%Scope{org: org, venue: venue} = scope) do
    now = DateTime.utc_now()
    queue = queue_orders_with_items(venue.id)

    %{
      low_stock: Inventory.list_low_stock(scope),
      delayed_orders: Enum.filter(queue, &delayed?(&1, now)),
      unaccepted_orders: Enum.filter(queue, &unaccepted?(&1, now)),
      flagged_orders: Ordering.list_flagged_orders(scope),
      sold_out_items: sold_out_items(scope),
      failed_payments: failed_payments_today(venue),
      subscription_issue: subscription_issue(org)
    }
  end

  defp queue_orders_with_items(venue_id) do
    Repo.all(
      from(o in Order,
        where: o.venue_id == ^venue_id and o.status in [:placed, :accepted, :preparing],
        preload: [items: :menu_item]
      )
    )
  end

  defp delayed?(%Order{placed_at: nil}, _now), do: false

  defp delayed?(%Order{placed_at: placed_at} = order, now) do
    DateTime.diff(now, placed_at, :second) > Ordering.expected_prep_minutes(order) * 60
  end

  # Same accept window `Ordering`'s own assignment algorithm treats as
  # "should have been claimed by now" — see that module's
  # `@accept_window_seconds`.
  @accept_window_seconds 90

  defp unaccepted?(%Order{status: :placed, placed_at: placed_at}, now)
       when not is_nil(placed_at) do
    DateTime.diff(now, placed_at, :second) > @accept_window_seconds
  end

  defp unaccepted?(_order, _now), do: false

  defp sold_out_items(%Scope{} = scope) do
    limits = Catalog.list_daily_limits(scope)

    scope
    |> Catalog.list_menu()
    |> Enum.flat_map(fn {_category, items} -> items end)
    |> Enum.filter(fn item ->
      !item.available_today or hit_limit?(limits[item.id])
    end)
  end

  defp hit_limit?(nil), do: false
  defp hit_limit?(limit), do: DailyItemLimit.remaining(limit) <= 0

  defp failed_payments_today(venue) do
    {start_at, end_at} = business_date_bounds(venue, Tenants.business_date(venue))

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.status == :failed and p.inserted_at >= ^start_at and
            p.inserted_at < ^end_at
      )
    )
  end

  defp subscription_issue(%{subscription_status: status}) when status in [:past_due, :canceled],
    do: status

  defp subscription_issue(_org), do: nil

  ## Screen 2 — Revenue & Sales (build-plan.md Feature 18; owner-dashboard.md).
  ## Every trend reads `range_summary/3` — closed days from `daily_rollups`,
  ## today (if in range) live via `today_summary/1` — so a chart and the
  ## Report Center's own CSV of the same range can never disagree.

  @doc """
  One row per calendar day in `[from_date, to_date]` — stored rollups
  where they exist, `today_summary/1` for today if it falls in range
  (never rolled up yet), and an honest all-zero row for any date with
  neither (a venue too new to have that day's data). Always the full
  range, gap-free, so a trend chart never has to special-case a
  missing day.
  """
  def range_summary(%Scope{venue: venue} = scope, from_date, to_date) do
    by_date = scope |> list_rollups(from_date, to_date) |> Map.new(&{&1.date, rollup_row(&1)})
    today = Tenants.business_date(venue)

    by_date =
      if Date.compare(today, from_date) != :lt and Date.compare(today, to_date) != :gt and
           not Map.has_key?(by_date, today) do
        Map.put(by_date, today, Map.put(today_summary(scope), :date, today))
      else
        by_date
      end

    from_date
    |> Date.range(to_date)
    |> Enum.map(&Map.get(by_date, &1, empty_day(&1, venue)))
  end

  defp rollup_row(%DailyRollup{} = r) do
    %{
      date: r.date,
      gross_sales: r.gross_sales,
      discounts: r.discounts,
      refunds: r.refunds,
      net_revenue: r.net_revenue,
      order_count: r.order_count,
      avg_check: r.avg_check,
      food_cost: r.food_cost,
      channel_mix: r.channel_mix,
      payment_mix: r.payment_mix,
      hourly_orders: r.hourly_orders,
      items_sold: r.items_sold,
      ingredient_usage: r.ingredient_usage,
      staff_metrics: r.staff_metrics,
      recompute_count: r.recompute_count
    }
  end

  defp empty_day(date, venue) do
    zero = Money.new!(venue.currency, 0)

    %{
      date: date,
      gross_sales: zero,
      discounts: zero,
      refunds: zero,
      net_revenue: zero,
      order_count: 0,
      avg_check: nil,
      food_cost: zero,
      channel_mix: %{},
      payment_mix: %{},
      hourly_orders: %{},
      items_sold: %{},
      ingredient_usage: %{},
      staff_metrics: %{"waiters" => %{}, "kitchen_avg_prep_seconds" => nil},
      recompute_count: 0
    }
  end

  @doc "The immediately-preceding period of the same length — the comparison range every Screen 2 chart ghosts against."
  def previous_period_range(from_date, to_date) do
    days = Date.diff(to_date, from_date) + 1
    {Date.add(from_date, -days), Date.add(from_date, -1)}
  end

  @doc """
  Ordinary discounts in the period (`Ordering.OrderDiscount` rows,
  windowed by the order's own `business_date` — same field
  `discount_total_for_day/3` already windows on), grouped by the staff
  member who applied them. Comp orders (100%-discount, `provider: :comp`
  payments) are excluded here and counted in `comps_breakdown/3` instead
  — design-qa.md Q30 tracks comps as their own category, not folded into
  ordinary discount totals.
  """
  def discounts_breakdown(%Scope{venue: venue}, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    comp_order_ids = comp_order_ids(venue, from_date, to_date)

    rows =
      Repo.all(
        from(d in OrderDiscount,
          join: o in Order,
          on: o.id == d.order_id,
          left_join: m in Membership,
          on: m.id == d.staff_membership_id,
          left_join: u in Tabletap.Accounts.User,
          on: u.id == m.user_id,
          where:
            o.venue_id == ^venue.id and o.business_date >= ^from_date and
              o.business_date <= ^to_date,
          select: {d.order_id, d.amount, d.staff_membership_id, u.email}
        )
      )
      |> Enum.reject(fn {order_id, _amount, _staff_id, _email} -> order_id in comp_order_ids end)

    %{
      total: rows |> Enum.map(&elem(&1, 1)) |> money_sum(zero),
      count: length(rows),
      by_staff: group_money_by_staff(rows, zero)
    }
  end

  @doc "Comp (100%-discount, `provider: :comp`) orders in the period — count, value at menu price, by staff and by reason (design-qa.md Q30: free food is tracked food)."
  def comps_breakdown(%Scope{venue: venue}, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    {start_at, _} = business_date_bounds(venue, from_date)
    {_, end_at} = business_date_bounds(venue, to_date)

    rows =
      Repo.all(
        from(p in Payment,
          join: d in OrderDiscount,
          on: d.order_id == p.order_id,
          left_join: m in Membership,
          on: m.id == d.staff_membership_id,
          left_join: u in Tabletap.Accounts.User,
          on: u.id == m.user_id,
          where:
            p.venue_id == ^venue.id and p.provider == :comp and p.status == :succeeded and
              p.inserted_at >= ^start_at and p.inserted_at < ^end_at,
          select: {p.order_id, d.amount, d.staff_membership_id, u.email, d.reason}
        )
      )

    %{
      total: rows |> Enum.map(&elem(&1, 1)) |> money_sum(zero),
      count: length(rows),
      by_staff: group_money_by_staff(rows, zero),
      by_reason: group_money_by_reason(rows, zero)
    }
  end

  defp comp_order_ids(venue, from_date, to_date) do
    {start_at, _} = business_date_bounds(venue, from_date)
    {_, end_at} = business_date_bounds(venue, to_date)

    Repo.all(
      from(p in Payment,
        where:
          p.venue_id == ^venue.id and p.provider == :comp and p.status == :succeeded and
            p.inserted_at >= ^start_at and p.inserted_at < ^end_at,
        select: p.order_id
      )
    )
    |> MapSet.new()
  end

  defp group_money_by_staff(rows, zero) do
    rows
    |> Enum.group_by(fn row -> {elem(row, 2), elem(row, 3)} end)
    |> Enum.map(fn {{staff_id, email}, staff_rows} ->
      %{
        staff_membership_id: staff_id,
        email: email || gettext_no_staff(),
        count: length(staff_rows),
        total: staff_rows |> Enum.map(&elem(&1, 1)) |> money_sum(zero)
      }
    end)
    |> Enum.sort_by(& &1.total, {:desc, Money})
  end

  defp group_money_by_reason(rows, zero) do
    rows
    |> Enum.group_by(&elem(&1, 4))
    |> Enum.map(fn {reason, reason_rows} ->
      %{
        reason: reason || gettext_no_reason(),
        count: length(reason_rows),
        total: reason_rows |> Enum.map(&elem(&1, 1)) |> money_sum(zero)
      }
    end)
    |> Enum.sort_by(& &1.total, {:desc, Money})
  end

  defp gettext_no_staff, do: "—"
  defp gettext_no_reason, do: "—"

  @doc """
  Refund total + rate (% of orders refunded) + reasons for the period —
  a rising rate is design-qa.md's own "ops fire alarm." Windowed the
  same way `succeeded_refunds_for_day/2` windows a single day, just
  across the whole range.
  """
  def refunds_breakdown(%Scope{venue: venue} = scope, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    {start_at, _} = business_date_bounds(venue, from_date)
    {_, end_at} = business_date_bounds(venue, to_date)

    rows =
      Repo.all(
        from(r in Refund,
          join: p in Payment,
          on: p.id == r.payment_id,
          where:
            p.venue_id == ^venue.id and r.status == :succeeded and r.inserted_at >= ^start_at and
              r.inserted_at < ^end_at,
          select: {r.amount, r.reason}
        )
      )

    order_count =
      range_summary(scope, from_date, to_date) |> Enum.map(& &1.order_count) |> Enum.sum()

    %{
      total: rows |> Enum.map(&elem(&1, 0)) |> money_sum(zero),
      count: length(rows),
      rate: if(order_count > 0, do: length(rows) / order_count, else: nil),
      by_reason:
        group_money_by_reason(
          Enum.map(rows, fn {amount, reason} -> {nil, amount, nil, nil, reason} end),
          zero
        )
    }
  end

  @doc "Platform fees accrued in the period (`platform_fee_ledger`) — full-cost transparency, owner-dashboard.md Screen 2."
  def platform_fees_paid(%Scope{venue: venue}, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    {start_at, _} = business_date_bounds(venue, from_date)
    {_, end_at} = business_date_bounds(venue, to_date)

    Repo.all(
      from(f in Tabletap.Payments.PlatformFeeLedgerEntry,
        where: f.venue_id == ^venue.id and f.accrued_at >= ^start_at and f.accrued_at < ^end_at,
        select: f.amount
      )
    )
    |> money_sum(zero)
  end

  @doc "Hour-of-day order counts summed across the whole range — the simplest honest version of owner-dashboard.md's peak-hours heatmap (a full weekday × hour matrix would need raw per-order weekday grouping the rollup doesn't carry; deferred, not silently faked)."
  def hourly_totals(%Scope{} = scope, from_date, to_date) do
    scope
    |> range_summary(from_date, to_date)
    |> Enum.flat_map(& &1.hourly_orders)
    |> Enum.reduce(%{}, fn {hour, count}, acc -> Map.update(acc, hour, count, &(&1 + count)) end)
  end

  ## Screen 3 — Menu Performance (build-plan.md Feature 18; owner-dashboard.md).
  ## Aggregates `range_summary/3`'s own `items_sold` jsonb across the
  ## range — never a second raw-order query — plus a live rating join,
  ## since `Feedback` has no range-filtered aggregate today.

  @doc """
  One row per menu item sold in the range: sold qty, revenue, food cost
  (recipe-base estimate, see this module's own moduledoc), margin
  (absolute + %), avg rating + count, and sellout days (business days
  in range where the item's own `DailyItemLimit` hit zero remaining).
  Modifier attach rate isn't tracked anywhere in the schema today
  (`items_sold` has no modifier dimension) — out of scope until it is,
  not silently guessed at.
  """
  def menu_performance(%Scope{venue: venue} = scope, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    days = range_summary(scope, from_date, to_date)

    item_rows =
      days
      |> Enum.flat_map(& &1.items_sold)
      |> Enum.group_by(fn {id, _row} -> id end, fn {_id, row} -> row end)

    item_ids = Map.keys(item_rows)
    ratings = Feedback.ratings_summary_for_items(scope, item_ids)
    sellout_counts = sellout_days_by_item(venue, item_ids, from_date, to_date)

    item_rows
    |> Enum.map(fn {menu_item_id, rows} ->
      revenue = rows |> Enum.map(&money_from_storage(&1["revenue"])) |> money_sum(zero)
      food_cost = rows |> Enum.map(&money_from_storage(&1["food_cost"])) |> money_sum(zero)
      margin = Money.sub!(revenue, food_cost)

      %{
        menu_item_id: menu_item_id,
        name: hd(rows)["name"],
        sold: rows |> Enum.map(& &1["qty"]) |> Enum.sum(),
        revenue: revenue,
        food_cost: food_cost,
        margin: margin,
        margin_pct: margin_pct(margin, revenue),
        rating: Map.get(ratings, menu_item_id),
        sellout_days: Map.get(sellout_counts, menu_item_id, 0)
      }
    end)
    |> Enum.sort_by(& &1.revenue, {:desc, Money})
  end

  defp money_from_storage(%{"amount" => amount, "currency" => currency}) do
    Money.new!(String.to_existing_atom(currency), amount)
  end

  defp margin_pct(_margin, %Money{amount: amount}) when amount == 0, do: nil

  defp margin_pct(margin, revenue) do
    margin |> Money.to_decimal() |> Decimal.div(Money.to_decimal(revenue)) |> Decimal.mult(100)
  end

  defp sellout_days_by_item(venue, item_ids, from_date, to_date) do
    Repo.all(
      from(l in DailyItemLimit,
        where:
          l.venue_id == ^venue.id and l.item_id in ^item_ids and l.date >= ^from_date and
            l.date <= ^to_date,
        select: l
      )
    )
    |> Enum.filter(&(DailyItemLimit.remaining(&1) <= 0))
    |> Enum.group_by(& &1.item_id)
    |> Map.new(fn {item_id, rows} -> {item_id, length(rows)} end)
  end

  @doc """
  Classic BCG-style menu-engineering quadrant (owner-dashboard.md Screen
  3): each item is above/below the range's own average sold-volume and
  average margin-%, giving **Stars** (high volume, high margin),
  **Plowhorses** (high volume, low margin), **Puzzles** (low volume,
  high margin), **Dogs** (low volume, low margin). Items with no
  computable margin % (zero revenue) are excluded — there's nothing to
  classify.
  """
  def menu_quadrant(item_rows) do
    case Enum.filter(item_rows, &(&1.margin_pct != nil)) do
      [] ->
        %{stars: [], plowhorses: [], puzzles: [], dogs: []}

      classifiable ->
        avg_volume = average(Enum.map(classifiable, & &1.sold))
        avg_margin_pct = average(Enum.map(classifiable, &Decimal.to_float(&1.margin_pct)))

        classifiable
        |> Enum.group_by(&classify(&1, avg_volume, avg_margin_pct))
        |> then(&Map.merge(%{stars: [], plowhorses: [], puzzles: [], dogs: []}, &1))
    end
  end

  defp classify(item, avg_volume, avg_margin_pct) do
    high_volume = item.sold >= avg_volume
    high_margin = Decimal.to_float(item.margin_pct) >= avg_margin_pct

    case {high_volume, high_margin} do
      {true, true} -> :stars
      {true, false} -> :plowhorses
      {false, true} -> :puzzles
      {false, false} -> :dogs
    end
  end

  defp average([]), do: 0
  defp average(numbers), do: Enum.sum(numbers) / length(numbers)

  @doc "Revenue grouped by category for the range — the Screen 3 category-mix pie, one query joining Catalog's own category ownership onto the menu-performance rows."
  def category_mix(%Scope{venue: venue} = scope, from_date, to_date) do
    zero = Money.new!(venue.currency, 0)
    item_rows = menu_performance(scope, from_date, to_date)
    category_by_item = category_by_item_id(scope)

    item_rows
    |> Enum.group_by(fn row ->
      Map.get(category_by_item, row.menu_item_id, gettext_no_category())
    end)
    |> Map.new(fn {category_name, rows} ->
      {category_name, rows |> Enum.map(& &1.revenue) |> money_sum(zero)}
    end)
  end

  defp gettext_no_category, do: "—"

  defp category_by_item_id(%Scope{} = scope) do
    scope
    |> Catalog.list_menu()
    |> Enum.flat_map(fn {category, items} -> Enum.map(items, &{&1.id, category.name}) end)
    |> Map.new()
  end

  ## Screen 4 — Feedback, rich (build-plan.md Feature 18; owner-dashboard.md).
  ## Ratings have no rollup dimension — `daily_rollups` carries none —
  ## so every read here queries `item_ratings`/`order_items`/`orders`
  ## directly for the requested range, windowed by the order's own
  ## `business_date` (same choice `menu_performance/3` already made for
  ## `items_sold`), not the rating's own `inserted_at` (a customer can
  ## rate hours or days after being served).

  defp ratings_in_range(venue, from_date, to_date) do
    Repo.all(
      from(r in ItemRating,
        join: oi in OrderItem,
        on: oi.id == r.order_item_id,
        join: o in Order,
        on: o.id == oi.order_id,
        where:
          r.venue_id == ^venue.id and o.business_date >= ^from_date and
            o.business_date <= ^to_date,
        select: %{
          stars: r.stars,
          business_date: o.business_date,
          order_id: o.id,
          waiter_membership_id: o.waiter_membership_id
        }
      )
    )
  end

  @doc "Daily average stars for the range — the Screen 4 venue rating trend."
  def feedback_trend(%Scope{venue: venue}, from_date, to_date) do
    venue
    |> ratings_in_range(from_date, to_date)
    |> Enum.group_by(& &1.business_date, & &1.stars)
    |> Enum.map(fn {date, stars} -> %{date: date, avg: average(stars), count: length(stars)} end)
    |> Enum.sort_by(& &1.date, Date)
  end

  @doc "1-5 star histogram for the range."
  def rating_distribution(%Scope{venue: venue}, from_date, to_date) do
    ratings = ratings_in_range(venue, from_date, to_date)
    Map.new(1..5, &{&1, Enum.count(ratings, fn r -> r.stars == &1 end)})
  end

  @doc "% of served/closed orders in the range that got at least one rating — low means the prompt isn't landing."
  def rating_rate(%Scope{venue: venue}, from_date, to_date) do
    servable_ids =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and o.business_date >= ^from_date and
              o.business_date <= ^to_date and
              o.status in [:served, :closed],
          select: o.id
        )
      )

    if servable_ids == [] do
      nil
    else
      rated_ids =
        venue |> ratings_in_range(from_date, to_date) |> Enum.map(& &1.order_id) |> Enum.uniq()

      length(rated_ids) / length(servable_ids)
    end
  end

  @doc "Avg stars per waiter for the range — orders they served, not orders they were merely assigned (design-qa.md's fairness guardrail: always shown with venue averages and hours, never a naked leaderboard — the LiveView's own job)."
  def per_waiter_ratings(%Scope{venue: venue}, from_date, to_date) do
    venue
    |> ratings_in_range(from_date, to_date)
    |> Enum.reject(&is_nil(&1.waiter_membership_id))
    |> Enum.group_by(& &1.waiter_membership_id, & &1.stars)
    |> Enum.map(fn {membership_id, stars} ->
      %{waiter_membership_id: membership_id, avg: average(stars), count: length(stars)}
    end)
    |> Enum.sort_by(& &1.avg, :desc)
  end

  @doc "Every rated menu item's all-time avg + count, worst-first — the Screen 4 sortable list."
  def worst_rated_items(%Scope{} = scope) do
    item_ids =
      scope
      |> Catalog.list_menu()
      |> Enum.flat_map(fn {_category, items} -> items end)
      |> Map.new(&{&1.id, &1.name})

    scope
    |> Feedback.ratings_summary_for_items(Map.keys(item_ids))
    |> Enum.map(fn {item_id, summary} ->
      Map.merge(summary, %{menu_item_id: item_id, name: item_ids[item_id]})
    end)
    |> Enum.sort_by(& &1.avg, Decimal)
  end

  @doc "Items whose last 20 ratings (all-time, not range-bound) average below 3.0 — owner-dashboard.md's own low-rating alert."
  def low_rated_items(%Scope{venue: venue} = scope) do
    item_ids =
      Repo.all(
        from(r in ItemRating,
          where: r.venue_id == ^venue.id,
          distinct: true,
          select: r.menu_item_id
        )
      )

    names =
      scope
      |> Catalog.list_menu()
      |> Enum.flat_map(fn {_category, items} -> items end)
      |> Map.new(&{&1.id, &1.name})

    item_ids
    |> Enum.map(&{&1, last_20_stars(venue, &1)})
    |> Enum.filter(fn {_id, stars} -> stars != [] and average(stars) < 3.0 end)
    |> Enum.map(fn {item_id, stars} ->
      %{menu_item_id: item_id, name: names[item_id], avg: average(stars)}
    end)
  end

  defp last_20_stars(venue, item_id) do
    Repo.all(
      from(r in ItemRating,
        where: r.venue_id == ^venue.id and r.menu_item_id == ^item_id,
        order_by: [desc: r.inserted_at],
        limit: 20,
        select: r.stars
      )
    )
  end

  ## Screen 7 — Customers (build-plan.md Feature 18; owner-dashboard.md,
  ## "MVP-honest: we only know what our data supports"). Identity is
  ## `customer_user_id` when the guest signed up (Feature 16), the raw
  ## `guest_token` otherwise — two anonymous visits under two different
  ## guest_tokens can't be linked (no PII to link them by, by design),
  ## the same honesty owner-dashboard.md itself calls for. "New vs
  ## returning" looks at each identity's very first order ever, not just
  ## within the selected range, so a first-time visitor mid-range doesn't
  ## get miscounted as "returning."

  @history_statuses [:placed, :accepted, :preparing, :ready, :served, :closed, :refunded]

  @doc """
  New vs returning counts, a visit-frequency histogram (1× / 2-3× / 4+×),
  and the 30-day repeat rate (design-qa.md's own "% of customers with
  2+ orders in 30 days") for the range.
  """
  def customers_summary(%Scope{venue: venue}, from_date, to_date) do
    orders = orders_with_identity(venue, from_date, to_date)
    by_identity = Enum.group_by(orders, &identity_key/1)
    identities = Map.keys(by_identity)
    first_seen = first_seen_by_identity(venue, identities)

    {new_count, returning_count} =
      Enum.reduce(identities, {0, 0}, fn key, {new_acc, returning_acc} ->
        if Date.compare(Map.fetch!(first_seen, key), from_date) != :lt do
          {new_acc + 1, returning_acc}
        else
          {new_acc, returning_acc + 1}
        end
      end)

    visit_counts = Map.new(by_identity, fn {key, orders} -> {key, length(orders)} end)

    %{
      new_count: new_count,
      returning_count: returning_count,
      visit_frequency: %{
        "1" => Enum.count(visit_counts, fn {_k, c} -> c == 1 end),
        "2-3" => Enum.count(visit_counts, fn {_k, c} -> c in 2..3 end),
        "4+" => Enum.count(visit_counts, fn {_k, c} -> c >= 4 end)
      },
      repeat_rate: repeat_rate(venue, to_date)
    }
  end

  defp orders_with_identity(venue, from_date, to_date) do
    Repo.all(
      from(o in Order,
        where:
          o.venue_id == ^venue.id and o.business_date >= ^from_date and
            o.business_date <= ^to_date and
            o.status in @history_statuses,
        select: %{customer_user_id: o.customer_user_id, guest_token: o.guest_token}
      )
    )
  end

  defp identity_key(%{customer_user_id: nil, guest_token: guest_token}), do: {:guest, guest_token}
  defp identity_key(%{customer_user_id: id}), do: {:account, id}

  defp first_seen_by_identity(venue, identities) do
    account_ids = for {:account, id} <- identities, do: id
    guest_tokens = for {:guest, token} <- identities, do: token

    accounts =
      if account_ids == [] do
        %{}
      else
        Repo.all(
          from(o in Order,
            where: o.venue_id == ^venue.id and o.customer_user_id in ^account_ids,
            group_by: o.customer_user_id,
            select: {o.customer_user_id, min(o.business_date)}
          )
        )
        |> Map.new(fn {id, date} -> {{:account, id}, date} end)
      end

    guests =
      if guest_tokens == [] do
        %{}
      else
        Repo.all(
          from(o in Order,
            where: o.venue_id == ^venue.id and o.guest_token in ^guest_tokens,
            group_by: o.guest_token,
            select: {o.guest_token, min(o.business_date)}
          )
        )
        |> Map.new(fn {token, date} -> {{:guest, token}, date} end)
      end

    Map.merge(accounts, guests)
  end

  defp repeat_rate(venue, to_date) do
    from_date = Date.add(to_date, -29)

    counts =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and not is_nil(o.customer_user_id) and
              o.business_date >= ^from_date and o.business_date <= ^to_date and
              o.status in @history_statuses,
          group_by: o.customer_user_id,
          select: count(o.id)
        )
      )

    case counts do
      [] -> nil
      _ -> Enum.count(counts, &(&1 >= 2)) / length(counts)
    end
  end

  @doc "Top customers by spend in the range — account holders only (privacy-safe: no guest_token/anonymous rows), owner-dashboard.md's own scoping."
  def top_customers(%Scope{venue: venue}, from_date, to_date, limit \\ 10) do
    zero = Money.new!(venue.currency, 0)

    rows =
      Repo.all(
        from(o in Order,
          where:
            o.venue_id == ^venue.id and not is_nil(o.customer_user_id) and
              o.business_date >= ^from_date and o.business_date <= ^to_date and
              o.status in @history_statuses,
          select: {o.customer_user_id, o.total}
        )
      )

    user_ids = rows |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    emails =
      Repo.all(
        from(u in Tabletap.Accounts.User, where: u.id in ^user_ids, select: {u.id, u.email}),
        skip_org_id: true
      )
      |> Map.new()

    rows
    |> Enum.group_by(fn {user_id, _total} -> user_id end, fn {_user_id, total} -> total end)
    |> Enum.map(fn {user_id, totals} ->
      %{
        customer_user_id: user_id,
        email: Map.get(emails, user_id, "—"),
        total: money_sum(totals, zero),
        order_count: length(totals)
      }
    end)
    |> Enum.sort_by(& &1.total, {:desc, Money})
    |> Enum.take(limit)
  end
end
