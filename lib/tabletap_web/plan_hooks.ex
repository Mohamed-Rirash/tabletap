defmodule TabletapWeb.PlanHooks do
  @moduledoc """
  Feature-gating for LiveViews, via `on_mount` (build-plan.md Feature 19)
  — checks `org.plan` through `Tabletap.Plans`, never a scattered `if`
  (code-standards.md), mirroring `ScopeHooks`' role-gating pattern.
  Always runs after `ScopeHooks` in a route's `on_mount` list, so
  `current_scope` is already assigned.
  """
  use TabletapWeb, :verified_routes

  import Phoenix.LiveView

  alias Tabletap.Plans

  @doc """
  Gates a LiveView behind a plan feature (`:inventory`,
  `:report_center`, `:org_comparison`). A trialing org always passes
  (`Plans.feature_enabled?/2` unlocks every tier during trial). An org
  whose current plan doesn't include the feature is redirected to the
  dashboard with a flash naming exactly which plan unlocks it — gating
  exists to sell the upgrade, not just to block the page.
  """
  def on_mount(feature, _params, _session, socket)
      when feature in [:inventory, :report_center, :org_comparison] do
    org = socket.assigns.current_scope.org

    if Plans.feature_enabled?(org, feature) do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, Plans.upgrade_message(feature))
       |> redirect(to: ~p"/dashboard")}
    end
  end
end
