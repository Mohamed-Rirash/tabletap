# TableTap

Multi-tenant SaaS QR-ordering platform for cafés/restaurants (Phoenix LiveView + React Native in Phase 8). **The `context/` directory is the blueprint and the contract** — read `context/progress-tracker.md` for current status and `context/design-qa.md` (Q1–Q56) before changing ordering/payment/assignment behavior. `CONTEXT.md` is the distilled domain glossary.

## Agent skills

### Issue tracker

Issues and PRDs live as **local markdown** under `.scratch/<feature-slug>/` (no git remote exists). See `docs/agents/issue-tracker.md` for file layout, `Status:` lines, and wayfinder conventions.

### Triage labels

The five canonical triage roles map 1:1 to their default strings (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context repo: `CONTEXT.md` glossary + `docs/adr/` at the root; `context/` remains the source of truth. See `docs/agents/domain.md` for reading order and conflict-flagging rules.
