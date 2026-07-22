defmodule TabletapWeb.Api.OwnerController do
  @moduledoc """
  build-plan.md Feature 23 Commit 4 — `GET /api/v1/owner/dashboard`,
  wrapping the exact same `Analytics`/`Ordering` calls `Manager.
  DashboardLive` makes on mount. Manager/owner only (`:require_api_manager`
  pipeline), same reach as the web dashboard's own `:require_manager` gate.
  """
  use TabletapWeb, :controller

  alias Tabletap.{Analytics, Ordering}
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

  defp render_kitchen_order(scope, order) do
    Serializers.kitchen_order(order, Ordering.estimated_minutes(scope, order))
  end
end
