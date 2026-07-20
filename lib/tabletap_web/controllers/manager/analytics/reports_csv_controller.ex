defmodule TabletapWeb.Manager.Analytics.ReportsCsvController do
  @moduledoc """
  The Report Center's CSV export (build-plan.md Feature 18) — one
  controller, 13 report shapes, each reading the exact same
  `Tabletap.Analytics.Reports.generate/4` the LiveView renders on
  screen. Rendering itself lives in `Reports.Csv`, shared with
  `Workers.SendScheduledReports`' emailed attachment.
  """
  use TabletapWeb, :controller

  alias Tabletap.Analytics.Reports
  alias Tabletap.Analytics.Reports.Csv

  def show(conn, params) do
    scope = conn.assigns.current_scope
    report_type = resolve_report_type(params["report"])
    {from_date, to_date} = date_range(scope.venue, params)
    data = Reports.generate(report_type, scope, from_date, to_date)
    csv = Csv.render(report_type, data)

    conn
    |> put_resp_content_type("text/csv")
    |> put_resp_header(
      "content-disposition",
      "attachment; filename=\"#{report_type}-#{from_date}-to-#{to_date}.csv\""
    )
    |> send_resp(200, csv)
  end

  defp resolve_report_type(report) do
    atom = String.to_existing_atom(report)
    if atom in Reports.report_types(), do: atom, else: :revenue
  rescue
    ArgumentError -> :revenue
  end

  defp date_range(_venue, %{"from" => from, "to" => to})
       when from not in [nil, ""] and to not in [nil, ""] do
    {Date.from_iso8601!(from), Date.from_iso8601!(to)}
  end

  defp date_range(venue, _params) do
    today = Tabletap.Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end
end
