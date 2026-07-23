defmodule TabletapWeb.WaiterChannel do
  @moduledoc """
  `waiter:{membership_id}` (build-plan.md Feature 23 Commit 3) — relays
  the same `{:order_assigned, id}` / `{:order_unassigned, id}` /
  `{:waiter_called, id}` / `{:order_ready, id}` / `{:order_ready_retracted,
  id}` broadcasts `Waiter.QueueLive` already subscribes to
  (`OrderStateMachine.notify_waiter/3` is the source of the last two —
  Feature 14's "waiter notified on ready" and its Q25 undo). Join
  requires the socket's bearer-authenticated user to
  actually hold this membership — `ApiSocket.connect/3` resolves
  `current_user` from the access token; a missing/invalid token means
  `current_user` is `nil`, which never matches a real membership below.
  A push here is a lightweight "something changed" signal, not the full
  queue state — code-standards.md's own rule for mobile Channels
  ("every screen must fully rebuild from a REST fetch"; a push is an
  optimization, not the source of truth) — the client re-fetches its
  queue via the staff REST API (Commit 4).

  build-plan.md Feature 25 — also the process that tracks this waiter's
  `TabletapWeb.Presence` entry, since a mobile shift toggle is a
  stateless REST call (`Tabletap.Staffing.clock_in/1`/`clock_out/1`)
  with no long-lived process of its own to track against, unlike
  `Waiter.QueueLive`'s own `handle_event`, which *is* that long-lived
  process on the web. `clock_in/1`/`clock_out/1` broadcast a bare
  `:shift_changed` on this same topic; `handle_info(:shift_changed, _)`
  below re-checks `Staffing.get_open_shift/1` and tracks/untracks
  accordingly. No explicit untrack on disconnect is needed —
  `Phoenix.Presence` already drops an entry the instant its tracking
  pid dies (the same mechanism that already makes a web waiter closing
  their laptop drop off Presence today), and this channel's own pid
  *is* the long-lived thing this whole feature builds around.
  """
  use TabletapWeb, :channel

  alias Tabletap.Accounts.Scope
  alias Tabletap.{Repo, Staffing, Tenants}
  alias TabletapWeb.Api.Params
  alias TabletapWeb.Presence

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
      sync_presence(membership)
      {:ok, assign(socket, :membership, membership)}
    else
      _ -> {:error, %{reason: "unauthorized"}}
    end
  end

  def join("waiter:" <> _membership_id, _params, _socket), do: {:error, %{reason: "unauthorized"}}

  @impl true
  def handle_info({event, _order_id}, socket)
      when event in [
             :order_assigned,
             :order_unassigned,
             :waiter_called,
             :order_ready,
             :order_ready_retracted
           ] do
    push(socket, "queue_updated", %{event: event})
    {:noreply, socket}
  end

  def handle_info(:shift_changed, socket) do
    sync_presence(socket.assigns.membership)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp sync_presence(membership) do
    topic = Presence.staff_topic(membership.venue_id)

    if Staffing.get_open_shift(%Scope{membership: membership}) do
      Presence.track(self(), topic, membership.id, %{role: :waiter})
    else
      Presence.untrack(self(), topic, membership.id)
    end
  end
end
