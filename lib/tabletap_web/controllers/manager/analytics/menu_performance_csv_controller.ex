defmodule TabletapWeb.Manager.Analytics.MenuPerformanceCsvController do
  @moduledoc """
  The Menu Performance screen's CSV export (build-plan.md Feature 18) —
  same `Analytics.menu_performance/3` read the LiveView table renders,
  same hand-rolled CSV pattern as `Manager.RestockCsvController`.
  """
  use TabletapWeb, :controller

  alias Tabletap.Analytics

  def show(conn, params) do
    scope = conn.assigns.current_scope
    {from_date, to_date} = date_range(scope.venue, params)

    rows =
      Analytics.menu_performance(scope, from_date, to_date)
      |> Enum.sort_by(& &1.revenue, {:desc, Money})

    csv =
      [
        [
          "Item",
          "Sold",
          "Revenue",
          "Food cost",
          "Margin",
          "Margin %",
          "Avg rating",
          "Rating count",
          "Sellout days"
        ]
        | Enum.map(rows, &csv_row/1)
      ]
      |> Enum.map_join("", &csv_line/1)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"menu-performance-#{from_date}-to-#{to_date}.csv\""
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

  defp csv_row(row) do
    [
      row.name,
      to_string(row.sold),
      money_string(row.revenue),
      money_string(row.food_cost),
      money_string(row.margin),
      if(row.margin_pct, do: Decimal.to_string(Decimal.round(row.margin_pct, 1)), else: ""),
      if(row.rating, do: Decimal.to_string(Decimal.round(row.rating.avg, 1)), else: ""),
      if(row.rating, do: to_string(row.rating.count), else: ""),
      to_string(row.sellout_days)
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
