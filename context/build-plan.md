# Build Plan

## Core Principle

Build vertically — one complete slice at a time, always ending in something a real venue could use. The spine of the product is **QR scan → order → pay → assign → serve → deduct stock**. Get that loop live and trustworthy before touching analytics, ratings, or polish. A beautiful dashboard means nothing if the order loop drops an order or oversells the last portion of rice.

Every feature ends with a **Verify** step. Do not start the next feature until the current one passes on a real phone (customer + waiter surfaces are mobile-first).

---

## Phase 1 — Foundation (Week 1)

### 01 Project Setup

```bash
mix phx.new tabletap --binary-id
cd tabletap

# deps to add in mix.exs (see library-docs.md for pinned usage patterns):
# oban, ex_money, ex_money_sql, cloak_ecto, qr_code,
# web_push_ex, ex_aws, ex_aws_s3, req (already), swoosh (already)
# (no payments SDK — the WaafiPay client is hand-rolled on req, see library-docs.md)

mix ecto.create
```

**Configure:**
- Tailwind 4 + daisyUI (ships with Phoenix 1.8) — apply ui-tokens.md theme variables
- Oban with queues: `default, webhooks, notifications, rollups, escalations`
- `ex_money` default currency config; Postgres `money_with_currency` migration from `ex_money_sql`
- Swoosh with a real transactional adapter (Postmark or SES) + SPF/DKIM on the sending domain — magic-link auth depends on deliverability (design-qa.md Q47); dev keeps the local mailbox preview
- CI: `mix format --check-formatted`, `mix credo --strict`, `mix test` on every push

**Verify:** `mix phx.server` boots; healthcheck route returns 200; CI green on the initial commit.

---

### 02 Auth & Scopes

- `mix phx.gen.auth Accounts User users --live` (Phoenix 1.8 magic-link default; staff also get optional passwords); **owner/manager accounts require a password** at setup so email delay can never lock a venue out (design-qa.md Q47); magic-link sends throttled per email address + per IP, form always answers "link sent if the account exists"
- Define the app Scope: `%Scope{user, org, venue, membership, role}`; configure it as the default scope for generators
- Session plugs/LiveView hooks: `assign_scope`, `require_role/2`

**Verify:** A user can sign up and log in via magic link; visiting a manager route without a membership is rejected.

---

### 03 Tenancy Core

- `orgs`, `venues`, `memberships`, `staff_invites` schemas + migrations (composite FK pattern from architecture.md)
- Tenant-enforcing Repo: `prepare_query/3` raising without `org_id`, `put_org_id/1` process-dict helper, `default_options/1`
- Org signup flow: create org → first venue → owner membership
- Venue switcher for multi-venue orgs

**Verify:** In IEx, querying `menu_items` (a stub table is fine) without org context **raises**. Two seeded orgs cannot see each other's venues through any context function. Owner signup lands in an empty venue dashboard.

---

## Phase 2 — Catalog & Floor (Week 2)

### 04 Menu Builder

- `menu_categories`, `menu_items` CRUD LiveViews (manager role), photo upload to S3, drag-to-reorder positions; **archive-not-delete** (`archived_at`) once an item/category has history — hard delete only if never referenced (design-qa.md Q41; same rule for ingredients and tables in their features)
- Availability toggle + `daily_item_limits` (set today's limit, live sold/remaining count)
- Dietary/allergen tag multi-select

**Verify:** Manager creates categories and items with photos on a phone-sized window; toggling availability hides the item from the (stub) public menu instantly.

---

### 05 Modifier Groups

- `modifier_groups`, `modifier_options`, `item_modifier_groups` CRUD, attach/detach groups to items with min/max/required rules
- Price-delta preview: item detail shows computed price range

**Verify:** "Hamburger" gets groups "Cheese (min 0 max 3, +$1/extra)" and "Remove (onions/pickles, $0)"; validation blocks max<min and required-with-min-0 configs.

---

### 06 Tables & QR Codes

- `tables` CRUD (archive-not-delete once a table has orders — design-qa.md Q41); `qr_token` generation and rotation
- Printable QR sheet LiveView (grid of SVG QR codes + table numbers, print CSS) — manager prints and laminates
- Public route `GET /t/:qr_token` → resolves venue+table into session → public menu LiveView (read-only for now)

**Verify:** Print preview shows crisp per-table QR codes; scanning one with a real phone camera opens that venue's live menu with the table number shown; a rotated token kills the old QR.

---

## Phase 3 — Ordering Loop (Weeks 3–4) ← the make-or-break phase

### 07 Customer Menu & Cart

- Public menu LiveView: category tabs, item cards (photo, price, tags), sold-out states from daily limits
- Item detail sheet: modifier group selection with live price recalculation, quantity (sanity cap 20/line), notes, validation of min/max
- **DB-backed cart** (`carts` + `cart_items`, keyed guest_token + venue, rebuilt on every mount — survives reconnects and deploys, design-qa.md Q50; abandoned sweep after 24h), dine-in vs takeaway toggle, sticky checkout bar; checkout **revalidates every line against current modifier rules** — structurally invalid lines (rules edited mid-cart) prompt "please re-add," never a crash (design-qa.md Q42)

**Verify:** On a real phone: scan → browse → customize a burger (extra cheese +$1, no onions) → cart shows the right total. Two carts on two phones at the same table stay independent.

---

### 08 Orders & State Machine

- `orders`, `order_items`, `order_item_modifiers` with snapshot fields
- Totals engine: `subtotal − discounts = total` (menu prices are final — no tax/tip/service-charge math), property-tested against hand-computed cases
- `OrderStateMachine` with the full transition table (incl. `pending_payment`, expiry, and **one-step-back undo**: `ready → preparing`, `preparing → accepted` for kitchen/manager, logged — design-qa.md Q25) + telemetry + PubSub broadcast-after-commit
- Atomic daily-limit **hold at checkout** (`reserved_qty`, before any charge — design-qa.md Q1); 12-min TTL with Oban sweep releasing stale holds
- **Business-day cutoff** (`venues.business_day_cutoff`, default 04:00 — design-qa.md Q20): daily limits, "today" queries, and everything downstream (Z-report, rollups) use the business date, not the calendar date
- Busy Mode: manager pause (20/40 min/until reopened) + ETA inflation + honest paused-menu state (design-qa.md Q2); opening-hours gate; rate limits: per-`guest_token` active-order cap is the real limit, IP only throttles token minting generously — the whole restaurant shares one WiFi IP (Q33)
- Order numbers: per-venue sequence keyed on **business date**, same cutoff as limits/reports (design-qa.md Q39)
- Customer order tracker LiveView at `/orders/:guest_token`: status timeline, live ETA (static prep_minutes × queue depth for now); 30-day guest cookie + active-order banner on re-scan

**Verify:** Concurrency test: two simultaneous checkouts for the last limited portion — exactly one reaches payment, the other sees sold-out **before** being charged. An abandoned checkout releases its hold within the TTL. Tracker updates within 2s when status changes from IEx.

---

### 09 Wallet Payments (Payments.Provider + WaafiPay adapter)

_Supersedes the Stripe Connect design — launch markets are Hargeisa/Mogadishu/Jigjiga (design-qa.md Q57–Q61; research/somalia-payments-waafipay-zaad.md)._

- **`Payments.Provider` behaviour** (`charge/2`, `refund/3`, `lookup/2`, `verify_callback/2`) + the **WaafiPay adapter** (custom client on `req`, sandbox first): covers ZAAD, EVC Plus, Sahal, WAAFI
- Venue onboarding: manager enters the venue's WaafiPay merchant credentials (encrypted via `cloak_ecto`, never logged) → verification charge → `charges_enabled`; onboarding checklist gains the guided "get your merchant account" step (manual/in-person with WaafiPay — the one step we can't compress)
- Checkout: customer enters/confirms wallet phone number → `API_PURCHASE` on the venue's credentials → **push PIN prompt** on the customer's phone (~5-min hard timeout, inside our 12-min hold) → confirmation via HMAC-verified callback **or** reconciliation poll, first wins, idempotent by `provider_txn_id`
- **Reconciliation poller** (Oban): every `pending` payment polled via transaction inquiry (~30s cadence, final sweep before hold expiry) — callbacks are never relied on (WaafiPay doesn't retry them)
- **Comp settlement** (design-qa.md Q30): zero-total order (100% discount) skips the charge and records `payments.provider: comp` — manager-gated, reason required, order fires normally, own line in all money reports
- Itemized digital receipt on the tracker (items, modifiers, discounts, total); email copy for account holders
- Checkout screen shows the venue's refund/cancellation policy line (sensible default — design-qa.md Q56)
- Refund flow (manager): full **and line-item partial** refunds via the provider adapter (design-qa.md Q4); stock never auto-restored on refund; **cash refunds** (no `provider_refund_id`) net against expected cash (Q22); **over-refund guard** — locked-payment transaction validates against paid − already-refunded, line items refund once (Q35); post-payment goodwill is always a refund, never a discount edit (Q36); refunds report on the refund's business day (Q37); refund failures → loud manager alert, never silent (Q23)
- **Late-success handling** (design-qa.md Q21): a poll/callback success on an `expired` order → atomic limit re-reserve → resurrect to `placed`, or auto-refund with an honest sold-out tracker state
- **`platform_fee_ledger`**: every wallet order accrues its per-order fee (no split-payment API exists — collected monthly with the subscription, feature 19)
- No chargebacks on wallet rails — dispute machinery dormant until a card adapter exists (Q5 note)

**Verify:** In the WaafiPay sandbox end-to-end on a phone: pay with a test wallet number → PIN prompt → money lands on the venue's test merchant account → order flips to `placed` → fee row appears in the ledger. Kill the callback (drop it deliberately) — the poller still confirms within a minute. Replaying a callback does nothing. A sandbox refund round-trips.

---

### 10 Waiter Assignment & Waiter App

- `shifts` (clock in/out), Presence on `venue:{id}:staff`
- Assignment: same-table stickiness first (one waiter owns a table per sitting — design-qa.md Q8), then lowest-open-workload + round-robin tiebreak; 90s Oban escalation → claim board; **solo-waiter shortcut** — exactly one waiter on shift auto-accepts, no 90s window, watchdog-only alerts (Q49); Presence with ~30s flap grace + flap-rate telemetry (Q55)
- **Pickup fulfillment mode** (`venues.fulfillment_mode: pickup` — design-qa.md Q18): counter-service venues skip waiter assignment entirely; `ready` notifies the customer to collect at the counter; tracker shows "Ask at the counter" instead of call-waiter (Q46)
- Staff lifecycle: deactivating a membership force-ends any open shift and pushes open orders to the claim board + manager alert (design-qa.md Q44); open shifts auto-close at the business-day cutoff, flagged `auto_closed` (Q45)
- Manager reassign action (chosen waiter or claim board) + waiter "Can't find customer" → unserveable flow (design-qa.md Q9/Q10)
- Waiter LiveView (mobile PWA): FIFO queue with "next up" pinned, accept button, order detail (items + customizations + table), claim board tab
- "Call waiter" button on the customer tracker → `waiter_calls` → assigned waiter's queue flashes

**Verify:** With two waiter phones on shift: three orders distribute by load, not round-robin blindly; turning off one phone's wifi routes new orders to the other within 60s; an unaccepted order hits the claim board at 90s.

---

### 11 Serve Confirmation & Stock Deduction

- Waiter "Mark served" opens camera scan (JS hook + `qr-scanner` lib) → must match the order's table `qr_token`; takeaway orders scan the customer's tracker QR instead; **pickup-mode venues scan the customer's tracker QR at the counter** (design-qa.md Q18)
- **Manager-only manual serve confirm** (design-qa.md Q19): scan fallback for damaged table QRs — attributed, telemetry-counted, prompts a QR reprint
- **Pickup no-show flow** (design-qa.md Q32): `ready` past `pickup_timeout_minutes` (default 15) → "not picked up" flag → manager/POS resolves (refund / mark collected / close + wastage)
- `served` transition calls `Inventory.deduct_for_order/2` (stub inventory OK until Phase 4 — write movements against seeded ingredients)
- `closed` auto-transition Oban job after the rating window (24h)

**Verify:** Serving at the wrong table's QR is rejected with a clear error; the right table flips the order to `served` and the customer's tracker celebrates; stock movement rows appear.

---

## Phase 4 — Inventory (Week 5)

### 12 Ingredients & Recipes

- `ingredients` CRUD (unit, cost, threshold; archive-not-delete once movements exist — design-qa.md Q41), `recipe_lines` editor on the menu item form (ingredient + qty per serving), modifier options optionally linked to an ingredient delta
- Unit-conversion input helpers (enter "1.5 kg", stored as 1500 g)

**Verify:** Burger recipe = bun 1pc, patty 150g, cheese 20g; the "extra cheese" option adds 20g. Serving a burger with extra cheese writes movements of exactly those quantities.

---

### 13 Stock Ops & Alerts

- Restock entry, manual adjustment, wastage log with reasons — all as `stock_movements`
- Low-stock detection on every deduction → `venue:{id}:inventory` broadcast + manager notification
- Restock report (name, current, threshold, suggested = threshold×2 − current), CSV export **+ print-ready purchase-order sheet** (print CSS, supplier-ready); restock entry records `unit_cost` paid and refreshes `ingredients.cost_per_unit`
- **86 an item**: one-tap kill-switch on manager live view + KDS; **auto-86** when a recipe can't be fulfilled from stock (manager notified, override available) — design-qa.md Q11; 86'ing **flags every open ticket containing the item** (KDS badge + manager alert listing affected orders — Q27)
- **Stocktake**: physical count entry → variance report (theoretical vs actual, valued at cost) + reconciling adjustment movement; negative stock allowed but flagged — design-qa.md Q14; the session **snapshots theoretical quantities at start** so mid-service sales can't corrupt the variance, UI recommends counting at close (Q43)

**Verify:** Dropping cheese below threshold pings the manager dashboard live; the restock CSV opens in a spreadsheet with correct numbers; a wastage entry reduces stock and appears in the ledger with its reason.

---

## Phase 5 — Kitchen & POS (Week 6)

### 14 Kitchen Display System

- KDS LiveView (tablet layout): ticket cards for `placed/accepted` orders → kitchen taps `preparing` → `ready`; per-ticket elapsed timer; delay highlight past expected prep time
- Waiter notified on `ready`

**Verify:** Full loop on three devices at once (customer phone, waiter phone, kitchen tablet): order flows scan→pay→accept→preparing→ready→served with every screen updating live, no refresh.

---

### 15 Cashier POS

- POS LiveView: visual item grid with modifier quick-sheet, running open ticket (edit/void lines before payment), order- or line-level discounts (permission-gated, reason required; a 100% discount routes to the manager-gated **comp** settlement — design-qa.md Q30), cash payment (recorded, change calculator) or wallet (cashier enters the customer's wallet number → push PIN prompt, same provider flow as QR checkout)
- Walk-in orders get `kind: :counter`, skip waiter assignment (cashier hands over), still hit KDS
- **Table assignment on POS orders**: staff can place a dine-in order for any table (the no-QR fallback for customers who won't scan) — enters the normal waiter/KDS pipeline with same-table stickiness
- **Cash-order verification** (if venue enabled): customer chose Cash at QR checkout → their screen shows an order number → cashier enters/scans it, takes cash, taps Verify paid → order fires (design-qa.md Q3); an **expired** code offers **Revive** (atomic limit re-reserve; names the sold-out item if gone — Q26)
- **Cash refunds** from the POS: attributed refund row (no `stripe_refund_id`), reason required, subtracted from expected cash in shift summary + Z-report (design-qa.md Q22)
- Cashier as full customer proxy: everything the QR flow offers (dine-in + table, takeaway, customization, notes) is doable from the POS on the customer's behalf
- **End-of-day close (Z-report)**: per-venue business-day close (respects `business_day_cutoff` — a 1am order belongs to yesterday) — day totals by payment method, expected vs counted cash per cashier shift (cash refunds netted), discrepancies flagged and stored; feeds the owner dashboard
- Cashier shift summary: transactions, cash total for reconciliation

**Verify:** Cashier rings up a takeaway coffee with oat milk in under 15 seconds; cash total for the shift matches the recorded payments.

---

## Phase 6 — Customer Identity, Ratings & Analytics (Week 7)

### 16 Customer Accounts & History

- Post-order magic-link signup; link `guest_token` orders to the new account
- `/me/history`: cross-venue order list, monthly spend, per-venue totals

**Verify:** A guest who ordered twice then signs up sees both orders; ordering at a second seeded venue shows both venues in one history.

---

### 17 Ratings

- Rating prompt on the tracker after `served` (stars per item + optional comment), one per order item
- Aggregates on menu items (avg + count) shown on the public menu; manager feedback screen

**Verify:** Rating from the customer phone appears on the manager screen live and updates the item's public average.

---

### 18 Analytics Dashboard & Rollups

- Nightly Oban rollup job → `daily_rollups` (business-day boundaries); dashboard reads rollups + live today
- **Closed days stay closed** (design-qa.md Q37/Q38): refunds count on the refund's business day; late-arriving orders/payments on a past business day enqueue a rollup recompute and appear as flagged "post-close adjustments" on that day's Z-report — never silent mutation of a report the accountant already saw
- Build to the full spec in **owner-dashboard.md**: Today live screen, Revenue & Sales, Menu Performance (incl. margin + menu-engineering quadrant), Feedback, Staff & Work Analytics, Inventory & Cost (food cost %, variance), Customers, org-wide venue comparison, alert feed
- Scheduled report emails **re-check membership + role at send time**; deactivation purges subscriptions and push tokens (design-qa.md Q52)
- **Report Center** (owner-dashboard.md § Report Center): 13 report types (revenue, orders, successful orders & bills, payments money-in, cashier daily cash, assisted orders, inventory, menu, feedback, employee work, customers, day-close, **profit P&L-lite**) × daily/weekly/monthly/yearly/custom **+ season/quarter grouping and same-period-last-year comparison**, CSV export, scheduled email delivery (daily close / weekly / monthly opt-ins); manager sees all venue reports, owner-only: cross-venue/billing/fees/org profit
- Date-range picker + CSV export (Oban job → email link)

**Verify:** Seed a month of fake orders; every number on every owner-dashboard.md screen reconciles with a hand-run SQL query; export CSV matches; Today screen updates live while a seeded order flows through its lifecycle.

---

## Phase 7 — Platform & Polish (Week 8)

### 19 Subscriptions & Platform Admin

- Subscription billing **without Stripe** (design-qa.md Q59): monthly itemized invoice = plan price + accrued `platform_fee_ledger` fees → push-prompt wallet charge from our own merchant account; `subscription_status` is our state machine with `past_due` grace; **14-day free trial** (`orgs.trial_ends_at`, countdown banner from day 10, expiry = billing wall + unavailable QR menu — Q29); expiry enforced at the venue's next business-day cutoff, never mid-dinner (Q40); platform admin shows trial states + cash-share per venue (Q24)
- Platform admin LiveView: tenants list, subscription states, per-tenant order volume, impersonation guard (read-only)
- `config/plans.exs`: **Essentials** ($40/venue/mo, 2.5% fee, 1-venue cap, order-loop features only), **Growth** ($75/venue/mo, 1.5% fee, 1-venue cap, adds inventory + Report Center), **Pro** ($55/venue/mo, 1.0% fee, 10-venue cap, adds cross-venue view) compiled config — numbers and feature gates from pricing.md (design-qa.md Q63, supersedes Q62); no annual billing (monthly-only, no recurring-mandate API on these rails)
- Feature gating: Inventory, Report Center, and Org Comparison nav/routes check `org.plan` via a `Plans` context helper (not scattered `if`s); gated data is never deleted on downgrade, only made inaccessible (archive-never-delete, code-standards.md) — see pricing.md § Downgrade & tier-change rules
- Data lifecycle tooling: customer account deletion (anonymize orders, purge PII/push tokens), tenant offboarding export + 90-day delete (design-qa.md Q15) — offboarding first archives account-holders' orders as anonymized platform-level stubs ("a closed venue") so cross-venue history keeps no holes (Q31); the payment/dispute-evidence subset is retained 180 days for the chargeback window, then purged (Q54)
- Plan changes: **downgrade blocked while venue count exceeds the target cap** (Essentials/Growth cap = 1) — billing screen names the blocker; owner deactivates venues first (design-qa.md Q48)

**Verify:** Test-mode subscribe/cancel flips org status and shows the billing banner; a canceled org's QR menu shows a "temporarily unavailable" page.

---

### 20 Notifications & PWA Hardening

- Web Push (VAPID): waiter new-order/call pings, manager low-stock — with in-app fallback always present
- Browser floor: iOS Safari 15+ / evergreen Chrome-Android (~2 years back) — QR flow tested there; below the floor, an honest "please update your browser" page (design-qa.md Q56)
- PWA manifests per surface (customer/waiter), service worker, offline shell ("you're offline, reconnecting…"), install prompts; **iOS staff onboarding requires install-to-home-screen** (blocks with instructions until installed) + loud in-app audio alert on assignment — accepted push-reliability risk until the Phase 8 staff app (design-qa.md Q28)
- Onboarding checklist widget for new venues (venue info ✓ wallet merchant setup ✓ menu ✓ tables ✓ first order ✓)

**Verify:** Locked waiter phone buzzes on a new order. Airplane-mode customer sees the reconnect shell, and their tracker recovers state on reconnect. A fresh venue completes the checklist to a first live order without help.

---

### 21 Reliability & Ops Hardening

- Two-node clustered deploy (libcluster) behind the platform's load balancer; verify PubSub works cross-node and rolling deploys drop zero LiveView sessions unrecoverably
- Managed Postgres HA (standby + automated failover) + WAL/PITR; run one real restore drill and document it
- Stuck-order watchdog: Oban cron sweep alerting managers on orders in a non-terminal state past thresholds
- Degradation banners: payment gateway unreachable (QR wallet payments paused, cash keeps working), reconnecting states audited on all five surfaces
- Alerting: webhook-lag p95, Oban queue depth, external uptime probe on `/t/:qr_token → order placed` synthetic check

**Verify (chaos drill):** kill one app node mid-order — customer, waiter, and KDS screens recover without losing the order. Kill the app entirely, complete a sandbox wallet payment while down, restart — the reconciliation poller finds the success and the order appears and assigns. Fail over Postgres — app reconnects and the in-flight order is intact.

---

### 22 Load & Security Pass

- Tenant-isolation audit: grep for `skip_org_id`, test cross-tenant access on every route with a second org's session
- Load test one venue at 50 concurrent carts + 200 open trackers; watch LiveView memory and DB pool
- Provider callback HMAC verification, callback-vs-poller race tests (both confirm the same payment concurrently — exactly one transition), rate limiting on public routes, Ecto sandbox concurrency tests for limits/assignment races

**Verify:** No cross-tenant read/write found; p95 order placement < 500ms under load; race tests green in CI.

---

## Phase 8 — Mobile Apps (Weeks 9–11)

React Native + Expo (TypeScript) monorepo (`apps/customer`, `apps/staff`, `packages/shared` for the API client, Channels wrapper, and design tokens mirrored from ui-tokens.md). Ships **after** the web MVP is live — the apps reuse `/api/v1` and the exact Channel topics, so nothing here blocks a venue from operating.

### 23 API & Auth Hardening for Mobile

- Finalize `/api/v1` (menu, orders, waiter ops, owner dashboard) + `Phoenix.Token` bearer auth with refresh; magic-link deep-linking (`tabletap://auth/:token`)
- Device registration endpoint: Expo push tokens into the notifications fan-out alongside web push
- Contract tests: every API response schema snapshot-tested; API and LiveView drive the same context functions

**Verify:** A scripted client (no UI) can log in, fetch a menu, place a paid test order, and receive the `order:{id}` channel events for every status change.

---

### 24 TableTap Customer App

- Expo app: scan-to-order (expo-camera), menu + modifier sheets + cart (shared design tokens), wallet checkout (enter wallet number → live payment state while the PIN prompt is approved on the phone), live tracker over Channels, order history & spend, ratings, push opt-in for order status
- EAS build + store submission (TestFlight / Play internal track first)

**Verify:** On one physical iPhone and one Android: scan a real table QR from inside the app → customize → sandbox wallet payment (PIN prompt approved on the phone) → live tracker updates through served — feature-parity with the PWA flow.

---

### 25 TableTap Staff App

- Waiter mode: shift toggle, assigned FIFO queue, claim board, accept/serve flow with in-app QR scan-to-serve, call-waiter alerts — push wakes a locked phone reliably (the reason this app exists)
- Owner mode: today's live revenue/orders (Channels), venue comparison, low-stock + delayed-order + subscription alerts
- Role detection at login; users with both roles get a mode switcher

**Verify:** Locked phone in pocket: new order buzzes within 3s of `placed`; full accept→scan→served flow works one-handed; owner mode numbers match the web dashboard live.

---

## Feature Count

| Phase | Features |
|---|---|
| Phase 1 — Foundation | 3 |
| Phase 2 — Catalog & Floor | 3 |
| Phase 3 — Ordering Loop | 5 |
| Phase 4 — Inventory | 2 |
| Phase 5 — Kitchen & POS | 2 |
| Phase 6 — Identity, Ratings & Analytics | 3 |
| Phase 7 — Platform & Polish | 4 |
| Phase 8 — Mobile Apps | 3 |
| **Total** | **25** |
