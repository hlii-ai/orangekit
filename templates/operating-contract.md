<!-- T0 standing norms. session-brief.sh prints them every session.
     Plugin-owned → updated automatically. The project cannot edit it, so drift is structurally impossible.
     budget: 42 lines (enforced by doctor --fast). The canonical source for the reversibility classes **is the table below** — planner·README quote it. -->

## ORANGEKIT Operating Rules

**Reversibility classification** — decided by path. Not judged by size (line count·file count). This table sets the verification intensity and **who performs it**.

| Class | Deciding path | Requirement — who does it |
| --- | --- | --- |
| Irreversible | `**/migrations/**` · auth/RLS · payments·settlement · production data | `orangekit-reviewer` multi-lens fan-out + **user confirmation** + rollback procedure |
| Costly | shared packages · public API · type contracts · `**/api/**` · `**/actions.ts` · `**/middleware.ts` · generated files | `orangekit-reviewer` is mandatory — **self-review is not a substitute** |
| Reversible | everything else, test code included (default) | Proceed directly. Closing documentation is `/completion-review` |

**Work entry** — when all four below are met, implement immediately with no preparatory work.
Intent clear · context current · impact radius known · verification path exists.
Fill only the unmet items — do not create documents for items already met.
**If two or more are unmet, or the impact radius is unclear, delegate the diagnosis to the `orangekit-planner` subagent.**
Three of the four you resolve yourself — **intent alone belongs to the user.** If intent is not clear, ask, regardless of how many items are unmet.
What gets built in what order (Phase) is set by the routing table in `.claude/rules/workflow-routing.md` (loaded every session).

**Minimal change** — implement only what was requested. If a file outside the scope needs editing, stop and confirm.
Do not refactor, abstract, or add dependencies without a separate request.
"We might need it later" is not a reason.
**Even inside** the file you are fixing, leave comments·formatting·style unrelated to the request as they are — report someone else's dead code, clean up only the orphans your own change created.

**Verification** — once you edit source, the build/test is part of the same single action. "I wrote it" is not "it works".
When you add or modify a script·hook, actually run it → confirm exit 0 → confirm the expected output.

**Decision point** — when the outcome of a decision is hard to reverse or affects the user's workflow,
present the options and the **real difference between them**, and let the user choose.
Trivial decisions about **method** you settle yourself and proceed — do not ask on every decision.

**Context boundary** — decide it **when a phase ends** (design·implementation·QA). Do not decide mid-phase — continue, or split off only the remaining work to a subagent.
Read from the top; the first "yes" is the answer. ① Does the next phase use this conversation as its **primary source**, or is there enough room left in the window → **continue**
② Is the current context irrelevant to the next phase → `/clear` ③ Are you handing this to another tool·directory·person → **handoff**
④ Can it be finished without supervision → **subagent** ⑤ Otherwise → `/compact` plus an instruction on what to do next.
**Rule out ① first** — the other four all replace the primary source with a summary, and that loss cannot be undone.

**Lessons** — when the user points out something about code·approach·workflow, record it in `docs/lessons.md` right then, **regardless of the path involved** (format: `.claude/rules/lessons.md`).
**Language** — internal reasoning and analysis in English. User-facing output and the prose of produced documents in {{RESPONSE_LANGUAGE}}, written to read naturally to a speaker of that language by reflecting intent·context·domain rather than translating literally. Code·identifiers·commands·machine-readable tokens and **technical terms that are standard in English** (Bottom Sheet · GNB · middleware · migration) are not translated.
