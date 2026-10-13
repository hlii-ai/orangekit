---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "ios/**"
  - "android/**"
  - "lib/**"
---
<!-- orangekit-rule-version: 3.32.0 -->

# Code Change Card

Loaded when you edit files in the `src/` family. It does not carry general coding common sense.
Only **what the model gets wrong over and over** stays here.

## When Fixing a Bug — the reproduction loop comes before the hypothesis

**Do not guess at the cause until you have actually run one command that turns red.**
Reading the code and forming a plausible cause first is the most common failure in bug fixing —
there is no way to judge whether that hypothesis was right or wrong, so there is no way to know whether it is fixed either.

**① Build the loop.** From the top, use the first one that is possible in this situation:
a failing test · curl against a running server · a CLI call with a fixture + a diff against expected output ·
a headless browser script · replaying a captured request/log · a minimal harness with the dependencies cut away ·
1000 random inputs (for the kind that fails occasionally) · `git bisect run` (when it appeared between two good states).

Move on only when **all four** pass conditions hold. If you cannot build even one of them,
**stop, state what you tried, and ask the user for a reproduction environment·captured artifact.**

- It goes red on **exactly the symptom** the user described (running without an error is not a loop)
- The same verdict every time (for a nondeterministic bug, raise the reproduction rate — 50% is debuggable, 1% is not)
- Seconds, not minutes
- It can run by itself with no human intervention

**② Shrink it.** From the red state, remove inputs·settings·call sites·steps **one at a time** and rerun each time.
The point where removing anything turns it green is the minimal reproduction; it narrows the candidates in step 3 and becomes the regression test in step 5.

**③ Three to five hypotheses at once, in falsifiable form.** Form only one and you anchor on the first plausible thought.
If you cannot write "if X is the cause, changing Y makes the symptom disappear", it is an impression, not a hypothesis — discard it.
Show the list to the user first. Domain knowledge flips the ranking outright, and often.

**④ One variable at a time.** Give debug logs a unique `[DEBUG-<4 chars>]` prefix —
cleanup becomes a single grep, and logs without the prefix survive and ship to production.
For a performance regression, **measure first** rather than log (baseline → binary search).

**⑤ A regression test before the fix.** But **only when a correct seam exists.**
Covering a bug that arises from a chain of several call sites with a unit test on a single call site is false comfort.
**The absence of a correct seam is itself a finding** — report it as one, and do not write a test against a seam that is not there.

**⑥ Before you say it is done**: rerun the original loop and confirm green · confirm every `[DEBUG-` is gone ·
record the hypothesis that turned out right in the commit message (so the next person does not walk the same path again).

## Implementation Ladder (before writing)

Before writing new code, scan from the top and **stop at the first rung that catches.**
Rung 0 ("should this exist at all") has its canonical source in T0 "Minimal change" — this card picks up after that.
It has the same shape as "Priority of Solution Means" for harness assets (`harness-change.md`); this is the app-code counterpart.

| Rung | Ask | If it catches |
| --- | --- | --- |
| 1 | Does it already exist in this repository | Find it with grep and reuse it. Rewriting something that sits a few files away is the most common waste |
| 2 | Does the standard library·runtime do it | Use it |
| 3 | Does the platform do it natively | DB constraint > app code, CSS > JS, `<input type="date">` > a picker library |
| 4 | Does an already-installed dependency do it | Use it. **For adding a new one, see "Before Adding a Dependency" below** |
| 5 | Can it be done in one line | Write the one line |
| — | If none apply | The minimal implementation that works |

If two rungs catch at once, take the upper one and move on. The ladder is a reflex, not a research assignment.

**The ladder shortens the solution, not the understanding.** Trace the files the change touches and the actual
flow first, then climb. A small diff that skipped understanding is not efficiency; it is a confident wrong answer.

**What you never trim** — input validation at the trust boundary · error handling that prevents data loss · security (`security.md`) ·
accessibility basics · **a verification device for non-obvious logic** (even when cut to one line, a branch·loop·parser·money/security path
keeps one runnable check) · anything the user explicitly asked for.
When the reversibility class is **Costly or higher, explicitness beats brevity** — run the ladder, but do not tilt it
toward making the result short.

**After-the-fact cleanup does not belong here** — shrinking code already written is the built-in `/simplify`.
This section applies only before writing.

**Mark a shortcut whose ceiling you know** — when you deliberately cut a corner (a global lock · an O(n²) scan ·
a naive heuristic), leave one comment line: `ORANGEKIT-SHORTCUT: <ceiling>, <release condition>`.
A marker with no release condition is where "later" becomes "forever" — `/shortcut-ledger` reclaims them.

## Post-Change Back-Trace

grep the variables·functions you changed and clean up the unused leftovers. Improving something and leaving the old code
is the most common failure. Check that the variable name still matches the role it now has.

## Propagating the Same Pattern

If you changed a regex·constant·signature, **search out every use** with grep and change them in one pass.
Fix one place only and the rest drift out of line silently.

## Wiring Check (existing ≠ running)

When you introduce a rule·status value·handler, check the **execution wiring** across the full CRUD lifecycle.
Not "does the file exist" but **"who calls it, and when"**.

- If you write code that appends to a file, add rotation/a ceiling along with it
- Consider the abnormal-termination scenarios
- If you add a new branch, check that some input actually enters that branch

## Reference Freshness

The four-axis check right before quoting·extending earlier work is loaded every session by
`.claude/rules/workflow-routing.md` — the moment of quoting is unrelated to editing `src/`, so that card is canonical.

## Shared Boundary (confirm before editing)

Before editing a shared package (`packages/**` · a monorepo workspace · an internally distributed library),
**survey every consumer with grep, present the list first, and get the user's confirmation.**
A consumer may live outside this repository, and then the impact radius is invisible even to grep.

Solving a problem that app code could solve by editing the shared package is scope expansion —
"that is the more correct place for it" happens when it is separately requested.

## Verification Is Part of the Same Action

Once you edit source, the change is finished only after **running the build/test → checking the result**.
The `build-gate` hook enforces this, but do it yourself before the hook blocks you.

## Extra Requirements by Reversibility Class

**The canonical source is the "Reversibility classification" table in the T0 operating rules, injected every session.** Do not copy it here —
a copy was kept here and it did drift: the table that used to sit here wrote Reversible as "none" and
erased T0's `/completion-review`. With two values in one context, the later one wins.

## Before Adding a Dependency (a pre-install check, not a post-install audit)

Check five things before installing a new package: ① origin (official registry·active repository)
② history (recent updates·maintainer changes) ③ dependency tree (including suspicious transitives)
④ community size (downloads·issue responsiveness) ⑤ the package manager audit — **on a Critical/High finding,
stop the install and report to the user**. If 10 lines can replace the feature, do not add the dependency.

**The primary evidence is the registry and the repository** — do not use an AI-generated comparison table·a single blog post·a
Stack Overflow answer as grounds for the choice. They are good for "how do I use it" and bad for "should I use it".

If the choice is **Costly or higher, record it in `docs/decisions.md`** — what is needed later is not what you picked but **the candidates
you dropped and why** (the canonical format is `.claude/rules/reversibility.md`).

## Self-Check (when the implementation is done)

- Did you edit a file nobody asked for
- Is there code added "for extensibility"
- Is there code the requested feature still works without
- **The deletion test** — if this module is deleted, does the complexity disappear (= a pass-through layer, delete it),
  or does it come back at several call sites (= it earns its keep, keep it)
- Did you build an interface with **only one** thing to swap in — one makes it a hypothetical seam (just an indirection layer),
  two or more (production + test, say) is what makes it a real seam

→ If any one of them is YES, remove it.
