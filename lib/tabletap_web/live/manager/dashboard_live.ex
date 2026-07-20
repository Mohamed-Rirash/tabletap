defmodule TabletapWeb.Manager.DashboardLive do
  @moduledoc """
  The venue dashboard a fresh signup lands on (build-plan.md Feature 03
  Verify step), now owner-dashboard.md's Screen 1 — "walk in the door
  and know everything," auto-updating, no refresh (build-plan.md
  Feature 18). Every tile/alert reuses `Tabletap.Analytics`'s own live
  queries (`today_summary/1`, `today_operations/1`, `today_alerts/1`)
  rather than a parallel calculation, so this page and the eventual
  Revenue & Sales screen (reading the same day once it's rolled up)
  can never disagree.

  Busy Mode (build-plan.md Feature 08, design-qa.md Q2 "one tap for
  manager") predates this screen and stays exactly where it was — Screen
  1 only *displays* its status as one of the tiles, it doesn't duplicate
  the control.

  Reloads the whole snapshot on any relevant broadcast rather than
  patching individual tiles — `venue:<id>:orders` (`{:order_updated,
  _}`), `venue:<id>:menu` (`:menu_updated`, covers Busy Mode/sold-out/
  availability), and `venue:<id>:staff` (Presence diffs, on-shift
  counts). Cheap enough per venue that a full recompute on every event
  is simpler and more obviously correct than tracking which tiles a
  given event could possibly affect.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Analytics
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
      </div>

      <.today_tiles today={@today} ops={@ops} locale={@current_scope.venue.locale} />

      <div class="mt-6 grid gap-6 lg:grid-cols-3">
        <.floor_strip class="lg:col-span-2" orders={@open_orders} delayed_ids={@delayed_order_ids} />
        <.alert_feed alerts={@alerts} />
      </div>

      <div class="mt-6 rounded-box border border-base-300 bg-base-100 p-6">
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
    </Layouts.manager>
    """
  end

  ## Screen 1 tiles (owner-dashboard.md)

  attr :today, :map, required: true
  attr :ops, :map, required: true
  attr :locale, :string, required: true

  defp today_tiles(assigns) do
    ~H"""
    <div class="mt-6 grid grid-cols-2 sm:grid-cols-4 gap-3">
      <.tile label={gettext("Revenue today")}>
        <.money amount={@today.net_revenue} locale={@locale} />
      </.tile>
      <.tile label={gettext("Orders today")}>
        {@today.order_count}
        <:sub>{channel_breakdown_label(@today.channel_mix)}</:sub>
      </.tile>
      <.tile label={gettext("Average check")}>
        {if @today.avg_check, do: format_money(@today.avg_check, @locale), else: "—"}
      </.tile>
      <.tile label={gettext("Open orders now")}>
        {@ops.open_order_count}
        <:sub :if={@ops.oldest_open_order_minutes}>
          {gettext("oldest %{minutes}m", minutes: @ops.oldest_open_order_minutes)}
        </:sub>
      </.tile>
      <.tile label={gettext("Live ETA quoted")}>
        {gettext("~%{minutes} min", minutes: @ops.quoted_eta_minutes)}
      </.tile>
      <.tile label={gettext("On shift now")}>
        {@ops.on_shift.waiters + @ops.on_shift.cashiers + @ops.on_shift.kitchen}
        <:sub>
          {gettext("%{w} waiter · %{c} cashier · %{k} kitchen",
            w: @ops.on_shift.waiters,
            c: @ops.on_shift.cashiers,
            k: @ops.on_shift.kitchen
          )}
        </:sub>
      </.tile>
    </div>
    """
  end

  attr :label, :string, required: true
  slot :inner_block, required: true
  slot :sub

  defp tile(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <p class="text-xs font-medium text-base-content/60">{@label}</p>
      <p class="mt-1 text-2xl font-bold tabular-nums">{render_slot(@inner_block)}</p>
      <p :for={sub <- @sub} class="mt-0.5 text-xs text-base-content/50">{render_slot(sub)}</p>
    </div>
    """
  end

  attr :class, :any, default: nil
  attr :orders, :list, required: true
  attr :delayed_ids, :any, required: true

  defp floor_strip(assigns) do
    ~H"""
    <div class={["rounded-box border border-base-300 bg-base-100 p-4", @class]}>
      <h2 class="font-semibold mb-3">{gettext("Live floor")}</h2>
      <p :if={@orders == []} class="text-sm text-base-content/50">
        {gettext("No open orders right now.")}
      </p>
      <div :if={@orders != []} class="flex flex-wrap gap-2">
        <span
          :for={order <- @orders}
          class={[
            "badge gap-1.5",
            status_badge_class(order.status),
            MapSet.member?(@delayed_ids, order.id) && "motion-safe:animate-pulse"
          ]}
        >
          {order_chip_label(order)} · {status_label(order.status)}
        </span>
      </div>
    </div>
    """
  end

  attr :alerts, :map, required: true

  defp alert_feed(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4">
      <h2 class="font-semibold mb-3">{gettext("Alerts")}</h2>
      <ul class="space-y-2 text-sm">
        <.alert_row
          :if={@alerts.low_stock != []}
          icon="hero-cube"
          navigate={~p"/inventory"}
          text={
            ngettext(
              "%{count} ingredient low on stock",
              "%{count} ingredients low on stock",
              length(@alerts.low_stock)
            )
          }
        />
        <.alert_row
          :if={@alerts.delayed_orders != []}
          icon="hero-clock"
          navigate={~p"/kitchen"}
          text={
            ngettext(
              "%{count} order running late",
              "%{count} orders running late",
              length(@alerts.delayed_orders)
            )
          }
        />
        <.alert_row
          :if={@alerts.unaccepted_orders != []}
          icon="hero-exclamation-triangle"
          navigate={~p"/orders"}
          text={
            ngettext(
              "%{count} order not yet accepted",
              "%{count} orders not yet accepted",
              length(@alerts.unaccepted_orders)
            )
          }
        />
        <.alert_row
          :if={@alerts.flagged_orders != []}
          icon="hero-flag"
          navigate={~p"/orders"}
          text={
            ngettext(
              "%{count} order needs attention",
              "%{count} orders need attention",
              length(@alerts.flagged_orders)
            )
          }
        />
        <.alert_row
          :if={@alerts.sold_out_items != []}
          icon="hero-x-circle"
          navigate={~p"/menu"}
          text={
            ngettext(
              "%{count} item sold out",
              "%{count} items sold out",
              length(@alerts.sold_out_items)
            )
          }
        />
        <.alert_row
          :if={@alerts.failed_payments != []}
          icon="hero-credit-card"
          navigate={~p"/orders"}
          text={
            ngettext(
              "%{count} failed payment",
              "%{count} failed payments",
              length(@alerts.failed_payments)
            )
          }
        />
        <.alert_row
          :if={@alerts.subscription_issue}
          icon="hero-banknotes"
          navigate={~p"/dashboard"}
          text={subscription_issue_label(@alerts.subscription_issue)}
        />
      </ul>
      <p
        :if={
          @alerts.low_stock == [] and @alerts.delayed_orders == [] and @alerts.unaccepted_orders == [] and
            @alerts.flagged_orders == [] and @alerts.sold_out_items == [] and
            @alerts.failed_payments == [] and
            is_nil(@alerts.subscription_issue)
        }
        class="text-sm text-base-content/50"
      >
        {gettext("Nothing needs your attention.")}
      </p>
    </div>
    """
  end

  attr :icon, :string, required: true
  attr :navigate, :string, required: true
  attr :text, :string, required: true

  defp alert_row(assigns) do
    ~H"""
    <li>
      <.link navigate={@navigate} class="flex items-center gap-2 hover:text-brand">
        <.icon name={@icon} class="size-4 shrink-0 text-warning" />
        {@text}
      </.link>
    </li>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:orders")
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:menu")
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:staff")
    end

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:venues, Tenants.list_venues(scope))
     |> assign(:eta_factors, @eta_factors)
     |> load_today()}
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

  # Every relevant broadcast just triggers a full snapshot reload rather
  # than patching individual tiles — see this module's own moduledoc for
  # why that's the simpler, more obviously-correct choice here.
  @impl true
  def handle_info({:order_updated, _order_id}, socket), do: {:noreply, load_today(socket)}
  def handle_info(:menu_updated, socket), do: {:noreply, load_today(socket)}
  def handle_info(%{event: "presence_diff"}, socket), do: {:noreply, load_today(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

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

  defp role_label(:owner), do: gettext("Owner")
  defp role_label(:manager), do: gettext("Manager")
  defp role_label(:waiter), do: gettext("Waiter")
  defp role_label(:cashier), do: gettext("Cashier")
  defp role_label(:kitchen), do: gettext("Kitchen")

  ## Screen 1 data loading

  defp load_today(socket) do
    scope = socket.assigns.current_scope
    alerts = Analytics.today_alerts(scope)

    socket
    |> assign(:today, Analytics.today_summary(scope))
    |> assign(:ops, Analytics.today_operations(scope))
    |> assign(:alerts, alerts)
    |> assign(:open_orders, Tabletap.Ordering.list_kitchen_orders(scope))
    |> assign(:delayed_order_ids, MapSet.new(alerts.delayed_orders, & &1.id))
  end

  defp channel_breakdown_label(channel_mix) when map_size(channel_mix) == 0,
    do: gettext("no orders yet")

  defp channel_breakdown_label(channel_mix) do
    Enum.map_join([:dine_in, :takeaway, :counter], " · ", fn kind ->
      count = get_in(channel_mix, [to_string(kind), "count"]) || 0
      "#{count} #{order_kind_short_label(kind)}"
    end)
  end

  defp order_kind_short_label(:dine_in), do: gettext("dine-in")
  defp order_kind_short_label(:takeaway), do: gettext("takeaway")
  defp order_kind_short_label(:counter), do: gettext("counter")

  defp order_chip_label(%{table: %Tabletap.Tenants.Table{number: number}}), do: "#" <> number
  defp order_chip_label(%{kind: :takeaway}), do: gettext("Takeaway")
  defp order_chip_label(%{kind: :counter}), do: gettext("Counter")
  defp order_chip_label(order), do: gettext("Order #%{number}", number: order.number)

  defp status_badge_class(:placed), do: "bg-status-placed text-white"
  defp status_badge_class(:accepted), do: "badge-info"
  defp status_badge_class(:preparing), do: "bg-status-preparing text-white"
  defp status_badge_class(:ready), do: "badge-success"

  defp status_label(:placed), do: gettext("Placed")
  defp status_label(:accepted), do: gettext("Accepted")
  defp status_label(:preparing), do: gettext("Preparing")
  defp status_label(:ready), do: gettext("Ready")

  defp subscription_issue_label(:past_due), do: gettext("Subscription payment past due")
  defp subscription_issue_label(:canceled), do: gettext("Subscription canceled")
end
