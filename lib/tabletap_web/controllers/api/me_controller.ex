defmodule TabletapWeb.Api.MeController do
  @moduledoc """
  build-plan.md Feature 24 (`GET /api/v1/me/history`) and Feature 25
  (`GET /api/v1/me/memberships`) — bearer-auth protected only, no
  venue/membership scope needed for either: a customer's cross-venue
  history and a user's own membership list are both deliberately not
  tenant-scoped (the same reasoning `UserLive.History` already
  documents for the former).
  """
  use TabletapWeb, :controller

  alias Tabletap.{Ordering, Tenants}
  alias TabletapWeb.Api.Serializers

  def history(conn, _params) do
    orders =
      conn.assigns.current_api_user
      |> Ordering.list_orders_for_customer()
      |> Enum.map(&Serializers.history_entry/1)

    json(conn, %{orders: orders})
  end

  @doc """
  Every active membership the caller holds — the mobile staff app's
  role-detection/mode-switcher source (build-plan.md Feature 25): a
  user with one `:waiter` membership goes straight into waiter mode, one
  with both a `:waiter` and an `:owner` membership gets a mode switcher.
  """
  def memberships(conn, _params) do
    memberships =
      conn.assigns.current_api_user
      |> Tenants.list_active_memberships_for_user()
      |> Enum.map(&Serializers.membership/1)

    json(conn, %{memberships: memberships})
  end
end
