defmodule TabletapWeb.UserLive.History do
  @moduledoc """
  `/me/history` (build-plan.md Feature 16) — a customer's own order
  history, cross-venue: every order any venue's `checkout/2` ever
  attributed to their `customer_user_id` (`Ordering.link_guest_orders_to_customer/2`,
  triggered from `Public.OrderTrackerLive`'s "Save your history" prompt
  the moment a magic link confirms), whichever org placed it.

  Reachable by any authenticated user (`:require_authenticated`, no role
  check — a customer account has no staff membership, `scope.role: nil`)
  same as `/users/settings`.
  """
  use TabletapWeb, :live_view

  alias Tabletap.Ordering

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-2xl space-y-6">
        <h1 class="text-2xl font-bold">{gettext("Your order history")}</h1>

        <p :if={@orders == []} class="text-sm text-base-content/60">
          {gettext("No orders yet — once you order somewhere, it'll show up here.")}
        </p>

        <div :if={@orders != []} class="space-y-6">
          <div class="rounded-box bg-base-100 border border-base-300 p-4">
            <h2 class="font-semibold mb-3">{gettext("Spend by month")}</h2>
            <div class="space-y-1">
              <div
                :for={{label, amount} <- @monthly_spend}
                class="flex items-center justify-between text-sm"
              >
                <span class="text-base-content/70">{label}</span>
                <.money amount={amount} class="font-medium" />
              </div>
            </div>
          </div>

          <div class="rounded-box bg-base-100 border border-base-300 p-4">
            <h2 class="font-semibold mb-3">{gettext("By venue")}</h2>
            <div class="space-y-2">
              <div
                :for={{venue, count, total} <- @venue_totals}
                class="flex items-center justify-between text-sm"
              >
                <span class="text-base-content/70">
                  {venue.name} <span class="text-base-content/40">({count})</span>
                </span>
                <.money amount={total} locale={venue.locale} class="font-medium" />
              </div>
            </div>
          </div>

          <div class="rounded-box bg-base-100 border border-base-300 divide-y divide-base-300">
            <.link
              :for={order <- @orders}
              navigate={~p"/orders/#{order.guest_token}"}
              class="flex items-center justify-between gap-3 p-4 hover:bg-base-200"
            >
              <div class="min-w-0">
                <p class="font-medium truncate">{order.venue.name}</p>
                <p class="text-xs text-base-content/50">
                  {gettext("Order #%{number} — %{date}",
                    number: order.number,
                    date: Calendar.strftime(order.placed_at, "%b %-d, %Y")
                  )}
                </p>
              </div>
              <div class="text-end shrink-0">
                <.money amount={order.total} locale={order.venue.locale} class="font-semibold block" />
                <span class="text-xs text-base-content/50">{status_label(order.status)}</span>
              </div>
            </.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    orders = Ordering.list_orders_for_customer(socket.assigns.current_scope.user)

    {:ok,
     socket
     |> assign(:hide_utility_bar, true)
     |> assign(:orders, orders)
     |> assign(:monthly_spend, monthly_spend(orders))
     |> assign(:venue_totals, venue_totals(orders))}
  end

  # design-qa.md Q60 — venues can be USD or ETB; a customer's cross-venue
  # spend is never summed across currencies, only grouped alongside it.
  # Newest month first.
  defp monthly_spend(orders) do
    orders
    |> Enum.group_by(fn order -> {month_key(order.placed_at), order.total.currency} end)
    |> Enum.map(fn {{{year, month}, _currency}, month_orders} ->
      {month_label(year, month), sum_totals(month_orders)}
    end)
    |> Enum.sort_by(fn {label, _amount} -> label end, :desc)
  end

  defp month_key(%DateTime{} = dt), do: {dt.year, dt.month}

  defp month_label(year, month) do
    Calendar.strftime(Date.new!(year, month, 1), "%B %Y")
  end

  defp venue_totals(orders) do
    orders
    |> Enum.group_by(& &1.venue)
    |> Enum.map(fn {venue, venue_orders} ->
      {venue, length(venue_orders), sum_totals(venue_orders)}
    end)
    |> Enum.sort_by(fn {venue, _count, _total} -> venue.name end)
  end

  # Every order in one bucket already shares a currency here — either the
  # same venue (Q53 locks currency per venue) or the same
  # {month, currency} group — so a plain fold is safe.
  defp sum_totals([first | rest]), do: Enum.reduce(rest, first.total, &Money.add!(&2, &1.total))

  defp status_label(:closed), do: gettext("Closed")
  defp status_label(:served), do: gettext("Served")
  defp status_label(:refunded), do: gettext("Refunded")
  defp status_label(other), do: other |> to_string() |> String.capitalize()
end
