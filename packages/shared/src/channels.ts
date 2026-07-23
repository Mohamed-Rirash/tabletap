/**
 * Thin wrapper over the official `phoenix` client (code-standards.md
 * "Mobile Apps" — "real-time via the official phoenix npm client only,
 * same topics as LiveView"). Connects to `TabletapWeb.ApiSocket` and
 * joins `order:{id}` exactly as `TabletapWeb.OrderChannel` expects
 * (build-plan.md Feature 23 Commit 3) — the `"order_updated"` push
 * payload is the identical `Order` shape `api.ts`'s REST client already
 * types, since both are `TabletapWeb.Api.Serializers.order/3`.
 *
 * Every screen must still fully rebuild from a REST fetch on
 * reconnect (code-standards.md) — this wrapper never claims to be the
 * source of truth, only a live-update optimization on top of it.
 */
import { Socket, type Channel } from "phoenix";
import type { Order } from "./api";

export interface OrderChannelHandle {
  channel: Channel;
  leave: () => void;
}

/**
 * Joins `order:{orderId}`, authorized by `guestToken` — the same
 * "possessing the token is the credential" design the REST tracker
 * endpoint already uses (design-qa.md Q13). `onUpdate` fires with the
 * full current order on every real status change.
 */
export function joinOrderChannel(
  socket: Socket,
  orderId: string,
  guestToken: string,
  onUpdate: (order: Order) => void,
): Promise<OrderChannelHandle> {
  return new Promise((resolve, reject) => {
    const channel = socket.channel(`order:${orderId}`, { guest_token: guestToken });

    channel.on("order_updated", (order: Order) => onUpdate(order));

    channel
      .join()
      .receive("ok", () => resolve({ channel, leave: () => channel.leave() }))
      .receive("error", (reason: unknown) => reject(reason))
      .receive("timeout", () => reject(new Error("order channel join timed out")));
  });
}

export type WaiterChannelEvent =
  | "order_assigned"
  | "order_unassigned"
  | "waiter_called"
  | "order_ready"
  | "order_ready_retracted";

export interface WaiterChannelHandle {
  channel: Channel;
  leave: () => void;
}

/**
 * Joins `waiter:{membershipId}` (build-plan.md Feature 23 Commit 3,
 * Feature 25) — bearer-authenticated via `createSocket`'s own
 * `accessToken` param, checked server-side against the socket's
 * `current_user` actually holding this membership. Every push is a
 * lightweight "something changed" signal with no order data
 * (code-standards.md "every screen must fully rebuild from a REST
 * fetch") — `onEvent` fires the bare event name so the caller can
 * both refetch its queue/claim-board *and*, for `"waiter_called"`
 * specifically, surface a distinct in-app alert.
 */
export function joinWaiterChannel(
  socket: Socket,
  membershipId: string,
  onEvent: (event: WaiterChannelEvent) => void,
): Promise<WaiterChannelHandle> {
  return new Promise((resolve, reject) => {
    const channel = socket.channel(`waiter:${membershipId}`, {});

    channel.on("queue_updated", (payload: { event: WaiterChannelEvent }) =>
      onEvent(payload.event),
    );

    channel
      .join()
      .receive("ok", () => resolve({ channel, leave: () => channel.leave() }))
      .receive("error", (reason: unknown) => reject(reason))
      .receive("timeout", () => reject(new Error("waiter channel join timed out")));
  });
}

export type VenueChannelEvent = "order_needs_claim" | "order_claimed" | "order_updated" | "order_ready";

export interface VenueChannelHandle {
  channel: Channel;
  leave: () => void;
}

/**
 * Joins `venue:{venueId}:orders` (build-plan.md Feature 23 Commit 3,
 * Feature 25's owner dashboard) — bearer-authenticated, checked
 * server-side that the caller's membership at this venue is `:manager`
 * or `:owner` (`TabletapWeb.VenueChannel`'s own `:require_manager`-
 * equivalent gate). Same lightweight "something changed, refetch"
 * signal as `joinWaiterChannel` — `Manager.DashboardLive` itself does a
 * full reload on any of these events, never a partial patch, and this
 * mirrors that exactly.
 */
export function joinVenueChannel(
  socket: Socket,
  venueId: string,
  onEvent: (event: VenueChannelEvent) => void,
): Promise<VenueChannelHandle> {
  return new Promise((resolve, reject) => {
    const channel = socket.channel(`venue:${venueId}:orders`, {});

    channel.on("venue_updated", (payload: { event: VenueChannelEvent }) => onEvent(payload.event));

    channel
      .join()
      .receive("ok", () => resolve({ channel, leave: () => channel.leave() }))
      .receive("error", (reason: unknown) => reject(reason))
      .receive("timeout", () => reject(new Error("venue channel join timed out")));
  });
}

/**
 * `baseUrl` is the REST API's http(s) origin. The `phoenix` client only
 * auto-derives `ws`/`wss` for a *relative* path (`endPointURL()`
 * checks whether the endpoint starts with `/`) — an absolute `http://`
 * URL is passed straight to the `WebSocket` constructor as-is, which
 * silently fails to connect (a `ws://`/`wss://` scheme is required).
 * Confirmed empirically: the live tracker never received a single
 * update until this was fixed, with no visible error either — `phoenix`
 * doesn't surface "wrong scheme" as a `channel.join()` error, so this
 * failure mode is easy to miss without watching the actual socket
 * connection, not just the join callback.
 */
export function createSocket(baseUrl: string, accessToken?: string): Socket {
  const wsUrl = baseUrl.replace(/^http/, "ws");
  return new Socket(`${wsUrl}/socket`, {
    params: accessToken ? { token: accessToken } : {},
  });
}
