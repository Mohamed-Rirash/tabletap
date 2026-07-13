defmodule TabletapWeb.Manager.DashboardLive do
  @moduledoc """
  The venue dashboard a fresh signup lands on (build-plan.md Feature 03
  Verify step), now inside the manager sidebar shell (`Layouts.manager/1`).
  Content itself is still deliberately minimal — the real back office
  (live order feed, alerts, analytics) is owner-dashboard.md's job in
  Feature 18; this proves the tenancy loop end-to-end: a signed-in
  owner/manager sees their own venue, and only their own venue.

  Busy Mode (build-plan.md Feature 08, design-qa.md Q2 "one tap for
  manager") is the one exception to "deliberately minimal": its backend
  (`Tenants.pause_ordering/3` etc.) has no other manager-facing surface
  yet, and owner-dashboard.md's own "Today" screen (Feature 18) only
  *displays* Busy Mode status as one of many tiles — it doesn't invent
  the control. This is that control's home until Feature 18 gives it a
  richer one.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Tenants
  alias Tabletap.Tenants.Venue

  @eta_factors ["1", "1.5", "2"]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:dashboard}
      venues={@venues}
    >
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

      <div class="mt-10 rounded-box border border-base-300 bg-base-100 p-6">
        <div class="flex items-center justify-between flex-wrap gap-4">
          <div>
            <h2 class="font-semibold">{gettext("Busy Mode")}</h2>
            <p class="text-sm text-base-content/60 mt-1">{busy_mode_message(@current_scope.venue)}</p>
          </div>
          <span class={["badge", busy_mode_badge_class(@current_scope.venue)]}>
            {busy_mode_badge_label(@current_scope.venue)}
          </span>
        </div>

        <div class="mt-4 flex flex-wrap gap-2">
          <button
            :if={Venue.paused?(@current_scope.venue)}
            type="button"
            phx-click="resume_ordering"
            class="btn btn-sm btn-primary"
          >
            {gettext("Resume ordering")}
          </button>
          <button
            :if={!Venue.paused?(@current_scope.venue)}
            type="button"
            phx-click="pause_ordering"
            phx-value-minutes="20"
            class="btn btn-sm btn-outline"
          >
            {gettext("Pause 20 min")}
          </button>
          <button
            :if={!Venue.paused?(@current_scope.venue)}
            type="button"
            phx-click="pause_ordering"
            phx-value-minutes="40"
            class="btn btn-sm btn-outline"
          >
            {gettext("Pause 40 min")}
          </button>
          <button
            :if={!Venue.paused?(@current_scope.venue)}
            type="button"
            phx-click="pause_ordering"
            phx-value-minutes="indefinite"
            class="btn btn-sm btn-outline"
          >
            {gettext("Pause until reopened")}
          </button>
        </div>

        <div class="mt-4 pt-4 border-t border-base-300">
          <p class="text-sm font-medium mb-2">{gettext("Kitchen speed")}</p>
          <div class="flex flex-wrap gap-2">
            <button
              :for={factor <- @eta_factors}
              type="button"
              phx-click="set_eta_inflation"
              phx-value-factor={factor}
              class={[
                "btn btn-sm",
                eta_active?(@current_scope.venue, factor) && "btn-primary",
                !eta_active?(@current_scope.venue, factor) && "btn-outline"
              ]}
            >
              {eta_factor_label(factor)}
            </button>
          </div>
        </div>
      </div>

      <div class="mt-6 rounded-box border border-base-300 bg-base-100 p-8 text-center">
        <.icon name="hero-check-circle" class="size-10 text-success mx-auto" />
        <h2 class="mt-3 font-semibold text-lg">{gettext("Your venue is set up")}</h2>
        <p class="mt-2 text-base-content/60 max-w-md mx-auto">
          {gettext(
            "Live orders and alerts land as the next build phases ship. Your trial is active — no card needed to keep exploring."
          )}
        </p>
      </div>
    </Layouts.manager>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:trial_days_left, trial_days_left(scope.org))
     |> assign(:eta_factors, @eta_factors)}
  end

  @impl true
  def handle_event("pause_ordering", %{"minutes" => "indefinite"}, socket) do
    {:noreply, do_pause(socket, :indefinite)}
  end

  def handle_event("pause_ordering", %{"minutes" => minutes}, socket) do
    {:noreply, do_pause(socket, String.to_integer(minutes))}
  end

  def handle_event("resume_ordering", _params, socket) do
    scope = socket.assigns.current_scope
    {:ok, venue} = Tenants.resume_ordering(scope, scope.venue)
    {:noreply, socket |> put_venue(venue) |> broadcast_menu_updated()}
  end

  def handle_event("set_eta_inflation", %{"factor" => factor}, socket) do
    scope = socket.assigns.current_scope
    {:ok, venue} = Tenants.set_eta_inflation(scope, scope.venue, Decimal.new(factor))
    {:noreply, socket |> put_venue(venue) |> broadcast_menu_updated()}
  end

  defp do_pause(socket, minutes_or_indefinite) do
    scope = socket.assigns.current_scope
    {:ok, venue} = Tenants.pause_ordering(scope, scope.venue, minutes_or_indefinite)
    socket |> put_venue(venue) |> broadcast_menu_updated()
  end

  defp put_venue(socket, venue) do
    assign(socket, :current_scope, %{socket.assigns.current_scope | venue: venue})
  end

  # Same topic/event `Manager.MenuLive` already broadcasts on — reused
  # here so `Public.MenuLive`'s existing subscription picks up a Busy
  # Mode change live, with no second PubSub topic to maintain.
  defp broadcast_menu_updated(socket) do
    Phoenix.PubSub.broadcast(
      Tabletap.PubSub,
      "venue:#{socket.assigns.current_scope.venue.id}:menu",
      :menu_updated
    )

    socket
  end

  defp eta_active?(venue, factor_string) do
    current = venue.eta_inflation_factor || Decimal.new(1)
    Decimal.equal?(current, Decimal.new(factor_string))
  end

  defp eta_factor_label("1"), do: gettext("Normal speed")
  defp eta_factor_label("1.5"), do: gettext("Slower (1.5×)")
  defp eta_factor_label("2"), do: gettext("Much slower (2×)")

  defp busy_mode_badge_class(venue) do
    if Venue.paused?(venue), do: "badge-warning", else: "badge-success"
  end

  defp busy_mode_badge_label(venue) do
    if Venue.paused?(venue), do: gettext("Paused"), else: gettext("Open")
  end

  defp busy_mode_message(venue) do
    cond do
      not Venue.paused?(venue) ->
        gettext("Taking orders normally.")

      venue.ordering_paused_until == Venue.indefinite_pause_sentinel() ->
        gettext("Paused until you resume it.")

      true ->
        gettext("Paused until %{time}.", time: format_local_time(venue))
    end
  end

  defp format_local_time(venue) do
    venue.ordering_paused_until
    |> DateTime.shift_zone!(venue.timezone)
    |> Calendar.strftime("%H:%M")
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
