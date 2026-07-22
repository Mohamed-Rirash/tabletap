defmodule TabletapWeb.Api.TableController do
  @moduledoc """
  build-plan.md Feature 24 — `GET /api/v1/tables/:qr_token`, the API
  equivalent of `Public.TableController`'s scanned-QR resolution. The
  web controller writes the resolved table into the HTTP session and
  redirects; the mobile app has no server session, so this just returns
  the resolved `{venue_slug, table_id}` for the client to hold locally
  (its own equivalent of the web's session write) and navigate with.
  """
  use TabletapWeb, :controller

  alias Tabletap.Tenants

  def show(conn, %{"qr_token" => qr_token}) do
    case Tenants.get_table_by_qr_token(qr_token) do
      nil ->
        conn |> put_status(:not_found) |> json(%{error: "table_not_found"})

      table ->
        json(conn, %{venue_slug: table.venue.slug, table_id: table.id})
    end
  end
end
