defmodule TabletapWeb.Admin.TenantsLive do
  @moduledoc """
  Platform-admin tenants list (build-plan.md Feature 19;
  role-features.md "Platform Admin (us) — Tenant management: all
  orgs/venues, subscription states, order volumes"). Read-only, like
  every admin screen this feature builds — no action here writes to a
  tenant's data.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Admin
  alias Tabletap.Plans

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <h1 class="text-2xl font-bold mb-4">Tenants</h1>
      <table class="table table-sm">
        <thead>
          <tr>
            <th>Org</th>
            <th>Plan</th>
            <th>Status</th>
            <th>Trial</th>
            <th>Venues</th>
            <th>Orders</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @tenants}>
            <td>
              <.link navigate={~p"/admin/tenants/#{row.org.id}"} class="link">{row.org.name}</.link>
            </td>
            <td>{Plans.name(row.org.plan)}</td>
            <td>
              <span class={["badge", status_badge_class(row.org.subscription_status)]}>
                {row.org.subscription_status}
              </span>
            </td>
            <td class="tabular-nums">{trial_days_left(row.org)}</td>
            <td class="tabular-nums">{row.venue_count}</td>
            <td class="tabular-nums">{row.order_count}</td>
          </tr>
          <tr :if={@tenants == []}>
            <td colspan="6" class="text-center text-base-content/50 py-4">No tenants yet.</td>
          </tr>
        </tbody>
      </table>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :tenants, Admin.list_tenants())}
  end

  defp trial_days_left(%{subscription_status: :trialing, trial_ends_at: trial_ends_at}) do
    max(DateTime.diff(trial_ends_at, DateTime.utc_now(), :day), 0)
  end

  defp trial_days_left(_org), do: "—"

  defp status_badge_class(:active), do: "badge-success"
  defp status_badge_class(:trialing), do: "badge-info"
  defp status_badge_class(:past_due), do: "badge-warning"
  defp status_badge_class(:canceled), do: "badge-error"
end
