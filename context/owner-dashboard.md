# Owner Dashboard — What the Owner Sees

Full specification of the owner/manager analytics surfaces. Every metric here is computable from our schema (orders + snapshots, recipes, stock movements, shifts, ratings) — if a metric can't be derived from those tables, it doesn't belong on the dashboard. Data source is either **live** (today, via PubSub/queries) or **rollup** (history, from `daily_rollups`).

Owner sees org-wide (all venues + comparison); Manager sees their venue only. Same components, different scope. The owner's mobile app (TableTap Staff, owner mode) shows the Today strip + alerts; deep analysis is web.

---

## Screen 1 — Today (the default landing, all live)

The "walk in the door and know everything" view. Auto-updating, no refresh.

| Tile | Definition | Why the owner cares |
|---|---|---|
| Revenue today | Sum of `placed`+ orders' totals, minus refunds, so far | The number they check 10× a day |
| Orders today | Count + breakdown dine-in / takeaway / counter | Volume + channel mix at a glance |
| Average check | Revenue ÷ orders | Are customizations/menu changes lifting spend? |
| Open orders now | Orders in placed→ready, with oldest-order age | Is service flowing or backing up? |
| Live ETA being quoted | Current computed ETA shown to customers | What experience are we selling right now? |
| On shift now | Waiters/cashiers/kitchen clocked in (Presence-confirmed) | Staffing vs demand, live |
| Busy Mode status | Off / paused-until / slowed | One tap away from throttling |
| Sold out / 86'd today | Items that hit daily limit or were 86'd, with time it happened | Lost-sales signal — "rice died at 13:20 again" |

**Live floor strip:** open orders as status chips grouped by table, delayed ones pulsing — the manager's live floor view, embedded read-only.

**Alert feed (right rail):** low stock, delayed orders (> expected prep), unaccepted orders, unserveable flags, sold-out events, failed payments, subscription issues. Every alert deep-links to its fix.

---

## Screen 2 — Revenue & Sales (rollups + today)

Date-range picker (today / 7d / 30d / custom), compare-to-previous-period on everything, CSV export on every table.

| Metric / chart | Definition |
|---|---|
| Revenue trend | Daily net revenue line (gross − discounts − refunds), previous period ghosted |
| Orders trend | Daily order count line |
| Average check trend | Daily revenue ÷ orders |
| Channel mix | Dine-in vs takeaway vs counter, stacked area |
| Peak hours heatmap | Orders by hour × weekday — staffing and prep planning |
| Discounts given | Total + count + by staff member (catches discount abuse) |
| **Comps given** | Zero-total (`provider: comp`) orders: count, value at menu price, by staff member + reason — free food is tracked food (design-qa.md Q30) |
| Refunds | Total + rate (% of orders) + reasons — a rising rate is an ops fire alarm. Counted on the **refund's business day** (design-qa.md Q37) |
| Payment mix | Wallet vs cash vs pay-at-counter — with per-wallet split (ZAAD / EVC Plus / eDahab) |
| Platform fees paid | Application fees for the period — full cost transparency |
| **Gross profit & margin** | Net revenue − COGS (recipe-valued ingredient consumption) — the headline from the Profit report, trended |

---

## Screen 3 — Menu Performance ("most sold" and much more)

The money screen. One row per menu item, sortable by every column, category filter.

| Column | Definition |
|---|---|
| Sold | Units in period (from `order_items` snapshots) |
| Revenue | Line totals for the item |
| **Food cost** | Recipe ingredient quantities × current ingredient `cost_per_unit` |
| **Margin** | Price − food cost, absolute and % — *the* menu-engineering number |
| Rating | Avg stars + count (from `item_ratings`) |
| Sellout behavior | Days it hit its daily limit + average sellout time |
| Modifier attach rate | % of orders adding paid modifiers (upsell performance) |

**Menu engineering quadrant** (classic BCG-style, computed, with plain-language labels):
- **Stars** (high volume, high margin) → feature them, never 86 them
- **Plowhorses** (high volume, low margin) → raise price or cut recipe cost
- **Puzzles** (low volume, high margin) → better photo, better placement
- **Dogs** (low volume, low margin) → candidates to remove

Plus: top 10 / bottom 10 sold, category mix pie, "sold out early" list (items whose limits consistently exhaust before close — raise the limit or the price).

---

## Screen 4 — Feedback

| Element | Definition |
|---|---|
| Venue rating trend | Daily avg stars line |
| Rating distribution | 1–5 histogram |
| Per-item ratings | Sortable list, worst-first toggle — find the dish hurting you |
| Recent comments | Stream with item + order link; unread badge |
| Rating rate | % of served orders that got rated (low = prompt isn't landing) |
| Per-waiter ratings | Avg stars on orders they served |

Low-rating alert: any item averaging < 3.0 over the last 20 ratings pings the manager.

---

## Screen 5 — Staff & Work Analytics

From `shifts`, order timestamps, and ratings — measured, not guessed.

| Metric | Definition |
|---|---|
| Orders served per waiter | Count in period |
| Avg accept time | placed → accepted (are they watching the queue?) |
| Avg serve time | accepted → served (hustle + kitchen dependency) |
| Escalation rate | % of their assignments that timed out to the claim board |
| Unserveable flags | Count raised (context, not blame — could be door-dash customers) |
| Tables covered | Distinct tables served (stickiness makes this meaningful) |
| Rating | Avg stars on their served orders |
| Hours on shift | From `shifts` — normalizes all of the above (orders/hour) |
| Kitchen: avg prep time | accepted → ready, per hour-of-day (find the slow shift) |
| Cashier: transactions + cash variance | Recorded cash vs shift summary |

**Fairness guardrail:** per-waiter numbers are always shown alongside venue averages and hours worked — never a naked leaderboard; a waiter covering the patio on a dead Tuesday isn't "slow."

---

## Screen 6 — Inventory & Cost

| Element | Definition |
|---|---|
| Stock on hand | Ingredients with current qty, valued at cost; low-stock flagged |
| Restock report | Below-threshold list: current / threshold / **suggested order quantity** — CSV **and a print-ready purchase-order sheet** (venue header, date, ingredient, unit, qty to order, blank supplier/price columns) the manager can hand to a supplier. Low-stock alerts (push + dashboard) link straight to it |
| Usage trend | Consumption per ingredient over time (from `sale` movements) |
| **Food cost %** | (Ingredient cost consumed ÷ revenue) for the period — the industry's #1 profitability KPI, healthy ≈ 28–35% |
| Wastage | Logged wastage valued at cost, by reason — where money leaks |
| **Variance (actual vs theoretical)** | Stocktake counts vs recipe-computed usage, valued at cost — reveals over-portioning, waste, or theft (the WISK/MarketMan metric) |
| Purchase history | Restock movements with costs over time |

---

## Screen 7 — Customers

MVP-honest (we only know what our data supports):

| Metric | Definition |
|---|---|
| New vs returning | By customer account / guest token recurrence |
| Repeat rate | % of customers with 2+ orders in 30 days |
| Top customers | By spend (account holders only, privacy-safe display) |
| Visit frequency histogram | 1×, 2–3×, 4+× in period |

Loyalty/segments/marketing = post-MVP (needs the loyalty engine we deferred).

---

## Org View (Owner only, multi-venue)

- Venue comparison table: revenue, orders, avg check, food cost %, rating, refund rate — side by side, same period
- Org totals + revenue-by-venue stacked trend
- Subscription & billing status per venue
- Every row clicks through to that venue's dashboard

---

## Owner Mobile App (TableTap Staff, owner mode) — the subset

Today tile strip (revenue, orders, avg check, open orders) · live alert feed · Busy Mode toggle · venue switcher · yesterday-vs-today sparkline. **No deep tables on mobile** — anything analytical deep-links to the web dashboard.

---

## Implementation Notes

- Screens 1 = live queries + PubSub; screens 2–7 = `daily_rollups` + today's live delta. `daily_rollups` gains: `discount_total`, `refund_total`, `payment_mix`, `channel_mix`, `hourly_orders` (jsonb), `staff_metrics` (jsonb), `food_cost` — extend the Feature 18 rollup job accordingly
- Food cost uses **current** ingredient costs at rollup time (historical cost snapshots = post-MVP; noted limitation, displayed in the UI footnote)
- Every chart follows the dataviz skill + ui-rules.md: axis labels, one-line "so what" caption, no chart without a takeaway
- Every table: CSV export. Date ranges resolve in the **venue's timezone**, and a "day" is the **business day** (`venues.business_day_cutoff`, default 4am — design-qa.md Q20): the Today screen, daily reports, and Z-report all agree on what "today" means for a venue open past midnight
- Empty states teach: pre-first-order dashboards show example cards explaining what will appear

## Report Center (founder requirement: every report, every period)

Dashboards are for looking; **reports are documents** — generated, exportable, shareable with an accountant or business partner. One Reports screen, available to owner and manager (venue-scoped for managers, org-wide option for owners).

**Every report supports: daily / weekly / monthly / yearly / custom range** (venue-local calendar), on-screen view + CSV export (PDF post-MVP), and generation as an Oban job with an emailed download link for big ranges.

**Seasonal analysis:** revenue, orders, and menu-performance reports additionally support **quarter/season grouping** and **same-period-last-year comparison** (this June vs last June; this summer vs last summer) — how a venue learns that ice coffee carries July and soup carries January.

**Visibility rule:** the **manager sees every report for their venue** — that's how they run it day to day. Owner-only extras: cross-venue comparison, platform fees paid, subscription/billing, and the Profit report's org rollup.

| Report | Contents |
|---|---|
| **Revenue report** | Gross, discounts, **comps**, refunds, net; by day within the period; by payment method (card/cash/comp); by channel (dine-in/takeaway/counter); platform fees paid. Refunds count on the refund's business day; late-arriving events show as flagged post-close adjustments, closed days never silently change (design-qa.md Q37/Q38) |
| **Orders report** | Every order in the period **with its status** (incl. cancelled/refunded/unserveable), timestamps for each stage, table, waiter, totals — filterable by status |
| **Successful orders & bills report** | Preset of the above: `served`/`closed` orders only, each with its **full bill** (line items, modifiers, discounts, total, payment method, who served it) — the export-all-receipts document |
| **Payments (money-in) report** | Every payment in the period as a row: **wallet (online) vs cash**, which wallet, amount, order link, who took it (cash), refunds netted; totals per method reconcile to the revenue report to the cent |
| **Cashier daily cash report** | Per cashier per business day: cash orders rung, cash-verified QR orders (order-number confirms), **cash refunds given (netted from expected cash)**, total cash taken, expected vs counted at close, variance — the drawer accountability document |
| **Assisted orders report** | Orders placed by staff on a customer's behalf (`placed_by_membership_id` set): per cashier — count, value, dine-in vs takeaway, cash vs pay-link — shows how much counter service each cashier is carrying |
| **Inventory report** | Stock on hand (valued), consumption per ingredient, restocks, wastage by reason, stocktake variances, low-stock events in the period |
| **Menu performance report** | Per item: sold, revenue, food cost, margin, rating, sellouts — the Screen-3 table as a document |
| **Feedback report** | All ratings + comments in the period, per-item and per-waiter averages, trend vs previous period |
| **Employee work report** | Per staff member: shifts + hours (auto-closed shifts flagged — design-qa.md Q45), orders served/rung, avg accept & serve times, escalations, ratings, discounts + comps given, cash variance (cashiers), manual serve-confirm count |
| **Customers report** | New vs returning counts, repeat rate, top spenders (account holders) |
| **Day-close (Z) reports** | The stored end-of-day closes for the period, with cash discrepancies; late webhooks/refunds after close appear as flagged **post-close adjustment** addenda, never edits to the stored close (design-qa.md Q38) |
| **Profit report (P&L-lite)** | The money picture in one document: net revenue − **COGS** (ingredient cost consumed per recipes) = **gross profit & margin**; alongside: inventory purchases in the period (valued from restock `unit_cost`), wastage cost, discounts given, refunds, platform fees. **Honest limit stated on the report:** labor, rent, and utilities aren't tracked (no payroll module) — this is gross profit on food, not net profit; manual expense entries are a post-MVP candidate |

**Scheduled delivery (opt-in per report):** daily summary at close of business, weekly on Monday morning, monthly on the 1st — email with the CSV attached/linked. Yearly = generated on demand. Every send **re-checks the recipient is still an active member with a role allowed to see that report** (design-qa.md Q52) — a fired manager stops receiving numbers the same day.

Implementation: all reports read from `daily_rollups` + raw tables for drill-down; yearly aggregates monthly rollups. No report may compute a number differently than its dashboard twin — same context functions.

---

## Alert Summary (what finds the owner, vs what they find)

| Alert | Trigger | Where |
|---|---|---|
| Low stock | Threshold crossed | Push (app) + dashboard |
| Sold out / auto-86 | Limit hit or recipe unfulfillable | Push + dashboard |
| Delayed orders | Ticket > expected prep | Dashboard; push if > 2× |
| Stuck/unserveable orders | Watchdog / waiter flag | Push + dashboard |
| Item rating < 3.0 | Rolling last-20 average | Dashboard |
| Refund-rate spike | > 2× the venue's 30-day norm | Push + dashboard |
| Daily digest (opt-in) | End of business day | Email: revenue, orders, top seller, flags |
