defmodule TabletapWeb.Manager.Analytics.StaffLive do
  @moduledoc """
  Owner-dashboard.md Screen 5 — Staff & Work Analytics (build-plan.md
  Feature 18), "measured, not guessed." Reads
  `Tabletap.Analytics.staff_summary/3` — per-waiter orders served, avg
  accept/serve time, unserveable flags, tables covered, avg rating, and
  hours on shift, always rendered **alongside the venue's own average**
  (design-qa.md's fairness guardrail: never a naked leaderboard — a
  waiter covering the patio on a dead Tuesday isn't "slow"). Kitchen
  avg prep time is venue-wide (no per-person attribution exists in the
  schema). Cashier transactions + cash variance come from `Payments`'
  own tables directly — variance only exists once a Z-report closes it.
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
      active_nav={:analytics_staff}
      venues={@venues}
    >
      <div class="flex items-center justify-between flex-wrap gap-4 mb-6">
        <h1 class="text-2xl font-bold">{gettext("Staff & Work")}</h1>
        <.range_picker range={@range} />
      </div>

      <div class="rounded-box border border-base-300 bg-base-100 p-4 mb-6 overflow-x-auto">
        <div class="flex items-center justify-between mb-3">
          <h2 class="font-semibold">{gettext("Waiters")}</h2>
          <p :if={@summary.waiters != []} class="text-xs text-base-content/50">
            {gettext("Venue average: %{avg} orders served",
              avg: Float.round(@summary.venue_avg_orders_served, 1)
            )}
          </p>
        </div>
        <p :if={@summary.waiters == []} class="text-sm text-base-content/50">
          {gettext("No waiter-served orders in this period.")}
        </p>
        <table :if={@summary.waiters != []} class="table table-sm">
          <thead>
            <tr>
              <th>{gettext("Waiter")}</th>
              <th>{gettext("Orders")}</th>
              <th>{gettext("Avg accept")}</th>
              <th>{gettext("Avg serve")}</th>
              <th>{gettext("Unserveable")}</th>
              <th>{gettext("Tables")}</th>
              <th>{gettext("Rating")}</th>
              <th>{gettext("Hours")}</th>
              <th>{gettext("Orders/hr")}</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @waiters_with_names}>
              <td class="font-medium">{row.email}</td>
              <td class="tabular-nums">{row.orders_served}</td>
              <td class="tabular-nums">{seconds_label(row.avg_accept_seconds)}</td>
              <td class="tabular-nums">{seconds_label(row.avg_serve_seconds)}</td>
              <td class="tabular-nums">{row.unserveable_count}</td>
              <td class="tabular-nums">{row.tables_covered}</td>
              <td class="tabular-nums">{rating_label(row.avg_rating)}</td>
              <td class="tabular-nums">{Float.round(row.hours_on_shift, 1)}</td>
              <td class="tabular-nums">{orders_per_hour(row)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div class="grid gap-6 lg:grid-cols-2">
        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <p class="text-xs font-medium text-base-content/60">{gettext("Kitchen avg prep time")}</p>
          <p class="mt-1 text-2xl font-bold tabular-nums">
            {seconds_label(@summary.kitchen_avg_prep_seconds)}
          </p>
          <p class="text-xs text-base-content/50 mt-0.5">
            {gettext("accepted → ready, venue-wide (no per-kitchen-staff attribution exists)")}
          </p>
        </div>

        <div class="rounded-box border border-base-300 bg-base-100 p-4">
          <h2 class="font-semibold mb-3">{gettext("Cashiers")}</h2>
          <p :if={@cashiers_with_names == []} class="text-sm text-base-content/50">
            {gettext("No cashier transactions in this period.")}
          </p>
          <ul :if={@cashiers_with_names != []} class="text-sm space-y-1.5">
            <li :for={row <- @cashiers_with_names} class="flex items-center justify-between">
              <span class="truncate">{row.email}</span>
              <span class="tabular-nums shrink-0 ml-2">
                {row.transaction_count} tx ·
                <.money amount={row.total_variance} locale={@locale} /> {gettext("variance")}
              </span>
            </li>
          </ul>
        </div>
      </div>
    </Layouts.manager>
    """
  end

  attr :range, :string, required: true

  defp range_picker(assigns) do
    ~H"""
    <div class="join">
      <.link
        patch={~p"/analytics/staff?#{[range: "today"]}"}
        class={["btn btn-sm join-item", @range == "today" && "btn-primary"]}
      >
        {gettext("Today")}
      </.link>
      <.link
        patch={~p"/analytics/staff?#{[range: "7d"]}"}
        class={["btn btn-sm join-item", @range == "7d" && "btn-primary"]}
      >
        {gettext("7d")}
      </.link>
      <.link
        patch={~p"/analytics/staff?#{[range: "30d"]}"}
        class={["btn btn-sm join-item", @range == "30d" && "btn-primary"]}
      >
        {gettext("30d")}
      </.link>
    </div>
    """
  end

  defp seconds_label(nil), do: "—"

  defp seconds_label(seconds) do
    minutes = seconds / 60
    gettext("%{minutes}m", minutes: Float.round(minutes, 1))
  end

  defp rating_label(nil), do: "—"
  defp rating_label(avg), do: "#{Float.round(avg, 1)}★"

  defp orders_per_hour(%{hours_on_shift: hours}) when hours <= 0, do: "—"

  defp orders_per_hour(%{orders_served: orders, hours_on_shift: hours}),
    do: Float.round(orders / hours, 1)

  ## Mount / params

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:locale, scope.venue.locale)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    scope = socket.assigns.current_scope
    range = if params["range"] in @ranges, do: params["range"], else: "7d"
    {from_date, to_date} = range_dates(scope.venue, range)

    summary = Analytics.staff_summary(scope, from_date, to_date)

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign(:summary, summary)
     |> assign(:waiters_with_names, with_names(scope, summary.waiters, :waiter_membership_id))
     |> assign(:cashiers_with_names, with_names(scope, summary.cashiers, :cashier_membership_id))}
  end

  defp with_names(scope, rows, key) do
    membership_ids = Enum.map(rows, &Map.fetch!(&1, key))
    memberships = Tenants.list_memberships(scope, membership_ids) |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn row ->
      membership = memberships[Map.fetch!(row, key)]
      Map.put(row, :email, membership && membership.user.email)
    end)
  end

  defp range_dates(venue, "today") do
    today = Tenants.business_date(venue)
    {today, today}
  end

  defp range_dates(venue, "30d") do
    today = Tenants.business_date(venue)
    {Date.add(today, -29), today}
  end

  defp range_dates(venue, _seven_day) do
    today = Tenants.business_date(venue)
    {Date.add(today, -6), today}
  end
end
