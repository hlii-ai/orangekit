# CLAUDE.md

`orangekit` is the **source repository** of a Claude Code plugin. It is not a consumer project. Do not create `orangekit.config.json`, `dev/active/`, or stack guides here. `rules/` is an asset shipped to consumers, not configuration that loads automatically in this repo — which is exactly why this file exists.

## Read before you work

The files below are canonical. **Do not copy them here** — a copy is a source of drift.

| When | Read |
| --- | --- |
| Touching a hook·rule·skill·agent·script | `rules/harness-change.md` + `harness/rules/harness-authoring.md` |
| Baseline rules for all work | `templates/operating-contract.md` |
| Code changes generally | `rules/code-change.md` |
| Deciding a reversibility class, and the 5 steps | `rules/reversibility.md` |
| Recording a defect or lesson | `rules/lessons.md` |

## Facts specific to this repository

**A version bump touches four places at once** — `plugin.json` · `package.json` · the `README.md` badge · `marketplace.json` (two entries). `doctor` cross-checks them. All four are local files, so **stopping there ships nothing to anyone** — the bump is commit → `claude plugin validate .` → `claude plugin tag --push` → merge to main (`docs/harness-anatomy.md` §08, "a version bump is five steps, not four places"). `orangekit-marketing` under `marketing/` and `orangekit-harness` under `harness/` are **versioned independently and are not bumped with those four** — for different reasons: marketing is about the description budget, the harness is about **not handing consumers a command they cannot run** (`dmi: true` already puts its budget at zero). **For a new skill, decide the root before the name**: if it has nothing to do in a consumer project it belongs in `harness/skills/`, not `skills/`.

**Where scripts go** — a script used by a single skill lives in `skills/<skill>/scripts/` and is invoked through **`${CLAUDE_SKILL_DIR}`** (a home-made variable spelling is not substituted and fails on the consumer side — `doctor` catches it). Root-level `scripts/*.sh` is reserved for hooks, `doctor`, and the **installers** (`install-rules.sh`, `install-guide.sh`); `scripts/gen/` holds the illustrated-manual generators, which are Python and irrelevant to consumers. Putting a skill script at the root means (a) `doctor`'s own lint false-positives on the regex strings inside a checker and (b) it contradicts the two-root premise.

**Shell conventions** — hooks source `scripts/lib/common.sh`. **Checkers do not**: `set -Eeuo pipefail` and an ERR trap conflict with the policy that every check runs to the end. Instead, **copy** `ok/warn/bad/sec` + `num()` + the 0/1/2 exit codes + `--help`-from-header-comment out of `scripts/doctor.sh`, and state `return 0` explicitly (the originals return 1 when `$2` is empty).

**Guides are `guides/` assets, not skills** — because the pre-built unit is an axis (4 frontend · 1 app · 9 backend), not a combination (36). **When you change a pack resource, look at `ledger.md`, `pack.json` and `policies.md` too** — `guide-gate.sh --pack` validates a pack on its own, `pack-smoke.sh` validates that it runs, and the `proof example` and `fixesVariants` columns of the policy table are **mandatory** (FAIL if missing). In a contract (`seams/*/contract.md`), **values go only in lists and table rows**: backticks in running prose are explanation, and a negation written as a list item becomes a requirement on both sides of the wire.

**If you build a guard, prove that it blocks** — check that a fixture with a planted defect gets exit 1, and that it gets it **for the intended reason** (reason matching is built into the self-test). Alive is not the same as working.

**Language** — this repository ships in English: every skill, hook, rule, agent, script, guide and document. What a **user** sees is a separate question: `templates/operating-contract.md` tells the model to reason internally in English but to write user-facing output and produced documents in the user's own language, leaving code, identifiers, commands, machine-readable tokens and standard English technical terms untranslated. Keep that split intact when you edit either side.

## Required after any change

```bash
npm test                            # doctor --default · --self-test · --consumer (proves the consumer layout) · render proof (unverified without playwright)
bash skills/stack-guide-generator/scripts/guide-gate.sh --self-test   # guide harness — add --regress on a version bump (shipped-asset regression)
bash skills/stack-guide-generator/scripts/pack-smoke.sh --self-test
bash skills/ui-ux-design/scripts/design-sync.sh --self-test           # if you touched the token cross-check
```

## Commit

Commit only when the user asks. End the message with a `Co-Authored-By:` trailer, but **do not hard-code a model name here** — use the model that actually did the work (the runtime supplies it).

## Real-world verification cannot happen here

This repository has no consumer, so **you cannot confirm here that a rule reaches a consumer project.** When verifying by installing the plugin into a fresh project, always check that the T1 cards actually landed in `.claude/rules/` — that one thing is precisely what v2 missed for four months.
