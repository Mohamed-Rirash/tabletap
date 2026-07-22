defmodule TabletapWeb.Api.CartController do
  @moduledoc """
  build-plan.md Feature 23 — `POST /api/v1/venues/:slug/cart/items`, the
  same write `Public.MenuLive`'s `do_add_to_cart/4` does
  (`Ordering.add_to_cart/7`). No cookie mechanism exists in a JSON API,
  so unlike the web (which mints a `guest_token` client-side via a JS
  hook the first time), the server mints one here when the caller omits
  it and returns it in the response for the mobile client to persist —
  same lifecycle, different transport.
  """
  use TabletapWeb, :controller

  alias Tabletap.Catalog
  alias Tabletap.Ordering
  alias Tabletap.Ordering.Cart
  alias TabletapWeb.Api.{GuestScope, Params, Serializers}

  def add_item(conn, %{"slug" => slug} = params) do
    case GuestScope.by_slug(slug) do
      {:ok, scope} -> add_item(conn, scope, params)
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "venue_not_found"})
    end
  end

  defp add_item(conn, scope, params) do
    with {:ok, item_id} <- Params.cast_uuid(params["item_id"]),
         %Catalog.MenuItem{} = item <- Catalog.get_item(scope, item_id) do
      guest_token = params["guest_token"] || Cart.generate_guest_token()
      table_id = params["table_id"]
      option_ids = params["option_ids"] || []
      qty = params["qty"] || 1
      notes = params["notes"]

      case Ordering.add_to_cart(scope, guest_token, table_id, item, option_ids, qty, notes) do
        {:ok, cart} ->
          json(conn, %{guest_token: guest_token, cart: Serializers.cart(cart)})

        {:error, reason} when reason in [:item_unavailable, :options_changed] ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: to_string(reason)})

        {:error, %Ecto.Changeset{}} ->
          conn |> put_status(:unprocessable_entity) |> json(%{error: "invalid_line"})
      end
    else
      :error -> conn |> put_status(:not_found) |> json(%{error: "item_not_found"})
      nil -> conn |> put_status(:not_found) |> json(%{error: "item_not_found"})
    end
  end
end
