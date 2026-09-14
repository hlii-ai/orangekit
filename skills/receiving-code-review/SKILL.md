---
name: receiving-code-review
description: Technically verifies received code-review feedback and handles it by severity. Use when you receive built-in /code-review results, an orangekit-reviewer report, external AI cross-verification (codex) results, or an external review the user pasted in. It does not accept feedback blindly — it confirms each point against the actual code before adopting it, and rebuts incorrect points with evidence.
---

# Receiving Code Review

Technically verify code-review feedback and handle each item appropriately by severity.

## Core principles

- **Verification first**: do not accept feedback blindly. Check the actual code to verify that it is correct.
- **Technical rigor**: technical judgement comes before social agreement ("great catch!").
- **Evidence-based rebuttal**: when the reviewer is wrong, rebut with concrete evidence.
- **YAGNI check**: verify that a "professional-looking" suggestion is actually needed.

## Forbidden response patterns

Do not use these phrases when receiving feedback:

- "Great catch!" / "Excellent feedback!" (performative agreement)
- "I'll fix that right away" (accepting before verifying)
- Long apologies or excessive explanation

Use these instead:

- "Fixed. [summary of the change]" (when accepting)
- "The current implementation is correct because [evidence]." (when rejecting)
- "Checked, and you are right. [reason]. Fixing it." (when accepting after a rebuttal)

## Workflow

### Step 1: Identify the feedback source and decide the scope

| Source | Path to run |
|------|----------|
| Built-in `/code-review` or `orangekit-reviewer` results | Step 2 → Step 3 → Step 4 |
| External AI cross-verification (`codex-claude-loop`) results | Step 2 → Step 3 → Step 4 |
| An external review the user pasted in | Step 2 (source trust is low, so verify harder) → Step 3 → Step 4 |
| Static analyzer (SonarQube) issues — `health-check` Step 5.6 | Step 2 (**verify harder**) → Step 3 → Step 4 → Step 5 |

Why static-analyzer issues get harder verification: **a rule engine does not know the project context.** Sonar's
code smells trip especially often on Step 2's YAGNI check ("is this abstraction justified at the current scale?") and on naming a
replacement — the rule only says a threshold was crossed, never what to replace it with.
Issues on paths that are expensive to reverse (`**/migrations/**` · auth/RLS · payments · `**/api/**` · `**/actions.ts` ·
`**/middleware.ts`) are **not fixed here even when accepted** — hand them to `orangekit-reviewer`.

### Step 2: Verify the feedback

For each issue, check the following:

| Check | How | Outcome |
|----------|------|------|
| Fact check | Open the actual file:line and read the code | Filters out false positives |
| Severity fit | Re-assess the impact in the project's context | Adjust the severity if needed |
| YAGNI check | "Is there a current problem that introducing this solves?" | Downgrade or reject unnecessary suggestions |
| Deliberate decision | Check plan.md and context.md for a prior decision | If deliberate, record the reason for rejection |
| Impact on existing behavior | Would accepting the suggestion break existing behavior | If there are side effects, reject or defer |
| **Named replacement** (simplification family) | Is "what to replace it with" named — a function name, a platform feature, a shorter form | If not, do not adopt; ask for clarification |

On naming a replacement:

Simplification-family findings **arrive in a format that has no replacement field.** The required fields of
`ReportFindings`, which `/code-review` uses, are file · summary · **failure scenario**, and a failure scenario is
shaped like **a correctness defect**: "specific input/state → wrong output" — for a simplification finding
that slot is empty, and there is no slot to put the replacement in either.

"This could be simpler", with no replacement, is an **impression**, not a work order. Adopting it as-is
turns into an aimless rewrite, and a rewrite is riskier than the original finding. If the finding does not say
what to replace it with, ask that before fixing anything.

On the YAGNI check:

```
Suggestion: "we need to introduce [feature/pattern]"
Check:
1. Is there an actual use site in the current codebase? (confirm with grep)
2. Is this abstraction justified at the current scale?
3. Does the problem it solves actually exist?
→ If not needed, downgrade to Suggestion or reject
```

Verification result format:

```
Feedback verification results:
- Accepted: [N] (original severity kept)
- Severity adjusted: [N] (with [original→adjusted] and the reason)
- Rejected: [N] (with evidence)
- Awaiting clarification: [N] (no replacement named — to Step 3, "handling unclear feedback")
```

### Step 3: Handle by severity

**Order of handling**: Critical (blocking) → Important (simple → complex) → Suggestion (record only)

| Severity | Handling | When |
|--------|------|------|
| Critical | Report to the user immediately. Confirm whether build must be re-entered. | verify stops |
| Important | Report to the user, then fix. When the fix is done, verify continues. | fixed within verify |
| Suggestion | Record it in the report. No separate fix needed. | record only |

**Report format when a Critical is found**:

```
[Critical issue found]

1. [file:line] - [description of the issue]
   Impact: [blast radius]
   Suggested fix: [recommended approach]

Shall we go back to the build stage and fix it?
```

**Splitting Important**:
- Simple fix (1-2 lines, an obvious direction): fix it directly and report
- Complex fix (logic change, a design decision needed): report to the user and decide the direction together

**Handling unclear feedback**:

If a feedback item is unclear, do not handle it partially — ask for clarification of the whole thing. Items may be related, so this prevents a wrong fix made on a partial understanding.

### Step 4: Summarize what was done

```
Feedback handling complete:
- Critical: [N] → [handled / build re-entry needed]
- Important: [N] → [handled / awaiting user confirmation]
- Suggestion: [N] → recorded
- Rejected: [N] → [summary of the evidence]

[When every Critical/Important has been handled]
→ Proceeding to documentation update (completion-review).
```

### Step 5: Re-run the static analysis (Sonar path only)

Do this only when the source was `health-check` Step 5.6. Once the fixes are done, **run Sonar exactly one more time**
to confirm the issue count dropped — the canonical source for the command is `health-check` Step 5.5, and no copy is kept
here (a copy is a source of drift).

The termination predicate is `zero new issues OR the one re-analysis is spent`. Hand the remaining issues to the user as a list and
**do not run a second re-analysis** — an unbounded fix loop is a defect. If the fixes increased the issue count,
report that in itself (a regression signal).

## How to write a rebuttal

When the reviewer's finding is inaccurate:

```
I see this differently:

Finding: [summary of the reviewer's point]
Rebuttal: [concrete evidence]
References: [related code/docs/official documentation paths]
Conclusion: [accept/reject/partially accept] + reason
```

When a rebuttal is warranted:
- The suggestion would break existing behavior
- The reviewer did not have the full context
- YAGNI violation (introducing an unused feature/pattern)
- It is technically inaccurate for this project's stack
- It conflicts with a user's architectural decision

When the rebuttal turns out to be wrong:

```
Checked, and [the finding] is correct. [verification evidence]. Fixing it.
```

## Reference documents

Consult these when you need a standard for judging whether feedback is warranted. **If they are absent, skip the reference.**

- Code change norms: `.claude/rules/code-change.md`
- Reversibility class decisions: `.claude/rules/reversibility.md`
- If the project wrote its own convention rules under `.claude/rules/`, consult those as well
