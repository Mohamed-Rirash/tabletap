defmodule TabletapWeb.Public.OrderTrackerLive do
  @moduledoc """
  The customer order tracker (build-plan.md Feature 08) — status
  timeline, live ETA, no auth. Reached at `/orders/:guest_token`
  straight after checkout (`Public.MenuLive`'s "Place order" redirects
  here), by re-scanning the table QR or reopening the venue menu while
  an order is active (design-qa.md Q13's banner), or from a bookmarked/
  saved link days later.

  `guest_token` alone carries no venue context, so this resolves like
  `Public.MenuLive`'s slug/qr_token entry points: `Tenants.get_order_by_guest_token/1`
  is the pre-scope, `skip_org_id: true` lookup (see that function's
  moduledoc for why it lives in `Tenants` rather than `Ordering`), then
  `Repo.put_org_id/1` and every subsequent read is normally tenant-scoped.

  Subscribes to `"order:<id>"` — `OrderStateMachine.transition/3`
  broadcasts there after every commit, so status changes appear within
  seconds without a refresh (build-plan.md verify step: "Tracker updates
  within 2s when status changes from IEx").
  """
  use TabletapWeb, :live_view

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Ordering, Payments, Repo, Tenants}
  alias Tabletap.Ordering.Order

  @step_order [:placed, :accepted, :preparing, :ready, :served]
  @terminal_non_timeline [:cancelled, :expired, :refunded]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="mb-6">
        <h1 class="text-2xl font-bold">{@venue.name}</h1>
        <p class="text-sm text-base-content/60">
          {gettext("Order #%{number}", number: @order.number)}
        </p>
      </div>

      <div
        :if={@order.status == :pending_payment}
        class="rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <.icon name="hero-clock" class="size-8 mx-auto opacity-40 motion-safe:animate-pulse" />
        <p class="font-medium">{gettext("Confirming your payment…")}</p>
        <p class="text-sm text-base-content/60">
          {gettext("This updates automatically — no need to refresh.")}
        </p>
      </div>

      <div
        :if={@order.status in @terminal_non_timeline_status}
        class="rounded-box bg-base-100 border border-base-300 p-6 text-center space-y-2"
      >
        <.icon name="hero-x-circle" class="size-8 mx-auto text-error" />
        <p class="font-medium">{terminal_message(@order, @latest_payment)}</p>
      </div>

      <.status_timeline
        :if={@order.status not in [:pending_payment | @terminal_non_timeline_status]}
        order={@order}
        eta_minutes={@eta_minutes}
      />

      <div class="mt-6 rounded-box bg-base-100 border border-base-300 p-4">
        <h2 class="font-semibold mb-3">{gettext("Order details")}</h2>
        <div class="divide-y divide-base-300">
          <div :for={item <- @order.items} class="py-2">
            <div class="flex items-start justify-between gap-3">
              <div class="min-w-0">
                <p class="font-medium">{item.qty}× {item.name_snapshot}</p>
                <p :for={mod <- item.modifiers} class="text-xs text-base-content/60">
                  {mod.name_snapshot}
                </p>
                <p :if={item.notes} class="text-xs text-base-content/50 italic">"{item.notes}"</p>
              </div>
              <.money amount={item.line_total} locale={@venue.locale} class="whitespace-nowrap" />
            </div>
          </div>
        </div>
        <div class="flex items-center justify-between mt-3 pt-3 border-t border-base-300">
          <span class="font-semibold">{gettext("Total")}</span>
          <.money amount={@order.total} locale={@venue.locale} class="font-bold text-brand" />
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :order, Order, required: true
  attr :eta_minutes, :integer, required: true

  defp status_timeline(assigns) do
    assigns = assign(assigns, :steps, @step_order)

    ~H"""
    <div class="rounded-box bg-base-100 border border-base-300 p-6">
      <.timeline_step
        :for={step <- @steps}
        step={step}
        state={step_state(step, @order.status)}
        timestamp={step_timestamp(@order, step)}
        eta_minutes={@eta_minutes}
        is_last={step == :served}
      />
    </div>
    """
  end

  attr :step, :atom, required: true
  attr :state, :atom, required: true, doc: ":done | :current | :upcoming"
  attr :timestamp, :any, default: nil
  attr :eta_minutes, :integer, required: true
  attr :is_last, :boolean, default: false

  defp timeline_step(assigns) do
    ~H"""
    <div class="flex gap-3">
      <div class="flex flex-col items-center">
        <span class={[
          "size-4 rounded-full shrink-0",
          @state == :upcoming && "bg-base-300",
          @state != :upcoming && step_bg_class(@step),
          @state == :current && "motion-safe:animate-pulse"
        ]}></span>
        <div
          :if={!@is_last}
          class={[
            "w-0.5 flex-1 min-h-8",
            @state == :done && step_bg_class(@step),
            @state != :done && "bg-base-300"
          ]}
        >
        </div>
      </div>
      <div class="pb-8">
        <p class={["font-medium", @state == :upcoming && "text-base-content/40"]}>
          {step_label(@step)}
        </p>
        <p :if={@timestamp} class="text-xs text-base-content/50">
          {Calendar.strftime(@timestamp, "%H:%M")}
        </p>
        <p :if={@state == :current} class="text-xs text-base-content/60 mt-0.5">
          {gettext("~%{minutes} min", minutes: @eta_minutes)}
        </p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(%{"guest_token" => guest_token}, _session, socket) do
    case Tenants.get_order_by_guest_token(guest_token) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, gettext("Order not found."))
         |> redirect(to: ~p"/")}

      resolved ->
        Repo.put_org_id(resolved.org_id)
        scope = %Scope{org: resolved.venue.org, venue: resolved.venue, role: :guest}
        order = Ordering.get_order(scope, resolved.id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order.id}")
        end

        {:ok,
         socket
         |> assign(:hide_utility_bar, true)
         |> assign(:venue, resolved.venue)
         |> assign(:current_scope, scope)
         |> assign(:order, order)
         |> assign(:eta_minutes, Ordering.estimated_minutes(scope, order))
         |> assign(:latest_payment, Payments.get_latest_payment_for_order(scope, order.id))
         |> assign(:terminal_non_timeline_status, @terminal_non_timeline)}
    end
  end

  @impl true
  def handle_info(:order_updated, socket) do
    scope = socket.assigns.current_scope
    order = Ordering.get_order(scope, socket.assigns.order.id)

    {:noreply,
     socket
     |> assign(:order, order)
     |> assign(:eta_minutes, Ordering.estimated_minutes(scope, order))
     |> assign(:latest_payment, Payments.get_latest_payment_for_order(scope, order.id))}
  end

  defp step_state(step, current_status) do
    step_index = Enum.find_index(@step_order, &(&1 == step))
    current_index = Enum.find_index(@step_order, &(&1 == current_status)) || 0

    cond do
      step_index < current_index -> :done
      step_index == current_index -> :current
      true -> :upcoming
    end
  end

  defp step_timestamp(order, :placed), do: order.placed_at
  defp step_timestamp(order, :accepted), do: order.accepted_at
  defp step_timestamp(_order, :preparing), do: nil
  defp step_timestamp(order, :ready), do: order.ready_at
  defp step_timestamp(order, :served), do: order.served_at

  defp step_label(:placed), do: gettext("Placed")
  defp step_label(:accepted), do: gettext("Accepted")
  defp step_label(:preparing), do: gettext("Preparing")
  defp step_label(:ready), do: gettext("Ready")
  defp step_label(:served), do: gettext("Served")

  defp step_bg_class(:placed), do: "bg-status-placed"
  defp step_bg_class(:accepted), do: "bg-info"
  defp step_bg_class(:preparing), do: "bg-status-preparing"
  defp step_bg_class(:ready), do: "bg-success"
  defp step_bg_class(:served), do: "bg-status-served"

  # Q21 late-success resurrection: the order expired, but a payment for
  # it still ended up refunded — meaning it *was* briefly charged before
  # the sold-out re-reservation failed. That's a materially different
  # story for the customer than a plain never-charged expiry.
  defp terminal_message(%Order{status: :expired}, %{status: :refunded}) do
    gettext("Sorry — this item sold out while your payment was confirming. You've been refunded.")
  end

  defp terminal_message(%Order{status: :cancelled}, _payment),
    do: gettext("This order was cancelled.")

  defp terminal_message(%Order{status: :expired}, _payment),
    do: gettext("This order expired before payment was confirmed.")

  defp terminal_message(%Order{status: :refunded}, _payment),
    do: gettext("This order was refunded.")
end
