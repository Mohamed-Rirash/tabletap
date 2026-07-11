# Pricing

Concrete numbers for the plan model that architecture.md, role-features.md, and design-qa.md (Q24/Q48/Q59) had already committed to in shape ("Starter / Pro by venue count & fee %") but left unset. First decided 2026-07-08 (design-qa.md Q62, founder-delegated: "study the pricing and decide"), then **restructured same day** (Q63, founder-delegated: "rewrite it, list them based on features someone will use," entry price set to $40/month) from a 2-tier venue-count model to a **3-tier feature model**. This file is the single source of truth for numbers — other docs reference it rather than repeating figures, so a repricing is a one-file diff plus `config/plans.exs` (code-standards.md: "changing a fee is a deploy, deliberately").

---

## Plans

Tiers now differentiate by **feature depth**, not just venue count — the question a plan answers is "what does this venue actually need to run," not just "how many locations." Every tier still gets the full order loop; depth is added on top.

| | **Essentials** | **Growth** | **Pro** |
|---|---|---|---|
| Venues per org | 1 | 1 | 2–10 |
| Price | **$40 / month** | **$75 / month** | **$55 / venue / month** |
| Per-order platform fee (wallet/card orders only) | **2.5%** | **1.5%** | **1.0%** |
| QR ordering, live menu, sold-out states | ✓ | ✓ | ✓ |
| Kitchen Display (KDS) | ✓ | ✓ | ✓ |
| Waiter app (queue, assignment, scan-to-serve) | ✓ | ✓ | ✓ |
| Cashier POS | ✓ | ✓ | ✓ |
| Order tracker + call-waiter | ✓ | ✓ | ✓ |
| Today's live dashboard (revenue, orders, avg check) | ✓ | ✓ | ✓ |
| Inventory, recipes &amp; stock alerts | — | ✓ | ✓ |
| Full Report Center — all 13 report types (owner-dashboard.md) | — | ✓ | ✓ |
| Menu engineering &amp; margins, discounts/comps tracking | — | ✓ | ✓ |
| Cross-venue comparison &amp; org-level Profit (P&amp;L-lite) rollup | — | — | ✓ |

**More than 10 venues:** no self-serve tier — talk to us for a custom rate. Ten is a real ceiling, not a marketing round number: it matches the documented target user exactly ("independent cafés and small restaurant chains, 1–10 venues," project-overview.md § Target Users).

A single-venue org can be Essentials or Growth; adding a second venue requires Pro (self-serve venue creation is blocked above a plan's venue cap, same mechanism as the downgrade rule below).

---

## Why feature-tiered, not venue-tiered

The previous (Q62) model gated almost nothing — both tiers got the full feature set, and the only lever was venue count and fee %. That undersold the product: a solo café that only ever runs the order loop (no formal inventory tracking, no need for 13 report types) was paying for capability it wouldn't touch, and a venue that *does* want inventory + full analytics had no way to signal that without buying a second venue's worth of Pro.

The new ladder maps to genuine usage patterns:
- **Essentials** — the order loop and nothing else. A venue that just wants guests to scan, order, and pay, with a kitchen board and a waiter queue, and a plain today's-numbers view. No inventory discipline, no report catalog to learn.
- **Growth** — the venue that's past day one and wants to *run the business* on the numbers: recipes tied to ingredients so stock deducts itself, low-stock alerts, and the full 13-report Report Center (owner-dashboard.md) for food cost %, menu engineering, and margins.
- **Pro** — the same Growth depth, for every venue in a chain, plus the features that only make sense once there's more than one venue: cross-venue comparison and the org-level Profit rollup.

---

## Fee mechanics

- The per-order fee applies **only** to orders settled through a wallet/card payment provider (ZAAD, EVC Plus, eDahab, Sahal, and a future card adapter). Cash and comp (`provider: comp`) orders carry **zero** platform fee — unchanged from the existing acknowledged decision (design-qa.md Q24).
- Mechanism is unchanged (design-qa.md Q59): every wallet order accrues its fee to `platform_fee_ledger` — this file only sets the percentages, not the pipeline.
- Fee **decreases** as tier increases (2.5% → 1.5% → 1.0%), same shape as the price-per-venue logic: committing to more of the platform earns a lower take rate, not just a volume discount on the subscription line.
- **Stacking, for honesty in any pricing copy:** WaafiPay charges the venue its own ~1% transaction fee directly, outside our system (research/somalia-payments-waafipay-zaad.md). Worst case, total order-time deduction is WaafiPay's ~1% + ours: **≈3.5% (Essentials)**, **≈2.5% (Growth)**, or **≈2.0% (Pro)**. All three stay far below delivery-app commissions (15–30%), which is the fair comparison point — never compare our fee to zero.

---

## Billing

- Monthly, itemized (design-qa.md Q59, unchanged): `(venue plan price(s)) + accrued per-order fees for the period`, one invoice per org.
- Collected via a single PIN-approved push-prompt wallet charge from the org owner's wallet, initiated from our own merchant account. No card, no autopay, no stored payment method — there is no recurring-mandate API on these rails, so every cycle is a fresh approval.
- **Monthly billing only — deliberately no annual plan.** Unchanged from Q62: an annual charge would mean one large lump-sum PIN approval, which fights the "no card required" trust positioning the trial leans on for a market that "won't card-up for an unproven tool" (Q29).

---

## Trial

Unchanged in spirit, clarified for the new tiers: 14-day free trial, no card required. During the trial, **every feature across all three tiers is unlocked** — a trialing venue sees the full Pro-depth product (inventory, full Report Center, the works) so it can evaluate what it actually needs before picking a tier at day 14, not guess from a feature-comparison table. Per-order fees still accrue on real wallet orders during the trial at the **Essentials rate (2.5%)** until a plan is chosen — "no card required" describes the trial's entry cost, not a fee waiver. This is the honest evolution of Q29's "full features and live ordering" promise now that "full features" is no longer a single flat thing.

---

## Downgrade &amp; tier-change rules

Concrete, tier-aware form of the existing rule (design-qa.md Q48):
- **Pro → Growth/Essentials is blocked while venue count > 1** (both lower tiers cap at 1 venue) — the owner deactivates venues down to one first; the system never chooses which venues die.
- **Growth → Essentials is allowed** at any time, but is a genuine feature downgrade, not just a price change: inventory/recipe configuration and report history are **preserved, not deleted** (archive-never-delete, code-standards.md), simply inaccessible while on Essentials — reactivating Growth restores access to the same data, nothing is recomputed or lost. The downgrade confirmation names exactly what becomes unreachable (mirrors the existing Q48 "billing screen explains exactly what's blocking" pattern).
- **Essentials → Growth/Pro (upgrade)** is unrestricted and takes effect immediately — no reason to gate access to more.

---

## Currency & launch phasing

- **USD at launch** — Hargeisa and Mogadishu (Phase A/B, design-qa.md Q61); mobile-money balances in both cities are USD-denominated (Q60).
- **Jigjiga (Phase C, ETB)** pricing is deliberately not set here — see Q61's phasing gates. Percentages carry over unchanged; only the flat per-venue prices need ETB figures when that phase opens.

---

## Rationale

- **Why $40 for Essentials, not $19:** the entry price was raised (founder decision, Q63) alongside the move to feature tiers. At $19 flat for the full feature set (Q62), the number undersold a product that runs a venue's entire floor — kitchen, waiter, POS, live tracking. $40 is still trivially small against even modest venue revenue, and now buys a clearly-scoped tier (the order loop) rather than "everything, cheaply," leaving real room for Growth and Pro to read as genuine upgrades rather than a fee-percentage footnote.
- **Why Growth costs more than Essentials but less than 2× Pro's per-venue rate:** $75 vs $40 is a meaningful, feature-justified step (inventory + the entire Report Center is a lot of product), not a rounding change.
- **Why Pro's per-venue price ($55) sits between Essentials and Growth:** a chain on Pro gets Growth-level depth on every venue at a volume discount off Growth's flat rate — rewards consolidating onto one plan as a chain grows, the standard SaaS shape, while still being the platform's highest-revenue tier per venue owner in aggregate (a 3-venue Pro org pays $165/mo, more in absolute terms than any single-venue tier).
- **Why 10 venues, not "unlimited" or a fourth tier:** unchanged from Q62 — matches project-overview.md's stated target market exactly; no invented Enterprise tier for a segment the product doesn't target.
- **Why trial unlocks everything:** gating the trial to Essentials would mean a prospective Growth/Pro customer never sees the feature that would convince them to pay more for it — the trial's whole job (Q29) is "the product selling itself."
