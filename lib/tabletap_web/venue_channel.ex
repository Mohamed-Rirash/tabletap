defmodule TabletapWeb.VenueChannel do
  @moduledoc """
  `venue:{id}:claim_board` and `venue:{id}:orders` (build-plan.md
  Feature 23 Commit 3) — relays the same broadcasts `Waiter.QueueLive`
  (claim board) and `Manager.DashboardLive` (orders) already subscribe
  to. Role gate per topic mirrors each LiveView's own `ScopeHooks` gate
  exactly: claim_board is `:require_waiter` (`[:waiter]` only — the
  claim board is a personal-queue companion view, not a shared kitchen
  screen); orders is `:require_manager` (`[:manager, :owner]`).
  """
  use TabletapWeb, :channel

  alias Tabletap.{Repo, Tenants}
  alias TabletapWeb.Api.Params

  @impl true
  def join("venue:" <> rest, _params, %{assigns: %{current_user: %{id: user_id}}} = socket) do
    case String.split(rest, ":", parts: 2) do
      [venue_id, "claim_board"] -> authorize(socket, user_id, venue_id, "claim_board", [:waiter])
      [venue_id, "orders"] -> authorize(socket, user_id, venue_id, "orders", [:manager, :owner])
      _ -> {:error, %{reason: "unknown_topic"}}
    end
  end

  def join("venue:" <> _rest, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  # Same cast-before-query discipline as WaiterChannel — venue_id is a
  # client-controlled topic segment, not a trusted server-generated id.
  defp authorize(socket, user_id, venue_id, suffix, allowed_roles) do
    with {:ok, venue_id} <- Params.cast_uuid(venue_id),
         %{role: role} = membership <-
           Tenants.get_active_membership_for_user_and_venue(user_id, venue_id),
         true <- role in allowed_roles do
      Repo.put_org_id(membership.org_id)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "venue:#{venue_id}:#{suffix}")
      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info({event, _order_id}, socket)
      when event in [:order_needs_claim, :order_claimed, :order_updated, :order_ready] do
    push(socket, "venue_updated", %{event: event})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
