defmodule TabletapWeb.Api.OwnerController do
  @moduledoc """
  build-plan.md Feature 23 Commit 4 (dashboard) and Feature 25 (venue
  comparison) — wrapping the exact same `Analytics`/`Ordering` calls
  `Manager.DashboardLive`/`Manager.Analytics.VenueComparisonLive` make
  on mount. Manager/owner only (`:require_api_manager` pipeline), same
  reach as the web's own `:require_manager`/`:require_owner` gates.
  """
  use TabletapWeb, :controller

  alias Tabletap.{Analytics, Ordering, Plans, Tenants}
  alias TabletapWeb.Api.Serializers

  def dashboard(conn, _params) do
    scope = conn.assigns.current_scope

    json(conn, %{
      summary: Analytics.today_summary(scope),
      operations: Analytics.today_operations(scope),
      alerts: Analytics.today_alerts(scope),
      kitchen_orders:
        Enum.map(Ordering.list_kitchen_orders(scope), &render_kitchen_order(scope, &1))
    })
  end

  @doc """
  Cross-venue comparison — Pro-tier only, same
  `Plans.feature_enabled?/2` gate `TabletapWeb.PlanHooks` uses for the
  web's own `/analytics/venues` (a plain function, not LiveView-only, so
  a controller checks it directly rather than needing a plug-form
  port). Owner-only in practice too: `:require_api_manager` lets a
  manager reach this action, but `Manager.Analytics.VenueComparisonLive`
  is `:require_owner`-gated on the web, so a manager gets the same
  "forbidden" a manager hitting `/analytics/venues` gets there.
  """
  def venues(conn, params) do
    scope = conn.assigns.current_scope

    cond do
      scope.role != :owner ->
        conn |> put_status(:forbidden) |> json(%{error: "forbidden"})

      not Plans.feature_enabled?(scope.org, :org_comparison) ->
        conn |> put_status(:forbidden) |> json(%{error: "plan_upgrade_required"})

      true ->
        {from_date, to_date} = Tenants.range_dates(scope.venue, params["range"])
        rows = Analytics.org_comparison(scope, from_date, to_date)
        json(conn, %{venues: rows, totals: Analytics.org_totals(rows)})
    end
  end

  defp render_kitchen_order(scope, order) do
    Serializers.kitchen_order(order, Ordering.estimated_minutes(scope, order))
  end
end
