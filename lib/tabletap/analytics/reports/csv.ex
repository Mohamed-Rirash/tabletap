defmodule Tabletap.Analytics.Reports.Csv do
  @moduledoc """
  Hand-rolled CSV rendering for every `Tabletap.Analytics.Reports`
  report shape (build-plan.md Feature 18) — shared by
  `Manager.Analytics.ReportsCsvController`'s on-demand download and
  `Workers.SendScheduledReports`' emailed attachment, so a subscribed
  report's numbers can never drift from the same report downloaded by
  hand. Same RFC-4180-lite escaping every other CSV export in the app
  uses (`Manager.RestockCsvController` and friends).
  """

  @doc "The full CSV document (header + rows) for `report_type`'s `data`, as returned by `Reports.generate/4`."
  def render(report_type, data) do
    {header, rows} = to_csv_rows(report_type, data)
    [header | rows] |> Enum.map_join("", &csv_line/1)
  end

  defp to_csv_rows(:revenue, data) do
    {["Date", "Orders", "Gross sales", "Net revenue", "Food cost"],
     Enum.map(data.days, fn day ->
       [
         Date.to_string(day.date),
         to_string(day.order_count),
         m(day.gross_sales),
         m(day.net_revenue),
         m(day.food_cost)
       ]
     end)}
  end

  defp to_csv_rows(:orders, orders) do
    {["Number", "Status", "Table", "Placed at", "Total"],
     Enum.map(orders, fn o ->
       [
         to_string(o.number),
         to_string(o.status),
         (o.table && o.table.number) || "",
         ts(o.placed_at),
         m(o.total)
       ]
     end)}
  end

  defp to_csv_rows(:successful_orders, rows) do
    {["Number", "Items", "Discounts", "Total", "Payment"],
     Enum.map(rows, fn row ->
       items = Enum.map_join(row.order.items, "; ", &"#{&1.qty}x #{&1.name_snapshot}")

       [
         to_string(row.order.number),
         items,
         to_string(length(row.discounts)),
         m(row.order.total),
         (row.payment && to_string(row.payment.provider)) || ""
       ]
     end)}
  end

  defp to_csv_rows(:payments, rows) do
    {["Provider", "Order", "Amount", "Refunded", "Net"],
     Enum.map(rows, fn row ->
       [
         to_string(row.payment.provider),
         (row.payment.order && to_string(row.payment.order.number)) || "",
         m(row.payment.amount),
         m(row.refunded),
         m(row.net)
       ]
     end)}
  end

  defp to_csv_rows(:cashier_daily_cash, rows) do
    {["Date", "Cashier", "Orders rung", "Cash taken", "Expected", "Counted", "Variance"],
     Enum.map(rows, fn row ->
       [
         Date.to_string(row.business_date),
         row.cashier_membership_id,
         to_string(row.cash_orders_rung),
         m(row.cash_taken),
         (row.expected_cash && m(row.expected_cash)) || "",
         (row.counted_cash && m(row.counted_cash)) || "",
         (row.variance && m(row.variance)) || ""
       ]
     end)}
  end

  defp to_csv_rows(:assisted_orders, rows) do
    {["Staff", "Count", "Total", "Dine-in", "Takeaway"],
     Enum.map(rows, fn row ->
       [
         row.membership_id,
         to_string(row.count),
         m(row.total),
         to_string(row.dine_in_count),
         to_string(row.takeaway_count)
       ]
     end)}
  end

  defp to_csv_rows(:inventory, data) do
    {["Ingredient", "Qty on hand", "Value", "Low stock"],
     Enum.map(data.stock_on_hand, fn row ->
       [row.name, Decimal.to_string(row.stock_qty), m(row.value), to_string(row.low_stock)]
     end)}
  end

  defp to_csv_rows(:menu_performance, data) do
    {["Item", "Sold", "Revenue", "Food cost", "Margin", "Rating"],
     Enum.map(data.rows, fn row ->
       [
         row.name,
         to_string(row.sold),
         m(row.revenue),
         m(row.food_cost),
         m(row.margin),
         rating(row.rating)
       ]
     end)}
  end

  defp to_csv_rows(:feedback, data) do
    {["Item", "Order", "Stars", "Comment"],
     Enum.map(data.ratings, fn r ->
       [
         r.order_item.menu_item.name,
         to_string(r.order_item.order.number),
         to_string(r.stars),
         r.comment || ""
       ]
     end)}
  end

  defp to_csv_rows(:employee_work, data) do
    {["Staff", "Started", "Ended", "Auto-closed"],
     Enum.map(data.shifts, fn shift ->
       [
         shift.membership.user.email,
         ts(shift.started_at),
         ts(shift.ended_at),
         to_string(shift.auto_closed)
       ]
     end)}
  end

  defp to_csv_rows(:customers, data) do
    {["Email", "Orders", "Total spend"],
     Enum.map(data.top_customers, fn c -> [c.email, to_string(c.order_count), m(c.total)] end)}
  end

  defp to_csv_rows(:day_close, rows) do
    {["Business date", "Closed at", "Post-close adjustment"],
     Enum.map(rows, fn row ->
       [
         Date.to_string(row.z_report.business_date),
         ts(row.z_report.closed_at),
         to_string(row.adjustment != nil)
       ]
     end)}
  end

  defp to_csv_rows(:profit, data) do
    {["Metric", "Value"],
     [
       ["Net revenue", m(data.net_revenue)],
       ["Food cost", m(data.food_cost)],
       ["Gross profit", m(data.gross_profit)],
       ["Purchases", m(data.purchases_total)],
       ["Wastage", m(data.wastage_total)],
       ["Platform fees", m(data.platform_fees)]
     ]}
  end

  defp m(%Money{} = money), do: money |> Money.to_decimal() |> Decimal.to_string()
  defp ts(nil), do: ""
  defp ts(%DateTime{} = dt), do: DateTime.to_string(dt)
  defp rating(nil), do: ""
  defp rating(%{avg: avg}), do: Decimal.to_string(Decimal.round(avg, 1))

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_escape/1) <> "\r\n"

  defp csv_escape(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end
end
