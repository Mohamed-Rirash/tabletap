defmodule TabletapWeb.Manager.DashboardLive do
  @moduledoc """
  The empty venue dashboard a fresh signup lands on (build-plan.md Feature
  03 Verify step). Deliberately minimal — the real back office (nav shell,
  live order feed, alerts) is owner-dashboard.md's job in Feature 18; this
  just proves the tenancy loop end-to-end: a signed-in owner/manager sees
  their own venue, and only their own venue.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Tenants

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-between flex-wrap gap-4">
        <div>
          <p class="text-xs font-semibold uppercase tracking-wide text-base-content/50">
            {role_label(@current_scope.role)} · {@current_scope.org.name}
          </p>
          <h1 class="text-2xl font-bold">{@current_scope.venue.name}</h1>
        </div>

        <div :if={@trial_days_left} class="flex items-center gap-3">
          <span class="badge badge-outline">{trial_days_left_label(@trial_days_left)}</span>
        </div>
      </div>

      <div :if={length(@venues) > 1} class="mt-6">
        <.form for={%{}} as={:venue} method="post" action={~p"/venues/switch"}>
          <label class="fieldset">
            <span class="label mb-1">{gettext("Venue")}</span>
            <select
              name="venue_id"
              class="select select-bordered"
              onchange="this.form.requestSubmit()"
            >
              <option
                :for={venue <- @venues}
                value={venue.id}
                selected={venue.id == @current_scope.venue.id}
              >
                {venue.name}
              </option>
            </select>
          </label>
        </.form>
      </div>

      <div class="mt-10 rounded-box border border-base-300 bg-base-100 p-8 text-center">
        <.icon name="hero-check-circle" class="size-10 text-success mx-auto" />
        <h2 class="mt-3 font-semibold text-lg">{gettext("Your venue is set up")}</h2>
        <p class="mt-2 text-base-content/60 max-w-md mx-auto">
          {gettext(
            "Menu, tables, staff, and live orders land as the next build phases ship. Your trial is active — no card needed to keep exploring."
          )}
        </p>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:trial_days_left, trial_days_left(scope.org))}
  end

  defp trial_days_left(%{subscription_status: :trialing, trial_ends_at: trial_ends_at}) do
    days = DateTime.diff(trial_ends_at, DateTime.utc_now(), :day)
    max(days, 0)
  end

  defp trial_days_left(_org), do: nil

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:manager), do: gettext("Manager")
  defp role_label(:waiter), do: gettext("Waiter")
  defp role_label(:cashier), do: gettext("Cashier")
  defp role_label(:kitchen), do: gettext("Kitchen")

  defp trial_days_left_label(days) do
    ngettext("%{count} day left in trial", "%{count} days left in trial", days)
  end
end
