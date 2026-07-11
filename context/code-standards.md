# Code Standards

Implementation rules for TableTap. Follow these in every session without exception. They exist to protect the two things that make or break this product: **tenant isolation** (a data leak between restaurants kills the business) and **order-loop integrity** (a lost order or an oversold item kills a venue's trust).

---

## Engineering Mindset

- **The order loop is sacred.** Scan → order → pay → assign → serve → deduct. Any change touching this path needs its tests run and a manual phone walk-through before moving on.
- **Tenancy by construction, not by discipline.** Never rely on "remembering" to filter by org. The Scope struct + `prepare_query` raise makes forgetting impossible — keep it that way.
- **Contexts own their tables.** Web modules (LiveViews, controllers) never call `Repo`. Cross-context access goes through public functions only.
- **Money is never a float.** `Money.new/2` in, `Money` out, `money_with_currency` in the DB. Arithmetic via `Money.add/2`, `Money.mult/2`.
- **Snapshots over joins for history.** Orders copy names and prices at purchase time. Reports on the past must never change because a manager edited the menu.
- **Archive, never delete, anything with history.** Menu items, categories, ingredients, tables: hard delete only with zero references; otherwise `archived_at` (design-qa.md Q41). A closed business day is equally immutable — late events land as flagged post-close adjustments on their own business day, never as silent edits to a closed report (Q37/Q38).
- **One feature at a time.** Finish and verify per build-plan.md before starting the next. Real-time bugs compound when stacked unverified.
- **Real phones, real networks.** Customer and waiter surfaces are verified on actual devices — LiveView reconnect behavior and camera QR scanning don't reproduce in a desktop browser.

---

## Elixir / Phoenix Conventions

- `mix format` clean, `credo --strict` clean — CI enforces both
- Module naming: `Tabletap.Catalog.MenuItem` (context.schema), `TabletapWeb.Customer.MenuLive` (surface.live view)
- Context public functions take `%Scope{}` first: `Catalog.list_items(scope, opts \\ [])`. No context function accepts a bare `org_id` integer — the scope is the unit of authorization
- Changesets: one function per use case (`creation_changeset`, `update_changeset`) — no giant catch-all `changeset/2` with conditionals
- Pattern-match errors at the boundary: LiveViews handle `{:ok, _}/{:error, changeset}` — contexts don't raise for expected failures; they raise only for bugs (e.g., illegal state transitions)
- No `Repo.get!` on user-supplied ids in web paths — use `get_*` returning nil → 404, so guessing ids across tenants can't leak "exists but forbidden"
- Background work goes through Oban jobs, not `Task.start` — jobs must be idempotent and safe to retry
- All datetimes UTC in the DB; venue-local display uses `venue.timezone` at the presentation layer only. "Today" for daily limits/rollups/order numbers/Z-reports = the venue's **business day** (`business_day_cutoff`, default 04:00, cutoff-to-cutoff in venue time — design-qa.md Q20/Q39); one shared `Tenants.business_date(venue, datetime)` function, never ad-hoc date math
- **i18n from day one:** every user-facing string goes through Gettext (`gettext("Add to cart")`) — a hardcoded English string in a template fails review. Customer-surface language follows `venue.locale`; staff surfaces follow the user's locale
- **RTL-ready CSS:** use logical Tailwind utilities (`ps-*`/`pe-*`, `ms-*`/`me-*`, `text-start`/`text-end`) instead of left/right variants; layouts must survive `dir="rtl"` without changes

---

## LiveView Patterns

- Use **streams** for any list that grows (orders, KDS tickets, movements) — never hold unbounded lists in assigns
- `handle_info` for PubSub events updates only the affected stream item — no full re-fetch on every event
- Subscribe in `mount` only when `connected?(socket)`
- Role enforcement in `on_mount` hooks (`{TabletapWeb.ScopeHooks, :require_waiter}`), never inside individual `handle_event`s
- JS interop (QR camera scan, wallet checkout status, print) via hooks in `assets/js/hooks/` — one file per hook, named `PascalCase`
- Forms: `to_form/2` + `<.form>`; validations live in changesets, not in the LiveView
- Optimistic UI is allowed for cosmetic state only (button spinners) — order status shown always reflects a committed DB transition

---

## Tenancy Rules (zero tolerance)

- Every tenant-owned schema has `org_id` (+ `venue_id` where applicable) and composite FKs `(parent_id, org_id)`
- `skip_org_id: true` may appear **only** in: `Accounts`, `Tenants` (org/venue resolution), platform-admin context, and migrations/seeds. Any other occurrence fails code review — grep for it in the Phase-7 audit
- Public customer routes resolve tenancy from the table `qr_token` / venue slug — then everything downstream is scoped exactly like an authenticated request
- Tests: every new context gets at least one "second tenant cannot see/touch this" test. Use the `two_orgs` fixture

---

## Ordering & Payments Rules

- Status changes only via `Ordering.OrderStateMachine.transition(scope, order, event)` — direct `status` updates are forbidden, including in tests (use the machine or fixtures that use it)
- Daily-limit reservation and order insert share one transaction (`Ecto.Multi`); the limit check is a DB-level `UPDATE ... WHERE sold_qty < limit_qty` — never a read-then-write
- Provider callbacks are HMAC-verified and idempotent: unique index on `provider_txn_id`, insert-first then process
- **Callbacks are an optimization, never the mechanism:** wallet providers don't retry callbacks — every `pending` payment has a reconciliation poller (transaction-inquiry API) as the guaranteed path (design-qa.md Q58)
- **Confirmations reconcile, never trust:** a state-bearing callback triggers a fetch of the current transaction from the provider API and reconciles to that, never to the callback body's snapshot (design-qa.md Q51)
- Never mark a wallet payment `succeeded` from client-side state — the provider (callback or poll) is the source of truth (the client only shows an optimistic "waiting for your PIN…" state)
- Refunds, cancellations, and manual order edits always record who did it (`staff_user_id` / membership)
- Amount serialization is the provider adapter's job, always from `Money` structs (WaafiPay takes decimal strings; a future Stripe adapter takes minor units via `Money.to_integer_exp/1`) — business code never formats amounts, and nothing is ever hand-multiplied by 100
- Venue merchant credentials are encrypted at rest (`cloak_ecto`), never logged, never serialized into errors or telemetry
- Order totals follow one fixed formula — `total = subtotal − discount_total` — implemented in exactly one module (`Ordering.Totals`); no surface recomputes totals locally, and the client never sends an amount. No tax, tip, or service-charge fields exist — menu prices are final (founder decision; don't reintroduce without one)
- Discounts always record who applied them and why (`order_discounts` row) — an unattributed discount is a bug
- **Discounts exist only pre-payment** (design-qa.md Q36): `order_discounts` is immutable once the order leaves `pending_payment`; post-payment goodwill is a refund, full stop
- A zero-total order settles as `provider: comp` (manager-gated, reason required) — the kitchen-only-after-settlement rule covers Stripe, cash, and comp (design-qa.md Q30)
- Refund creation locks the payment row and validates against `paid − existing refunds` in one transaction; a line item refunds once (design-qa.md Q35). Refunds belong to the refund's business day (Q37)
- `venue.currency` is immutable after the venue's first order (design-qa.md Q53) — aggregates assume one currency per venue's history
- **Scheduled deliveries re-authorize at send time:** any emailed report/digest resolves "still an active member with a role allowed to see this" when it sends, not when it was scheduled; membership deactivation purges report subscriptions and push tokens (design-qa.md Q52)

---

## Testing

- `mix test` must pass before any feature is called done; async tests by default (Ecto sandbox)
- Every context function: happy path + authorization (wrong tenant / wrong role) + validation failure
- State machine: full transition table test — every legal transition succeeds, every illegal one raises
- Race-sensitive paths (daily limits, waiter assignment, webhook idempotency) get dedicated concurrency tests (`Task.async_stream` hammering the function)
- LiveView tests with `Phoenix.LiveViewTest` for each surface's core flow; provider calls mocked via the `Payments.Provider` behaviour + Mox (`ProviderMock`)
- No test hits the real WaafiPay API; callback tests feed recorded fixture payloads; a dedicated race test has callback and poller confirm the same payment concurrently — exactly one transition wins

---

## Telemetry Events

All events use exactly these names, emitted from context functions. Never invent new event names without adding them here.

| Event | When | Metadata |
|---|---|---|
| `[:tabletap, :order, :placed]` | Payment confirmed, order enters queue | org_id, venue_id, order_id, total, kind |
| `[:tabletap, :order, :transition]` | Every state machine transition | order_id, from, to, actor_role |
| `[:tabletap, :order, :assigned]` | Waiter auto-assignment | order_id, membership_id, open_load, assignment_ms |
| `[:tabletap, :order, :escalated]` | 90s unaccepted → claim board | order_id, venue_id |
| `[:tabletap, :order, :served]` | Delivery QR confirmed | order_id, accept_to_served_ms |
| `[:tabletap, :payment, :succeeded]` | Webhook processed | payment_id, amount, application_fee, provider |
| `[:tabletap, :payment, :refunded]` | Refund issued | payment_id, amount, reason |
| `[:tabletap, :inventory, :deducted]` | Stock deduction for an order | order_id, movement_count |
| `[:tabletap, :inventory, :low_stock]` | Threshold crossed | ingredient_id, stock_qty, threshold |
| `[:tabletap, :limit, :sold_out]` | Daily limit exhausted | item_id, venue_id, at_time |
| `[:tabletap, :waiter, :called]` | Customer call-waiter tap | table_id, order_id, membership_id |
| `[:tabletap, :tenant, :signup]` | New org created | org_id, plan |

---

## Environment / Configuration

| Value | Where |
|---|---|
| `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST` | runtime.exs from env |
| `WAAFIPAY_API_URL`, `WAAFIPAY_PLATFORM_MERCHANT_*` (our own merchant account, used for subscription collection) | env |
| `CLOAK_KEY` | env — encrypts per-venue merchant credentials at rest |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | env (web push) |
| `S3_*` bucket credentials | env |
| Plan definitions (fee %, venue caps) | `config/plans.exs` compiled config — changing a fee is a deploy, deliberately |

Rules:
- No secrets in code or in `config/*.exs` committed values — `runtime.exs` env reads only
- WaafiPay sandbox credentials in dev/staging; production merchant credentials only in the production environment group

---

## Dependencies

Never add a dependency without checking: does Phoenix/Elixir/OTP already do this, and is the package maintained (commit within the last year)?

**Approved:**

- `phoenix`, `phoenix_live_view`, `ecto_sql`, `postgrex` — core
- `oban` — background jobs
- `cloak_ecto` — encrypted merchant-credential fields (the WaafiPay client itself is hand-rolled on `req` — no hex SDK exists; pattern in library-docs.md)
- `ex_money`, `ex_money_sql` — money type
- `qr_code` — QR generation (SVG/PNG)
- `web_push_ex` — Web Push (VAPID)
- `swoosh` + adapter — email
- `req` — HTTP client
- `ex_aws`, `ex_aws_s3` — object storage
- `credo`, `mox` — dev/test
- JS (vendored in assets): `qr-scanner` (camera scanning) — no payment JS needed: wallet approval happens on the customer's phone, the page just live-updates payment state

Do not install any other package without updating this list first and documenting the reason.

---

## Mobile Apps (Phase 8 — React Native + Expo, TypeScript)

- Monorepo layout: `apps/customer`, `apps/staff`, `packages/shared` (typed API client, Channels wrapper, design tokens mirrored from ui-tokens.md — one source, generated, never hand-copied)
- TypeScript `strict: true`; ESLint + Prettier in CI alongside the Elixir checks
- **Zero business logic in the apps.** Totals, availability, assignment, permissions — all server-side. The apps render server state and send intents; an app must never compute a price
- Real-time via the official `phoenix` npm client only — same topics as LiveView; every screen must fully rebuild from a REST fetch on reconnect (channels are an optimization here exactly as PubSub is on web)
- Payments: the app submits the wallet number and renders live payment state from the server — no payment SDK, no card forms, and the app never talks to the payment provider directly
- Push tokens registered/pruned through the same `Notifications` context as web push; push is never the only channel
- API changes are contract-tested (schema snapshots) — the apps and web ship against the same `/api/v1` version; breaking changes require a new version, no exceptions

**Approved mobile packages:** `expo`, `expo-camera`, `expo-notifications`, `phoenix`, `expo-router`, `zustand` (screen-local state only). Same rule as Elixir deps: nothing else without updating this list.
