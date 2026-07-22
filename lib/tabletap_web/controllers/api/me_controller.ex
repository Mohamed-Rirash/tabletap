defmodule TabletapWeb.Api.MeController do
  @moduledoc """
  build-plan.md Feature 24 — `GET /api/v1/me/history`, wrapping
  `Ordering.list_orders_for_customer/1` exactly as `UserLive.History`
  does. Bearer-auth protected only — no venue/membership scope needed,
  since a customer's cross-venue history is deliberately not
  tenant-scoped (the same reasoning `UserLive.History` itself documents:
  any authenticated user, staff or customer, sees their own history).
  """
  use TabletapWeb, :controller

  alias Tabletap.Ordering
  alias TabletapWeb.Api.Serializers

  def history(conn, _params) do
    orders =
      conn.assigns.current_api_user
      |> Ordering.list_orders_for_customer()
      |> Enum.map(&Serializers.history_entry/1)

    json(conn, %{orders: orders})
  end
end
