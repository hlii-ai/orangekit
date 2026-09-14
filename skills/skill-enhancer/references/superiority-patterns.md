# Superiority pattern catalog — 6 ways a harness-grade skill beats a skill-creator artifact

Extracted from this repository's ✅ 21 skills (full review 2026-08-19). Each pattern is described
together with **the reason the skill-creator methodology structurally cannot produce it** —
that reason is exactly why this catalog exists.

> skill-creator's eval loop scores "is the artifact good".
> The 6 below design not the artifact but **the environment the skill sits in and its behavior on failure**.
> A handful of test prompts do not expose this dimension.

## P1. Boundary declaration — the description contracts the division of labor with its neighbors

**Why skill-creator cannot produce it**: description optimization measures trigger accuracy (firing
when it should fire), but **the division of roles with other tools** is invisible to an evaluation of
that one skill. It is a property that shows up only in an environment with a competing tool.

**Evidence** — the security-review description:
> "To see only vulnerabilities newly introduced in a branch diff, use Claude Code's built-in
> /security-review — this skill covers the full audit, dependencies, secrets and payments, and the
> built-in tool does not cover those areas."

It **does not push the built-in tool aside; it divides precisely.** Result: misfiring (stealing the
built-in's job) and non-firing (forgotten because the built-in crowds it out) both go down at once.

**Injection method**: find the native or neighboring skill that overlaps the target skill and add the
sentence "if you need X, use Y — this skill covers Z" to the description.
If there is no overlapping neighbor, do not apply it (do not invent a boundary that does not exist).

### 4 steps to eliminate the overlapping stretch

A boundary split **does not end with keeping both.** Just keeping them leaves the overlapping stretch
intact, and for every utterance in that stretch you cannot tell which one will fire (misfiring and non-firing live together).

1. **Write the overlapping stretch down as a real utterance.** Not an abstraction like "both are
   planning" but the sentence a user would actually type, such as `"I want to add payments, how do I start?"`.
   An overlap that is not written down is an overlap you cannot handle.
2. **Assign that utterance to one side.** Look at the advantage list and rule by *which side's advantage
   that utterance needs*. If it is even, do not split — settle it as a **precedence relation** (A first → then B).
3. **Put cross-references in both descriptions.** Put it in only one and the other side keeps stealing.
4. **Measure.** Put the overlapping utterance into the eval set as both should-trigger and
   should-not-trigger and run skill-creator's description optimizer.

**Look at this first: is the boundary already in the body.** Measured case — the "After the Design"
table in `brainstorming`'s body already writes the precedence relation "prompt enhancement → implementation flow",
but the description does not. Only the description is resident at routing time, so the overlap lives on.
In such a case the job is not to **invent** a boundary but to **lift it into the resident layer**.

## P2. Behavioral contract — designs the manner of response itself, not the artifact

**Why it cannot be produced**: the eval loop scores the final artifact. "How it speaks when uncertain"
and "what it does not report" are behavioral dimensions that artifact scoring does not catch.

**Three pieces of evidence**:
- receiving-code-review **prohibited response patterns**: "Good catch!" (performative agreement) ·
  "I'll fix it right away" (immediate acceptance before verification) are banned + **a replacement phrasing is paired with each**
- orangekit-reviewer **falsifiability requirement**: "If you cannot write the failure scenario, do not
  report that issue. 'This could be...' is a guess, not an issue"
- orangekit-reviewer **over-reporting boundary**: "Do not report a Suggestion as if it were Important.
  Over-reporting invites being ignored"

**Applicability**: skills that produce judgements, reports or reviews. Not applicable to simple conversion utilities.
**Injection method**: ① state 2–4 bad responses the skill is prone to as prohibitions and
**always pair each with a replacement phrasing** ② give reported items a falsifiability criterion
③ unify the severity vocabulary on the repository standard (Critical/Important/Suggestion).

## P3. Failure path — failure is a branch, not a termination

**Why it cannot be produced**: test prompts mostly walk the success path. Partial failure, infinite
loops and unmet preconditions appear only in the field, and by then it is already too late.

**Three pieces of evidence**:
- council-review **partial-failure demotion**: "1 failure → proceed with 2 responses (marked unanalyzed),
  2+ failures → BLOCKED" + "at most 1 re-query, **no second re-query**"
- shared-workflow (the AI loop) **iteration ceiling**: "at most 2 re-verifications. Unresolved Criticals
  go to a user tie-break" — a loop with no ceiling either does not run or burns tokens
- extract-frames.sh **concrete precondition failure**: FFmpeg missing → "FAIL FFmpeg not installed
  — brew install ffmpeg" (what, why and how to fix it, at the moment of failure)

**Injection method**: ① at every iteration point, a ceiling N + the behavior on reaching it (user tie-break, etc.)
② for multi-input/fan-out, a partial-failure demotion table ③ for external dependencies (CLI · API key · file),
a verification command + a concrete failure message. **Derive the ceiling number from the nature of the work** — do not copy defaults.

## P4. Machine-first verification — the model judges only what a machine cannot

**Why it cannot be produced**: skill-creator goes as far as "put repetitive work in a script", but
**the inversion of handing the ruling itself to the machine and narrowing the model's judgement to the remainder** is not in the methodology.

**Three pieces of evidence**:
- harness-evaluation: "**do not count it again**" — doctor's measurement as the input, with the ruling
  greps nailed into the body + "do not go read a document that neither grep nor doctor flagged"
- stack-guide-generator: "self-test — **do not install on failure**" (passing verification is a
  precondition of shipping the artifact. A false placeholder contract becomes structurally impossible)
- build-parser.sh: consumes only the JSON summary instead of the raw log (coupled with token discipline)

**Injection method**: ① at every judgement step of the skill, ask "can a machine rule on this?" and if
it can, nail the exact command into the body as a code block ② for skills that produce artifacts, a
self-test checklist + a **do-not-install / do-not-report on failure** gate ③ replace points of bulk
text consumption with a structuring script.

## P5. Ecosystem wiring — a skill is not a file but a node in the graph

**Why it cannot be produced**: skill-creator builds and evaluates a skill as **an isolated unit**.
Who calls me, what I return and to whom, and which variable I branch on
can only be written by someone who knows the whole graph.

**Three pieces of evidence**:
- Invocation contract: codex-claude-loop desc "invoked when orangekit-reviewer's cross-check condition
  is met" + a graph edge declaring the return target (receiving-review)
- Unified routing variables: every branch uses only the reversibility class and the count of unmet entry
  conditions (the measured counterexample where mixing S/M/L left council-review waiting on a dead variable)
- workflow.graph.json node/edge declarations → `doctor --graph` verifies reachability

**Injection method**: ① state the caller (who calls me and when) and the return contract in the desc
② unify the branch variables on the repository standard ③ in a project with a graph file, add the node and edges.

## P6. Token discipline — subtraction is the default

**Why it cannot be produced**: it says "Keep the prompt lean", but nailing **the condition for not
creating** and **the condition for not reading** into the skill's logic is a different dimension.

**Three pieces of evidence**:
- dev-docs-generator: "if the work finishes in one session, **do not create** a workspace"
  (the necessity ruling comes before creation)
- seo-strategy: a "when to read" table per resource — outside Mode 2 the checklist is never read
- harness-evaluation: a 30-day timestamp cache — if it is fresh, skip re-investigation

**Injection method**: ① in a generator skill, make "the condition for not creating" Step 1 ② with two
or more resources, a when-to-read table ③ where there is repeated investigation, a timestamp cache.

## Applicability matrix — over-application is bloat, not hardening

| Skill type | P1 | P2 | P3 | P4 | P5 | P6 |
| --- | --- | --- | --- | --- | --- | --- |
| Review · analysis · evaluation | when there is an overlapping neighbor | **required** | if there is fan-out | **required** | recommended | recommended |
| Generator (docs · code · assets) | 〃 | falsifiability criterion only | precondition verification | **required (do-not-install gate)** | recommended | **required (necessity ruling)** |
| Orchestrator (multi-step · loops) | 〃 | recommended | **required (ceiling · demotion)** | recommended | **required** | recommended |
| Guide (reference knowledge) | 〃 | — | — | — | — | **required (when-to-read table)** |
| Simple utility | 〃 | — | preconditions only | recommended | — | — |

**Subtraction-first principle**: subtract before you harden — empty Step headings, unjustified MUSTs,
desc promises the body cannot keep, unused resources. What the superior skills have in common is not
the number of mechanisms they carry but that **every mechanism has a firing condition and a failure path**.
