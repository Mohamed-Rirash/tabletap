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
  alias Tabletap.Feedback.ItemRating
  alias Tabletap.Inventory.{Ingredient, RecipeLine, StockMovement}
  alias Tabletap.Ordering.{Order, OrderDiscount, OrderItem}
  alias Tabletap.Payments.{Payment, Refund}
  alias Tabletap.Repo
  alias Tabletap.Staffing.Shift
  alias Tabletap.Tenants

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
end
