---
name: shortcut-ledger
description: Harvests the deliberate shortcut markers (`ORANGEKIT-SHORTCUT:`) left in the code, re-assesses whether each ceiling still holds, and decides what to reclaim. Use for a debt check before a release, or after scale or load has grown. Shrinking code that is already written is the built-in `/simplify`.
---

# Shortcut Ledger

Looks at one thing only: whether a deliberately left shortcut has **expired**.
The canonical source for the marker convention (`ORANGEKIT-SHORTCUT: <ceiling>, <release condition>`) is
"the implementation ladder" in `.claude/rules/code-change.md` — this skill is the side that reclaims those markers.

> **Boundary** — shrinking code that is already written is the built-in `/simplify`, producing findings is `/code-review`,
> and recording mistakes is `lessons.md`. This skill owns only what those three do not: **the expiry of deferred decisions**.
> It does not create new shortcuts and does not fix code itself — reclaiming goes back to build.

## Step 1: Harvest

```bash
grep -rnE '(#|//|--|/\*|<!--) ?ORANGEKIT-SHORTCUT:' . \
  --exclude-dir={node_modules,.git,dist,build,.next,vendor,target,coverage} 2>/dev/null
```

The comment prefix is required so that **prose that merely mentions the convention** (this file · the rule cards)
does not end up in the ledger. If your stack uses a different prefix, add it.

**If there are zero, finish with "Shortcut ledger: empty".** Do not invent debt that does not exist.

## Step 2: Build the rows

One marker = one row. Take the ceiling and the release condition verbatim from the comment.

```
<file>:<line> | <what was shortcut> | ceiling: <limit> | release: <condition> | <verdict>
```

If the release condition is empty, mark it `no-trigger` — this is the category that rots quietly.
If you need an owner per row, add `git blame -L<line>,<line> <file>`.

## Step 3: Verdict — does the ceiling still hold

Hold each row against **the current scale, load, and requirements** and give it one of three verdicts.

| Verdict | Condition | What to do |
| --- | --- | --- |
| Keep | The ceiling has not been reached yet | Leave it. One line of rationale |
| Reclaim | The ceiling has been reached, or the release condition is met | Go back to build and pay it off |
| Expired | The ceiling is **already broken** — a real bug or performance loss | Critical, report to the user immediately |

Accept **only verdicts you confirmed by opening the code**. The ceiling the comment claims may not match the actual
implementation — a comment is a hint about where to look, not evidence
(`.claude/rules/workflow-routing.md`, "reference freshness").

A shortcut on a path whose reversibility class is Costly or worse makes **the reclamation itself a Costly change**.
Present the impact radius (the list of call sites) before paying it off.

## Step 4: Report

```
Shortcut ledger: N items (keep A · reclaim B · expired C · no-trigger D)

<the row list — expired → reclaim → no-trigger → keep>
```

**Do not invent a per-repository "lines saved" figure.** Code that was never written has no baseline, so that number
cannot be verified. The ledger reports only **what was counted** (marker counts, verdict counts).

If there is one or more reclaim/expired item, end with: `B+C items to reclaim — shall we proceed to build?`

## Ceiling

Judge at most 30 rows per invocation. Beyond that, cut in the order `expired` → `no-trigger` → oldest first
and state how many are left. Do not emit **a listing with no verdicts** just because the ledger is long —
a ledger that only counts is the same as `grep`, which means this skill was not needed.
