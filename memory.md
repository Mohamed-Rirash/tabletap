# Memory — TableTap: Landing Page, Pricing Model, Feature 03 (Tenancy Core) + 4 Review Rounds + E2E Verification

Last updated: 2026-07-08

## What was built

**Marketing landing page redesign** (`lib/tabletap_web/controllers/page_html/home.html.heex`, `assets/css/app.css`):
- Full dark/bold/gradient redesign replacing the earlier cream/terracotta version, scoped under a `.mk` CSS class in `app.css` so it never touches product surfaces or daisyUI's `data-theme` tokens.
- "How it works" section as 4 mini phone-frame mockups showing the guest journey: scan→menu-opens, browse&customize, pay/wallet-PIN-wait, track&call-waiter.
- Pricing section as 3 cards (Essentials/Growth/Pro), Growth visually highlighted as "Most popular".
- Sitewide utility bar in `root.html.heex` suppressed on `/` via `@hide_utility_bar`.

**Pricing model** (`context/pricing.md`, single source of truth): 3 feature-tiered plans — **Essentials** $40/mo + 2.5% fee (1 venue, order loop only), **Growth** $75/mo + 1.5% fee (1 venue, + inventory + Report Center), **Pro** $55/venue/mo + 1.0% fee (2–10 venues, + cross-venue comparison). Monthly billing only. Trial unlocks every tier for 14 days. Wired into all relevant `context/*.md` files (design-qa.md Q62→Q63 supersedes it).

**Feature 03 — Tenancy Core** (closes Phase 1), then **4 rounds of `/review` + fix**:
- Migrations: `orgs`, `venues`, `memberships`, `staff_invites` (composite `(id, org_id)` FK pattern) + a later migration adding a partial unique index `memberships_org_user_owner_index` on `(org_id, user_id) WHERE venue_id IS NULL`.
- `lib/tabletap/repo.ex`: tenant-enforcing `Tabletap.Repo` (`put_org_id/1`, `prepare_query/3` raise).
- `lib/tabletap/tenants.ex` + `lib/tabletap/tenants/{org,venue,membership,staff_invite,slug}.ex`: the `Tabletap.Tenants` context. Final function shapes after review rounds: `create_org_with_owner/1` (returns `{:error, changeset}` with a `:city` error for an unrecognized city — never silently defaults), `build_scope/2`, `list_venues/1` and `switch_venue/2` and `create_staff_invite/3` each have a second clause handling `%Scope{org: nil}` gracefully instead of crashing, `accept_staff_invite/3` (note: **3-arg, not 2** — takes a required `magic_link_url_fun`).
- `lib/tabletap/accounts.ex` + `user.ex`: `register_owner/1` (password-required path, Q47), every query has `skip_org_id: true`.
- `lib/tabletap_web/user_auth.ex`: scope resolution via `Tenants.build_scope/2`; `signed_in_path/1` matches generically on `%{assigns: ...}` (works for both `%Plug.Conn{}` and `%Phoenix.LiveView.Socket{}`) and sees the post-login scope.
- `lib/tabletap_web/live/user_live/registration.ex`: `/users/register` is the org-signup flow. Field IDs follow `to_form(changeset, as: "user")` convention: `#user_business_name`, `#user_city`, `#user_email`, `#user_password`, `#user_password_confirmation`; form id is `#registration_form`, submit button has no explicit `type="submit"` attribute (relies on HTML default).
- `lib/tabletap_web/live/manager/dashboard_live.ex` + `lib/tabletap_web/controllers/venue_controller.ex`: `/dashboard` + venue switcher (`VenueController.switch/2` has a fallback clause for a missing `venue_id` param).
- `lib/tabletap/oban_repo.ex`: second, non-tenant-enforcing Repo for Oban's own tables.
- `lib/tabletap_web/components/layouts.ex`: `app/1`'s header rebuilt — removed the stock Phoenix-generator chrome, replaced with a minimal TableTap brand mark (`bg-primary`/`text-primary-content`) + theme toggle.
- Gettext: every new user-facing string wrapped in `gettext()`/`ngettext()`; ran `mix gettext.extract` + `mix gettext.merge priv/gettext` so `priv/gettext/en/LC_MESSAGES/default.po` actually has the 29 msgids.
- Test fixtures: `test/support/fixtures/tenants_fixtures.ex` (`org_fixture/1`, `venue_fixture/2`, `two_orgs/0`), `ConnCase.register_and_log_in_owner/1`.

**End-to-end browser verification of Feature 03** (this session, no code changes — verification only): booted the real dev server (`mix phx.server`) and drove it with Playwright (installed via `npm install playwright` in the scratchpad dir; Chromium binary already cached at `~/.cache/ms-playwright`, so no download needed — **this environment has no `chromium-cli` but DOES support installing the `playwright` npm package and running scripts with `node`, contradicting the earlier session's note that no browser automation was available**). Verified: signup at `/users/register` (business name, city select, email, password) → lands on `/dashboard` showing "OWNER · CADAANI COFFEE", venue name, "13 days left in trial", empty-state copy → log out via utility bar → re-login at `/users/log-in` with the same credentials via the password form (`#login_form_password`, distinct from the magic-link form which shares the `email` field name) → lands back on the same venue's dashboard with an intact session. All checks passed. Screenshots taken at each step (business names/emails were test-only, not real data).

## Decisions made

- **Landing page is dark/bold/gradient**, not cream/terracotta — founder rejected the old design. Real page is `home.html.heex`; `landing/index.html` is a dead static prototype.
- **Pricing is feature-tiered (3 tiers)** — founder iterates fast on pricing *shape*. Expect structural changes again, not just new digits, if asked to revisit.
- **Second Ecto Repo for Oban** (`Tabletap.ObanRepo`) rather than special-casing table names in `prepare_query`.
- **`accept_staff_invite/2` → `/3`, breaking change to a required `magic_link_url_fun` param** — deliberate, matches `Accounts.deliver_login_instructions/2`'s own signature. Nothing outside tests calls it yet.
- **`accept_staff_invite` now finds-or-registers by email** instead of always registering fresh — required to support "same person, manager at one venue and waiter at another" (project-overview.md).

## Problems solved (bugs found across 4 review rounds — all fixed except 2, see Open Questions)

Round 1 (7 issues): `resolve_city/1` silently defaulted to Hargeisa/USD instead of erroring (**Critical** — currency is immutable after first order, Q53); no Gettext on new strings; Postgres allows duplicate NULL `venue_id` in a unique index (fixed with a partial unique index); `staff_invites` context functions shipped with zero tests; missing shared `two_orgs` fixture; `switch_venue/2` didn't check `archived_at`; `VenueController.switch/2` had no fallback clause.

Round 2 (3 issues): `create_staff_invite/3` merged atom keys into string-keyed params (Ecto rejects mixed keys) — fixed by normalizing to string keys first; `accept_staff_invite/2` broke the documented multi-venue-per-person scenario; `accept_staff_invite/2` never sent a magic link for waiter/cashier/kitchen roles.

Round 3 (3 issues): the dashboard's "Live" badge misused ui-rules.md's specifically-defined meaning — removed; `Layouts.app` showed Phoenix-framework chrome on the actual product's front door — rebuilt; `mix gettext.extract` had never been run.

Round 4 (2 issues found, **still not fixed** — see Open Questions below; this session's Playwright run visually reconfirmed both are still live in the running app).

**Infra lessons (apply to any future infra-level work):**
- `Repo.insert`/`update` don't go through `prepare_query` (only `all`/`one`/`get`/`update_all`/`delete_all` do) — insert-side tenant correctness rests on composite FK constraints, not the Repo guard.
- Oban's background queries have no per-request `org_id` and will crash a tenant-enforced app in a boot loop — invisible to tests because `Oban testing: :manual` means Oban's machinery never runs under test. **Always boot the real dev server after any Repo/Oban/supervision-tree change, not just `mix test`.**
- `Phoenix.LiveViewTest.submit_form/2` doesn't fire `phx-submit` — only does the native `phx-trigger-action` POST. For a form whose target resource doesn't exist until the LiveView event creates it, use `render_submit(form)` then `follow_trigger_action(form, conn)` instead.
- **Correction to a prior session's lesson**: `chromium-cli` is NOT available in this environment, but full Playwright IS usable — `npm install playwright` in a scratch dir picks up the already-cached Chromium binary at `~/.cache/ms-playwright` with no download needed, so real browser-driven screenshot verification is possible. Don't assume it's unavailable; check `~/.cache/ms-playwright` and try `npm install playwright` before falling back to curl/context-call-only verification.
- Phoenix's `<.button>` component (`core_components.ex`) does not render an explicit `type="submit"` attribute — it relies on the HTML default. A Playwright/CSS selector like `button[type="submit"]` will NOT match it; select by container + tag (`#form_id button`) instead.
- The flash toast (`core_components.ex` `flash/1`) is `class="toast toast-top toast-end z-50"` and can visually overlap/intercept clicks on the utility bar's top-right links (Log out, Settings) shortly after a redirect (e.g. right after login/registration). The whole flash div has `phx-click` wired to dismiss itself — click anywhere on `[role="alert"]` to clear it before interacting with anything underneath.

## Current state

- **Phase 1 (Foundation) is CLOSED** — Features 01, 02, 03 all done.
- 169/169 tests passing, `mix credo --strict` clean, `mix format --check-formatted` clean, `mix compile --force --warnings-as-errors` clean (as of round 3/4; no code changed this session).
- 4 rounds of `/review` completed. Rounds 1–3's findings (13 issues total) are all fixed and verified. **Round 4's 2 findings are still open** — this session re-confirmed both are live via real browser screenshots (see below), but did not fix them (the user's most recent message asked whether to fix them now, no answer given yet before this save).
- Dev server stopped at end of session.

## Next session starts with

**The user was last asked (end of this session) whether to fix round 4's 2 open findings now — answer this first:**
1. **[Important]** `/dashboard` and `/users/register` render two stacked header bars — the root layout's utility bar (email/Settings/Log out) plus `Layouts.app`'s own TableTap brand header. **Visually reconfirmed this session** via Playwright screenshots (`2-register-filled.png`, `3-dashboard.png`, `6-relogin-dashboard.png` in the session's scratchpad — not persisted anywhere durable, would need to be retaken if wanted again). Fix: either extend `@hide_utility_bar` to `/dashboard`/`/users/register`, or fold account actions into `Layouts.app`'s header directly.
2. **[Important]** `Venue.registration_changeset`'s `currency`/`timezone` fields have no validation at the schema or DB level — only `Tenants.create_org_with_owner/1`'s single call to `resolve_city/1` protects against an arbitrary currency string. Fix: add `validate_inclusion(:currency, ["USD", "ETB"])` to the changeset itself.

Once those are resolved (or explicitly deferred), **Phase 2, Feature 04 — Menu Builder** (`context/build-plan.md`): `menu_categories`/`menu_items` CRUD LiveViews (manager role), photo upload to S3, drag-to-reorder, archive-not-delete once referenced, availability toggle + `daily_item_limits`, dietary/allergen tag multi-select.

## Open questions

- The 2 round-4 findings above — fix now or defer to a fast-follow? (Asked again at end of this session, unanswered as of save.)
- Staff invite creation/acceptance UI (schema + context exist, LiveViews don't) — not blocking Phase 2, but needed before "Staff management" is genuinely complete. `accept_staff_invite/3`'s required `magic_link_url_fun` param needs a real caller once that UI is built.
