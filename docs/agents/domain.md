# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

**This repo is single-context:** one `CONTEXT.md` + `docs/adr/` at the root. TableTap is one Phoenix app with one shared domain language (the Phase-8 React Native apps speak the same language).

**Repo-specific:** the `context/` directory is the full product/architecture blueprint and the source of truth (see `CLAUDE.md`). `CONTEXT.md` is the distilled glossary; when they disagree, `context/architecture.md` and `context/design-qa.md` win — and the glossary should be fixed. Pre-code design decisions live in `context/design-qa.md` (Q1–Q56); `docs/adr/` takes decisions made **during implementation**.

## Before exploring, read these

- **`CONTEXT.md`** at the repo root
- **`docs/adr/`** — read ADRs that touch the area you're about to work in
- For ordering/payment/assignment behavior, also read **`context/design-qa.md`** — those decisions override anything contradictory elsewhere

If any of these files don't exist, **proceed silently**. Don't flag their absence; don't suggest creating them upfront. The `/domain-modeling` skill creates them lazily when terms or decisions actually get resolved.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

If the concept you need isn't in the glossary yet, that's a signal — either you're inventing language the project doesn't use (reconsider) or there's a real gap (note it for `/domain-modeling`).

## Flag ADR conflicts

If your output contradicts an existing ADR or a design-qa.md decision, surface it explicitly rather than silently overriding:

> _Contradicts design-qa.md Q1 (holds at checkout) — but worth reopening because…_
