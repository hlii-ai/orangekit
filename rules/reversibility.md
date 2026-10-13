---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "ios/**"
  - "android/**"
  - "supabase/**"
  - "**/migrations/**"
  - "dev/active/**"
---
<!-- orangekit-rule-version: 3.32.0 -->

# The Work Axis — reversibility

Do not classify by size (S/M/L). Size demands human judgement, so it drifts, and
**it watches the wrong variable** — a 5-line migration is more dangerous than a 400-line refactor.

## Class Decision (path-based, no model judgement required)

**The canonical source for the deciding paths is the "Reversibility classification" table in the T0 operating rules injected each session.**
Do not copy it here — a copy is a source of drift. This card covers what comes *after* the decision.

| Class | Requirement — who does it |
| --- | --- |
| **Irreversible** | `orangekit-reviewer` multi-lens fan-out (correctness·security·reversibility) + user confirmation + a rollback procedure |
| **Costly** | `orangekit-reviewer` is mandatory — **self-review is not a substitute**. Present the impact scope (call sites) |
| **Reversible** | Proceed directly. Closing documentation is `/completion-review` |

This table's `supabase/` schema·RLS and deletion/transformation of production data fall under T0's "auth/RLS ·
production data" — T0 simply words it more broadly; they are the same thing.

**If two or more apply, follow the higher one.** When it is ambiguous, treat it as Costly.

**Access policy decision point** — the patterns below look like code changes but are in essence **UX/access policy decisions**.
Judge them on the auth axis (Irreversible), present the real difference between the options, and let the user choose:

- Adding/moving/removing a route guard (`redirect` → login, the `(protected)` group, a layout guard)
- Creating a new route group (the `(protected)` / `(public)` / `(auth)` directories)
- Changing the auth gate (the guard branch in `middleware.*`)
- Changing the exposure policy for unauthenticated/anonymous users

> Real incident: a guard move was filed as "code refactoring", so an access policy change
> went through with no user confirmation. It is a blind spot hidden behind the planning/technical abstraction.

## The Four Entry Conditions

These are **states**, not Phases. They have no order, and you fill only the unmet ones.
**The canonical source is T0's "Work entry"** — the table below is a quotation with a how-to-check column added; where the wording diverges, T0 is right.

| State | How to check | If unmet |
| --- | --- | --- |
| Intent clear | Can you say in one sentence what you are building and why | Confirm with the user |
| Context current | Do the documents/code you are relying on reflect HEAD | Check with `git log` |
| Impact radius known | Which files·domains·schemas change | Find the call sites with grep |
| Verification path exists | How will you know it worked (build/test/manual check) | Define the verification method first |

> **All four met means zero preparation. Implement straight away.**
> Do not create documents for items already met — do not write a PRD·plan just to record what you already know.

## Stages (unnumbered, each callable on its own)

| Stage | When | Output |
| --- | --- | --- |
| `understand` | When the impact radius is unclear | Exploration results (file list·call relationships) |
| `plan` | When two or more entry conditions are unmet | A plan — written to a file only when it spans sessions |
| `build` | Always | Code |
| `verify` | Costly or higher | Review results |
| `cross-check` | **Irreversible only** | Independent multi-lens verification results |

Do not number them. Numbers create obligations, and obligations create paperwork.

## Workspace

Create `dev/active/<slug>/` **only when the work spans sessions**.
Do not create a workspace for work that finishes within one session.
Prove closure by **moving** it to `dev/archive/<slug>/` — by a directory move, not by a status label.

## Decision Records — `docs/decisions.md`

When T0's "Decision point" fires and what the user chose is **Costly or higher**, record that choice.
Where `lessons.md` holds *mistakes*, this holds *choices* — they are different things, and mixing them
makes both unusable. **Do not record trivial decisions.**

```markdown
## [decision: <slug>] <one-line title>

- Date: YYYY-MM-DD
- Situation: what had to be decided
- Options: A / B (/ C) — **what each one gives up**
- Choice: <what was picked> — user decision | automatic determination
- Rationale: why that one
- Reversal: <the cost of undoing this decision. If it cannot be undone, write that>
```

**An entry with no options written down is not a decision record but a reflection.** What whoever reads this
file later needs is not what was picked but **what was dropped and why**.

The readers are `orangekit-planner` (checking prior decisions before planning) and `/pr-prep` (the Decisions line of a PR body).
When quoting, apply the four axes of "Reference Freshness" — the canonical source may have moved since the decision, and
**a quotation that was not re-verified is not evidence.**

Ceiling: 30 entries. Past that, **move** the oldest ones to `docs/decisions-archive.md` first.
An entry whose premise has become void (a stack swap·a withdrawn requirement) is a move target regardless of age.

## cross-check: multi-lens fan-out

An Irreversible change is **verified independently through different lenses**. Not the same lens N times, but N different lenses.

- **correctness** — does the logic match the spec, what about the edge cases
- **security** — permissions·RLS·input validation·secret exposure
- **reversibility** — is a rollback actually possible on failure, where are the data loss points

Each lens decides independently, and **it passes only when a majority finds no problem**.
Calling an external model is optional — lens diversity is the essence, model diversity is incidental.
