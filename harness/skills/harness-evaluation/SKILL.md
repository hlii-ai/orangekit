---
name: harness-evaluation
description: Runs a full path-level evaluation of the harness (graph) engine across 8 axes and produces a severity-ranked defect list, a per-area summary, and an uncertainty map. Use when the user asks for a "harness evaluation", "graph evaluation", "full evaluation", "harness check", or "exhaustive inspection"; manual invocation only. Fact measurement is done by doctor, so this skill takes that output as input and only judges, confirming Critical findings solely by isolated reproduction.
disable-model-invocation: true
---

# Harness(Graph) Evaluation

Evaluate by **path** ("which nodes does one task step on, where does it stop, and what does it
leave behind"), not by asset ("what exists"). No score is given — the output is **a defect list**,
and that list is itself the improvement backlog. The per-area table is the **input** to a verdict, not the unit of verdict.

**This one skill must complete the exhaustive inspection.** Step 1 collects every machine verdict, Step 2
judges across the 8 axes, and Step 3 fills the places that count (8 axis rows · per-area summary · uncertainty map).
The mapping between a request's perspective and an axis is held in the ledger `references/coverage-map.md` — read it **only when reorganizing the axes**.

## The 8 axes

**When responsibilities overlap between axes, the results turn vague.** Respect each axis's "looks only at".

| axis | question | machine verdict (Step 1) | model judgement (Step 2) |
| --- | --- | --- | --- |
| **P1 routing and canonical-source consistency** | do two places claim the same fact differently — **routing card ↔ graph ↔ hbs ↔ T0, all four** | S/M/L grep (the vulnerability severity table is a false positive, so it is excluded) · `--graph` G6·G9 Phase both ways · `--fast`'s "declaration ↔ reality" (counts · names · tool lists · T0 budget) · `shared-copy` · version stamps | does the violation actually cause misbehavior · closure of the 6 document-dependency edges · the 4 axes of reference freshness · does the copy carry a canonical-source marker |
| **P2 firing accuracy** | ①does it fire when the condition holds ②is the node's permission shape right ③does it catch what it must ④does it leave alone what it must ⑤**are the exemption and bypass paths closed** | comparison against the graph declaration · G8 manual↔frontmatter · agent frontmatter · `--self-test` positive/benign/**bypass-attempt** fixtures · "blocking reason ↔ fixture" | is manual the intent or an omission · gate misses · sufficiency of handoff restoration · does the verification base a gate presumes actually exist · false-positive history (`--lessons` per guard) |
| **P3 loop termination** | does a repeating node have a ceiling and a termination predicate | grep for ceilings — including references/ | is the ceiling appropriate to the nature of the work |
| **P4 feedback closure** | does a record come back as an asset diff | `--lessons` promotion/narrowing candidates + archive count · `--graph` G7 store consumption paths · the `eval-report → lessons` edge | is the chosen promotion form (hook/skill/rule) right · **does narrowing happen** · was it physically moved into the archive |
| **P5 path cost** | are the node and gate counts for one representative task, and the **resident · on-invocation · conditional** costs, appropriate | `--usage` (resident bytes · graph.log · skilluse.log) · `--inventory` (SKILL lines · on-invocation bytes · card `paths:` width) | excess gates on the Reversible path · resident budget allocation · does a wide `paths:` drag a large card into unrelated edits · SKILL.md files over 300 lines |
| **P6 structural restraint** | ①excess ②duplication ③vagueness (table below) | `--usage` never-invoked list · `--fast` native-wording and description hygiene · lingering warnings · `--inventory` 0 document mentions | the substantive judgement on each item |
| **P7 boundaries** | ①does it go outside ②does it leave residue ③is there attribution | `--fast`'s platform-contract 180 days · log rotation (hookrun · graph · skilluse) · `dev/handoff/` count | does a prior-notice point exist · secrets in the residue · attribution |
| **P8 consumer journey** | install → first session → first task → first block → recovery → update — **is there any place where a consumer following the docs diverges from reality** | `--consumer` (T1 reach · consent gate · undecidable does not block) · "declaration ↔ reality" exhaustive skill names · tool lists · config fields · release tags | does the blocking message state the next action · do two documents say different things about the same subject · does it invite a workaround · an uncommitted asset does not exist for a consumer |

**P5 and P6 are orthogonal** — something cheap can still be a duplicate, and something expensive can still be justified (security-check).
**P2, P7, and P8 are orthogonal too** — P2 is blocking power, P7 is crossing boundaries, P8 is the path the consumer walks.

### P6 detail — the three questions, thrown again at assets that already exist

The three questions before adding in `rules/harness-change.md` apply **only when creating an asset**. Here is where
those questions get thrown again at assets that exist. Without this, the harness only grows.

| item | what to look at |
| --- | --- |
| ① **excess** | is it still needed · has model improvement made it unnecessary · was something that could be 1–3 lines of documentation built as a script · declarations with no reading code (config fields · dead checks) |
| ② **duplication** | pairs of assets with overlapping roles — custom vs **native** (`/code-review` · `/simplify` · `/security-review` · `skill-creator` · `/init` · `/run` · `/loop`) · custom vs custom · the same norm asserted by two files (no canonical/quoted marking) |
| ③ **vagueness** | does the output lead to an action — **a warning that will not turn off** · undecidable folded into blocked · two checks counting the same thing · a failure report with no remedy text · a warning pointing opposite to the rule (a false positive reported as a "promotion candidate") |

Always leave a point-in-time stamp ("Claude Code version · model · date"). **If the previous stamp is within 30 days and
there have been 0 harness asset commits since**, skip the P6-② re-survey — never skip on the date alone
(10 versions shipped in the 14 days after v5). **To propose retiring a custom asset, actually open both bodies**
and compare coverage — the existence of a native is evidence of duplication, not evidence of inferiority.
The comparison target must be **the best, undamaged version**.

#### P6-② has three verdicts — replace · keep · compose

**Write out all five perspectives** and then judge: coverage (only after opening both bodies) · firing accuracy (false-positive
and miss history) · maintenance cost (do we fix it or does the platform) · consumer reach · model dependence.

| verdict | condition | action |
| --- | --- | --- |
| **replace with the native** | the native is equal or better on all five perspectives | retire the custom asset (retirement protocol). Rewrite remaining references to call the native |
| **keep the custom** | an area the native cannot cover actually exists | leave that area in the skill body in 1–2 lines |
| **compose** | the perspectives split on which is better | **put the native at the base and layer only the custom's unique value thinly on top** |

Precedent: `/security-review` (branch diff) and the `security-review` skill (exhaustive · CVE · secrets · payments) had
split coverage and both survived, and `receiving-code-review` was narrowed to *verifying* findings rather than *generating* them.
**A verdict is not done until it is applied** — for each verdict, write whether it goes to `eval-report → rule-promotion`
(asset replacement or promotion) or to `eval-report → skill-enhancer` (skill redesign).

## Workflow

### Step 1: Collect the machine verdicts — do not count them again

It is one block. Run all of it and keep the output — this is the "measurement" column of the 8 axes.

```bash
# This skill belongs to the `orangekit-harness` plugin, so CLAUDE_PLUGIN_ROOT points at harness/ —
# the devkit assets under evaluation (scripts/ · skills/ · agents/) live **one level above** it.
# Derive the repository root directly. Outside the harness source repository this skill has nothing to evaluate.
R="$(git rev-parse --show-toplevel 2>/dev/null)"
[ -n "$R" ] && [ -f "$R/scripts/doctor.sh" ] || { echo "not the harness source repository — nothing to evaluate (undecidable)"; exit 2; }
bash "$R/scripts/doctor.sh" --all            # fast · self-test · graph · consumer · usage · lessons · inventory
bash "$R/scripts/doctor.sh" --usage --root <consumer project>     # only when a consumer exists
# Guide harness — only when there are guides/ or stack-guide-generator/ commits since the last report (--regress is slow)
bash "$R/skills/stack-guide-generator/scripts/guide-gate.sh" --regress
bash "$R/skills/stack-guide-generator/scripts/pack-smoke.sh" --self-test
# Pack freshness — runs **every time** (the ecosystem moves even without commits). A pack with a bump is not on this
# evaluation's defect list but on the maintenance list: handle it with pack-authoring.md "Pack refresh" and release.
# Putting it off makes the user pay the same refresh separately on every consumer init (measured 2026-10: all 14 packs bumped)
for p in "$R"/guides/frontend/*/ "$R"/guides/backend/*/ "$R"/guides/app/*/; do
  bash "$R/scripts/guide-freshness.sh" --pack "$p" >/dev/null 2>&1 || echo "needs refresh: ${p#"$R"/}"
done
# P1 — routing vocabulary (read it excluding the severity-table context)
grep -rn 'Small\|Medium\|Large' "$R"/skills/*/SKILL.md
# P3 — repetition ceilings (including shared files)
grep -rln 'at most [0-9]\|retry once\|one retry' "$R"/skills/*/SKILL.md "$R"/skills/*/references/*.md
# P7 — nodes that go outside · residue
grep -rln 'WebSearch\|WebFetch\|codex' "$R"/skills/*/SKILL.md "$R"/agents/*.md
ls "$R"/dev/handoff/ 2>/dev/null | wc -l
# P6 re-survey decision · P8 shipping reach — asset commits since the last report · uncommitted assets
LAST=$(ls -t "$R"/dev/docs/harness-evaluation/v*.md 2>/dev/null | head -1)
git -C "$R" log --oneline --since="$(date -r "$LAST" '+%Y-%m-%dT%H:%M:%S')" -- skills agents rules hooks scripts templates | wc -l
git -C "$R" status --porcelain -- skills agents rules hooks scripts templates workflow.graph.json | wc -l
```

**Sources of repetition evidence** (P6-① and P2-④ require it):
`docs/lessons.md` · `docs/lessons-archive.md` · `.claude/.orangekit/{hookrun,graph,skilluse}.log` ·
`dev/handoff/*.md` · `dev/docs/skill-review/*` · a consumer project (`--root`).
**Only something observed 2 or more times is grounds for intervention** — once is a hypothesis, not a pattern.

### Step 2: 8-axis verdict + defect list + reproduction

- Judge each axis in two lines: `measurement: <summary of machine output — always state what was not measured>` /
  `verdict: <met | partially met | unmet | unmeasured> — <basis>`
- A defect takes the form `ID | severity | file:line | failure scenario | intervention point | fix direction | disposition`.
  Severity uses the same vocabulary as orangekit-reviewer (Critical/Important/Suggestion). IDs continue from the previous round.
- The **intervention point** is where the fix will sit: ①the opening briefing (T0 · session-brief) ②the decision point
  (rule `paths:` · skill firing) ③the behavioral checkpoint (PreToolUse) ④after-the-fact recovery (Stop · PostToolUse · handoff).
- **If you cannot write the failure scenario, do not report that defect** — "it could happen" is speculation.
- **Do not go read documents that grep, doctor, and inventory did not catch.** Reading every document is a retired method.
- Do not inherit the previous round's verdicts — always re-confirm against the current files.
- **A delegated report's (Explore, etc.) defect candidates go on the list only after opening the file:line yourself and re-confirming** —
  in v6 and v7 running, 2 delegated findings each diverged from the current files (a claim of a missing stamp · a claim about a platform default).
- **P2 is never judged met by reading.** For each guard, inject in isolation the bypass and false-positive cases that are **not in the fixtures**
  (reproduction procedure below · for the Stop gate, a synthetic transcript) and record the result in the measurement column — v8 read all the
  code and declared it met, and v9's injection produced 3 bypasses and 5 false positives, while v6 E-21 also lived
  4 months with the fixtures green. Passing fixtures proves "what the fixtures know", not "there is no bypass".

**A Critical is confirmed only by reproduction.** Reading documents alone tops out at Important. Reproduction must not
pollute the instrumentation logs (`ORANGEKIT_STATE_DIR` isolation — the lesson of v5 E-13). If a reproduction command contains
destructive syntax or a secret, **the live hook blocks that very command** — write the case to a file and run it.

```bash
jq -nc --arg c '<the Bash command to reproduce>' '{tool_name:"Bash",tool_input:{command:$c}}' > "$TMPDIR/case.json"
ORANGEKIT_STATE_DIR=$(mktemp -d) CLAUDE_PROJECT_DIR="$R" bash "$R/scripts/security-check.sh" < "$TMPDIR/case.json"; echo "exit=$?"
```

**A defect claiming absence does three things first** — both false positives (v2 E-06 · v5 E-18) concluded absence
from a single observation: ①open the place (the code) where the policy would live ②confirm through the firing frequency in
`docs/platform-contract.md` §5.1 that the event was given time to happen ③measure with the binary on the execution path (not a shell wrapper).

Write the **per-area summary** — one row per area from `--inventory` (skills · rules · hooks · agents · guide packs · references ·
templates · presets · documents · check scripts): `area | inventory figure | this round's defect IDs | one-line verdict`.
Do not leave the row empty for an area with no defects — "none" is a verdict.

### Verdict discipline — do not hunt for findings

This skill's output is not a defect count. **8 axes met, 0 defects is a legitimate result** — when that is the case, write
it that way and stop. Even a "met" verdict records what was looked at in the measurement column — an empty "met" is unmeasured.

- Set a **disposition** per defect: `fix` · `defer (reason)` · **`accept`** (not fixed — the cost of intervening and the
  regression risk exceed the cost of the defect). The default disposition for a Suggestion is **record** (same as orangekit-reviewer).
  The reporting threshold is not lowered — "no failure scenario, no report" still holds; this only separates reporting
  from fixing.
- "Review at least 1 narrowing proposal" is **a duty to review, not a duty to propose.** If there is none, "none + reason".
- Stop when a review inflates into a reorganization plan — findings outside the request scope get a one-line report and stay on the list.
  The scope (2026-09-09) and false-positive (2026-09-04) entries in `docs/lessons.md` were exactly this failure, and
  v7 fixed 12/12 in the same round, down to 4 Suggestions — the signal that the defect count had started to read as achievement.
- Leave a table of "things reviewed but not intervened in": `target | why no intervention`. The value of that table is
  keeping the next round from digging at the same spot again.

### Step 3: Save + comparison with the previous round + feedback

1. Format: `assets/report-template.md`. Do not drop a section — a place that does not count does not get counted.
2. Version: the highest vN in `ls dev/docs/harness-evaluation/` plus 1 (**the filename is the ledger**)
3. Save to: `dev/docs/harness-evaluation/v{N}.md` — the save time is itself the external-change check stamp.
   The `session-brief` hook computes the 30-day elapse from the latest report's mtime and announces the next check.
4. If there is a previous round, summarize only defect deltas (new · resolved · remaining, by ID) and resident-cost deltas. There is no score trend.
5. **Review at least 1 narrowing proposal** (a review, not a duty to propose). If there is none, write "none + reason" —
   with promotion only and no narrowing, the harness only grows.
6. Write an **uncertainty map** as a table: `item | state (measured · unmeasured · impossible here) | why | closing condition |
   where (here · consumer · platform)`. If something unmeasured last round was measured this time, leave that row as "closed".
7. **Feedback**: if this round retracted a false positive or found an error in the evaluation's own verdict, record it on the spot
   in `docs/lessons.md` as `[category: false-positive]` plus a `- Guard:` line (`eval-report → lessons`).
   If the narrowing finished as an asset diff in the same round, **physically move** it into `docs/lessons-archive.md`.
