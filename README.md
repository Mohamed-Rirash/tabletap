# TableTap

Multi-tenant SaaS QR-ordering platform for cafés and restaurants. Any venue can subscribe, connect their own payment account, build a menu down to the ingredient level, print QR codes for their tables, and run their entire floor — ordering, kitchen, waiters, inventory, and analytics — from one system.

Customers scan the QR code on their table, browse the venue's live menu, customize items, pay from their phone, watch a live order status, and call their assigned waiter with one tap. Payments go directly to the venue's own payment account; the platform takes a small per-order application fee plus a monthly subscription.

## Stack

- **Backend / web:** Elixir, Phoenix 1.8, LiveView
- **Database:** PostgreSQL 16 (via `Ecto`), `Oban` for background jobs
- **Money:** `ex_money` — every amount is a typed `Money.t()`, never a float or bare integer
- **Mobile (Phase 8):** React Native + Expo, on the same `/api/v1` + Phoenix Channels the web app uses

See `mix.exs` for the full dependency list.

## Getting started

**Prerequisites:** Erlang and Elixir versions are pinned in [`.tool-versions`](.tool-versions) (use [asdf](https://asdf-vm.com/) or [mise](https://mise.jdx.dev/) to install them automatically). Docker is used to run Postgres locally.

```bash
# 1. Start Postgres (+ Adminer at localhost:8080) in the background
docker compose up -d

# 2. Install deps, create/migrate the database, install & build assets
mix setup

# 3. Start the Phoenix server
mix phx.server
# or, with an interactive shell:
iex -S mix phx.server
```

The app is now running at [`localhost:4000`](http://localhost:4000).

Before committing, run:

```bash
mix precommit
```

This compiles with warnings-as-errors, checks for unused deps, formats, and runs the test suite.

## Project status

**Phase 1 — Foundation is closed.** Tenancy core (orgs, venues, memberships, staff invites), authentication, and the base project scaffold are all in place. Phase 2 (menu builder, modifier groups, tables & QR codes) is next.

See [`context/progress-tracker.md`](context/progress-tracker.md) for the live status of every feature, and [`context/build-plan.md`](context/build-plan.md) for what's planned across all phases.

## Documentation

The `context/` directory is the blueprint and the contract for this project — it drives every implementation decision:

| File | Purpose |
|---|---|
| [`context/project-overview.md`](context/project-overview.md) | Product pitch, surfaces, user roles, core order flow |
| [`context/architecture.md`](context/architecture.md) | System architecture, multi-tenancy model |
| [`context/design-qa.md`](context/design-qa.md) | Pre-code design decisions (Q&A form) |
| [`context/code-standards.md`](context/code-standards.md) | Coding conventions enforced across the codebase |
| [`context/pricing.md`](context/pricing.md) | Subscription tiers and fee structure |
| [`context/role-features.md`](context/role-features.md) | Feature breakdown per user role |
| [`context/ui-rules.md`](context/ui-rules.md) / [`ui-tokens.md`](context/ui-tokens.md) | UI conventions and design tokens |

[`CONTEXT.md`](CONTEXT.md) is a distilled domain glossary — the fast way to pick up TableTap's vocabulary (org, venue, membership, scope, business day, settlement, etc.) without reading the full blueprint.

Architectural decisions made during implementation (as opposed to pre-code design) are logged in [`docs/adr/`](docs/adr/).

## Testing

```bash
mix test
```

Tests run against a dedicated database (created/migrated automatically by the `test` alias). LiveView interaction tests live alongside their modules under `test/`.
