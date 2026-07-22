defmodule TabletapWeb.Api.MenuController do
  @moduledoc """
  build-plan.md Feature 23 — `GET /api/v1/venues/:slug/menu`, the same
  read `Public.MenuLive` does on mount (`Catalog.list_public_menu/1`),
  just JSON instead of a rendered page. Modifier groups are eagerly
  included per item (unlike the web, which loads them lazily on tap) —
  a REST client wants the full screen's data in one round trip, and
  architecture.md names no separate "modifier groups for an item"
  endpoint.
  """
  use TabletapWeb, :controller

  alias Tabletap.Catalog
  alias TabletapWeb.Api.{GuestScope, Serializers}

  def show(conn, %{"slug" => slug}) do
    case GuestScope.by_slug(slug) do
      {:ok, scope} ->
        menu = Catalog.list_public_menu(scope)
        json(conn, Serializers.menu(menu, scope))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "venue_not_found"})
    end
  end
end
