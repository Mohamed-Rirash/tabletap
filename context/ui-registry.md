# UI Registry

Living document. Updated after every component is built. Read this before building any new component — match existing patterns exactly before inventing new ones.

---

## How to Use

Before building any component:

1. Check if a similar component already exists here
2. If yes — reuse it or match its exact structure, sizing, and tokens
3. If no — build it following ui-rules.md and ui-tokens.md, then add it here after building

After building any component:
- Add the component name, module/function path, key tokens used, and any non-obvious decisions
- If a component uses a special pattern (JS hook, stream, print CSS, Presence), note it here

Shared components live in `lib/tabletap_web/components/` — one module per component family (e.g. `order_components.ex`, `menu_components.ex`, `core_components.ex`).

---

## Components

_Empty. Components will be added here as they are built._

| Component | Module / function | Used on | Notes |
|---|---|---|---|
| | | | |

---

## Planned Component Families (build these as function components, not copy-paste markup)

### `core_components.ex` (extends Phoenix defaults)
- `<.status_chip status={:preparing} />` — the ONLY way to render an order status anywhere; maps status → `--status-*` token + label
- `<.money amount={@item.price} />` — the ONLY way to render money; wraps `Money.to_string!/2`, tabular-nums
- `<.stat_tile label value delta />` — dashboard tiles
- `<.skeleton kind={:card|:row|:tile} />` — loading placeholders
- `<.empty_state icon title cta />`
- `<.confirm_modal />` — typed-confirmation destructive dialog

### `menu_components.ex` (customer + POS)
- `<.menu_item_card item sold_out />`
- `<.modifier_sheet item groups />` — bottom sheet with live total (LiveComponent)
- `<.cart_bar count total />`
- `<.tag_chip tag />` — dietary/allergen

### `order_components.ex` (all staff surfaces + tracker)
- `<.status_timeline order eta />` — customer tracker
- `<.kds_ticket order />` — with elapsed-timer JS hook `TicketTimer`
- `<.waiter_order_card order variant={:next_up|:queued|:claimable} />`
- `<.order_line_items order />` — shared snapshot renderer (modifiers indented)

### JS Hooks (assets/js/hooks/)
- `QrScanner` — camera scan for serve-confirmation (vendored `qr-scanner` lib)
- `WalletCheckoutStatus` — polls/subscribes for the live "waiting for your PIN…" → succeeded/failed state during a wallet push charge (no payment SDK — approval happens on the customer's phone, this hook just reflects server state; design-qa.md Q57)
- `TicketTimer` — client-side elapsed/overdue ticking (server sends placed_at; client ticks — no per-second server messages)
- `PrintSheet` — window.print for the table QR sheet
- `SoundCue` — staff notification sounds with per-device localStorage toggle
- `CountUp` — dashboard stat entrance (respects prefers-reduced-motion)

---

## Patterns Reference

### Status rendering
Every order status shown to any user goes through `<.status_chip>` / `<.status_timeline>`. If a new surface needs status display, extend those components — never map status → color locally.

### Money rendering
`<.money>` only. It takes the `Money` struct; locale comes from the venue in scope. No template ever formats an amount by hand.

### Streams for boards
KDS columns, waiter queue, order lists, and stock movements all use LiveView streams keyed by DOM id `orders-#{id}` etc. PubSub events call `stream_insert/stream_delete` — never re-query the whole list on an event.

### Bottom sheets (mobile)
One shared sheet wrapper (drag-handle, radius-lg top, focus trap, `phx-click-away` dismiss) reused by the modifier sheet, cart, and waiter order detail.

### Print CSS
The QR sheet route renders a dedicated print layout (`@media print`, A4 grid, no nav). QR SVGs generated server-side by `qr_code` and inlined — no client rendering, so printing works even on flaky connections.
