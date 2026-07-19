defmodule TabletapWeb.Manager.Analytics.RevenueCsvController do
  @moduledoc """
  The Revenue & Sales screen's CSV export (build-plan.md Feature 18).
  Reads the exact same `Analytics.range_summary/3` the LiveView charts
  read — never a second query — so the download always matches what's
  on screen. Hand-rolled CSV, same pattern as
  `Manager.RestockCsvController` (code-standards.md: no dependency for
  a handful of already-safe columns).
  """
  use TabletapWeb, :controller

  alias Tabletap.Analytics

  def show(conn, params) do
    scope = conn.assigns.current_scope
    {from_date, to_date} = date_range(scope.venue, params)
    days = Analytics.range_summary(scope, from_date, to_date)

    csv =
      [
        [
          "Date",
          "Orders",
          "Gross sales",
          "Discounts",
          "Refunds",
          "Net revenue",
          "Avg check",
          "Food cost"
        ]
        | Enum.map(days, &csv_row/1)
      ]
      |> Enum.map_join("", &csv_line/1)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"revenue-#{from_date}-to-#{to_date}.csv\""
    )
    |> send_resp(200, csv)
  end

  defp date_range(_venue, %{"from" => from, "to" => to})
       when from not in [nil, ""] and to not in [nil, ""] do
    {Date.from_iso8601!(from), Date.from_iso8601!(to)}
  end

  defp date_range(venue, _params) do
    today = Tabletap.Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end

  defp csv_row(day) do
    [
      Date.to_string(day.date),
      to_string(day.order_count),
      money_string(day.gross_sales),
      money_string(day.discounts),
      money_string(day.refunds),
      money_string(day.net_revenue),
      if(day.avg_check, do: money_string(day.avg_check), else: ""),
      money_string(day.food_cost)
    ]
  end

  defp money_string(%Money{} = money), do: money |> Money.to_decimal() |> Decimal.to_string()

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_escape/1) <> "\r\n"

  defp csv_escape(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end
end
