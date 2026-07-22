/**
 * Typed client for /api/v1 (build-plan.md Feature 23/24). One function
 * per endpoint, matching the exact JSON shapes those Elixir controllers
 * render (`TabletapWeb.Api.Serializers`) — confirmed empirically against
 * a real running dev server's own `Jason.encode!/1` output, not
 * guessed: `Money` fields are `{currency, amount}` with `amount` as a
 * decimal *string* (`"5.00"`), never a bare float — never parse it with
 * `parseFloat`, only for display formatting.
 *
 * Zero business logic here (code-standards.md "Mobile Apps" — apps
 * render server state and send intents) — this file is a thin fetch
 * wrapper, nothing computes a price or a permission.
 */

export interface Money {
  currency: string;
  amount: string;
}

export type OrderStatus =
  | "pending_payment"
  | "placed"
  | "accepted"
  | "preparing"
  | "ready"
  | "served"
  | "cancelled"
  | "expired"
  | "refunded";

export interface ModifierOption {
  id: string;
  name: string;
  price_delta: Money;
  default: boolean;
}

export interface ModifierGroup {
  id: string;
  name: string;
  min_selections: number;
  max_selections: number;
  required: boolean;
  options: ModifierOption[];
}

export interface MenuItem {
  id: string;
  name: string;
  description: string | null;
  photo_url: string | null;
  price: Money;
  remaining: number | "unlimited";
  dietary_tags: string[];
  allergen_tags: string[];
  modifier_groups: ModifierGroup[];
}

export interface MenuCategory {
  id: string;
  name: string;
  items: MenuItem[];
}

export interface Menu {
  categories: MenuCategory[];
}

export interface CartLineOption {
  id: string;
  name: string;
  price_delta: Money;
}

export interface CartLine {
  id: string;
  menu_item_id: string;
  name: string;
  qty: number;
  notes: string | null;
  options: CartLineOption[];
}

export interface Cart {
  guest_token: string;
  kind: "dine_in" | "takeaway" | "counter";
  items: CartLine[];
}

export interface OrderLineModifier {
  name: string;
  price_delta: Money;
}

export interface OrderLine {
  id: string;
  menu_item_id: string;
  name: string;
  qty: number;
  unit_price: Money;
  line_total: Money;
  notes: string | null;
  modifiers: OrderLineModifier[];
}

export interface OrderPayment {
  provider: string;
  status: string;
}

export interface Order {
  id: string;
  guest_token: string;
  number: number;
  status: OrderStatus;
  kind: "dine_in" | "takeaway" | "counter";
  subtotal: Money;
  discount_total: Money;
  total: Money;
  eta_minutes: number | null;
  payment: OrderPayment | null;
  items: OrderLine[];
  placed_at: string | null;
  accepted_at: string | null;
  ready_at: string | null;
  served_at: string | null;
}

export interface HistoryEntry {
  id: string;
  guest_token: string;
  number: number;
  status: OrderStatus;
  total: Money;
  venue_name: string;
  placed_at: string | null;
}

export interface AuthTokens {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  user: { id: string; email: string };
}

export interface ApiClientConfig {
  baseUrl: string;
  /** Bearer access token, if the caller is signed in — omit for guest-token-only calls. */
  accessToken?: string;
}

export class ApiError extends Error {
  status: number;
  body: unknown;

  constructor(status: number, body: unknown) {
    super(
      typeof body === "object" && body !== null && "error" in body
        ? String((body as { error: unknown }).error)
        : `API error ${status}`,
    );
    this.status = status;
    this.body = body;
  }
}

async function request<T>(
  config: ApiClientConfig,
  method: "GET" | "POST" | "DELETE",
  path: string,
  body?: unknown,
): Promise<T> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (config.accessToken) headers.authorization = `Bearer ${config.accessToken}`;

  const response = await fetch(`${config.baseUrl}${path}`, {
    method,
    headers,
    body: body === undefined ? undefined : JSON.stringify(body),
  });

  if (response.status === 204) return undefined as T;

  const json = await response.json();
  if (!response.ok) throw new ApiError(response.status, json);
  return json as T;
}

export function createApiClient(config: ApiClientConfig) {
  return {
    // Auth (Feature 23 Commit 1)
    requestMagicLink: (email: string) =>
      request<{ message: string }>(config, "POST", "/auth/request_magic_link", { email }),
    confirmMagicLink: (token: string) =>
      request<AuthTokens>(config, "POST", "/auth/confirm", { token }),
    refresh: (refreshToken: string) =>
      request<AuthTokens>(config, "POST", "/auth/refresh", { refresh_token: refreshToken }),
    logout: (refreshToken: string) =>
      request<void>(config, "POST", "/auth/logout", { refresh_token: refreshToken }),

    // Customer flow (Feature 23 Commit 2, Feature 24 Commit 1)
    getMenu: (venueSlug: string) => request<Menu>(config, "GET", `/venues/${venueSlug}/menu`),
    addToCart: (
      venueSlug: string,
      args: {
        item_id: string;
        qty: number;
        guest_token?: string;
        table_id?: string;
        option_ids?: string[];
        notes?: string;
      },
    ) =>
      request<{ guest_token: string; cart: Cart }>(
        config,
        "POST",
        `/venues/${venueSlug}/cart/items`,
        args,
      ),
    checkout: (args: {
      venue_slug: string;
      guest_token: string;
      payment_method?: "wallet" | "cash";
      wallet_msisdn?: string;
    }) => request<Order>(config, "POST", "/orders", args),
    getOrder: (guestToken: string) => request<Order>(config, "GET", `/orders/${guestToken}`),
    getTable: (qrToken: string) =>
      request<{ venue_slug: string; table_id: string }>(config, "GET", `/tables/${qrToken}`),
    callWaiter: (guestToken: string) =>
      request<void>(config, "POST", `/orders/${guestToken}/call_waiter`),
    rateItem: (guestToken: string, orderItemId: string, stars: number) =>
      request<void>(config, "POST", `/orders/${guestToken}/items/${orderItemId}/rate`, {
        stars,
      }),

    // Signed-in (Feature 24 Commit 1)
    getHistory: () => request<{ orders: HistoryEntry[] }>(config, "GET", "/me/history"),

    // Push (Feature 23 Commit 5)
    registerDevice: (deviceToken: string, platform: "ios" | "android") =>
      request<void>(config, "POST", "/devices", { token: deviceToken, platform }),
    unregisterDevice: (deviceToken: string) =>
      request<void>(config, "DELETE", `/devices/${deviceToken}`),
  };
}

export type ApiClient = ReturnType<typeof createApiClient>;
