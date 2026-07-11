# UI Tokens

Design tokens for TableTap. Implemented as CSS variables + a daisyUI theme in `assets/css/app.css`. Never hardcode colors or spacing in templates — always use the tokens below (via Tailwind utilities mapped to these variables).

---

## Design Philosophy

The visual language is **warm counter-service**: appetizing, calm, and fast to read. Customer screens must make food photos the hero — the chrome around them stays neutral and warm so any cuisine looks good. Staff screens (waiter, KDS, POS) are **status-first**: a glance from a meter away must tell you what's new, what's late, and what's ready.

Two theme modes:
- **Customer & back office:** light default with a dark variant (daisyUI theme toggle)
- **KDS:** always dark — kitchen tablets run for 12h and glare matters

**Tenant branding:** each venue sets one `--brand` color (plus logo). It's used exclusively for the customer surface's accents (header, price highlights, primary buttons). All functional/status colors below are platform-fixed and never overridden by tenants — status must read identically in every restaurant.

---

## Color Tokens

```
/* Neutral surfaces — light theme */
--color-background: #FAF8F5;        /* warm off-white */
--color-surface: #FFFFFF;
--color-surface-sunken: #F1EDE7;
--color-border: #E5DFD6;
--color-text-primary: #241E19;
--color-text-secondary: #6E655C;
--color-text-muted: #9C948A;

/* Neutral surfaces — dark theme / KDS */
--color-background-dark: #17151A;
--color-surface-dark: #211E24;
--color-surface-raised-dark: #2B2730;
--color-border-dark: #3A3540;
--color-text-primary-dark: #F4F1EC;
--color-text-secondary-dark: #A9A19B;

/* Platform accent (staff surfaces, marketing, back office) */
--color-accent: #C96F2E;            /* burnt sienna */
--color-accent-dark: #A6551C;
--color-accent-muted: rgba(201, 111, 46, 0.12);

/* Tenant brand (customer surface only; per-venue override) */
--brand: var(--color-accent);       /* default when a venue hasn't set one */
--brand-muted: color-mix(in srgb, var(--brand) 12%, transparent);

/* Order status — FIXED platform-wide, never tenant-themed */
--status-placed: #8A63D2;           /* violet  — new, unaccepted */
--status-accepted: #2E7DC9;         /* blue    — waiter has it */
--status-preparing: #D9822B;        /* amber   — in the kitchen */
--status-ready: #2FA45C;            /* green   — waiting for pickup */
--status-served: #57906B;           /* calm green-gray — done */
--status-cancelled: #C0392B;        /* red */

/* Semantic */
--color-success: #2FA45C;
--color-warning: #D9A62B;           /* low stock, delayed */
--color-danger: #C0392B;            /* destructive, sold out, overdue */
--color-info: #2E7DC9;

/* Radius */
--radius-sm: 8px;
--radius-md: 12px;
--radius-lg: 16px;
--radius-full: 9999px;
```

---

## Color Usage Guide

| Element | Token |
|---|---|
| Customer page background | `background` |
| Menu item card, sheets, panels | `surface` |
| Customer primary button (Add to cart, Pay) | `--brand` |
| Price text on customer surface | `--brand` (dark enough variants enforced by contrast check) |
| Order status chips/timeline everywhere | the matching `--status-*` — never anything else |
| KDS ticket border | `--status-*` of its state; pulses `warning` when past expected prep time |
| Waiter "next up" order card | `accent` left border, 4px |
| Sold-out overlay / danger actions | `danger` |
| Low-stock badges, delay indicators | `warning` |
| Manager dashboard stat accents | `accent` |
| Call-waiter active ping | `info`, pulsing |

Contrast floor: all text ≥ 4.5:1 against its background (3:1 for ≥ 24px). Tenant `--brand` colors are validated at save time; too-light brands get an auto-darkened text variant.

---

## Typography

System font stack with **Inter** (variable) as the loaded face — fast, neutral, excellent numerals for prices and timers. No display font at MVP; the venue's logo carries the personality.

| Element | Size | Weight | Color |
|---|---|---|---|
| Page title (back office) | 24px | 700 | text-primary |
| Venue name (customer header) | 20px | 700 | text-primary |
| Section / category heading | 17px | 650 | text-primary |
| Menu item name | 16px | 600 | text-primary |
| Body / descriptions | 14px | 400 | text-secondary |
| Price | 15px | 700 | `--brand` (customer) / text-primary (staff), tabular-nums |
| Caption, meta, timestamps | 12px | 500 | text-muted |
| KDS ticket item lines | 18px | 600 | text-primary-dark — readable at arm's length |
| KDS timer | 22px | 800 | state color, tabular-nums |
| Order number (staff surfaces) | 15px | 800 | text-primary, `#`-prefixed |
| Stat tile value (dashboard) | 28px | 800 | text-primary, tabular-nums |

All numerals in prices, timers, quantities: `font-variant-numeric: tabular-nums`.

---

## Spacing & Touch Targets

| Token | Value | Use |
|---|---|---|
| `space-1` | 4px | icon-to-label gaps |
| `space-2` | 8px | inside chips, tight rows |
| `space-3` | 12px | standard gap between elements |
| `space-4` | 16px | card padding, screen edge padding on mobile |
| `space-6` | 24px | section spacing |
| `space-8` | 32px | dashboard section spacing |

**Minimum touch target 44×44px** everywhere; **56×56px** for waiter-app primary actions (Accept, Mark served) and POS grid cells — used one-handed while walking.

---

## Component Tokens

### Menu Item Card (customer)

```
layout: horizontal — text block left, 96×96px photo right (radius-md)
background: surface; border: 1px border; radius-lg
padding: space-4; gap: space-3
sold out: photo grayscale + "Sold out" chip (danger-muted bg, danger text); card not tappable
tags row: dietary/allergen chips, 11px, surface-sunken bg
```

### Modifier Sheet (customer)

```
bottom sheet, radius-lg top corners, drag handle
group header: name + requirement chip ("Choose 1", "Up to 3") — chip turns danger if unmet on submit
option row: 48px min height, checkbox/radio left, price delta right (+$1.00, tabular)
footer: qty stepper + "Add · $12.50" button (brand, full-width, 56px, live-updating total)
```

### Sticky Cart Bar (customer)

```
fixed bottom, full-width minus space-4 margins, radius-full
background: brand; text: white
content: item count badge · "View cart" · total (tabular)
appears with 200ms slide-up when cart is non-empty
```

### Order Status Timeline (customer tracker)

```
vertical steps: Placed → Accepted → Preparing → Ready → Served
completed step: filled dot in its --status-* color + timestamp
current step: pulsing dot + ETA line ("~8 min")
connector line fills with the current status color
```

### KDS Ticket

```
width: 280px, dark surface-raised, radius-md
left border: 6px in status color
header: order number (800) + table/takeaway chip + elapsed timer
body: qty × item name, modifiers indented one level in text-secondary, 16–18px
overdue (> expected prep): header background flips to warning at 15%, timer turns warning and pulses
footer: full-width state-advance button (Start → Ready), 56px
```

### Waiter Order Card

```
surface, radius-lg, padding space-4
"NEXT UP" variant: 4px accent left border + accent-muted background
rows: order #, table number (large, 700 — the thing they look for), item count, placed-ago
primary action: full-width 56px (Accept / Picked up / Scan to serve)
call-waiter ping: info-colored banner strip atop the card, pulsing until acknowledged
```

### Stat Tile (dashboard)

```
surface, radius-lg, padding space-4
label 12px text-muted uppercase; value 28px 800 tabular
delta vs previous period: small chip, success/danger with ▲▼
```

### Table QR Print Sheet

```
print CSS: 2×4 grid per A4 page
each cell: venue logo, "Table 7" at 24px 800, QR SVG at 160×160px minimum, short "Scan to order" line
pure black QR on white regardless of theme/brand — scannability first
```

---

## Animation Tokens

| Animation | Duration | Easing |
|---|---|---|
| Sheet / drawer open | 250ms | ease-out |
| Cart bar slide-up | 200ms | ease-out |
| Status step advance (tracker) | 300ms fill | ease-in-out |
| New KDS ticket / waiter card entrance | 250ms slide + fade | ease-out |
| Overdue / call-waiter pulse | 1s loop | ease-in-out |
| Stat count-up on dashboard load | 600ms | ease-out |
| Button press feedback | 80ms scale to 0.97 | ease-out |

Respect `prefers-reduced-motion`: replace pulses with static color, disable count-ups.

---

## Invariants

- Order-status colors are platform-fixed — a tenant brand can never restyle them; status must read the same in every venue
- Tenant `--brand` appears only on the customer surface — staff surfaces always use the platform `accent`
- Food photos are never stretched, tinted, or overlaid with text — 1:1 crop, `object-cover`
- QR codes print pure black-on-white at ≥ 160px — never brand-colored
- Prices, timers, quantities always use tabular numerals
- Staff primary actions (Accept, Start, Ready, Scan to serve) are always ≥ 56px and full-width on mobile
- KDS is dark-only; customer/back office must be fully legible in both light and dark
- Danger red is reserved for destructive/cancelled/sold-out — never decorative
