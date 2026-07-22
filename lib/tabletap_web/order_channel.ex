defmodule TabletapWeb.OrderChannel do
  @moduledoc """
  `order:{id}` (build-plan.md Feature 23 Commit 3) — the customer
  tracker's realtime channel, relaying the exact `:order_updated`
  broadcast `Public.OrderTrackerLive` already subscribes to
  (`OrderStateMachine.broadcast/3`). Authorization mirrors the web's
  own design (design-qa.md Q13): possessing the order's `guest_token`
  *is* the credential — no bearer auth, no socket-level user needed.
  """
  use TabletapWeb, :channel

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Ordering, Payments, Repo, Tenants}
  alias TabletapWeb.Api.Serializers

  @impl true
  def join("order:" <> order_id, %{"guest_token" => guest_token}, socket) do
    case Tenants.get_order_by_guest_token(guest_token) do
      %{id: ^order_id} = resolved ->
        Repo.put_org_id(resolved.org_id)
        scope = %Scope{org: resolved.venue.org, venue: resolved.venue, role: :guest}
        Phoenix.PubSub.subscribe(Tabletap.PubSub, "order:#{order_id}")
        {:ok, socket |> assign(:scope, scope) |> assign(:order_id, order_id)}

      _ ->
        {:error, %{reason: "unauthorized"}}
    end
  end

  def join("order:" <> _order_id, _params, _socket),
    do: {:error, %{reason: "guest_token_required"}}

  @impl true
  def handle_info(:order_updated, socket) do
    order = Ordering.get_order(socket.assigns.scope, socket.assigns.order_id)
    push(socket, "order_updated", render_order(socket.assigns.scope, order))
    {:noreply, socket}
  end

  defp render_order(scope, order) do
    eta = Ordering.estimated_minutes(scope, order)
    payment = Payments.get_latest_payment_for_order(scope, order.id)
    Serializers.order(order, eta, payment)
  end
end
