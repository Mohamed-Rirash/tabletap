defmodule TabletapWeb.Manager.RestockCsvController do
  @moduledoc """
  The restock report's CSV export (build-plan.md Feature 13 "restock
  report ... CSV export"). A plain controller, not a LiveView — this is
  a raw file response, not a page. Hand-rolled (no CSV dependency —
  code-standards.md's "does Elixir already do this?" check: five columns
  of already-safe data needs no library).
  """
  use TabletapWeb, :controller

  alias Tabletap.Inventory

  def show(conn, _params) do
    rows = Inventory.restock_report(conn.assigns.current_scope)

    csv =
      [
        ["Ingredient", "Unit", "Current", "Threshold", "Suggested reorder"]
        | Enum.map(rows, &csv_row/1)
      ]
      |> Enum.map_join("", &csv_line/1)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header("content-disposition", "attachment; filename=\"restock-report.csv\"")
    |> send_resp(200, csv)
  end

  defp csv_row(%{
         ingredient: ingredient,
         current: current,
         threshold: threshold,
         suggested: suggested
       }) do
    [
      ingredient.name,
      to_string(ingredient.unit),
      Decimal.to_string(current),
      Decimal.to_string(threshold),
      Decimal.to_string(suggested)
    ]
  end

  defp csv_line(fields), do: Enum.map_join(fields, ",", &csv_escape/1) <> "\r\n"

  # Minimal RFC 4180 escaping: quote any field containing a comma,
  # quote, or newline, doubling internal quotes.
  defp csv_escape(field) do
    if String.contains?(field, [",", "\"", "\n"]) do
      "\"" <> String.replace(field, "\"", "\"\"") <> "\""
    else
      field
    end
  end
end
