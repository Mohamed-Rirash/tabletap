# Project Overview

## About the Project

**TableTap** (working title) is a multi-tenant SaaS platform for cafés and restaurants. Any venue can subscribe, connect their own payment account, build their menu (down to the ingredient level), print QR codes for their tables, and run their entire floor — ordering, kitchen, waiters, inventory, and analytics — from one system.

Customers never wait for a menu or a bill: they scan the QR code on their table, browse the venue's live menu, customize items (extra cheese, no onions), pay from their phone, watch a live status/ETA for their order, and can call their assigned waiter with one tap. The money goes **directly to the venue's own payment account** — the platform takes a small per-order application fee plus the SaaS subscription.

One customer identity works across **every** venue on the platform: a diner sees their full history — what they ate, where, when, and what it cost — across all subscribed restaurants.

---

## The Surfaces

| Surface | Who | Form |
|---|---|---|
| QR ordering (web) | First-time diners | PWA — scan QR → opens instantly in browser, zero install. Always the first-order path |
| **TableTap** mobile app | Repeat diners | React Native (iOS + Android) — in-app scan & order, history, push order updates |
| **TableTap Staff** mobile app | Waiters + Owners | React Native — waiter mode (queue, claim, scan-to-serve, push) / owner mode (live numbers, alerts) |
| Kitchen Display (KDS) | Kitchen staff | LiveView web — tablet live board of tickets: new → preparing → ready |
| Cashier POS | Cashiers | LiveView web — fast visual grid for walk-in/counter orders, cash & wallet |
| Back office | Owner / Manager | LiveView web dashboard — menu builder, inventory, staff, tables/QR, reports (owner gets both this and the app) |
| Platform admin | Us (SaaS operator) | LiveView web — tenants, subscriptions, platform metrics |

**Per-job tooling:** Elixir/Phoenix LiveView powers the backend and every web surface; the two mobile apps are React Native + Expo (TypeScript) — chosen for the official Phoenix Channels client (real-time is the hard part; wallet checkout needs no payment SDK on either stack). Web MVP ships first (waiter/customer flows work as PWAs); the apps follow in Phase 8 on the same `/api/v1` + Channels.

---

## User Roles

| Role | Scope | Can do |
|---|---|---|
| **Platform Admin** | Whole platform | Manage tenants, plans, subscriptions, platform metrics |
| **Owner** | Their organization | Everything a manager can, plus billing, wallet merchant-account setup, venue creation, manager accounts |
| **Manager** | A venue | Menu & ingredients, staff (create waiters/cashiers/kitchen), tables & QR printing, daily limits, inventory, reports |
| **Cashier** | A venue | Walk-in POS orders, take cash/card payments, view their shift's transactions |
| **Waiter** | A venue | See assigned order queue, claim/accept, mark served via table-QR scan, view own performance/history |
| **Kitchen** | A venue | KDS board — see tickets, advance preparing → ready |
| **Customer** | Cross-venue | Scan & order at any venue, customize items, pay, track order live, call waiter, rate items, see personal spend history |

Staff roles are per-venue memberships — the same person can be a manager at one venue and a waiter at another.

**Full feature-by-role breakdown: see role-features.md.**

---

## The Core Idea — Order Flow

```
Customer sits at Table 7 → scans the table's QR code
        ↓
Venue's live menu opens (only today's available items, sold-out items marked)
        ↓
Customer picks items → customizes via modifier groups
  ("Extra cheese +$1", "No onions", "Size: Large +$2") → dine-in or takeaway
        ↓
Pays from their phone (wallet push: enter wallet number → approve
PIN — ZAAD/EVC Plus/eDahab — money lands in the venue's own account)
        ↓
Order enters the venue's queue (FIFO) and is auto-assigned to the
most-available on-shift waiter (lowest open workload, round-robin tiebreak)
        ↓
Waiter sees it in their queue → relays to kitchen / KDS ticket created
        ↓
Kitchen advances ticket: preparing → ready
        ↓
Waiter delivers to Table 7 → scans the table's QR code to confirm delivery
        ↓
Order marked served → ingredient stock auto-deducted per recipe →
daily limits decremented → history recorded
        ↓
Customer rates the items; both sides see the order in their history
```

Throughout, the customer sees a **live status timeline with an ETA** (based on queue depth and rolling average prep times) and a **"Call waiter"** button that pings their assigned waiter.

---

## Feature Areas

### 1. Tenant Onboarding & Subscription
- Venue signs up → guided onboarding: venue info (name, logo, hours, location, currency), wallet merchant onboarding (WaafiPay credentials — guided checklist for the manual paperwork step), subscription plan, first menu items, table setup
- **14-day free trial, no card required** — full features + live ordering during trial; card and plan required to continue (design-qa.md Q29)
- Multi-venue organizations supported (a chain = one org, many venues)
- **Pricing — three feature tiers, not just venue count:** Essentials $40/month (1 venue, order loop only), Growth $75/month (1 venue, + inventory + full Report Center), Pro $55/venue/month (2–10 venues, + cross-venue reporting) — plus a per-order fee (2.5%/1.5%/1.0%) on wallet/card orders only, cash and comped orders carry no fee; full spec and rationale in **pricing.md** (design-qa.md Q63)
- **Launch markets: Hargeisa, Mogadishu, Jigjiga** (founder, design-qa.md Q57 — supersedes the earlier Stripe-country decision). Payments = mobile-money wallets (ZAAD/EVC Plus/Sahal via WaafiPay; eDahab later; Ethiopia via Chapa in Phase C). Merchant onboarding includes a guided WaafiPay paperwork step — "first order in under an hour" counts from credentials-in-hand

### 2. Menu & Catalog (Manager)
- Categories, items with photos, descriptions, prices, prep-time estimates
- **Modifier groups** per item: required/optional, min/max selections, per-option price adjustments (e.g. "Cheese level: normal / extra +$1 / none")
- Dietary & allergen tags (vegan, gluten, nuts…)
- Availability toggles + **daily quantity limits** ("50 servings of rice today") with live sold-out state
- Item ↔ recipe link: each item maps to ingredient quantities (BOM)

### 3. Ordering & Payments
- Table-QR dine-in and takeaway ordering; guest checkout (no forced signup)
- Cart with live price recalculation from modifiers
- **Menu prices are final** — what the customer sees is what they pay; no taxes, tips, or service charges added at checkout
- **Discounts** — item- or order-level, applied by manager/cashier with a reason, permission-gated, visible in reports
- **Wallet push charges on the venue's own merchant account** (WaafiPay: ZAAD/EVC Plus/Sahal): customer pays the venue directly; the platform's per-order fee accrues to a ledger, collected monthly with the subscription (no split-payment API exists — design-qa.md Q59)
- **Digital receipts** — itemized receipt (items, modifiers, discounts, total) on the tracker page + emailed to account holders
- Cashier POS path for walk-ins (cash or wallet push), open-ticket editing before payment
- Refund/cancel flow (manager/cashier initiated)

### 4. Order Fulfillment
- Order state machine: `placed → accepted → preparing → ready → served → closed` (+ `cancelled`/`refunded`)
- **Waiter assignment algorithm**: on-shift waiters ranked by open workload; new order goes to the least-loaded; unclaimed orders escalate to a venue-wide claim board after a timeout
- KDS with per-ticket timers and delay alerts
- Delivery confirmed by the waiter scanning the table's QR — closes the loop physically at the table (manager-only manual override for damaged QRs)
- FIFO fairness: within a waiter's queue, oldest order first
- **Pickup fulfillment mode** for counter-service venues with no waiters: `ready` notifies the customer, staff scans their tracker QR at the counter (design-qa.md Q18)

### 5. Inventory
- Ingredients with units and unit conversions (kg → g, L → ml)
- Recipes per menu item; auto-deduction when an order is served
- Minimum stock thresholds, low-stock alerts, restock report (item, current, threshold, suggested qty — exportable)
- Manual adjustments and wastage logging with reasons
- Usage history feeding the analytics

### 6. Staff & Performance
- Manager creates staff accounts (waiter/cashier/kitchen) with invite links
- Shifts: waiters go on/off shift; only on-shift waiters receive assignments
- Per-waiter metrics: orders served, average accept→served time, ratings received
- Activity log per staff member

### 7. Analytics & Reports (Owner/Manager)
- Revenue (day/week/month/custom), order counts, average check
- Net sales breakdown: gross, discounts given, net revenue
- Top sellers, sales by category, peak hours heatmap
- Food cost % and ingredient usage trends; actual vs. planned usage
- Staff performance ranking
- CSV export (PDF later)

### 8. Customer Experience
- Cross-venue order history: every cent spent, which item, which venue, when
- Per-item ratings after an order is served; venue rating aggregate
- Live order tracker with ETA; call-waiter button
- Optional account (magic-link) — guests can order without one, history requires one

### 9. Notifications
- Waiter: new order assigned, call-waiter ping (web push + in-app real-time)
- Manager: low stock, daily-limit sold-out, delayed orders
- Customer: order status changes (in-app live; push if installed)

---

## Features Out of Scope (MVP)

_Full deferred-features register with triggers to build each one: design-qa.md → Gap Analysis._

- Native iOS/Android builds (PWA first; the JSON API keeps the door open)
- Delivery/courier logistics (dine-in + takeaway only, no address delivery)
- Table reservations / booking
- Loyalty points & promotions engine
- Payroll / full HR
- Multi-language menus (schema allows it later; single language per venue at MVP)
- Split-the-bill payments / ticket split-merge (Loyverse-style — post-MVP)
- Hold/fire coursing control (Toast-style "Hold, Stay, Send" — post-MVP)
- Offline-first POS (Toast's offline mode is a known differentiator; we accept requires-connectivity with graceful degradation at MVP)
- KOT thermal printer integration (KDS screen replaces it; printers later)

---

## Target Users

- **Independent cafés and small restaurant chains** (1–10 venues) that can't afford Toast-class enterprise systems but want QR ordering, live ops, and real inventory numbers
- **Diners** who want to order and pay without waiting for staff, and see their own eating-out spend in one place

---

## Success Criteria

- A brand-new venue can go from signup → printable table QR codes → first paid live order in **under one hour** once its wallet merchant credentials exist (the WaafiPay paperwork is the one step we can't compress — we hand-hold it via the onboarding checklist)
- A customer goes from QR scan → paid order in **under 90 seconds**, with no app install and no signup
- Order status shown to the customer is never stale by more than 2 seconds (LiveView/PubSub real-time)
- Ingredient stock and daily limits are always consistent with served orders — no overselling a sold-out item
- A venue owner can answer "what sold best, what did it cost, who served fastest, what do I need to reorder?" from the dashboard without exporting anything
- **Zero cross-tenant data leaks** — every query is tenant-scoped by construction (Phoenix Scopes + repo-level enforcement)
