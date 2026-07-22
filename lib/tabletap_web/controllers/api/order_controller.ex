defmodule TabletapWeb.Api.OrderController do
  @moduledoc """
  build-plan.md Feature 23 — `POST /api/v1/orders` (checkout) and
  `GET /api/v1/orders/:guest_token` (tracker), mirroring `Public.
  MenuLive`'s `place_order` handler and `Public.OrderTrackerLive`'s
  mount exactly. `Ordering.checkout/2` never charges payment itself
  (code-standards.md — a `pending_payment` order is already durable the
  instant it's inserted); payment is a deliberately separate,
  fire-and-forget second call, same as the web. The mobile client then
  watches `GET /orders/:guest_token` (or the `order:{id}` channel, once
  Commit 3 lands) for the payment to resolve — there is no synchronous
  "charge and wait" endpoint, on either surface.
  """
  use TabletapWeb, :controller

  alias Tabletap.{Ordering, Payments}
  alias TabletapWeb.Api.{GuestScope, Serializers}

  def create(conn, %{"venue_slug" => slug, "guest_token" => guest_token} = params) do
    case GuestScope.by_slug(slug) do
      {:ok, scope} -> checkout(conn, scope, guest_token, params)
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "venue_not_found"})
    end
  end

  defp checkout(conn, scope, guest_token, params) do
    cart = Ordering.get_active_cart(scope, guest_token)

    case cart && Ordering.checkout(scope, cart) do
      nil ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "empty_cart"})

      {:ok, order} ->
        kick_off_payment(scope, order, params)
        # The multi-insert result has no association preloads — reload
        # via get_order/2 (same :table/:items/:menu_item/:modifiers
        # preload the tracker itself relies on) before rendering.
        conn
        |> put_status(:created)
        |> json(render_order(scope, Ordering.get_order(scope, order.id)))

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})
    end
  end

  # Best-effort, exactly like the web's checkout_succeeded/4 — the order
  # itself is already safely committed regardless of what happens here;
  # a failure just means it expires via the standard 12-min sweep
  # instead of ever getting paid (design-qa.md Q1's zero-order-loss
  # rule doesn't depend on this call succeeding).
  defp kick_off_payment(scope, order, %{"payment_method" => "cash"}) do
    Payments.record_cash_intent(scope, order)
  end

  defp kick_off_payment(scope, order, params) do
    Payments.charge_order(scope, order, params["wallet_msisdn"])
  end

  def show(conn, %{"guest_token" => guest_token}) do
    case GuestScope.by_order_guest_token(guest_token) do
      {:ok, scope, resolved} ->
        order = Ordering.get_order(scope, resolved.id)
        json(conn, render_order(scope, order))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "order_not_found"})
    end
  end

  defp render_order(scope, order) do
    eta = Ordering.estimated_minutes(scope, order)
    payment = Payments.get_latest_payment_for_order(scope, order.id)
    Serializers.order(order, eta, payment)
  end
end
