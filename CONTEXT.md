# TableTap — Domain Glossary

Distilled vocabulary for this repo. The `context/` directory is the full blueprint and the source of truth — when this file disagrees with `context/architecture.md` or `context/design-qa.md`, **they win and this file gets fixed**. Pre-code design decisions are `context/design-qa.md` Q1–Q56; implementation-time decisions go in `docs/adr/`.

Use these terms exactly in issue titles, test names, and proposals. Don't drift to synonyms.

## Tenancy & people

- **Org** — the tenant (one restaurant business, possibly a chain). Every tenant-owned row carries `org_id`.
- **Venue** — one physical location inside an org. Carries currency (immutable after first order), timezone, locale, `fulfillment_mode`, `business_day_cutoff`.
- **Membership** — a per-venue staff role (`owner|manager|cashier|waiter|kitchen`); owner rows are org-wide (`venue_id: nil`). The same person can hold different roles at different venues.
- **Scope** — `%Scope{user, org, venue, membership, role}`; the unit of authorization. Every context function takes it first.
- **Customer** — platform-level identity (not tenant-owned); cross-venue history hangs off `customer_user_id`.
- **Guest token** — 30-day cookie token that lets an anonymous diner cart, order, and track with zero login.

## Floor & catalog

- **Table / qr_token** — the QR on a table encodes `/t/:qr_token`; opaque, rotatable. Rotating kills the old code.
- **Modifier group / option** — per-item customization rules (min/max/required, price deltas, optional ingredient deltas).
- **Combo** — not a schema: a bundle-priced `menu_item` whose required modifier groups are the choices.
- **Daily limit / hold / reserved** — "50 rice today" per business date; quantities are **reserved atomically at checkout** (`pending_payment`), converted to sold on payment, released on expiry.
- **86 / auto-86** — instant kill-switch hiding an item mid-service; auto-86 fires when the recipe can't be fulfilled from stock. 86'ing flags open tickets containing the item.
- **Archive, never delete** — anything with history (items, categories, ingredients, tables) gets `archived_at`; hard delete only with zero references.

## Ordering & money

- **Order states** — `cart → pending_payment → placed → accepted → preparing → ready → served → closed` (+ `expired`, `cancelled`, `refunded`). One-step-back undo: `ready→preparing`, `preparing→accepted`. `served` is irreversible.
- **Settlement** — the iron rule: no order reaches the kitchen without a recorded settlement — **Stripe, cash, or comp**.
- **Comp vs void** — comp = made but free (`payments.provider: comp`, manager-gated, reason required, stock still deducts); void = never made (pre-payment line void).
- **Revive** — cashier re-reserves limits on an expired pay-at-counter code instead of making the customer re-order.
- **Application fee** — the platform's per-order cut on Stripe direct charges (`application_fee_amount`). Cash orders carry none (acknowledged pricing decision).
- **Assisted order** — an order placed by staff on a customer's behalf (`placed_by_membership_id`).
- **Discounts are pre-payment only** — after payment, every goodwill gesture is a refund.

## Fulfillment

- **Fulfillment mode** — venue-level `waiter` (assignment + serve-scan loop) or `pickup` (counter service: `ready` notifies the customer, staff scans their tracker QR).
- **Stickiness** — a table with open orders keeps its current waiter for the sitting.
- **Claim board** — venue-wide pool for unaccepted/escalated orders; first tap wins. Solo-waiter shifts skip it (auto-accept).
- **Unserveable / not picked up** — waiter can't find the customer / pickup order uncollected past `pickup_timeout_minutes`; manager resolves (refund, convert, mark collected, waste).
- **Busy Mode** — manager pause (20/40 min/until reopened) or ETA inflation when the kitchen is slammed.

## Inventory & accounting

- **Stock movement** — append-only ledger (`restock|sale|wastage|adjustment`); `stock_qty` is a derived cache.
- **Recipe / BOM** — per-item ingredient quantities; deduction happens at `served`.
- **Stocktake variance** — counted vs a snapshot of theoretical quantities taken at session start.
- **Business day / cutoff** — cutoff-to-cutoff in venue time (default 04:00); governs limits, order numbers, Z-reports, rollups, shift auto-close, expiry enforcement. One shared `Tenants.business_date/2` — never ad-hoc date math.
- **Z-report** — per-venue business-day close: totals by payment method, expected vs counted cash, discrepancies stored.
- **Rollup** — nightly `daily_rollups` row per venue-day; dashboards read rollups + live today.
- **Post-close adjustment** — a late event landing on a closed business day appears as a flagged addendum + rollup recompute, never a silent edit.
