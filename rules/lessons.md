---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "lib/**"
  - ".claude/**"
  - "scripts/**"
  - "dev/docs/**"
  - "docs/lessons.md"
  - "docs/lessons-archive.md"
---
<!-- orangekit-rule-version: 3.28.0 -->
<!-- paths must fire "when doing work that could draw a correction", not "when editing the lessons file".
     Match only lessons.md and it loads after you already went to record — the trigger is inverted. -->

# Lesson Recording Card

## When to Record

When the user **corrects or points out** code·an approach·a workflow. Right then.

## Format

```markdown
## [category: <category>] <lesson title>

- Date: YYYY-MM-DD
- Guard: scripts/<hook>.sh or skills/<skill>   ← false-positive entries only. Which guard fired wrongly
- Situation: what you were doing
- Mistake: what you got wrong
- Lesson: what you will do differently next time
```

A `Guard:` line is what lets `doctor --lessons` count false positives **per guard** — a category total cannot tell you
"what to narrow". Without one, the first script name in the body is used as a guess and marked as a guess.

Name the category specifically. Broad categories like `misc`·`general` are forbidden —
they make the aggregate meaningless.

Examples: `validation` `tdd` `architecture` `security` `naming` `scope`
`workflow` `skill` `rule` `agent` `infra` `tooling` `false-positive`

**For `false-positive`, the answer is contraction, not promotion.** Record an incident where a guard fired wrongly
in the same format, but once there are two or more from the same guard, do not create a rule —
**narrow the condition or retire that guard.** False positives make the user switch the hook off,
and a hook that is off blocks nothing.

## Repeated Requests

When you notice you have carried out the same type of work request **two or more times**, record
`## [request: <request type>]` in the same format (e.g. `harness-evaluation`, `prd-review` —
no excessively broad naming). At three or more, doctor reports it as an **automation candidate (promotion to a skill)**.
The promotion procedure is the same as below — one user approval, and after approval the entry physically moves to the archive.

## Promotion

Aggregation and the promotion-candidate decision are **performed by doctor** (`bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/doctor.sh" --lessons` — the absolute path is on the 'self-test' line of the session briefing).
A rule does not make the model do the counting.

At three or more entries in the same category, doctor reports a promotion candidate. Promotion is:

1. Confirm the candidate in doctor's output
2. Choose the promotion form to match the nature of the mistake
   - Deterministically detectable by pattern matching → **extend a hook** or **a lint rule**
   - A repeated workflow → **a skill**
   - Requires semantic judgement·context understanding → **a rule card**
3. **One** user approval
4. After approval, **physically move** that entry to `docs/lessons-archive.md`

> **Step 4 is the point.** v2 declared "✅ promoted" 22 times and 0 rules changed.
> The evidence of a promotion is not a declaration but two things: **① the diff of the corresponding asset ② the entry gone from the file**.
> When the loop runs properly, `lessons.md` **shrinks.**

## Ceiling

Once `lessons.md` passes 30 entries, move the oldest archivable ones out first.
An entry whose category has not recurred in six months is also an archive target.
