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

| Component | Module / function | Used on | Notes |
|---|---|---|---|
| `<.money>` | `TabletapWeb.CoreComponents.money/1` (+ `format_money/2` for bare strings) | Manager `/menu`, public menu | The ONLY way to render money. `tabular-nums` span; takes `amount` (Money) and optional `locale`. Falls back to the app default locale when CLDR lacks currency data for the requested locale (e.g. :ETB under :so) instead of raising `Localize.CurrencyNotLocalizedError`. |
| Menu item preview card | `TabletapWeb.Manager.MenuLive.preview_grid/1` (private) | Manager `/menu` Preview tab | POS-style card: `rounded-box bg-base-100 shadow-sm p-4 text-center`, circular photo (`size-28 sm:size-32 rounded-full object-cover`), name `font-semibold`, price `font-bold text-primary`, availability line `text-xs text-base-content/50` ("Off today" / "N Available" from daily limits). Promote into `menu_components.ex` as `<.menu_item_card>` when the customer/POS surfaces need it. |
| Category filter chip | inline in `TabletapWeb.Manager.MenuLive.render/1` | Manager `/menu` | Pill buttons: active `btn btn-sm rounded-full btn-soft btn-primary border-primary/20`, inactive `bg-base-100 border-base-300 font-medium`. |
| Search pill | inline in `TabletapWeb.Manager.MenuLive.render/1` | Manager `/menu` | daisyUI `label.input` with `rounded-full bg-base-100`, hero-magnifying-glass prefix, `phx-debounce="300"`. Out-of-stock counter sits beside it: `text-sm font-semibold text-primary`. |
| Manager content canvas | `TabletapWeb.Layouts.manager/1` | All manager pages | `<main>` uses `bg-base-200` so `bg-base-100` cards read as raised surfaces (screenshot-style warm canvas). Cards on manager pages should prefer `shadow-sm` over borders. |
| Modifier rules badge | `rules_label/1` in `Manager.ModifiersLive` / `group_rules_label/1` in `Manager.MenuLive` (private, duplicated) | Manager `/menu/modifiers`, item-edit modal | `badge badge-ghost badge-sm` reading "Pick 0–3" (en dash) or "Pick 1" when min==max; a separate `badge badge-primary badge-soft` "Required" badge sits beside it. Promote to a shared `<.modifier_rules>` component when Feature 07's customer `<.modifier_sheet>` needs the same labels. |
| Price-delta display | `delta_sign/1` + `<.money>` in `Manager.ModifiersLive` | Manager `/menu/modifiers` | Deltas ALWAYS render through `<.money>` like every other amount; a bare "+" text node is prefixed when the delta is positive (`+$1.00`) so it reads as a change, not a price. `<.money>` itself renders the minus for negatives. Reuse this convention on the customer modifier sheet. |
| Group card w/ inline option form | inline in `Manager.ModifiersLive.render/1` | Manager `/menu/modifiers` | Same `rounded-box bg-base-100 shadow-sm p-5` card + `divide-y divide-base-300` rows as MenuLive's category cards. The add/edit option form swaps in-place inside the card (`rounded-field bg-base-200/60 p-3`), one form visible at a time via `option_form_target`. |
| Item modal section rows | `item_edit_modal/1` in `Manager.MenuLive` | Item-edit modal | Stacked `border-t border-base-300 p-5` sections under the form, each headed by a mono-ish `text-xs font-semibold uppercase tracking-wide text-base-content/50` label ("Modifier groups", "Quantity available today"). New per-item config (Feature 06+) should append another section, not a new modal. |

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
