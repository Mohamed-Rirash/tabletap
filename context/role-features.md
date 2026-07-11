# Role Features

One-page reference: every user role, the surface they use, and every feature they get. Derived from project-overview.md and build-plan.md — if those change, update this file too. Feature numbers refer to build-plan.md.

---

## Customer (diner) — Customer PWA, no install, no forced login

| Feature | Detail | Built in |
|---|---|---|
| Scan & browse | Scan table QR → venue's live menu opens instantly; sold-out items marked live | 06, 07 |
| Customize items | Modifier groups: extra cheese +$1, no onions, sizes — live price updates | 07 |
| Order type | Dine-in (table auto-detected) or takeaway | 07 |
| Pay from phone | Mobile-money wallet (ZAAD / EVC Plus / eDahab…): enter wallet number → approve PIN on your phone — money goes straight to the venue; price shown = price paid (no taxes/tips/fees) | 09 |
| Live order tracker | Status timeline (Placed → Accepted → Preparing → Ready → Served) with ETA, survives refresh/phone lock | 08 |
| Call waiter | One tap pings the assigned waiter ("Aisha is coming"); pickup venues show "Ask at the counter" instead | 10 |
| Pay at counter | If venue enables it: order by QR, show pickup code, pay cash at the counter | 15 |
| Order recovery | Closed the browser? Re-scan the table QR → "You have an active order" banner (30-day cookie) | 08 |
| Confirm delivery | Waiter scans the table QR at handoff — customer sees "Served" | 11 |
| Counter pickup (pickup-mode venues) | "Order ready!" notification → show tracker QR at the counter → staff scans → served | 10, 11 |
| Digital receipt | Itemized: items, modifiers, discounts, total | 09 |
| Rate the food | Stars + comment per item after serving | 17 |
| Cross-venue history | Optional account (magic link): every order at every venue — what, where, when, how much; monthly spend | 16 |

## Waiter — Waiter PWA (mobile, one-thumb)

| Feature | Detail | Built in |
|---|---|---|
| Shift toggle | Clock in/out; only on-shift + connected waiters receive orders | 10 |
| Auto-assigned queue | New orders assigned to the least-busy waiter; FIFO queue with "NEXT UP" pinned | 10 |
| Accept orders | 90s to accept, or the order escalates to the claim board; solo waiter on shift = auto-accepted, no timer | 10 |
| Claim board | Unclaimed/escalated orders — first tap wins | 10 |
| Order details | Items, customizations, notes, table number (large) | 10 |
| Scan to serve | Camera scan of the table's QR confirms delivery at the right table (takeaway: scan customer's screen) | 11 |
| Call-waiter alerts | Push + in-app ping when their table needs them | 10, 20 |
| Push notifications | New order / call alerts on a locked phone | 20 |
| Own performance | Orders served, average serve time, ratings received | 18 |
| Off-shift handoff | Going off shift with open orders forces handoff to the claim board | 10 |
| Can't find customer | Flag an order unserveable → manager resolves (refund or convert to takeaway) | 10 |
| Table stickiness | Follow-up orders from your table come to you, not the rotation | 10 |

## Kitchen — KDS (tablet, dark theme)

| Feature | Detail | Built in |
|---|---|---|
| Live ticket board | Columns: New → Preparing → Ready; new tickets appear instantly with sound cue | 14 |
| Full modifier visibility | "No onions" is never truncated or hidden | 14 |
| Advance tickets | Full-width tap: Start → Ready; waiter notified on Ready | 14 |
| Undo a mistap | One step back (Ready → Preparing, Preparing → Accepted), logged | 08, 14 |
| 86'd-item flags | Open tickets containing a just-86'd item get a warning badge | 13 |
| Timers & delay alerts | Elapsed timer per ticket; overdue tickets pulse amber | 14 |

## Cashier — POS (tablet/desktop)

| Feature | Detail | Built in |
|---|---|---|
| Fast visual ordering | Photo grid + category rail + search; modifier quick-sheet | 15 |
| Open tickets | Edit/void lines before payment | 15 |
| Discounts | Order- or line-level, reason required, permission-gated; 100% discount = manager-gated **comp** | 15 |
| Take payment | Cash (with change calculator) or wallet push prompt to the customer's phone | 15 |
| Pay-at-counter confirm | Take cash for a customer's QR order via pickup code → order fires to kitchen; expired code → **Revive** (re-reserves stock) | 15 |
| Cash refunds | Give cash back — recorded, attributed, netted from expected drawer cash | 15 |
| Walk-in orders | Counter orders skip waiter assignment but still hit the KDS | 15 |
| Table orders (no-QR fallback) | Place a dine-in order for any table — flows into the normal waiter/KDS pipeline | 15 |
| End-of-day close | Z-report: day totals by payment method, expected vs counted cash, discrepancies stored | 15 |
| Shift summary | Own transactions + cash total for drawer reconciliation | 15 |
| Refunds | Initiate refunds (also manager) | 09 |

## Manager — Back office (per venue)

| Feature | Detail | Built in |
|---|---|---|
| Menu builder | Categories, items, photos, prices, prep times, dietary/allergen tags; edits go live instantly | 04 |
| Modifier groups | Min/max/required rules, price deltas, reusable across items | 05 |
| Combos / meal deals | Bundle-priced item with required choice groups ("Combo" template in the builder) | 05 |
| Daily planning | Availability toggles + daily quantity limits ("50 rice today") with live sold/remaining | 04 |
| Tables & QR | Create tables, print laminated QR sheets, rotate stolen/worn codes | 06 |
| Staff management | Invite/deactivate waiters, cashiers, kitchen staff; per-venue roles | 03 |
| Live floor view | All open orders across the venue in real time | 08 |
| Ingredients & recipes **(Growth+)** | Ingredient list (units, costs, thresholds); recipe per item; modifier stock deltas | 12 |
| Stock operations **(Growth+)** | Restock, adjustments, wastage log with reasons — append-only ledger | 13 |
| Low-stock alerts **(Growth+)** | Live pings + restock report (current/threshold/suggested), CSV **+ printable purchase-order sheet** for suppliers | 13 |
| Delay & stuck-order alerts | Overdue kitchen tickets, unaccepted orders, watchdog warnings | 10, 14, 21 |
| Busy Mode | Pause new orders (20/40 min/until reopened) or inflate ETAs when the kitchen is slammed | 08 |
| 86 an item | Instant kill-switch when the kitchen runs out; auto-86 from recipe stock with override | 13 |
| Stocktake **(Growth+)** | Enter physical counts → variance report (theoretical vs actual, valued at cost) | 13 |
| Reassign orders | Move a stuck order to another waiter or the claim board | 10 |
| Manual serve confirm | Override for damaged table QRs — attributed + telemetry-counted | 11 |
| Fulfillment mode | Venue setting: waiter service or counter pickup (no waiters needed) | 10 |
| Business-day cutoff | "Today" for limits/reports runs cutoff-to-cutoff (default 4am) — late venues report correctly | 08 |
| Unserveable resolution | Decide refund vs convert-to-takeaway when a customer disappears; pickup mode: resolve "not picked up" orders (refund / collected / waste) | 10, 11 |
| Comp orders | Approve free (100%-discounted) orders — reason required, tracked in reports | 15 |
| Reports & analytics **(Growth+; Today live screen is on Essentials too)** | Full spec in **owner-dashboard.md**: Today live screen, revenue trends, menu performance + margins + menu-engineering quadrant, feedback, staff work analytics, food cost % & variance, customers; CSV export | 18 |
| Report Center **(Growth+)** | 13 report types (revenue, orders w/ statuses, successful orders & bills, payments online-vs-cash, cashier daily cash, assisted orders, inventory, menu, feedback, employee work, customers, day-close, profit P&L-lite) × daily/weekly/monthly/yearly/custom + season grouping & last-year comparison, exportable + scheduled email — **manager sees all of these for his venue** | 18 |
| Customer feedback | Item ratings and comments, live | 17 |
| Refunds & cancellations | Permission-gated, always attributed | 09 |

## Owner — Back office (org-wide: everything Manager has, plus)

| Feature | Detail | Built in |
|---|---|---|
| Org & venues | Create venues, switch between them, org-wide settings | 03 |
| Payment account | Wallet merchant credentials (WaafiPay) — where customer money lands; guided setup checklist + verification status | 09 |
| SaaS subscription | Pick/change plan — **Essentials** $40/mo (1 venue, order loop only, 2.5% fee), **Growth** $75/mo (1 venue, + inventory + full Report Center, 1.5% fee), or **Pro** $55/venue/mo (2–10 venues, + cross-venue view, 1.0% fee) — monthly itemized invoice (plan + accrued per-order fees) paid by wallet push prompt; downgrade blocked until venue count fits the target plan; pricing.md | 19 |
| Manager accounts | Create/remove managers per venue | 03 |
| Cross-venue view **(Pro only)** | Org comparison table (revenue, avg check, food cost %, rating, refund rate per venue) — owner-dashboard.md | 18 |
| Profit view (P&L-lite) **(Growth+ single-venue; org rollup is Pro only)** | Net revenue − COGS = gross profit & margin, plus purchases, wastage cost, fees — per venue and org rollup | 18 |
| Onboarding checklist | Venue info → wallet merchant setup → menu → tables → first live order | 20 |

## Platform Admin (us) — Admin panel

| Feature | Detail | Built in |
|---|---|---|
| Tenant management | All orgs/venues, subscription states, order volumes | 19 |
| Plans & fees | Plan definitions — Essentials/Growth/Pro venue caps, prices, feature gates, per-order fee % (pricing.md, `config/plans.exs`) | 19 |
| Platform metrics | Signups, active venues, order throughput, revenue (fees + subscriptions) | 19 |
| Health & alerts | Webhook lag, queue depth, uptime probes, watchdogs | 21 |

---

## Role → surface map

```
Customer        → QR web PWA (first order, zero install)
                  + TableTap app (RN — repeat orders, history, push)
Waiter          → TableTap Staff app (RN — queue, scan-to-serve, push)
                  (web PWA fallback until Phase 8)
Kitchen         → KDS                 (LiveView web, tablet, dark, always-on)
Cashier         → POS                 (LiveView web, tablet/desktop at the counter)
Manager         → Back office         (LiveView web, desktop-first, venue-scoped)
Owner           → Back office (LiveView web, org-scoped + billing)
                  + TableTap Staff app owner mode (live numbers, alerts)
Platform Admin  → Admin panel         (LiveView web, us only)
```

Staff roles are per-venue memberships — one person can hold different roles at different venues. Web surfaces are LiveViews in one Phoenix app; the two mobile apps (React Native + Expo) consume `/api/v1` + Phoenix Channels and enforce the same Scope/role permissions server-side (see code-standards.md).
