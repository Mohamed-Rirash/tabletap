# Architecture

## Stack

| Layer | Tool | Purpose |
|---|---|---|
| Language / Runtime | Elixir 1.17+ / OTP 27 | Concurrency model fits many-venues-many-live-orders perfectly |
| Framework | Phoenix 1.8 | Web framework; Scopes for tenant-safe data access, magic-link auth via `phx.gen.auth` |
| UI | Phoenix LiveView 1.x + Tailwind CSS 4 + daisyUI | All surfaces (customer PWA, waiter, KDS, POS, back office) are LiveViews — real-time by default |
| Database | PostgreSQL 16 | Single database, foreign-key multi-tenancy (`org_id` on every tenant-owned row) |
| ORM | Ecto + `ecto_sql` | Schemas, changesets, tenant-enforcing Repo |
| Background jobs | Oban | Webhook processing, notifications, daily rollups, report exports, unclaimed-order escalation timers |
| Payments (customer → venue) | **WaafiPay** (custom client on `req`) behind a `Payments.Provider` behaviour | Push-PIN wallet charges (ZAAD / EVC Plus / Sahal / WAAFI) on the **venue's own merchant credentials**; adapters to follow: eDahab, Chapa (Ethiopia: Coopay-Ebirr/telebirr/M-Pesa), Stripe (future markets). See design-qa.md Q57–Q59 + `research/` notes |
| Payments (venue → us) | Fee ledger + monthly wallet invoice | Plan price + accrued per-order fees, collected via push prompt from our own merchant account (no Stripe Billing in launch markets; no recurring-mandate API exists) |
| Money | `ex_money` + `ex_money_sql` | Currency-safe amounts stored as `money_with_currency` composite type |
| QR codes | `qr_code` | Table QR generation (SVG for print sheets, PNG for display) |
| Real-time | Phoenix PubSub + Presence | Order events, KDS/waiter boards, waiter on-shift presence |
| Push notifications | Web Push (VAPID) via `web_push_ex` | Waiter new-order/call-waiter alerts on installed PWAs |
| Email | Swoosh + Postmark (or SES) adapter | Magic links, staff invites, receipts, restock reports. Real transactional provider with SPF/DKIM from day one — auth depends on deliverability (design-qa.md Q47) |
| HTTP client | Req | WaafiPay API calls, provider callback verification helpers, outbound calls |
| File storage | S3-compatible (Tigris/S3) via `ex_aws_s3` | Menu item photos, venue logos |
| Mobile apps | React Native + Expo (TypeScript) | Two apps: **TableTap** (customer) and **TableTap Staff** (waiter + owner modes). Chosen over Flutter because the **official** `phoenix` JS channels client covers our hardest integration need (real-time); no payment SDK is needed on either stack now that checkout is wallet-push, not card (design-qa.md Q57); over native Swift/Kotlin because two codebases beat four (LiveView Native itself is archived Feb 2026) |
| Mobile real-time | `phoenix` npm client over Phoenix Channels | Same official client the web uses; waiter queue + order tracker subscribe to the same topics |
| Mobile payments | None needed — wallet push | Customer submits their wallet number and approves with their PIN on the phone itself; the app just shows live payment state (no card SDK at launch) |
| Mobile QR scanning | `expo-camera` barcode scanning | Waiter scan-to-serve + customer table scan in-app |
| Mobile push | Expo Notifications (APNs + FCM) | Staff app: assignments/calls; customer app: order status |
| Deploy | Fly.io or any Docker host | ≥2 clustered nodes (build-plan.md Feature 21) — `DNSCluster` (already Phoenix-scaffolded) discovers siblings via `DNS_CLUSTER_QUERY` (Fly.io: the app's own internal DNS name); `Phoenix.PubSub`'s default `:pg` adapter needs no further config once nodes connect, verified locally (two BEAM nodes, connected, a broadcast on one received by a subscriber on the other) |

---

## Application Structure

Single Phoenix app (no umbrella). Bounded contexts under `lib/tabletap/`:

```
lib/tabletap/
├── accounts/          → Users (staff + customers), magic-link auth, scopes
├── tenants/           → Organizations, venues, memberships, subscription state
├── catalog/           → Categories, menu items, modifier groups/options, tags, daily limits
├── inventory/         → Ingredients, recipes (BOM), stock levels/movements, wastage
├── ordering/          → Carts, orders, order items, state machine, waiter assignment
├── payments/          → Provider behaviour + adapters (WaafiPay first), merchant credentials, charges, refunds, callbacks + reconciliation polling, platform fee ledger
├── staffing/          → Shifts, waiter availability, staff performance metrics
├── feedback/          → Item ratings, venue rating aggregates
├── analytics/         → Daily rollups, dashboards queries, exports
└── notifications/     → Web push subscriptions, notification fan-out

lib/tabletap_web/
├── live/
│   ├── customer/      → Public: menu, cart, checkout, order tracker  (scanned via QR, no auth required)
│   ├── waiter/        → Order queue, claim/serve, scan-to-confirm
│   ├── kitchen/       → KDS board
│   ├── pos/           → Cashier grid, cash checkout
│   ├── manager/       → Menu builder, inventory, staff, tables, reports
│   └── admin/         → Platform admin (tenants, plans)
├── controllers/
│   ├── api/v1/        → JSON API for future native apps (menu, orders, auth tokens)
│   └── callback_controller.ex → payment provider callbacks (HMAC-verified; WaafiPay first)
└── components/        → Shared function components (see ui-registry.md)
```

**Context rule:** contexts never call each other's Repo queries directly — they call each other's public functions. `Ordering` calls `Inventory.deduct_for_order/2`, never `Repo.get(Ingredient, …)`.

---

## Multi-Tenancy

**Strategy: foreign-key tenancy** (one database, `org_id` column on every tenant-owned table) — not schema-per-tenant. Cheaper migrations, works with Ecto's tooling, and Phoenix 1.8 Scopes make it safe.

Three enforcement layers — all must hold:

1. **Phoenix Scope struct** — every authenticated request/LiveView carries `%Scope{user, org, venue, role}`. All context functions take the scope as their first argument (`Catalog.list_items(scope)`), and generators are configured with this default scope.
2. **Repo enforcement** — `Repo.prepare_query/3` raises unless the query carries `org_id: id` or explicit `skip_org_id: true` (allowed only in `Accounts`, `Tenants` lookup paths, and platform admin). Org id is placed in the process dictionary per request via `Repo.put_org_id/1`, applied through `default_options/1`.
3. **Composite foreign keys** — child tables reference parents with `(parent_id, org_id)` composite FKs so a row can never point at another tenant's parent.

**Customer data is NOT tenant-owned.** `users` (customers), their cross-venue order history view, and ratings live at the platform level; orders belong to a venue (tenant) but carry a nullable `customer_user_id` so the same identity aggregates across venues.

---

## Data Model

### Tenancy & Accounts

| Table | Key fields | Notes |
|---|---|---|
| `orgs` | name, slug, stripe_customer_id, subscription_status, plan, trial_ends_at | The tenant. Billing state cached from Stripe Billing webhooks. **14-day free trial, no card** (design-qa.md Q29): full features + live ordering during trial; expiry without a plan = billing wall + "temporarily unavailable" QR menu |
| `venues` | org_id, name, slug, logo_url, address, geo, currency, timezone, opening_hours (jsonb), payment_provider (`waafipay`\|`edahab`\|`chapa`\|`stripe`), payment_merchant_credentials (encrypted — Cloak/AES-GCM, never logged), charges_enabled (bool), ordering_paused_until (nullable), eta_inflation_factor (default 1.0), pay_at_counter_enabled (bool), locale, fulfillment_mode (`waiter`\|`pickup`, default `waiter`), pickup_timeout_minutes (default 15), business_day_cutoff (time, default 04:00) | One restaurant/café location. The venue's **own** wallet merchant credentials — charges land venue-direct (design-qa.md Q57/Q58); `charges_enabled` set by a verification charge at onboarding. Menu prices are final — no tax/tip/service-charge math anywhere. Busy Mode = pause/slow fields (design-qa.md Q2). `opening_hours` jsonb includes date-specific overrides (holidays/special hours). `locale` drives customer-surface language (Gettext) + money formatting; RTL locales supported via logical-property CSS. **`currency` locks at the venue's first order** — changing currency means a new venue; timezone/cutoff stay editable with a historical-dates warning (design-qa.md Q53). `fulfillment_mode: pickup` = counter-service venue, no waiter loop (design-qa.md Q18). `business_day_cutoff`: the business day runs cutoff-to-cutoff in venue time — daily limits, Z-report, rollups, and "today" all respect it (design-qa.md Q20) |
| `users` | email, name, hashed_password (staff, optional), confirmed_at | One table for staff AND customers — role comes from memberships |
| `memberships` | org_id, venue_id, user_id, role (`owner`\|`manager`\|`cashier`\|`waiter`\|`kitchen`), active | Per-venue staff role; owner rows have `venue_id: nil` (org-wide) |
| `staff_invites` | org_id, venue_id, email, role, token, expires_at | Invite-link onboarding for staff |

### Floor & Catalog

| Table | Key fields | Notes |
|---|---|---|
| `tables` | org_id, venue_id, number, label, qr_token (unique), active | `qr_token` is an opaque random token — the QR encodes `https://app/t/:qr_token`. Reprintable (rotate token) |
| `menu_categories` | org_id, venue_id, name, position, active | |
| `menu_items` | org_id, venue_id, category_id, name, description, photo_url, price (money), prep_minutes, active, available_today, dietary_tags[], allergen_tags[], position | `available_today` togglable per day |
| `modifier_groups` | org_id, venue_id, name, min_selections, max_selections, required | e.g. "Size" (min 1 max 1 required), "Extras" (min 0 max 5) |
| `modifier_options` | org_id, group_id, name, price_delta (money), default, active, ingredient_id (nullable), ingredient_qty_delta | Price and (optionally) stock effect of the option |
| `item_modifier_groups` | org_id, item_id, group_id, position | Many-to-many; groups are reusable across items |

**Combos/meal deals need no extra schema:** a combo is a `menu_item` priced at the bundle price whose required modifier groups are the choices ("Choose your burger" min 1 max 1, "Choose your side", "Choose your drink"); premium choices carry price deltas, and stock effects ride on the options' `ingredient_id`/`ingredient_qty_delta`. The menu builder exposes this as a "Combo" template preset; managers compose combos entirely themselves — any choice groups, any options, any bundle price (founder confirmation, design-qa.md gap analysis).
| `daily_item_limits` | org_id, venue_id, item_id, date, limit_qty, sold_qty, reserved_qty | "50 rice today" — holds reserved atomically at checkout (`pending_payment`), converted to sold on payment, released on expiry; sold out when `sold + reserved = limit`. `date` is the **business date** (cutoff-aware) |

**Archive, never delete (design-qa.md Q41):** `menu_items`, `menu_categories`, `ingredients`, and `tables` carry `archived_at`. Hard delete is allowed only with zero references (never ordered / no movements / no items / no orders); anything with history is archived — gone from menus and pickers, intact in every snapshot, report, and FK.

### Inventory

| Table | Key fields | Notes |
|---|---|---|
| `ingredients` | org_id, venue_id, name, unit (`g`\|`ml`\|`piece`), stock_qty (decimal), min_threshold, cost_per_unit (money), active | Stock kept in base units only (grams, milliliters, pieces) — conversions happen at input time |
| `recipe_lines` | org_id, menu_item_id, ingredient_id, qty_per_serving (decimal) | The BOM: one row per ingredient per item |
| `stock_movements` | org_id, venue_id, ingredient_id, qty_delta, reason (`restock`\|`sale`\|`wastage`\|`adjustment`), unit_cost (money, nullable — set on restocks; snapshots what was actually paid, powering purchase-expense and profit reports), order_id (nullable), staff_user_id, note, inserted_at | Append-only ledger. `stock_qty` is a cached sum, movements are the truth. A restock also updates `ingredients.cost_per_unit` to the latest price |

### Ordering & Payments

| Table | Key fields | Notes |
|---|---|---|
| `carts` + `cart_items` | org_id, venue_id, table_id (nullable), guest_token, customer_user_id (nullable), status (`active`\|`converted`\|`abandoned`); items: menu_item_id, qty, notes, selected option ids | **DB-backed** so carts survive reconnects, deploys, and phone locks (design-qa.md Q50) — one active cart per guest_token+venue, rebuilt on every LiveView mount, selections revalidated at checkout (Q42), abandoned carts swept after 24h |
| `orders` | org_id, venue_id, table_id (nullable for takeaway/walk-in), customer_user_id (nullable), guest_token, number (per-venue sequence per **business day** — keys on `business_day_cutoff`, design-qa.md Q39), kind (`dine_in`\|`takeaway`\|`counter`), status, placed_at, accepted_at, ready_at, served_at, closed_at, waiter_membership_id, placed_by_membership_id (nullable — set when staff place the order on a customer's behalf), subtotal, discount_total, total (all money), notes | The core aggregate. **Totals math: `total = subtotal − discount_total`** — computed server-side only. `guest_token` lets an anonymous customer track their order |
| `order_discounts` | org_id, order_id, order_item_id (nullable = whole order), amount (money), reason, staff_membership_id | Manager/cashier applied, permission-gated, always attributed |
| `order_items` | org_id, order_id, menu_item_id, name_snapshot, unit_price_snapshot (money), qty, line_total (money), notes | Snapshots survive later menu edits |
| `order_item_modifiers` | org_id, order_item_id, option_id, name_snapshot, price_delta_snapshot (money) | Chosen customizations, snapshotted |
| `payments` | org_id, venue_id, order_id, provider (`waafipay`\|`edahab`\|`chapa`\|`stripe`\|`cash`\|`comp`), provider_txn_id, wallet_msisdn_masked, amount, status (`pending`\|`succeeded`\|`refunded`\|`failed`\|`expired`), cashier_membership_id (nullable) | Wallet charges carry the provider's transaction id (idempotency + reconciliation key) and a masked customer wallet number. Cash rows recorded by cashier POS. **`comp`** = 100%-discounted order (total 0): no charge attempted, manager-permission-gated, reason required — the order still fires and stock still deducts (design-qa.md Q30) |
| `platform_fee_ledger` | org_id, venue_id, order_id, amount (money), accrued_at, settled_at (nullable), invoice_id (nullable) | Per-order platform fee accrual — no split-payment API exists on wallet rails, so fees are collected monthly with the subscription invoice (design-qa.md Q59) |
| `refunds` | org_id, payment_id, amount, reason, provider_refund_id (nullable — null = **cash refund**), status (`pending`\|`succeeded`\|`failed`), staff_user_id | Cash refunds subtract from expected cash in shift summaries and the Z-report (design-qa.md Q22). Stripe refund failures (`refund.failed` webhook) alert the manager loudly — never silent (Q23). **Over-refund guard** (Q35): created inside one transaction with the payment row locked, validating `amount ≤ paid − existing refunds`; a line item refunds once. Refunds report on the **refund's business day**, never the sale's (Q37) |

### Staffing, Feedback, Analytics

| Table | Key fields | Notes |
|---|---|---|
| `shifts` | org_id, venue_id, membership_id, started_at, ended_at, auto_closed (bool) | Waiter/cashier clock in/out; only open-shift waiters get assignments. Forgotten clock-outs auto-close at the business-day cutoff, flagged (design-qa.md Q45). Deactivating a membership force-ends its open shift + hands open orders to the claim board (Q44) |
| `waiter_calls` | org_id, venue_id, table_id, order_id, status (`open`\|`acknowledged`\|`resolved`), inserted_at | "Call waiter" button events |
| `item_ratings` | org_id, venue_id, order_item_id (unique), menu_item_id, customer_user_id, stars (1–5), comment | One rating per served order item |
| `push_subscriptions` | user_id, endpoint, keys (jsonb) | Web Push per device |
| `daily_rollups` | org_id, venue_id, date, gross_sales, discounts, refunds, net_revenue, order_count, avg_check, channel_mix (jsonb), payment_mix (jsonb), hourly_orders (jsonb), items_sold (jsonb), ingredient_usage (jsonb), food_cost, staff_metrics (jsonb) | Oban nightly job; dashboards read rollups + today live. Full dashboard spec: owner-dashboard.md |

---

## Order State Machine

Single source of truth in `Ordering.OrderStateMachine`. Transitions are validated — an illegal transition raises; no LiveView flips a status by updating a column directly.

```
         (tap Pay: limits reserved        (payment succeeded, or
          atomically, intent created)      cashier cash-confirm)
  cart ────► pending_payment ──────────────► placed ──────► accepted ──────► preparing ──────► ready ──────► served ──────► closed
                  │  12-min TTL —              │   auto-assigned   waiter/kitchen      kitchen        waiter scans          auto after
                  │  Oban sweep expires        │   to waiter;      relays / KDS        marks ready    table QR to           rating window
                  │  stale holds, cancels      │   waiter accepts  starts ticket                      confirm delivery      or manager close
                  ▼  the PaymentIntent         │
              expired                          └──► cancelled ──► refunded (if a payment existed)
              (limits released)                     (customer before accepted; manager/cashier any
                                                    time before served; unserveable resolution)
```

Rules:
- **Limits are reserved at `pending_payment`, before any charge** (design-qa.md Q1): `UPDATE daily_item_limits SET reserved_qty = reserved_qty + n WHERE limit_qty - sold_qty - reserved_qty >= n` in the same transaction that creates the order — a failed reservation means "sold out" shown before payment, never a refund after
- An order only becomes `placed` after payment succeeds (provider callback or reconciliation poll confirms the wallet charge), a cashier records cash, a **pay-at-counter** code is confirmed by the cashier (venue toggle, design-qa.md Q3), or a **comp** settlement is recorded for a zero-total order (manager-gated, Q30). Success converts the hold: `reserved_qty -= n, sold_qty += n`. **No order reaches the kitchen without a recorded settlement — Stripe, cash, or comp.**
- Checkout gates (beyond limits): every cart line is **revalidated against current modifier rules** — structurally invalid lines (rules changed mid-cart) block with "please re-add," never a mis-configured paid order (Q42); totals below the provider's minimum charge get cash/pay-at-counter alternatives instead of a raw error (Q34 — per-provider config; effectively no minimum on wallet rails, ~$0.50 when a card adapter arrives); cart lines cap at 20 units (sanity insurance)
- **Pickup no-show** (pickup mode, design-qa.md Q32): `ready` for longer than `venues.pickup_timeout_minutes` (default 15) → flagged **not picked up** → manager/POS resolves like unserveable (refund / mark collected / close + wastage)
- `served` requires the waiter to scan the **same table's** QR token that the order was placed from (takeaway/counter: customer shows the order QR from their tracker screen instead). A waiter who can't find the customer flags the order **unserveable** → manager resolves (cancel+refund or convert to takeaway) — design-qa.md Q9. **Fallback:** manager-only **manual serve confirm** (attributed, telemetry-counted) for damaged/unreadable table QRs — design-qa.md Q19
- **Pickup mode** (`venues.fulfillment_mode: pickup`, design-qa.md Q18): no waiter assignment; `ready` notifies the customer, who shows their tracker QR at the counter — staff scans it → `served`. Same state machine, no `accepted`-by-waiter step (KDS accept covers it)
- **One-step-back transitions** (design-qa.md Q25): `ready → preparing` and `preparing → accepted` are legal for kitchen/manager — logged, telemetry-counted, and any pickup/waiter notification is retracted. `served` is irreversible (stock deducted)
- **Late payment success** (design-qa.md Q21): a provider success discovered after the hold expired (slow PIN entry, late reconciliation poll) → try to re-reserve limits atomically; success = order resurrects to `placed`; failure = automatic full refund + honest "sold out while confirming" tracker state
- **Expired cash orders** (design-qa.md Q26): a cashier entering an expired cash-order code can **Revive** it — atomic re-reserve; if stock is gone the POS names the sold-out item
- On `served`: `Inventory.deduct_for_order/2` writes `stock_movements` per recipe line (+ modifier ingredient deltas)
- Every transition broadcasts on PubSub (see Real-time) and appends a telemetry event (see code-standards.md).

---

## Waiter Assignment Algorithm

Goal from the product: "give the order to the most available waiter, first order served first."

```
Order becomes `placed` at venue V
        ↓
FULFILLMENT MODE: venue is `pickup` (counter-service, no waiters)?
  → yes: skip assignment entirely — KDS handles the ticket; `ready` notifies
    the customer to collect at the counter (design-qa.md Q18). Done.
  → no (`waiter` mode): continue ↓
        ↓
STICKINESS CHECK: does this order's table already have open orders?
  → yes: assign to that table's current waiter (one waiter owns a table
    per sitting — design-qa.md Q8). Done.
  → no: continue ↓
        ↓
Candidates = memberships with role=waiter at V with an open shift
             (Presence-confirmed, with ~30s flap grace — design-qa.md Q55)
        ↓
SOLO-WAITER SHORTCUT: exactly one candidate on shift?
  → auto-accept into their queue (no 90s window, no claim-board hop);
    manager alerted only by stalled-order watchdog thresholds (Q49). Done.
        ↓
Score each candidate = count of their open orders (accepted/preparing/ready)
        ↓
Assign to the lowest score; tiebreak = longest time since last assignment
(round-robin fairness). Write orders.waiter_membership_id, notify (push + PubSub)
        ↓
Waiter must ACCEPT within 90s (Oban escalation job scheduled at assignment)
        ↓
Not accepted in time → unassign → order appears on the venue-wide
claim board (all on-shift waiters) + manager alert. First to tap claims it.
No waiters on shift at all → order lands on claim board immediately + manager alert.
        ↓
Within one waiter's queue: FIFO — the UI always sorts oldest-placed first,
and "next up" is pinned.
```

Deliberately simple and legible for MVP (matches how Simple Host-style rotation tools work: balance by open workload, keep turn order). Weighting by party size/covers is a post-MVP refinement — noted in progress-tracker risks.

---

## Payments

**Launch reality (design-qa.md Q57 — supersedes Q17):** launch markets are Hargeisa, Mogadishu, and Jigjiga; Stripe operates in none of them. Payments run on mobile-money wallets behind **`Tabletap.Payments.Provider`** — a behaviour (`charge/2`, `refund/3`, `lookup/2`, `verify_callback/2`) with per-provider adapters. Research record: `research/somalia-payments-waafipay-zaad.md` + `research/ethiopia-payments-ebirr.md`.

| Adapter | Wallets covered | Status |
|---|---|---|
| **WaafiPay** | ZAAD (Somaliland), EVC Plus (south Somalia), Sahal (Puntland), WAAFI, cards | **MVP build target** — REST/JSON, sandbox + test numbers, preauth/commit/cancel, programmatic full/partial refunds, HMAC-SHA256-signed callbacks |
| eDahab | eDahab (Somtel) | Second Somali rail (docs.edahab.net) — post-pilot, when customer demand shows |
| Chapa | Coopay-Ebirr, telebirr, M-Pesa (Ethiopia, ETB) | Phase C / Jigjiga — eBirr has no public API of its own; gated on legal opinion (data localization) + Chapa spike (design-qa.md Q61) |
| Stripe | Cards, Apple/Google Pay | Future markets only; the Rounds 1–4 Stripe design is preserved in git history |

### Customer → Venue (per order): wallet push charge on the venue's own merchant account

```
Venue onboarding: manager enters the venue's WaafiPay merchant credentials
  (obtained from WaafiPay/Telesom — a manual, in-person process, so the
  platform onboarding checklist includes a guided "get your merchant
  account" step; credentials stored encrypted, verified by a test charge
  → charges_enabled; ordering disabled until true)

Checkout: customer taps Pay
  → order totals finalized server-side (subtotal − discounts)
  → customer enters/confirms their wallet phone number
  → Payments.charge(order) → provider API_PURCHASE on the VENUE's
    merchant credentials → push PIN prompt on the customer's phone
  → customer approves with their wallet PIN
    (hard ~5-min user timeout with explicit cancelled/timed-out codes —
     comfortably inside our 12-min stock hold)
  → confirmation arrives BOTH ways, first one wins (idempotent by
    provider_txn_id):
      a) signed callback (HMAC-verified) — WaafiPay does NOT retry these
      b) reconciliation poll (transaction-inquiry API) — Oban, ~30s cadence
         for every pending payment, final sweep before hold expiry
  → payments row → succeeded; order → placed; assignment kicks off
```

- Money flows **venue-direct** into the venue's own wallet/merchant account — the platform never holds customer money (unchanged invariant, and it keeps us out of money-transmitter territory).
- **Chargebacks do not exist** in mobile money — the dispute-evidence machinery (Q5/Q23) is dormant for wallet providers and wakes only for a future card adapter. No card minimums either — Q34's gate is per-provider config, effectively off for wallets.
- Refunds: programmatic full/partial via the provider adapter; same over-refund guard (Q35), refund-business-day reporting (Q37), and loud-failure alerts (Q23's principle, minus the Stripe-specific negative-balance mechanics). Cash refunds unchanged (Q22).
- Late confirmation (Q21 adapted): the 5-minute wallet timeout makes pay-after-expiry far rarer than 3DS, but the resurrection-or-refund path stays — a reconciliation poll can discover a success after our hold expired.
- Cash path (POS): cashier records a `payments` row with `provider: :cash` — same order lifecycle afterwards. **Cash orders carry no platform fee** — acknowledged pricing decision (Q24); platform admin tracks cash share per venue.

### Platform revenue: fee ledger + monthly wallet invoice (design-qa.md Q59)

No wallet rail offers marketplace/split payments, so the per-order fee can't be skimmed at charge time:
- Every wallet order accrues its fee to `platform_fee_ledger`
- Monthly, one itemized invoice (plan price + accrued fees) is collected via a push-prompt charge from **our own merchant account** to the owner's wallet — each collection is PIN-approved by the owner (no recurring-mandate API exists)
- Non-payment → existing `past_due` grace → suspended; the ledger survives and is collected on reactivation

### Venue → Platform (SaaS): subscription without Stripe Billing
- Plans priced in **pricing.md** (design-qa.md Q63, supersedes Q62): three **feature-tiered** plans, not just venue-count tiers. **Essentials** $40/venue/mo + 2.5% fee (1 venue, order loop only). **Growth** $75/mo + 1.5% fee (1 venue, adds inventory/recipes + full Report Center). **Pro** $55/venue/mo + 1.0% fee (2–10 venues, adds cross-venue comparison + org Profit rollup). Feature access is plan-gated in the web UI (nav items / routes for Inventory, Report Center, and Org Comparison check `org.plan` via a `Plans` context helper, not scattered `if` checks) — data for a gated feature is never deleted on downgrade, only made inaccessible (archive-never-delete, code-standards.md). `orgs.subscription_status` is **our** state machine, driven by invoice payment instead of Stripe webhooks. **Downgrade below venue count is blocked** (Pro→Growth/Essentials while venue count > 1) — the owner deactivates venues first; the system never picks which venues die (design-qa.md Q48). Billing is **monthly only** — no annual plan, since these rails have no recurring-mandate API (pricing.md § Billing). **Trial unlocks every tier's features for 14 days** regardless of eventual plan choice (design-qa.md Q29/Q63).
- **14-day free trial** (design-qa.md Q29): full features + live ordering during trial (per-order fees still accrue on wallet orders); `orgs.trial_ends_at` drives countdown banners from day 10; expiry without a plan behaves like `canceled`. "No card required" is now literal — there are no cards.
- `subscription_status != active` → back office shows billing banner; ordering keeps working during `past_due` grace, disabled on `canceled`. **Expiry (trial or cancellation) is enforced at the venue's next business-day cutoff** — never mid-dinner (design-qa.md Q40).

---

## Real-time Topology

PubSub topics (all venue-scoped; broadcast happens inside context functions, after the DB transaction commits):

| Topic | Events | Subscribers |
|---|---|---|
| `venue:{id}:orders` | order_placed, order_updated (every transition) | KDS board, manager live floor view, POS |
| `waiter:{membership_id}` | order_assigned, order_unassigned, waiter_called | That waiter's queue LiveView + web push fan-out |
| `venue:{id}:claim_board` | order_needs_claim, order_claimed | All on-shift waiter apps |
| `order:{id}` | status_changed, eta_updated | The customer's order tracker LiveView |
| `venue:{id}:inventory` | low_stock, item_sold_out | Manager dashboard, menu availability |

**Presence** on `venue:{id}:staff` tracks which waiters are connected & on shift — the assignment algorithm only considers Presence-visible waiters, so a waiter whose phone died stops receiving orders within a minute. A **~30s grace window** absorbs WiFi↔cellular flapping before a waiter loses candidacy, and presence-flap rate is telemetry per venue (design-qa.md Q55).

**ETA calculation:** rolling average `prep_minutes` per item over the last 20 served orders (fallback: the item's static `prep_minutes`), multiplied by kitchen queue depth ahead of this order. Recomputed on every venue order transition; pushed on `order:{id}`.

---

## Customer Identity & QR Flow

```
GET /t/:qr_token
  → resolves table → venue → puts {venue_id, table_id} in the session
  → gates: venue open (opening_hours), not Busy-Mode-paused, subscription
    active — else an honest "ordering paused / closed" page, never an error
  → redirects to the venue menu LiveView
  → returning guest with an active order sees a "You have an active
    order →" banner (guest_token lives in a 30-day cookie — design-qa.md Q13)
  → cart is DB-backed (guest_token minted on first add) — rebuilt from the
    carts table on every mount, so reconnects and deploys lose nothing (Q50)
  → rate limits: max active orders per guest_token (the real cap); the IP
    limit only throttles token minting — generous, venue-crowd scale, and
    never blocks a token with a paid/active order, because the whole
    restaurant shares the WiFi's IP (design-qa.md Q6 + Q33)
  → after payment, tracker URL /orders/:guest_token works with zero login
  → "Save your history" prompt offers magic-link signup; linking sets
    customer_user_id on the guest's orders (match by guest_token)
```

Customers with an account see `/me/history`: all orders across all venues, monthly spend, favorite items, and pending rating prompts. When a venue offboards and its tenant data is hard-deleted, account holders' orders survive as **anonymized platform-level stubs** — items, quantities, totals, date, venue shown as "a closed venue" (design-qa.md Q31).

---

## Mobile Apps & JSON API (`/api/v1`)

**Platform split (per-job best tool):** Elixir/Phoenix LiveView for backend + all web surfaces (manager back office, KDS, POS, and owner's web dashboard); **React Native + Expo (TypeScript)** for the two mobile apps. The QR-scan → browser PWA flow **remains the primary first-order path** — a first-time diner never needs an install; the apps serve repeat customers and staff.

| App | Users | Core screens |
|---|---|---|
| **TableTap** (customer) | Diners | Scan-to-order (in-app camera), venue menu + cart + wallet checkout (enter wallet number → approve PIN on phone), live order tracker, cross-venue history & spend, ratings |
| **TableTap Staff** | Waiter + Owner (mode by role at login) | Waiter: shift toggle, assigned queue, claim board, scan-to-serve, call alerts. Owner: today's live numbers, per-venue comparison, low-stock/delay alerts, subscription status |

Both apps consume:
- `/api/v1` REST (token auth via `Phoenix.Token` bearer; login = magic link deep-link into the app):
  `GET /venues/:slug/menu`, `POST /orders`, `GET /orders/:id`, `POST /waiter/orders/:id/accept|served`, `GET /owner/dashboard`, device push-token registration
- **Phoenix Channels** over the official `phoenix` JS client for everything live: `order:{id}` (tracker), `waiter:{membership_id}` (queue), `venue:{id}:claim_board`, `venue:{id}:orders` (owner live view) — the exact topics the LiveViews use
- Expo push tokens stored alongside web-push subscriptions; `Notifications` context fans out to both

API controllers and LiveViews call the **same context functions** — no business logic in either. A feature isn't done until both surfaces behave identically.

---

## Reliability — No Downtime, No Lost Orders

Two distinct guarantees, solved at different layers. The hard promise is **zero order loss**; availability is an SLO (99.9%+), because 100% uptime does not exist and pretending otherwise leads to worse designs.

### The order-durability chain (an order paid is an order served)

```
1. The provider holds the payment truth — and we POLL it
   Wallet callbacks are not retried (WaafiPay), so callbacks are only an
   optimization: every pending payment is reconciliation-polled via the
   transaction-inquiry API (Oban, ~30s cadence, final sweep before hold
   expiry). App down when the customer pays? On recovery the poller finds
   the success and the order materializes. Delayed ≠ lost.
        ↓
2. Committed Postgres row before anything else
   Order + daily-limit reservation in one transaction. Everything downstream
   (assignment, KDS, notifications) derives from this row.
        ↓
3. Side-effects are Oban jobs (stored in Postgres, retried, idempotent)
   Crash mid-assignment → job survives restart and re-runs. Idempotency
   means a retry can never double-assign or double-charge.
        ↓
4. PubSub is an optimization, never the source of truth
   Boards re-read DB state on mount and every LiveView reconnect. A missed
   broadcast = seconds of staleness on one screen, never a vanished order.
        ↓
5. Liveness watchdogs — an order can be late, never silently stuck
   90s unaccepted → claim board + manager alert; KDS overdue pulse;
   manager "open orders older than X" alert (Oban cron sweep).
```

### Availability

| Layer | Mechanism |
|---|---|
| Runtime | BEAM/OTP supervision — every session/job is an isolated supervised process; one crash restarts one process, never the app. This is why Elixir was chosen |
| App tier | ≥ 2 clustered nodes (libcluster; PubSub is cluster-wide) behind a load balancer; rolling deploys → zero-downtime releases; LiveView clients auto-reconnect and re-sync to a surviving node |
| Database | The only stateful piece → managed Postgres, synchronous standby + automated failover, WAL/PITR (RPO ≈ 0, RTO minutes), backups restore-tested on a schedule |
| Jobs | Oban state lives in Postgres — survives any app restart/redeploy |
| Payment gateway outage (WaafiPay) | QR wallet payments pause with an honest banner; cashier/cash path keeps the venue serving; the reconciliation poller catches up in-flight charges when the gateway recovers |
| Push outage | Web push is never the only channel — in-app PubSub delivery always exists |
| Traffic spikes | Rate limiting on public routes; per-venue PubSub topics isolate load; load ceiling measured in the Phase-7 load test |
| Observability | Telemetry → dashboards + alerts: webhook-lag p95 > 10s, Oban queue depth, DB failover, external uptime probe on the order placement path |

**Client-side resilience:** every surface shows the reconnecting bar when the socket drops (ui-rules.md); the customer's tracker URL and the waiter queue fully restore from the DB on reconnect — a phone dying loses nothing, and an unreachable waiter stops receiving assignments within 60s (Presence liveness).

---

## Invariants

Rules that must never be violated:

- **Every tenant-owned query is org-scoped** — enforced by `prepare_query`; `skip_org_id: true` appears only in `Accounts`, `Tenants`, and platform-admin code paths, nowhere else
- Context functions take `%Scope{}` as the first argument; web modules never call `Repo` directly
- Order status changes go through `OrderStateMachine.transition/3` only — never a bare `Repo.update` of `status`
- An order reaches the kitchen only after a recorded settlement — succeeded Stripe payment, recorded cash, or manager-gated comp (design-qa.md Q30) — no exceptions
- Prices/names on orders are **snapshots**; editing a menu item never rewrites history
- `stock_movements` is append-only; `ingredients.stock_qty` is derived and re-derivable
- Daily limit reservation happens atomically at `pending_payment` (checkout), **before any charge is attempted** — two customers can't both pay for the last portion, and a customer is never refunded because stock ran out after payment
- A `pending_payment` hold always resolves within its TTL: converted (paid), released (expired/cancelled) — the Oban sweep guarantees no permanently stranded stock
- Money is `ex_money` `Money` structs end-to-end — never floats, never bare integers in business code
- Provider confirmations (signed callback or reconciliation poll) are processed idempotently (unique `provider_txn_id`) and are the only path that marks a wallet payment `succeeded` — client-side state alone never trusts. A callback is never the only path: every pending payment has a poller backstop, because wallet callbacks are not retried
- All PubSub broadcasts fire **after** the DB transaction commits
- The platform never holds customer money — every charge lands venue-direct on the venue's own merchant account; platform revenue is collected separately (fee ledger + monthly subscription invoice, design-qa.md Q59)
- An order that reached `placed` can never be deleted or lost — it only ever moves forward through the state machine or exits via `cancelled`/`refunded`, and a watchdog surfaces any order stalled in a non-terminal state
- Real-time messages (PubSub, push) are never the only record of anything — every screen must be fully reconstructable from Postgres alone
