# Design Q&A — Hard Scenarios and Their Decisions

Adversarial review of the whole design (2026-07-06): each scenario below is a question the original docs didn't answer or answered wrong. Each gets a decision and rationale. **These decisions override anything contradictory elsewhere** — the other context files have been patched to match, but this file is the reasoning record.

---

## Ordering & Money

### Q1. Two customers pay simultaneously for the last limited portion — who gets it?
**The original design had a real race:** limits were reserved at `placed`, but `placed` happens *after* payment succeeds. Both customers could pay; one paid order becomes unfulfillable.
**Decision — reserve at checkout, not at placed (ticketing-system pattern):**
- New order status `pending_payment`: created when the customer taps Pay, **atomically reserving** limit quantities in the same transaction (`UPDATE daily_item_limits SET reserved_qty = reserved_qty + n WHERE limit_qty - sold_qty - reserved_qty >= n` — fails → "sold out while you were deciding" before any charge)
- Payment success converts the hold: `reserved_qty -= n, sold_qty += n`, order → `placed`
- Holds expire after **12 minutes** (Oban sweep releases stale `pending_payment` orders and cancels their PaymentIntents); abandonment never strands stock
**Why:** the customer must never be charged for food the venue can't make. Charging first and refunding "oops sold out" destroys trust on both sides.

### Q2. The kitchen is slammed — orders keep flooding in. Toast/ChowNow/Olo all have throttling; we had nothing.
**Decision — Busy Mode (venue-level, one tap for manager, visible to waiters):**
- **Pause**: snooze new QR/app orders for 20 min / 40 min / until reopened (POS keeps working — staff can always ring up)
- **Slow**: inflate displayed ETA by a set factor and show a "High demand — longer waits" banner on the menu
- Menu shows an honest "Ordering paused — please order at the counter" state instead of silently failing
- Auto-suggestion (not auto-trigger, MVP): when open-order count crosses a threshold, prompt the manager to enable Busy Mode
**Why:** industry-standard for a reason — protecting food quality beats taking every order. Manual control first; capacity-aware auto-throttle is a post-MVP refinement.

### Q3. A customer wants to pay cash but order by QR (cash-heavy markets).
**Decision — "Cash" payment option at checkout (venue toggle), confirmed by founder:**
1. Customer selects **Cash** as the payment method at checkout → order goes to `pending_payment` and their screen shows a short **order number**
2. Customer walks to the counter, gives the number; cashier types it into the POS (or scans it), takes the cash, taps **Verify paid**
3. Order becomes `placed` and fires to the kitchen/waiter pipeline. Same 12-minute hold TTL if they never show up
**Why:** preserves the iron rule (kitchen never sees an unpaid order) while not excluding cash customers. Off by default; venues that don't want counter traffic never see it.

**Cashier is a full customer proxy (founder confirmation):** anything a customer can do in the QR flow, the cashier can do for them at the counter — dead phone, no phone, cash-only, or just preferring a human. That means: place dine-in (with table assignment) or takeaway orders, full modifier customization, apply the customer's requests via notes, and take payment. The QR flow is the fast path, never the only path.

### Q4. Wrong item delivered / one bad dish — full refund is too blunt.
**Decision — line-item partial refunds:** refund one or more order items (Stripe partial refund against the PaymentIntent, `refund_application_fee: true` proportionally). Stock is **not** auto-restored (the food was cooked); manager may log a wastage entry if applicable.
**Why:** most disputes are about one dish. Also matches the append-only inventory philosophy: refunds are money events, not stock events.

### Q5. Chargebacks — who eats them?
**Decision:** with direct charges, **the venue (connected account) bears disputes** — that's Stripe's model and it's correct: it's their sale. The platform's job is evidence: we auto-attach order snapshot, payment metadata, and — uniquely — the **serve-confirmation scan timestamp at the physical table** to dispute responses.
**Why:** the delivery scan we built for workflow integrity doubles as strong dispute evidence ("card was used to order at the table, and delivery was confirmed at that table at 19:42").

---

## QR & Abuse

### Q6. Someone photographs a table QR and orders from home to grief the kitchen.
**Decision — layered, accept small residual risk:**
1. Pay-first means the "attacker" pays real money for real food — self-limiting (industry consensus)
2. Ordering gated by venue opening hours + Busy Mode state
3. Rate limit: max active orders per guest token; IP limits throttle token minting only (refined in Q33 — the venue's WiFi is one shared IP)
4. The waiter delivery scan physically catches no-customer-at-table; unserveable flow (Q9) resolves it with a refund decision
**Why:** every commercial QR system accepts this residual risk with the same mitigations; heavier defenses (geofencing, SMS verification) would hurt the 90-second first-order promise far more than the rare prank costs.

### Q7. Fake QR sticker pasted over ours (phishing redirect — a documented real-world scam).
**Decision — ops + product:** printed QR sheets include the venue name and our domain in plain text under the code ("scan opens tabletap.app/t/…"); manager guidance to check tables when lamination looks tampered; token rotation invalidates stolen codes; the customer app's in-app scanner only opens our domain.
**Why:** can't technically stop stickers on tables; making the legit design recognizable + cheap rotation is the practical defense.

---

## Fulfillment

### Q8. Four friends at one table each order from their own phone — the waiter gets four "separate" orders.
**Decision — orders stay independent (independent payment = independent order), but:**
- **Same-table stickiness:** if a table has open orders, new orders from that table are assigned to the **same waiter** (overrides lowest-load), so one waiter owns table 7 tonight
- Waiter queue and KDS visually group tickets by table
- A shared "table session/tab" is explicitly post-MVP
**Why:** independent orders keep payment simple (everyone pays for their own food — also the de-facto split-the-bill solution); stickiness restores the human "this is my table" model restaurants actually run on.

### Q9. Customer pays, then leaves before the food is served.
**Decision — unserveable flow:** waiter taps "Can't find customer" → order flagged, manager notified → manager resolves: cancel + refund (customer's fault or not, venue's call), or convert to takeaway/hold. Telemetry tracks unserveable rate per venue.
**Why:** without an explicit exit, these orders rot in `ready` forever and poison the stuck-order watchdog with noise.

### Q10. A waiter accepts three orders, then their phone dies / they walk off shift.
**Decision:** accepted orders are **not** auto-reassigned on presence loss (the waiter may be mid-delivery); instead the stuck-order watchdog alerts the manager, and the manager gets an explicit **Reassign** action (to a chosen waiter or the claim board). Going off-shift in-app with open orders already forces handoff; this covers the non-graceful cases.
**Why:** auto-reassigning food that's physically in someone's hands creates double-delivery chaos; a human call with a good alert beats a clever algorithm here.

### Q11. An ingredient runs out mid-service but the dish's daily limit isn't hit.
**Decision — "86" (instant kill-switch, the industry term):** one-tap "86 item" on the manager live view and on the KDS ticket screen → item immediately unavailable on all menus; plus **auto-86**: when a recipe can no longer be fulfilled from current stock, the item auto-hides (was "optional", now standard, with a manager notification and an override).
**Why:** the daily limit is a plan; the walk-in fridge is reality. Every kitchen needs the instant button.

### Q12. A customer with a nut allergy orders — how far does our responsibility go?
**Decision:** allergen tags shown prominently on item detail; a fixed platform-level line on every menu and receipt: "Allergen info is provided by the venue — please confirm with staff"; order notes field encouraged for allergy notes, and notes are **always** rendered on KDS tickets (already an invariant: never truncate).
**Why:** the platform can surface data but can't verify kitchens; the disclaimer + confirm-with-staff line is the standard, honest posture.

---

## Data & Lifecycle

### Q13. The guest closes their browser and loses the tracker.
**Decision:** `guest_token` persists in a 30-day cookie; re-scanning the same table's QR (or reopening the venue menu) shows a "You have an active order →" banner; account holders always have the emailed receipt link.
**Why:** zero-login must not mean zero-recovery.

### Q14. Physical inventory never matches the system after a week.
**Decision — stocktake:** manager enters periodic physical counts → system writes an `adjustment` movement for the difference and produces a **variance report** (theoretical vs actual per ingredient, valued at cost). Negative computed stock is allowed (service never blocks on bookkeeping) but flagged on the dashboard until reconciled.
**Why:** actual-vs-theoretical variance is the metric real inventory tools (WISK, MarketMan) center on; drift is inevitable, reconciliation must be a workflow, not a crisis.

### Q15. GDPR — a customer demands deletion; a venue cancels and wants their data.
**Decision:**
- Customer deletion: account + PII erased; orders **anonymized** (customer_user_id nulled, guest linkage severed) but retained — they're the venue's financial records; ratings kept aggregate-only; push tokens purged
- Customer export: JSON of their orders/ratings on request (self-serve button post-MVP, manual at first)
- Tenant offboarding: full data export (menu, orders, inventory, reports as CSV), then hard delete after a 90-day grace window; Stripe connected account is theirs and simply detaches
**Why:** anonymize-don't-delete for transactional records is the standard GDPR-compatible pattern; venues legally need their sales history.

### Q16. Two venues in one org want the same menu without double entry.
**Decision — post-MVP, noted:** menu copy/template across venues in an org. MVP: menus are per-venue, full stop. Not worth complicating the catalog model before there's a real chain customer.

---

## Gap Analysis — "what does a real café need that we didn't have?" (2026-07-06)

Walked a venue's full day (open → serve every customer type → close the till) against the docs.

### Fixed in MVP (docs patched)

| Need | Decision |
|---|---|
| **Customers who won't/can't scan QR** (dine-in fallback) | POS orders can be assigned to a table → enter the normal waiter/KDS pipeline (stickiness applies). Any dine-in customer can order through a human; QR is the default, never the only door |
| **Combos / meal deals** | No new schema — a combo is a `menu_item` whose price is the bundle price, with required modifier groups ("Choose your burger", "Choose your side", "Choose your drink"; options can carry price deltas for premium choices). Recipe lines attach to the chosen options via `ingredient_qty_delta`. Documented pattern in architecture.md |
| **End-of-day close (Z-report)** | Formal business-day close per venue: day totals (orders, revenue, by payment method), expected vs counted cash per cashier shift, discrepancies flagged and stored. Runs in the venue's local day. Feature 15 + owner dashboard |
| **RTL / i18n groundwork** | Gettext wired from day one (all user-facing strings translatable); templates use CSS logical properties (`ps-*`/`pe-*`, `text-start`) so RTL is a locale switch, not a rewrite; venue locale drives customer-surface language + money formatting. Full multi-language *menus* stay post-MVP |
| **Holiday / special hours** | `opening_hours` jsonb includes date-specific overrides (closed days, special hours) — trivial now, annoying later |

### Consciously deferred (post-MVP register — don't rediscover these)

| Need | Why deferred / trigger to build |
|---|---|
| Scheduled pickup pre-orders ("ready at 13:00") | ASAP-only keeps ETA + kitchen flow simple; build when takeaway share is proven |
| Happy hour / scheduled pricing / promo codes | Needs a promo engine; workaround: manager edits prices or uses discounts |
| KDS station routing (bar vs kitchen vs dessert) | Single-KDS fits cafés; hook exists (`menu_categories` can gain `kds_station`); build for the first multi-station venue |
| Supplier records & purchase orders | Restock report CSV covers MVP purchasing; build when venues ask to send POs from the system |
| Fiscal receipt printing / compliance | **Market-dependent legal requirement** (fiscal printers/e-invoicing in some countries) — MUST re-check before launching in any regulated market; browser-print receipt from POS is the interim |
| Reservations / floor plan / waitlist | Explicitly out of scope since day one; different product muscle |
| Delivery aggregator integrations (Uber Eats etc.) | Dine-in/takeaway focus; integration surface is huge |
| Menu import (CSV/photo) for onboarding | Manual entry acceptable at MVP scale; build when onboarding volume hurts |
| Nutrition/calorie fields | Schema-trivial, demand-driven |
| Staff order editing after `placed` | Policy instead: cancel + refund + reorder — keeps payment/state machine simple (an edited paid order is a payment nightmare) |

---

## Round 2 — Second Adversarial Review (2026-07-07)

Thirteen more holes found by walking payments edge cases, ops reality, and business assumptions. Founder decided Q17, Q18, Q28, Q29; the rest follow the recommended fix.

### Q17. Launch market — does Stripe even work there?
**⚠ SUPERSEDED by Q57 (Round 5):** the real launch market is the Somali Horn (Hargeisa/Mogadishu/Jigjiga) — the re-open clause below fired. Kept as the historical record.
**Founder decision: launch in a Stripe-supported country** (US/UK/EU/UAE-class market). Stripe Connect stays exactly as designed — no payment-provider abstraction built now.
**Standing constraint recorded:** Stripe Connect Express does not exist in most of MENA (no Egypt, Jordan, Iraq, Morocco). Expanding into a non-Stripe market is an **architectural project**, not a config change: a local provider (Paymob/Tap/HyperPay), a provider abstraction over `Payments`, and the fiscal-receipt/e-invoicing compliance check from the gap register. Re-open this question before signing any venue outside Stripe's country list.

### Q18. Counter-service cafés with zero waiters couldn't use the app at all.
The fulfillment loop assumed a waiter delivers and scans the table QR; a no-waiter café would dump every order onto an empty claim board.
**Founder decision — venue-level fulfillment mode, in the MVP:** `venues.fulfillment_mode`: **`waiter`** (default — full assignment/serve loop as designed) or **`pickup`** — no waiter assignment; on `ready` the customer is notified ("Order #42 is ready!") and shows the QR on their tracker screen at the counter; staff scans it → `served` (stock deducts as usual). KDS, payments, limits, reports all unchanged.
**Why:** doubles the addressable venues (kiosks, coffee bars, food courts) for one enum and one branch in the ready-flow.

### Q19. The serve-scan had no fallback — a torn QR sticker stranded orders.
`served` required scanning the table's QR; damaged laminate meant no order at that table could ever complete, and rotation requires reprinting.
**Decision — manager-only "manual serve confirm" override:** marks the order served without a scan; requires the manager role (waiters can't self-serve around the scan), is always attributed, and is counted in telemetry + the employee work report so habitual bypassing is visible. The alert prompts reprinting the table's QR.
**Why:** physical-world failure needs a human escape hatch; making it manager-gated and measured keeps the scan's integrity value.

### Q20. What is "today" for a venue open past midnight?
Daily limits, Z-report, rollups, and the Today dashboard all used the calendar day — a shisha café open until 2am would have limits reset and reports split mid-service.
**Decision — `venues.business_day_cutoff` (time, default 04:00):** the business day runs cutoff-to-cutoff in the venue's timezone. Everything that says "day" respects it: daily limits (`daily_item_limits.date` = business date), Z-report, daily rollups, cashier daily cash report, the Today screen, scheduled daily emails. A 1am order belongs to yesterday's business day.
**Why:** 4am default is safe for late venues and invisible to early ones; the hospitality industry standard.

### Q21. Payment succeeds *after* the 12-min hold expired (slow 3D-Secure).
Customer taps Pay at minute 0, their bank's 3DS page confirms at minute 13; the sweep already expired the order and released the stock — and the PaymentIntent cancel fails because it just succeeded. Money taken, no order.
**Decision — resurrection-or-refund on late `payment_intent.succeeded`:** the webhook handler checks order status. If `expired`: try to **re-reserve** the limits atomically — success → order resurrects to `placed` and flows normally; failure → **automatic full refund** and the tracker shows an honest "Sorry — sold out while your bank was confirming. You have not been charged." Telemetry counts both outcomes.
**Why:** the iron rule (never keep money for food that can't be made) applied to the one path where charge-after-expiry is unavoidable.

### Q22. Cash refunds didn't exist in the schema.
The `refunds` table was Stripe-shaped; a cashier giving cash back had nowhere to record it, and the drawer math would silently drift.
**Decision:** `refunds.stripe_refund_id` is nullable — a refund against a `provider: cash` payment is a **cash refund**: recorded, attributed, reason required, and **subtracted from expected cash** in the cashier shift summary, daily cash report, and Z-report.
**Why:** if it moves money it must hit the ledger; the drawer must reconcile to the cent.

### Q23. A Stripe refund a week after payout can fail — or bill the platform.
Direct charges pay out daily; a later refund can hit a zero-balance connected account, fail, or drive the account negative (Express negatives can ultimately land on the platform).
**Decision:** enable **`debit_negative_balances: true`** on connected accounts at onboarding (Stripe pulls from the venue's bank for refunds exceeding balance), give `refunds` a `status` (`pending`/`succeeded`/`failed`), process `refund.failed`/`refund.updated` webhooks, and **surface failures loudly** — manager alert + red state on the order, never a silent fail. Monitor negative-balance accounts in the platform admin.
**Why:** refunds are a promise to a customer standing in the venue; a silent failure breaks it and the venue never knows.

### Q24. The platform earns zero per-order fee on cash orders — intended?
`application_fee_amount` only rides Stripe charges; a cash-heavy venue pays only the subscription, and venues could steer customers to cash.
**Decision — acknowledged pricing decision, not an oversight:** the subscription is priced to carry cash-heavy venues; the per-order fee is upside on card volume. Platform admin metrics track **cash share per venue** so systematic steering is at least visible; repricing (e.g., per-order fee on all orders via billing) is a future business decision, not a technical gap.

### Q25. The state machine had no undo — one fat-finger on the KDS was permanent.
**Decision — one-step-back transitions:** `ready → preparing` and `preparing → accepted`, allowed for kitchen and manager, validated in `OrderStateMachine` like any transition, logged + telemetry, and the waiter/customer screens update (a rollback from `ready` retracts the waiter's pickup notification).
**Why:** rush-hour mistap is a when, not an if. `served` stays irreversible (stock deducted, scan-confirmed) — fixing a wrong serve is a manager refund flow.

### Q26. Cash pay-at-counter dies if the counter queue is longer than 12 minutes.
The customer's hold expires while they stand in line; the cashier types the code and gets "expired."
**Decision — cashier revive:** entering an expired cash-order code offers **Revive** — re-reserves the limits atomically; success → hold recreated, cashier takes the cash, order fires. If stock is gone, the POS says exactly which item sold out and the cashier rebuilds the order with the customer.
**Why:** the customer did nothing wrong; making them re-order from their phone in line is punishment for our TTL.

### Q27. 86'ing an item didn't warn about in-flight tickets.
Auto-86 hides the dish from the menu, but an order paid 60 seconds earlier is already on the KDS for a dish the kitchen can't make.
**Decision:** when an item is 86'd (manual or auto), **flag every open ticket containing it**: the KDS ticket shows an "⚠ contains 86'd item" badge and the manager gets an alert listing affected orders → resolve per order (kitchen confirms they can still make the remaining portions, or unserveable/partial-refund flow).
**Why:** the slow path (customer waits, waiter discovers) was already covered, but discovery should take seconds, not a cold dish cycle.

### Q28. Waiters on iPhones get no reliable push until the native staff app (Phase 8).
iOS web push requires the PWA installed to the home screen (16.4+) and is still flaky; a Safari-tab waiter misses locked-phone alerts.
**Founder decision — accept the risk, staff app stays Phase 8.** Mitigations required in staff onboarding: iOS waiters **must install to home screen** (onboarding blocks with instructions until installed), loud in-app audio alert on assignment while the app is open, and the existing 90s escalation → claim board + manager alert already catches any missed order. Telemetry on accept-timeout rate per platform tells us if this is hurting real venues before Phase 8.

### Q29. Free trial — onboarding as written required a paid plan on day one.
**Founder decision — 14-day free trial, no card required:** venue signs up free with **full features and live ordering** during the trial (per-order application fee still applies to real card orders — real money moves, we take our cut). Card + plan required to continue after day 14; expiry without payment → back office shows the billing wall, QR ordering shows "temporarily unavailable" (same as canceled). `orgs.trial_ends_at` drives banners (countdown from day 10), Stripe Billing `trial_end` handles the mechanics, and platform admin shows trial states.
**Why:** small cafés won't card-up for an unproven tool; live ordering during trial is the product selling itself.

---

## Round 3 — Third Adversarial Review (2026-07-07)

Seventeen more issues from walking money math at the edges, time & accounting, data lifecycle, and the new pickup mode. Researched against industry practice (Toast/Restaurant365 comp-void discipline, POS Z-report accounting, McDonald's-style pickup no-show handling, Stripe currency minimums). Founder delegated the calls: "research the best way we can solve those errors."

### Q30. Comped (free) orders — a 100% discount breaks "no unpaid order reaches the kitchen."
Stripe can't charge zero, so a fully-discounted order could never fire — yet restaurants comp food constantly (owner's friend, apology dish).
**Decision — comps allowed, as their own payment provider:** when `total` is zero, checkout skips the charge and records a `payments` row with **`provider: comp`** — the order fires normally (the rule becomes "no order reaches the kitchen without a *recorded settlement*: Stripe, cash, or comp"). Comp is **manager-permission-gated** (like discounts), reason required, always attributed, and reported as its own line everywhere money is reported. Stock still deducts at `served` — a comped dish was cooked, and it must hit food cost (that's the industry-standard comp-vs-void distinction: **comp = made but free; void = never made** — our pre-payment line void already covers the latter).
**Why:** Restaurant365/Toast-class systems treat comps as first-class, reason-coded events precisely because untracked free food is where margins leak.

### Q31. Venue offboarding hard-delete contradicts "every order, every venue, forever."
Q15 hard-deletes tenant data after 90 days — which would silently punch holes in customers' cross-venue history.
**Decision — anonymized stub survives in customer histories:** before tenant hard-delete, orders belonging to **account-holding customers** are copied to a platform-level archive (date, item name snapshots, quantities, totals, "a closed venue"). Venue identity (name, logo, location) dies with the tenant; the customer's own record of what they ate and spent does not. Guests' orders (no account) are simply deleted with the tenant.
**Why:** an order row is *two* parties' record. The venue's copy is theirs to delete; the diner's copy is the product promise.

### Q32. Pickup mode had no exit for food nobody collects.
Waiter mode has unserveable → manager resolves; pickup mode had no equivalent — an uncollected `ready` order sat forever, poisoning the watchdog.
**Decision — not-picked-up flow:** after N minutes in `ready` (venue-configurable `pickup_timeout_minutes`, default 15), the order is flagged **not picked up** → manager/POS alert → same resolution set as unserveable: refund, mark collected (customer showed late), or close + wastage log. Telemetry tracks no-show rate.
**Why:** mirrors how mobile-order chains handle it (timeout-triggered, venue-resolved); reuses the existing unserveable resolution UI.

### Q33. Per-IP rate limiting would have blocked real customers.
Everyone in the restaurant shares the venue WiFi's public IP — a per-IP active-order cap locks out legitimate diners mid-rush.
**Decision:** the **per-`guest_token` cap is the real limit**. The IP limit only throttles **token minting** (bot-flood protection), is set generously (venue-crowd scale), and never blocks a token that already has a paid or active order.

### Q34. Stripe minimum charge (~$0.50 / £0.30, varies by settlement currency) fails a lone espresso.
**Decision:** checkout knows the venue currency's card minimum; below it, the Pay button is replaced with an honest "Card payments start at {min}" plus the available alternatives — cash/pay-at-counter (if enabled) and an "add something small?" nudge. Never a raw Stripe error.

### Q35. Nothing stopped a double refund.
Two managers refunding concurrently, or a double-tapped line-item refund, could over-refund.
**Decision:** refund creation validates `amount ≤ amount_paid − sum(existing non-failed refunds)` **inside one transaction with the payment row locked** (`SELECT … FOR UPDATE`); a given order line can be refund-referenced only once. Violations are rejected, not clamped.

### Q36. A "discount" after payment isn't a discount.
Adjusting `order_discounts` post-payment would desync `total` from money actually taken.
**Decision — policy line: discounts exist only pre-payment.** After payment, every goodwill gesture is a **refund** (full or line-item). `order_discounts` rows are immutable once the order leaves `pending_payment`. Recorded in code-standards.md.

### Q37. Refunds were rewriting history.
Netting today's refund into last Tuesday's rollup silently changes reports the accountant already saw.
**Decision:** refunds count on the **refund's business day** — that's when money left the drawer/account (standard till-action accounting). Last Tuesday's report never changes; today's report shows the refund line. Applies to rollups, revenue/payment reports, and Z-reports alike.

### Q38. Late webhooks (Stripe retries 72h) materialize orders into closed business days.
**Decision — post-close adjustments, never silent mutation:** any order/payment/refund landing on a **past** business day enqueues a rollup recompute for that day and appears on that day's Z-report as a flagged **"post-close adjustment"** addendum — the original close stays visible as closed.

### Q39. Order numbers must follow the business-day cutoff too.
**Decision:** the per-venue daily order-number sequence keys on **business date** (cutoff-to-cutoff), same as limits and reports — no order #1 at midnight mid-service.

### Q40. Trial/subscription expiry at 19:30 kills ordering mid-dinner.
**Decision:** expiry (trial end, cancellation) is **enforced at the venue's next business-day cutoff**, not at the timestamp — a venue's last trial evening finishes; the wall appears in the morning.

### Q41. Hard-deleting a menu item that was ever ordered corrupts history.
**Decision — archive, never delete, anything with history:** `menu_items`, `menu_categories`, `ingredients`, and `tables` get `archived_at`. Delete is allowed only when the record has zero references (never ordered / no movements / no items / no orders); otherwise the UI offers **Archive** — hidden from menus and pickers, intact in every report, snapshot, and FK. General rule recorded in code-standards.md.

### Q42. Modifier-rule edits can strand carts structurally, not just on price.
"Size" changed from optional to required while a burger sits in a cart → the cart line is now invalid.
**Decision:** checkout **revalidates every line's selections against current modifier rules** (not just prices); an invalid line blocks checkout with "This item's options changed — please re-add it," never a crash or a mis-configured paid order.

### Q43. Stocktake during service produces garbage variance.
Counting the fridge at 6pm while sales keep deducting means the theoretical number moves under the count.
**Decision:** a stocktake **session snapshots theoretical quantities at start**; variance = counted vs snapshot. UI recommends counting at close (and warns when open orders exist).

### Q44. Deactivating a staff member mid-shift left ghosts.
**Decision:** deactivating a membership **force-ends any open shift** and pushes their open orders to the claim board + manager alert — identical to the off-shift handoff path. Assignment eligibility checks `membership.active`, not just Presence.

### Q45. Forgotten clock-outs corrupted the work report.
**Decision:** open shifts **auto-close at the business-day cutoff**, flagged `auto_closed` and visibly marked in the employee work report so hours from forgotten clock-outs are never silently trusted.

### Q46. Call-waiter in pickup mode pinged nobody.
**Decision:** pickup venues replace the tracker's call-waiter button with **"Ask at the counter"** static text; `waiter_calls` is never created for a pickup venue. (Routing calls to the POS is a post-MVP option if venues ask.)

---

## Round 4 — Final Review Tail (2026-07-07)

Ten smaller-caliber items: spec ambiguities and ops polish, no architecture changes. Founder decided Q47 (passwords), Q48 (downgrade), Q49 (solo waiter); the rest follow the recommended fix. **This closes paper review** — remaining unknowns live in running code (races, reconnects, real webhook timing) and are the job of the per-feature Verify steps and the Phase-7 chaos drills.

### Q47. Email is a single point of failure for the entire auth system.
Magic-link-first login means delayed/spam-foldered email = staff locked out and venues unable to onboard.
**Decision (founder):**
- **Owner and manager accounts require a password** at account setup (magic link still works as an alternative) — a venue can never be locked out of its own restaurant by an email delay. Waiter/cashier/kitchen stay magic-link-first with optional passwords.
- **Real transactional provider from day one** (Postmark or SES adapter for Swoosh) with SPF/DKIM configured — dev-mode email in production would read as "your app is broken."
- **Magic-link sends are throttled per email address** (and per IP) so the login form can't be used to bomb a victim's inbox; the form always answers "link sent if the account exists."

### Q48. Plan downgrade below current venue count.
5 venues on Pro → Starter (cap 2): nothing said which 3 venues die.
**Decision (founder): self-serve downgrade is blocked while venue count exceeds the target plan's cap.** The owner deactivates venues first, deliberately — the system never chooses which venues die. The billing screen explains exactly what's blocking.

### Q49. Single-waiter venues drown the manager in escalation noise.
One waiter on shift → every busy stretch fires the 90s timeout → claim board (whose only candidate is the same waiter) → manager alert, every few minutes at lunch.
**Decision (founder): in the MVP** — when **exactly one waiter is on shift, assignments auto-accept** into their queue (no 90s window, no claim-board hop); the manager is alerted only by the genuinely-stalled-order watchdog thresholds. Two or more waiters restores the full accept flow.

### Q50. The cart didn't durably survive reconnects and deploys.
"Cart lives in the LiveView + session" — but LiveView state dies on every reconnect, deploy, and long phone-lock; a rolling deploy at 8pm would wipe every in-progress cart at every venue.
**Decision — DB-backed carts:** `carts` + `cart_items` tables keyed by `guest_token` + venue; the menu LiveView rebuilds the cart from the DB on every mount. Also makes multi-tab behavior and the expired-order revive coherent. Abandoned carts swept after 24h.

### Q51. Stripe webhooks arrive out of order — handlers must not trust event payloads.
Stale/reordered `account.updated` events could flip `charges_enabled` the wrong way; idempotency doesn't cover reordering.
**Decision — fetch-and-reconcile (standard Stripe practice):** on receiving any state-bearing event, fetch the **current** object from the Stripe API and reconcile our row to that — never to the event body's snapshot. Recorded as a code-standards rule.

### Q52. Scheduled report emails must re-check membership at send time.
Opt in to the daily revenue email, get fired, keep receiving the venue's numbers every morning — a real data leak.
**Decision:** every scheduled delivery resolves "is this person still an active member with a role that may see this report" **at send time**; membership deactivation also purges the person's report subscriptions and push tokens (extends Q44's deactivation cleanup).

### Q53. Venue currency must be immutable after the first order.
Rollups, profit reports, and org comparisons assume one currency per venue's history — you can't sum USD and EUR rows.
**Decision:** **currency locks at the venue's first order**; changing currency means a new venue. Timezone and `business_day_cutoff` stay editable (display-safe) but warn that historical business days keep their original dates.

### Q54. The chargeback window outlives tenant deletion.
Offboarding hard-deletes at 90 days; card disputes arrive up to ~120 days after a charge.
**Decision:** the **payment + dispute-evidence subset** (payment rows, order snapshots, serve-scan timestamps) is retained **180 days** post-offboarding, then purged. Everything else still dies at 90 days.

### Q55. Presence flapping on restaurant WiFi causes assignment churn.
Phones bounce between WiFi and cellular; a strict 60s liveness gate would drop a waiter, escalate their order, and re-add them 20 seconds later.
**Decision:** a **grace window** (~30s) before Presence loss removes a waiter from assignment candidacy, and per-venue **presence-flap telemetry** so a venue's bad WiFi is visible to us before they complain.

### Q56. Checkout compliance line + browser floor.
Card networks require a visible refund/cancellation policy at the point of payment; and no minimum browser was defined — a customer on a 2019 phone is an invisible lost sale.
**Decision:** one venue-configurable refund-policy line on the checkout screen (sensible default provided). Supported-browser floor declared: **iOS Safari 15+ and evergreen Chrome/Android (≈2 years back)** — the QR flow is tested there, and below the floor customers get an honest "please update your browser" page instead of silent breakage.

---

## Round 5 — Launch-Market Reality: the Somali Horn (2026-07-07, grill session)

The grill's first question ("where is venue #1?") overturned Round 2's biggest assumption. Founder facts: he is in Somalia; the pilot venue is real; **MVP target cities are Hargeisa (Somaliland), Mogadishu (Somalia), and Jigjiga (Ethiopia, Somali Region)**; payments run on mobile-money wallets — ZAAD, EVC Plus, Sahal/Golis, eDahab, and eBirr (Ethiopia). Primary-source research: `research/somalia-payments-waafipay-zaad.md` (WaafiPay/ZAAD/eDahab) and `research/ethiopia-payments-ebirr.md` (eBirr — in progress).

### Q57. Launch markets are Hargeisa, Mogadishu, and Jigjiga — Stripe does not operate in any of them.
**Decision — supersedes Q17:** payments are built on Somali/Ethiopian mobile money behind a **`Payments.Provider` behaviour** (charge / refund / lookup / verify_callback). Adapter order: **WaafiPay first** (one REST/JSON gateway covering ZAAD + EVC Plus + Sahal + WAAFI + cards; sandbox, programmatic full/partial refunds, HMAC-SHA256-signed callbacks), eDahab second (own API, docs.edahab.net), **Chapa third for Ethiopia** (Phase C) — eBirr itself publishes **no developer API**; Chapa is the NBE-licensed gateway with real public docs whose Direct Charge API covers Coopay-Ebirr, telebirr, and M-Pesa via the same push-PIN UX class. A Stripe adapter is reserved for future markets — the Rounds 1–4 Stripe design survives in git history and this file's earlier answers.
**Why WaafiPay first:** it is the only single integration that covers both Somali cities' dominant wallets, and its transaction model (below) fits the existing order design with minimal surgery.

### Q58. The wallet transaction model — what changes in the order loop?
**Findings and decisions:**
- **Charge = push PIN prompt** on the customer's phone against the **venue's own merchant credentials** (entered at onboarding, stored encrypted, never logged). Money lands venue-direct — the platform still never holds customer money, and we stay out of money-transmitter territory.
- The prompt has a **hard ~5-minute user timeout** (explicit cancelled/timed-out result codes) — comfortably inside the 12-minute stock hold; the Q21 resurrection-or-refund path stays for successes discovered late by polling.
- **Callbacks are NOT retried** (unlike Stripe's 72h). Decision: callbacks are an optimization only — every pending payment gets a **reconciliation poller** (transaction-inquiry API, Oban, ~30s cadence, final sweep before hold expiry). The zero-order-loss chain's first pillar becomes "the provider holds the truth **and we poll it**."
- **Chargebacks don't exist** in mobile money — the Q5/Q23 dispute machinery goes dormant for wallet providers (wakes for a future card adapter). No card minimums either — Q34's gate becomes per-provider config, effectively off.
- **Merchant onboarding is manual/in-person** (paperwork with WaafiPay/Telesom; Somaliland business license for direct ZAAD). Decision: venue onboarding gains a guided "get your merchant account" checklist step we hand-hold — the honest revision to the "signup → first order in under 1 hour" promise: **under 1 hour once merchant credentials exist**.

### Q59. Platform revenue without `application_fee_amount` or Stripe Billing.
No marketplace/split-payment API exists on any of these rails.
**Decision — fee ledger + monthly wallet invoice:** every wallet order accrues its per-order fee to a `platform_fee_ledger` (org, order, amount, accrued/settled). Monthly, the platform collects **subscription + accrued fees** in one itemized invoice via a push-prompt charge from **our own merchant account** to the owner's wallet (no recurring-mandate API exists — each collection is a PIN-approved prompt). Non-payment follows the existing `past_due` grace → suspended flow; the ledger survives and collects on reactivation. Trial (Q29) unchanged — "no card required" is now literal. Downgrade rule (Q48) and cutoff-timed expiry (Q40) unchanged.

### Q60. Currencies and locales are now concrete.
**Decision:** Somali-city venues are **USD** (mobile-money balances there are USD-denominated); Jigjiga venues are **ETB**. The per-venue currency lock (Q53) now does real work — org rollups across USD and ETB venues report per-currency, never summed. Customer-surface locales: **Somali + English + Arabic** — RTL (Q from Round 1 groundwork) is a **day-one feature**, not groundwork. `ex_money` handles both currencies natively.

### Q61. Phasing the three cities.
**Decision (recommended; founder to confirm the pilot city):** **Phase A** = the pilot's city on WaafiPay (its dominant wallets). **Phase B** = the second Somali city — mostly free, same gateway, plus the eDahab adapter when demanded. **Phase C** = Jigjiga — new provider adapter (**Chapa**, reaching eBirr/telebirr/M-Pesa), ETB venues, and three gates before building: a Chapa test-mode spike, an Ethiopian legal opinion (data-localization Proclamation 1321/2024 says personal data collected in Ethiopia must be stored on servers in Ethiopia — the biggest flagged landmine — plus licensing perimeter), and a decided ETB fee-collection/repatriation approach. None look fatal (research/ethiopia-payments-ebirr.md), but Jigjiga launches only after the Somali loop is proven. Feature 09 builds the provider behaviour + WaafiPay adapter; nothing else in the build plan moves.

---

## Round 6 — Pricing Numbers (2026-07-08)

Q24, Q48, and Q59 had already committed to the *shape* of the plan model (Starter/Pro by venue count and fee %, monthly wallet-invoice billing) but left every number unset — the marketing page could only say "a small per-order fee" (research/landing-page-patterns.md explicitly flagged this as acceptable pre-launch, "free to state even before exact numbers are set"). Founder delegated: "study the pricing and decide." Full numbers, mechanics, and rationale now live in **pricing.md**; this entry is the pointer other Qs get.

### Q62. What are the actual plan prices and fee percentages?
**Decision — see pricing.md for the full spec:** **Starter** $19/venue/month + 2.0% per-order fee, 1 venue. **Pro** $15/venue/month + 1.2% per-order fee, 2–10 venues, adds cross-venue comparison + org Profit rollup. Beyond 10 venues: custom, no self-serve tier (matches project-overview.md's "1–10 venues" target market — no invented Enterprise tier). Fee mechanics, cash/comp exemption, and downgrade rule (Q48) are unchanged, now with concrete numbers. **Monthly billing only, deliberately no annual plan** — the wallet rails have no recurring-mandate API (Q58), so "annual" would mean one large lump-sum PIN-approved charge, which fights the "no card required" trust positioning the trial (Q29) leans on. Jigjiga/ETB pricing (Phase C, Q61) is deliberately left unset until that phase's legal/provider gates clear, rather than fabricated now.
**Why:** everything downstream (`config/plans.exs`, the billing screen, the marketing pricing section) needs one number, not "TBD" — and the numbers had to be derived from the actual payment-rail constraints (Q58/Q59) and target market (project-overview.md), not picked generically.

---

## Round 7 — Pricing Restructured to Feature Tiers (2026-07-08)

Same day as Round 6. Founder delegated again: "rewrite it, list them based on features someone will use" — plus a concrete constraint, the entry price becomes $40/month. Q62's 2-tier venue-count model is **superseded**, not deleted (kept below as the historical record of what shipped first).

### Q63. Restructure Starter/Pro into feature-differentiated tiers, entry price $40.
**Decision — supersedes Q62; see pricing.md for the full spec:** three tiers now, differentiated by **what a venue actually uses**, not just venue count. **Essentials** $40/venue/month + 2.5% fee, 1 venue — the order loop only (QR ordering, KDS, waiter app, cashier POS, tracker, today's live numbers). **Growth** $75/month + 1.5% fee, 1 venue — adds inventory/recipes and the full 13-report Report Center. **Pro** $55/venue/month + 1.0% fee, 2–10 venues — Growth depth on every venue, plus cross-venue comparison and the org Profit rollup. Trial (Q29) now explicitly unlocks **every tier's features** for the 14 days, not just "full features" as an undifferentiated blob — a trialing venue needs to see Growth/Pro depth to have a reason to pay for it. Downgrade rule (Q48) extended: Growth→Essentials is allowed (unlike a venue-cap breach) but is a real feature downgrade — inventory/report data is preserved, not deleted, just inaccessible until the venue upgrades again (archive-never-delete, code-standards.md).
**Why $40, not $19:** at Q62's flat $19, the number undersold a product that runs a venue's entire floor. Raising the entry price while *narrowing* what it includes lets Growth and Pro read as genuine, feature-justified upgrades instead of a fee-percentage footnote — see pricing.md § Rationale for the full reasoning.

---

## Scenarios reviewed and left as-designed (no change needed)

- **Menu edited while a cart is open** → snapshots at order + server-side recompute at checkout already handles it; customer sees updated price before paying (Round 3 tightened this: selections are re-validated structurally too — Q42)
- **Follow-up "can I add fries" orders** → just place a second order; same-table stickiness (Q8) sends it to the same waiter
- **Call-waiter before any order is accepted** → falls back to claim-board broadcast (all on-shift waiters) — already implied by assignment design, now explicit
- **Webhook delayed while customer stares at "confirming…"** → already designed (optimistic confirming state + alert on p95 lag)
- **Venue's Stripe onboarding incomplete** → already designed (ordering disabled until `charges_enabled`)
- **Refund after stock deducted** → covered by Q4 decision: money and stock are separate ledgers
- **Swapped QR stickers between tables** (round 3) → waiter sees the table number on the order and delivers by number; a mismatch is an ops problem the serve-scan surfaces, not a software one
- **Huge-quantity orders** (round 3) → pay-first self-limits; a sanity cap of 20 per cart line added as cheap insurance (one changeset validation, build-plan 07)
- **Staff rating their own venue's food** (round 3) → noise, not fraud; not worth excluding at MVP
- **DST makes 4am ambiguous one night a year** (round 3) → the timezone library resolves it; business-day math uses venue-timezone-aware datetimes throughout
