---
name: codebase-survey
description: Measures an existing repository's stack, structure, and architecture, updates the project-owned rule cards (project-structure, code-conventions), and reports drift. Use when the harness was installed into an existing project after the fact, or when the code has grown and the cards have gone stale. Creating CLAUDE.md for the first time is the built-in /init and choosing a stack is /orangekit-init — this skill updates cards that already exist to match what is actually there.
---

# Codebase Survey

**Measure and describe. Do not prescribe.**

The two project-owned cards `/orangekit-init` created from a one-time measurement have **no update path** after that
(being project-owned, they carry no version stamp either, so there is not even a mechanism to detect drift). As the code grows the cards
quietly become false, and a false card is worse than no card. This skill is that update path.

> **Boundary** — *choosing* a stack is `/orangekit-init`, *generating* guides is
> `/stack-guide-generator`, measuring *this change's* impact radius is `orangekit-planner`,
> and checking whether build and test *run* is `/health-check`. This skill owns what none of those four cover:
> **the current facts of the whole repository**. It does not fix code and does not change structure.

## Step 0: Project harness inventory — read only

Find what the consumer already had, first. **Fix nothing here**
(the non-invasiveness clause of "instruction precedence" in `.claude/rules/workflow-routing.md`).

```bash
ls -a
ls AGENTS.md CODEX.md CLAUDE.md README.md CONTRIBUTING.md 2>/dev/null
ls -d .github .gitlab .gitlab-ci.yml docs .harness .agents .cursor 2>/dev/null
ls .claude/rules/ 2>/dev/null
```

Read what you found and **report it as a list**. The conventions written there beat the plugin
guides in every later judgement — which is why this comes before measuring.

Before concluding that an asset "does not exist", check all three places: the project-local `.claude/` ·
the plugin cache `~/.claude/plugins/cache/` · the marketplace `~/.claude/plugins/marketplaces/`.

## Step 1: Measure — no guessing

The canonical source for the command block is `/orangekit-init` Step 0. **Do not copy it here** — read that step,
run the same thing, then add the following (init measures to fill in preset defaults, while here you measure the repository's
current shape):

```bash
git log --oneline -1 && git rev-parse --abbrev-ref HEAD    # facts as of when?
cloc . 2>/dev/null || find . -type f -name '*.*' -not -path '*/node_modules/*' \
  -not -path '*/.git/*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -15
ls -d */ && ls -d src/*/ app/*/ packages/*/ 2>/dev/null   # top two levels
ls -d services/*/ apps/*/ 2>/dev/null                     # msa or not
grep -o '"repoTopology"[^,}]*' orangekit.config.json 2>/dev/null  # declared value — compare against the measurement
```

Lockfiles, manifests, and config files are the truth. **Write down only what you read and confirmed** — do not conclude
from a preset or a framework convention. Leave anything you cannot confirm as "unconfirmed" and ask.
**"Not there" and "could not read it" are different** — do not put them in the same cell.

## Step 2: Describe the architecture — do not prescribe

Look at six things only. **Back each item with a file path.** If you cannot name a path, do not write the item down.

| Item | What to look for |
| --- | --- |
| Entry points | Routes, handlers, CLI, jobs, workers — where external requests enter the code |
| Layers | The divisions the repository actually uses and **the direction imports actually flow** (as they are; if none, "flat") |
| Data flow | Trace one real path: request → validation → business logic → storage → response |
| Trust boundaries | Where external input arrives and where authentication/authorization is applied |
| Recurring patterns | Anything that appears in the same shape three or more times — that is this repository's convention |
| Danger zones | Paths whose reversibility class is Costly or worse (migrations, auth, payments, shared packages, public API) |

**Explain what is there; do not recommend what is not.** If the repository does not use Clean Architecture · DDD · MVC ·
the repository pattern · event sourcing, **do not propose them.** Offer improvements only when
the user asks, and even then put improvements **within** the current boundaries first.

## Step 3: Update the cards + report drift

**Update** `project-structure.md` and `code-conventions.md` under `.claude/rules/`
(both cards are project-owned, so they do not exist in the plugin repository — they exist only in the consumer project).
Do not create a new document — a new document has no load point, and a document that is never loaded is pure cost.

| State | What to do |
| --- | --- |
| Card missing | Create it from the template (`${CLAUDE_PLUGIN_ROOT}/templates/rules/*.template.md`). The procedure is `/orangekit-init` Step 7.5 |
| Card present · matches the measurement | Leave it alone. Report as "matches" |
| Card present · **mismatched** | Present a per-item diff and update it **after the user confirms** |

**The per-item diff is this skill's artifact.** Do not overwrite a card wholesale — project-specific conventions
a human put in by hand are mixed in there, and a wholesale replacement quietly erases them.

```
project-structure.md
  − packages/shared/       (in the card but not on disk — removed?)
  + src/features/billing/  (on disk but not in the card)
  ~ paths: "src/**"        (the real source is app/ — the card is in a state where it never loads)
```

The "Layers" measurement from Step 2 goes into the **"dependency direction" section** of `project-structure.md`.
If no direction is observed, write "flat — not applicable" — do not erect layers in the card
that do not exist. If that section is empty, `orangekit-reviewer`'s reverse-import comparison stays
undecidable.

**Always confirm** that `paths:` covers the real source paths. If it does not, that card has never once
been loaded, and that is the first fact to report.

**Do not put** an `orangekit-rule-version` stamp in these two cards (that marks them as project-owned).

### The third comparison target — `repoTopology` in `orangekit.config.json`

`/orangekit-init` asks for the topology once, **when the project is at its smallest**, and records it. Nothing looks at
that value again afterwards, so as the repository grows the declaration and reality diverge. **The measurement beats the declaration.**

| Measured | Declared | What to do |
| --- | --- | --- |
| No `packages/` · `services/` · `apps/` | `single` | Matches |
| Two or more workspaces under `packages/` | `single` | Drift — propose promotion to `monorepo` |
| Services split across `services/` · `apps/` | `single` · `monorepo` | Drift — propose `msa` |
| Field absent | — | Unset — report only. Do not fill it in by guessing |

**The consequence comes before the value.** If they diverge, look at `paths:` in `project-structure.md` too —
if the new workspace paths (`packages/**` and the like) are not there, **that card has never once been
loaded over the new code.** Shared packages are exactly where `reversibility.md` classifies **Costly**,
so a card that never comes up means the code has been edited without the basis for the reversibility judgement.
Report this fact before updating the config value.

## Step 4: Pin down the verification path

Measure the build, test, and lint commands and **run each once** to prove it exists.
"It is written in the scripts" is not "it works".

Report any difference from `techStack.commands` in `orangekit.config.json` — the `build-gate` hook reads
`build` and `test` from there and runs them at end of turn (`scripts/build-gate.sh:85-86`). A mismatch means the hook is
running the wrong command, or the value is empty and it passes every time as "undecidable".

## Step 5: Report

```
Repository survey — <branch> @ <commit>

Harness inventory: <list of consumer-owned files — not modified>
Stack: <measured values. Anything unconfirmed is "unconfirmed">
Architecture: <6 items, each backed by a path>
Danger zones: <paths at Costly or worse>
Verification path: <commands + run results>

Card drift: project-structure <matches|N items> · code-conventions <matches|N items>
Topology: declared <value|unset> · measured <value> — <matches|mismatch: N paths not covered>
```

If there is one or more drift item, end with: `Update N cards? (you can choose item by item)`

## Ceiling

The architecture description is **at most three representative paths per layer**. Do not list every file —
there is no reason for a skill to stand in for `ls`, and a listing is not a description.
If the repository is too large to cover in one pass, fill in **the danger zones first** and state what is left uncovered.
