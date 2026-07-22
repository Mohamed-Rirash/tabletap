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
