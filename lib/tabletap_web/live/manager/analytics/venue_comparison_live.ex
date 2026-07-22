defmodule TabletapWeb.Manager.Analytics.VenueComparisonLive do
  @moduledoc """
  Owner-dashboard.md's "Org View (Owner only, multi-venue)"
  (build-plan.md Feature 18): every venue in the org side by side for
  the same period — revenue, orders, avg check, food cost %, avg
  rating, refund rate — plus org totals and subscription status per
  venue. Owner-only (`ScopeHooks.require_owner`, same `:owner`
  live_session `Manager.PaymentSettingsLive` already uses) — a manager
  sees only their own venue everywhere else in this app, and this
  screen is the one place that would leak sibling-venue numbers to
  them.

  Money never sums across venues on this screen (`Analytics.org_totals/1`
  only totals currency-free fields) — a Pro-tier org can run venues in
  different currencies, and design-qa.md Q53 locks currency per venue,
  not per org.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics
  alias Tabletap.Tenants

  @ranges ~w(today 7d 30d)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:analytics_org}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <div>
          <h1 class="text-2xl font-bold">{gettext("Org View")}</h1>
          <p class="text-sm text-base-content/60">{@current_scope.org.name}</p>
        </div>
        <.range_picker range={@range} />
      </div>

      <div class="grid grid-cols-2 gap-3 mb-6">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("Venues")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">{@totals.venue_count}</p>
        </div>
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("Orders (org-wide)")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">{@totals.order_count}</p>
        </div>
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 overflow-x-auto">
        <table class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Venue")}</th>
              <th>{gettext("Revenue")}</th>
              <th>{gettext("Orders")}</th>
              <th>{gettext("Avg check")}</th>
              <th>{gettext("Food cost %")}</th>
              <th>{gettext("Rating")}</th>
              <th>{gettext("Refund rate")}</th>
              <th>{gettext("Subscription")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @rows} id={"venue-#{row.venue_id}"}>
              <td>
                <.link
                  navigate={~p"/venues/#{row.venue_slug}/menu"}
                  target="_blank"
                  class="font-medium hover:text-brand"
                >
                  {row.venue_name}
                </.link>
              </td>
              <td class="tabular-nums">{format_money(row.net_revenue, nil)}</td>
              <td class="tabular-nums">{row.order_count}</td>
              <td class="tabular-nums">
                {if row.avg_check, do: format_money(row.avg_check, nil), else: "—"}
              </td>
              <td class="tabular-nums">
                {if row.food_cost_pct, do: "#{Decimal.round(row.food_cost_pct, 1)}%", else: "—"}
              </td>
              <td class="tabular-nums">
                {if row.avg_rating, do: "#{Float.round(row.avg_rating, 1)}★", else: "—"}
              </td>
              <td class="tabular-nums">
                {if row.refund_rate, do: "#{Float.round(row.refund_rate * 100, 1)}%", else: "—"}
              </td>
              <td>
                <span class={["badge badge-sm", subscription_badge_class(row.subscription_status)]}>
                  {row.subscription_status}
                </span>
              </td>
            </tr>
            <tr :if={@rows == []}>
              <td colspan="8" class="text-center text-base-content/50 py-6">
                {gettext("No venues yet.")}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.manager>
    """
  end

  attr :range, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        patch={~p"/analytics/venues?#{[range: "today"]}"}
        class={["btn btn-sm join-item", @range == "today" && "btn-primary"]}
      >
        {gettext("Today")}
      </.link>
      <.link
        patch={~p"/analytics/venues?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/venues?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
    </div>
    """
  end

  defp subscription_badge_class(:trialing), do: "badge-info"
  defp subscription_badge_class(:active), do: "badge-success"
  defp subscription_badge_class(:past_due), do: "badge-warning"
  defp subscription_badge_class(:canceled), do: "badge-error"

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    range = if params["range"] in @ranges, do: params["range"], else: "7d"
    {from_date, to_date} = Tenants.range_dates(scope.venue, range)

    rows = Analytics.org_comparison(scope, from_date, to_date)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:rows, rows)
     |> assign(:totals, Analytics.org_totals(rows))}
  end
end
