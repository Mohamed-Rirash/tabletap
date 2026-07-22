defmodule TabletapWeb.WaiterChannel do
  @moduledoc """
  `waiter:{membership_id}` (build-plan.md Feature 23 Commit 3) — relays
  the same `{:order_assigned, id}` / `{:order_unassigned, id}` /
  `{:waiter_called, id}` broadcasts `Waiter.QueueLive` already
  subscribes to. Join requires the socket's bearer-authenticated user to
  actually hold this membership — `ApiSocket.connect/3` resolves
  `current_user` from the access token; a missing/invalid token means
  `current_user` is `nil`, which never matches a real membership below.
  A push here is a lightweight "something changed" signal, not the full
  queue state — code-standards.md's own rule for mobile Channels
  ("every screen must fully rebuild from a REST fetch"; a push is an
  optimization, not the source of truth) — the client re-fetches its
  queue via the staff REST API (Commit 4).
  """
  use TabletapWeb, :channel

  alias Tabletap.{Repo, Tenants}
  alias TabletapWeb.Api.Params

  @impl true
  def join(
        "waiter:" <> membership_id,
        _params,
        %{assigns: %{current_user: %{id: user_id}}} = socket
      ) do
    # A channel topic is client-controlled input like any REST param —
    # cast before it reaches a query (TabletapWeb.Api.Params's own
    # moduledoc explains why an uncast id crashes instead of a clean
    # rejection).
    with {:ok, membership_id} <- Params.cast_uuid(membership_id),
         %{user_id: ^user_id} = membership <- Tenants.get_membership(membership_id) do
      Repo.put_org_id(membership.org_id)
      Phoenix.PubSub.subscribe(Tabletap.PubSub, "waiter:#{membership_id}")
      {:ok, socket}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join("waiter:" <> _membership_id, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info({event, _order_id}, socket)
      when event in [:order_assigned, :order_unassigned, :waiter_called] do
    push(socket, "queue_updated", %{event: event})
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
