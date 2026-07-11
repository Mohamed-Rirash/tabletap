# Landing-Page Patterns for Restaurant-Tech SaaS

Research for rebuilding TableTap's marketing home page (2026-07-07). Method: fetched and dissected the live landing pages of category competitors + NN/g conversion research. A background-agent run was cut short by a session limit; this note was completed inline by the main session from the same sources.

## TL;DR

Every competitor in this category runs the same enterprise, **sales-led** playbook: outcome headline → logo wall/usage stats immediately under the hero → phone-mockup product carousels → testimonials → "Talk to sales", with **pricing hidden on every single page checked**. TableTap is the opposite motion (self-serve, 14-day no-card trial, pre-launch, zero customers) — so we copy the *skeleton* (outcome hero, product-as-proof mockups, guest/staff/owner segmentation) and invert the two things we can win on: **a self-serve trial CTA instead of a demo form, and a transparent pricing model instead of "contact sales."** Everything social-proof-shaped (logos, "trusted by X", star ratings, testimonials) is off-limits until real venues exist — the honest pre-launch substitute is showing the actual product UI and making engineering guarantees.

## Competitor teardowns (fetched 2026-07-07)

| Site | Hero headline (quoted) | Primary CTA | Under the hero | Pricing |
|---|---|---|---|---|
| **sunday** ([sundayapp.com](https://sundayapp.com)) | "The payment experience that saves time and generates 5× more Google reviews." | "Discover it for free" | Product carousel: 7 phone mockups (pay-at-table, order-pay, terminal…) | Hidden (demo form) |
| **me&u** ([meandu.com](https://www.meandu.com)) | "Personalise every guest's experience" | "TALK TO SALES" | CEO testimonial + 15-logo carousel | Hidden |
| **Owner.com** ([owner.com](https://www.owner.com)) | "The AI platform restaurants use to grow online discovery." | "Get my AI report" (interactive audit tool) | Phone mockups of the grading dashboard; 4.8★ rating strip | Hidden |
| **TouchBistro** ([touchbistro.com](https://www.touchbistro.com)) | "All-in-One POS and Restaurant Management System" | "get a quote" | 3 rotating product images (FOH/BOH/guest) + 3 value props | Hidden (separate page) |
| Toast (pos.toasttab.com) | — | — | — | **UNVERIFIED — 403s bot fetches** (consistent with earlier research passes) |
| Square for Restaurants | — | — | — | **UNVERIFIED — JS-shell page, content not server-rendered**; Square is publicly known for transparent pricing but that wasn't verifiable from this fetch |

Notable structural details:

- **sunday segments by audience**, with dedicated sections: "FOR OPERATORS: Faster table turns…", "FOR STAFF: Higher tips…", "FOR GUESTS: Fast, simple, personalised checkout…" — the cleanest pattern found, and it maps 1:1 onto TableTap's role-features.md.
- **sunday's headline quantifies the outcome** ("saves 12 minutes per table", "5× more Google reviews") — the strongest hero formula observed; me&u's abstraction ("Personalise every guest's experience") is the weakest.
- **No competitor uses video in the hero.** Product is shown as static phone/tablet mockups everywhere — good news, since we can build those as real HTML components.
- me&u and TouchBistro segment by **venue type** (restaurants / fast casual / pubs / cafés…); sunday by **audience role**. Both appear; role-segmentation reads better for a product page, venue-type for nav.
- Every page ends in a lead-capture form or demo CTA; sunday and me&u repeat the primary CTA 3+ times down the page.

## The invariant skeleton (what all of them share)

1. Sticky nav with segmented product menus + CTA button
2. Hero: outcome-promise headline + product visual (mockups, not photos of food)
3. Proof strip immediately under the hero (logos and/or usage stats)
4. Mechanism section (how it works / product modules)
5. Audience- or venue-segmented feature sections with per-segment mockups
6. Testimonials / case studies mid-page
7. Ecosystem (integrations/APIs) — enterprise signal
8. Repeated CTA + lead capture + footer

## Conversion research (first-party sources read)

- **Above the fold is a gatekeeper**: NN/g's eyetracking found the 100px just above the fold get **102% more views** than the 100px just below — the hero must carry the value proposition alone ([NN/g, The Fold Manifesto](https://www.nngroup.com/articles/page-fold-manifesto/)).
- **The homepage must answer "why choose this over others"** via a descriptive tagline + hero content, grounded in the audience's actual goals ([NN/g, Homepage Design: 5 Fundamental Principles](https://www.nngroup.com/articles/homepage-design-principles/)).
- Consequence for CTA copy: for a self-serve SMB product the CTA should name the self-serve action and neutralize its perceived risk in the same breath ("Start free — no card required"), not borrow the enterprise "Get a demo" (we have no sales team to demo it).

## What TableTap must do differently (pre-launch, self-serve, Somali Horn)

**Cannot honestly use** (everything the competitors lean on): logo walls, "trusted by N venues", star ratings, testimonials, usage stats ("80M diners"), case studies. Fabricating any of these would be discovered instantly in a small market.

**Honest substitutes:**
- **Product-as-proof**: real UI mockups built as actual HTML components in the page (tracker, KDS ticket, dashboard tiles) — indistinguishable from screenshots because they *are* the design system.
- **Engineering guarantees framed as promises, not stats**: "<90s scan-to-paid", "an order paid is never lost" — clearly worded as what the system is built to do, never as measured usage.
- **Transparent pricing model** (subscription + per-order fee, nothing on cash/comp orders, 14-day no-card trial) — a direct inversion of five competitors' "talk to sales", and free to state even before exact numbers are set.
- **Mobile-money-first** (ZAAD/EVC Plus/eDahab by name) — no competitor on earth leads with this; it's the wedge for the actual launch market.
- **"Founding venue" angle** replaces case studies: early venues get hand-held onboarding.

## Recommended blueprint (rebuild to this)

1. **Nav** — logo, anchors (Product / How it works / Pricing / FAQ), Log in, `Start free` button
2. **Hero** — quantified-outcome headline; sub names the mechanism + the two differentiators (mobile money, menu-price-is-final). CTA `Start free — 14 days, no card` + secondary anchor `See it work ↓`. Visual: **one order shown on two screens at once** (customer tracker + KDS ticket, same order #) — product-as-proof and the real story (everyone sees the same order live).
   - Headline candidates: (a) "From table scan to paid order in 90 seconds." (b) "The QR menu that runs your whole restaurant." (c) "Scan. Order. Paid. Cooking."
3. **Guarantee strip** — the four Success-Criteria numbers, labeled as engineered promises
4. **How it works** — 4 steps, guest's-eye view
5. **For guests / For staff / For owners** — sunday's segmentation, one row each with a per-segment mockup fragment
6. **Feature grid** — 6 areas, compressed
7. **Money section** — wallets by name + venue-direct settlement + analytics/profit teaser
8. **Pricing** — the transparent *model* (no invented dollar figures), positioned explicitly against "talk to sales"
9. **FAQ** — real objections (tax/tips, wallets, no-waiter cafés, data isolation, trial)
10. **Founding-venue final CTA** + minimal footer

Leave out: video, integrations/API section (enterprise signal we can't back), testimonials/logos/stats of any kind, multi-audience nav dropdowns (one page is enough at this stage).
