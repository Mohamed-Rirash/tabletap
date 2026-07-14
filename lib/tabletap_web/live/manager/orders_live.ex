defmodule TabletapWeb.Manager.OrdersLive do
  @moduledoc """
  Manager order oversight (build-plan.md Feature 11): the manual serve
  confirm fallback for a damaged table QR (design-qa.md Q19), and
  resolution for orders flagged by the waiter ("Can't find customer",
  Q9) or the pickup no-show sweep (Q32). No POS exists yet (Feature 15),
  so this page is the only place these resolutions happen for now —
  role-features.md's "manager/POS resolves" becomes just "manager"
  until then.

  Boards re-read DB state on every mount/reconnect and on every
  `"venue:<id>:orders"` broadcast — PubSub is an optimization, never the
  source of truth (architecture.md "Reliability"), same discipline
  `Waiter.QueueLive` already follows.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Ordering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.manager
      flash={@flash}
      current_scope={@current_scope}
      active_nav={:orders}
      venues={@venues}
    >
      <h1 class="text-2xl font-bold mb-1">{gettext("Orders")}</h1>
      <p class="text-sm text-base-content/60 mb-6 max-w-prose">
        {gettext("Ready orders waiting on a serve scan, and anything flagged for your attention.")}
      </p>

      <section class="mb-8">
        <h2 class="font-semibold mb-3">{gettext("Ready — needs serving")}</h2>
        <div :if={@ready_orders == []} class="text-sm text-base-content/50 py-6 text-center">
          {gettext("Nothing waiting on a serve confirm right now.")}
        </div>
        <div class="space-y-3">
          <div
            :for={order <- @ready_orders}
            id={"ready-#{order.id}"}
            class="rounded-box bg-base-100 border border-base-300 p-4"
          >
            <.order_summary order={order} locale={@current_scope.venue.locale} />
            <button
              type="button"
              phx-click="manual_serve"
              phx-value-id={order.id}
              class="btn btn-outline btn-sm mt-3"
            >
              <.icon name="hero-check-circle" class="size-4" /> {gettext("Manual serve confirm")}
            </button>
          </div>
        </div>
      </section>

      <section>
        <h2 class="font-semibold mb-3">{gettext("Needs your attention")}</h2>
        <div :if={@flagged_orders == []} class="text-sm text-base-content/50 py-6 text-center">
          {gettext("Nothing flagged right now.")}
        </div>
        <div class="space-y-3">
          <div
            :for={order <- @flagged_orders}
            id={"flagged-#{order.id}"}
            class="rounded-box bg-base-100 border border-warning/40 p-4"
          >
            <span class="badge badge-warning badge-sm mb-2">{flag_label(order.flag)}</span>
            <.order_summary order={order} locale={@current_scope.venue.locale} />
            <div class="flex flex-wrap gap-2 mt-3">
              <button
                type="button"
                phx-click="resolve_refund"
                phx-value-id={order.id}
                class="btn btn-outline btn-sm"
              >
                {gettext("Refund")}
              </button>
              <button
                :if={order.flag == :unserveable}
                type="button"
                phx-click="resolve_convert_takeaway"
                phx-value-id={order.id}
                class="btn btn-outline btn-sm"
              >
                {gettext("Convert to takeaway")}
              </button>
              <button
                :if={order.flag == :not_picked_up}
                type="button"
                phx-click="resolve_mark_collected"
                phx-value-id={order.id}
                class="btn btn-outline btn-sm"
              >
                {gettext("Mark collected")}
              </button>
              <button
                :if={order.flag == :not_picked_up}
                type="button"
                phx-click="resolve_close_wasted"
                phx-value-id={order.id}
                class="btn btn-outline btn-sm text-error"
              >
                {gettext("Close (wasted)")}
              </button>
            </div>
          </div>
        </div>
      </section>
    </Layouts.manager>
    """
  end

  attr :order, :any, required: true
  attr :locale, :string, required: true

  defp order_summary(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div>
        <p class="font-bold">{gettext("Order #%{number}", number: @order.number)}</p>
        <p :if={@order.table} class="text-lg font-bold text-brand">
          {gettext("Table %{number}", number: @order.table.number)}
        </p>
        <p :if={!@order.table} class="text-sm font-medium text-base-content/70">
          {order_kind_label(@order.kind)}
        </p>
      </div>
      <.money amount={@order.total} locale={@locale} class="font-semibold whitespace-nowrap" />
    </div>
    <div class="divide-y divide-base-200 mt-2">
      <div :for={item <- @order.items} class="py-1">
        <p class="text-sm">{item.qty}× {item.name_snapshot}</p>
      </div>
    </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{scope.venue.id}:orders")
    end

    {:ok,
     socket
     |> assign(:venues, Tabletap.Tenants.list_venues(scope))
     |> reload_boards()}
  end

  @impl true
  def handle_event("manual_serve", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    case Ordering.get_order(scope, id) do
      nil ->
        {:noreply, reload_boards(socket)}

      order ->
        case Ordering.confirm_served_manually(scope, order) do
          {:ok, _served} ->
            {:noreply,
             socket
             |> put_flash(
               :info,
               gettext("Marked served without a scan. Consider reprinting this table's QR code.")
             )
             |> reload_boards()}

          {:error, :not_ready} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That order moved on — refreshing."))
             |> reload_boards()}
        end
    end
  end

  def handle_event("resolve_refund", %{"id" => id}, socket) do
    scope = socket.assigns.current_scope

    with order when not is_nil(order) <- Ordering.get_order(scope, id),
         {:ok, _order} <- Ordering.resolve_flag_refund(scope, order, scope.user.id) do
      {:noreply, socket |> put_flash(:info, gettext("Refunded.")) |> reload_boards()}
    else
      _ ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Couldn't refund that order — refreshing."))
         |> reload_boards()}
    end
  end

  def handle_event("resolve_convert_takeaway", %{"id" => id}, socket) do
    resolve(socket, id, &Ordering.convert_to_takeaway/2, gettext("Converted to takeaway."))
  end

  def handle_event("resolve_mark_collected", %{"id" => id}, socket) do
    resolve(socket, id, &Ordering.mark_collected/2, gettext("Marked served."))
  end

  def handle_event("resolve_close_wasted", %{"id" => id}, socket) do
    resolve(socket, id, &Ordering.close_as_wasted/2, gettext("Closed."))
  end

  defp resolve(socket, id, fun, success_message) do
    scope = socket.assigns.current_scope

    case Ordering.get_order(scope, id) do
      nil ->
        {:noreply, reload_boards(socket)}

      order ->
        case fun.(scope, order) do
          {:ok, _order} ->
            {:noreply, socket |> put_flash(:info, success_message) |> reload_boards()}

          {:error, _reason} ->
            {:noreply,
             socket
             |> put_flash(:error, gettext("That order moved on — refreshing."))
             |> reload_boards()}
        end
    end
  end

  @impl true
  def handle_info(:order_updated, socket), do: {:noreply, reload_boards(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp reload_boards(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:ready_orders, Ordering.list_ready_orders(scope))
    |> assign(:flagged_orders, Ordering.list_flagged_orders(scope))
  end

  defp order_kind_label(:takeaway), do: gettext("Takeaway")
  defp order_kind_label(:counter), do: gettext("Counter")
  defp order_kind_label(_), do: gettext("Dine in")

  defp flag_label(:unserveable), do: gettext("Can't find customer")
  defp flag_label(:not_picked_up), do: gettext("Not picked up")
end
