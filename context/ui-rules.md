# UI Rules

Rules for building TableTap's screens. Read this before building any screen or component. Five surfaces, five very different contexts of use — a hungry customer, a walking waiter, a loud kitchen, a queue at the counter, and an owner reading numbers.

---

## Platform

Everything is Phoenix LiveView + Tailwind (tokens from ui-tokens.md) + daisyUI primitives. Shared function components live in `TabletapWeb.Components.*` and are catalogued in ui-registry.md.

- Mobile-first: customer and waiter surfaces are designed at 390px width and must be perfect there; desktop is the adaptation
- KDS designed at tablet landscape (1024×768+); POS at tablet/desktop; back office responsive desktop-first
- Every interactive element works with touch only — no hover-dependent affordances anywhere
- LiveView reconnects: every surface shows the topbar "reconnecting…" indicator (built into the layout) — never a frozen screen with no signal
- RTL-ready: all layouts use logical properties (`ps-*`/`pe-*`, `text-start`) and must render correctly under `dir="rtl"` — the customer surface follows the venue's locale, which may be an RTL language

---

## Surface: Customer (QR PWA)

The customer is hungry, possibly in a hurry, on an unknown phone, maybe on bad Wi-Fi. **Time to first order beats everything.**

- No login wall, ever. Signup is offered exactly twice: after payment ("save your history") and on the tracker — both dismissible
- The menu is one scrollable page with sticky category tabs — never a multi-page category drill-down
- Every price change from a modifier updates the visible total instantly (client-side via the sheet's LiveView state)
- Cart is always reachable via the sticky cart bar; never more than one tap away
- Checkout = one screen: cart review, dine-in/takeaway toggle, table number confirmation, Payment Element. No shipping-style multi-step wizard
- The tracker page is the post-order home: status timeline, ETA, call-waiter button, receipt. The URL (`/orders/:guest_token`) survives refresh and phone lock
- Call-waiter button: single tap → confirmation haptic/toast "Aisha is coming" (assigned waiter's first name) → button disabled until resolved
- Show the venue's name/logo prominently — the customer must trust they're paying the right restaurant

## Surface: Waiter (mobile PWA)

Used while standing and walking, one thumb, dozens of times per hour.

- Queue screen is the home. Sorted FIFO, "NEXT UP" pinned at top. No configuration, no filters at MVP
- One primary action per card, full-width, 56px: `Accept` → `Picked up` → `Scan to serve`. The current action is always the same place on screen
- Scan-to-serve opens the camera full-screen with the target table number displayed large ("Scanning for Table 7") — wrong QR shows an unmistakable full-screen error, right QR a full-screen success flash
- New assignment: push notification + in-app banner + sound (if enabled). The card animates in at its FIFO position, not always on top
- Claim board is a second tab with a count badge — claiming is a single tap with optimistic lock (first tap wins, loser sees "already claimed")
- Shift toggle is prominent in the profile tab; going off-shift with open orders requires confirming a handoff to the claim board

## Surface: Kitchen Display (KDS)

Read from a meter away, hands are dirty, taps are coarse.

- Dark theme only. Tickets in status columns: **New | Preparing | Ready** — advancing a ticket moves it right
- Ticket text ≥ 16px; modifiers always visible (never truncated behind a tap — "no onions" hidden = wrong dish cooked)
- Elapsed timer on every ticket; overdue tickets pulse amber — the cook should spot the late ticket without reading
- The whole ticket footer is the advance button — a 56px strip, not a small icon
- No scrolling within a ticket; if an order is huge the ticket grows and the column scrolls
- Sound cue on new ticket (toggleable per device)

## Surface: Cashier POS

Speed of entry is the metric. A regular's coffee order should be rung up in seconds.

- Item grid: photo tiles ≥ 96px, category rail on the left, search box with keyboard focus hotkey
- Tapping an item with required modifiers opens the modifier sheet; items without go straight to the ticket
- Running ticket always visible on the right (or bottom sheet on narrow screens) with line-item void
- Payment: two big buttons — `Cash` (records + shows change calculator) and `Pay by QR` (customer scans a payment link)
- Shift summary reachable in two taps; cash total displayed prominently for drawer reconciliation

## Surface: Back Office (Manager/Owner)

- Left nav: Dashboard, Orders, Menu, Inventory, Tables & QR, Staff, Reports, Settings
- Every list (orders, items, ingredients, movements) gets: search, date-range where temporal, empty state, and CSV export where numbers matter
- Menu builder edits publish live — a visible "Live" pill reminds the manager that customers see changes immediately; destructive actions (delete item/category) require typed confirmation
- Dashboards: today is live (ticking), history from rollups. Every chart follows the dataviz skill guidance and gets a one-line "so what" caption
- Onboarding checklist panel stays pinned on the dashboard until all five steps are complete

---

## Forms & Validation

- Inline validation on blur; submit-time errors scroll to the first offender
- Money inputs: currency-prefixed, locale-formatted, parsed to `Money` — never a bare number field labeled "price ($)"
- Quantity/unit inputs accept human units ("1.5 kg") with a live conversion hint ("= 1500 g")
- Destructive buttons are never adjacent to primary ones and never the default focus

## Loading, Empty, Error States

- Every async region: skeleton (pulsing surface-sunken blocks matching final layout) — never spinner-only, never layout shift
- Empty states teach: empty menu → "Add your first item" CTA; empty waiter queue → "You're on shift — orders will appear here"; empty dashboard → seeded example card explaining what will show
- Errors are human and actionable: "Couldn't process the payment — you haven't been charged. Try again." Never raw provider/Ecto errors
- Payment confirmation limbo (waiting on the customer's wallet PIN, or a reconciliation poll still pending): show "Waiting for you to approve on your phone…" with the animated timeline dot — never a blank success or a scary error while waiting

## Notifications & Sound

- In-app real-time (PubSub) is the primary channel; web push is the wake-up channel — everything pushed is also visible in-app
- Sounds only on staff surfaces, each toggleable per device (waiter new-order, KDS new-ticket, call-waiter ping)
- Notification copy always contains the actionable fact: "New order #48 — Table 7" not "You have a new notification"

---

## Do Nots

- Never block the customer menu behind login, cookies walls, or an app-install interstitial — the QR must open straight into food
- Never let a tenant brand color restyle order-status colors or staff surfaces
- Never truncate modifier text on KDS or waiter cards
- Never show stale order status: if the LiveView is disconnected, show the reconnecting bar — don't let a "Preparing" badge silently freeze
- Never put two primary actions on one staff card — one card, one next step
- Never use `window.confirm` — styled confirmation modals only
- Never render prices by string concatenation — always `Money.to_string!/2` with the venue's locale
- Never auto-refresh/redirect the tracker page — the customer may be reading the receipt; state updates in place
- Never make a staff touch target smaller than 56px on mobile surfaces
- Never ship a chart without axis labels and a caption a non-analyst owner understands
