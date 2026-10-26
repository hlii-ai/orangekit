# Operations manual — for the people who fix and maintain the harness

This repository is **the source of a Claude Code plugin**. It is not a consumer project.
`rules/` is an asset to be distributed to consumers, not configuration that is auto-loaded here.

## The boundary of this document — where to find what

**Canonical sources are not transcribed here.** Copies are a source of drift. This document holds only
**"what to do in what order when this happens"**, and points at the original for the decision criteria.

| What you want to know | Where |
| --- | --- |
| **what to do when this happens** (procedures · runbooks) | **this document** |
| **why** this device looks like this (design rationale) | [harness-anatomy.md](harness-anatomy.md) — 1,232 lines |
| the **norms** for fixing the harness (what to obey) | `rules/harness-change.md` — a T1 card |
| what Claude Code **guarantees** (the platform contract) | [platform-contract.md](platform-contract.md) |
| is anything **actually out of line right now** | `scripts/doctor.sh` — a machine decision |
| how do **users** use this | [user-manual.md](user-manual.md) |
| what did we **get wrong** in the past | `docs/lessons.md` · [lessons-archive.md](lessons-archive.md) |

> **Reading order (a new administrator)** — ① `rules/harness-change.md` (the norms) → ② §1~§2 of this
> document (the parts and the procedures) → ③ `doctor.sh --help` (the diagnostic tool) → ④ `docs/lessons.md`
> (past failures) → ⑤ the relevant section of `harness-anatomy.md` when you need it. **Do not skip ④** — most of
> the failures recorded there are "fixes that looked plausible and had no effect".

---

## 1. The 5 parts and their ownership — what is affected when you fix what

| Part | Where it lives | Count | Owner | What comes with fixing it |
| --- | --- | --- | --- | --- |
| **Hooks** | `hooks/hooks.json` + `scripts/*.sh` | 5 | plugin | sourcing `common.sh` · per-event output format · fixtures · graph nodes |
| **Rule cards** | `rules/*.md` | 9 T1 cards | plugin → consumer `.claude/rules/` | `paths:` reach · version stamp · line budget |
| **Operating contract (T0)** | `templates/operating-contract.md` | a 42-line budget | plugin | injected every session, always — **the most expensive seat** |
| **Skills** | `skills/*/SKILL.md` | 26 | plugin | description budget (12,000 bytes) · graph declaration |
| **Agents** | `agents/*.md` | 2 | plugin | **does not inherit `.claude/rules/`** — norms go directly into the prompt |
| **Graph** | `workflow.graph.json` | 49 nodes · 90 edges | plugin | the declaration of every asset. doctor `--graph` cross-checks it |

### Load time is cost

| Tier | When it loads | Cost |
| --- | --- | --- |
| **T0** operating contract | every session, always | the full amount every session — the 42-line budget comes from here |
| **T1 always on** `workflow-routing.md` | every session, always | ditto — **it must not be given a `paths:`** (it turns conditional and is absent exactly when needed) |
| **T1 conditional** the other 8 cards | when a path matches | only in that piece of work |
| **skill descriptions** | always (the body on invocation) | the total across 26 is what is budgeted |

> 🔑 **The key judgement** — where a new norm goes is decided by "when is it needed". Needed before a file is
> opened → always on; needed when a particular file is touched → conditional. **Get it wrong and it does not
> arrive at all** — that is why 697 lines of rules in v2 reached no project for four months.

### Only two assets leave the machine (one was added on 2026-09-12)

Every other skill finishes locally. **Only these two cross the boundary, and both have prior consent as a precondition.**

| Asset | What leaves | Cost | Consent |
| --- | --- | --- | --- |
| `/codex-claude-loop` | the plan text or a `git diff` (**not the whole tree**) | within the subscription | every time — it is not recorded |
| `/image-generator` | **the image prompt only** (not source) | **billed separately from the subscription** | **once per project** → `assets.imageProvider` in `orangekit.config.json` |

`/image-generator` is **the harness's first paid external call.** So it keeps three things:

1. **It shows the unit price as a number first and lets you choose** — "you will be billed" is not enough to decide on
2. **It verifies dimensions, quality and format before the call** — so that bad input does not cost money
3. **After the call it reports the response's `usage` verbatim** — the measurement, not the estimate, is the basis of the bill

**The key is not stored anywhere.** Only the environment variable `OPENAI_API_KEY` is read —
write it into `.env`, `orangekit.config.json` or a shell config and this harness's own `security-check` blocks it.
With no key it is **undecidable (exit 2), not a block** — it drops into handoff mode and produces a prompt a
person can use (invariant ①).

---

## 2. Runbooks — procedures by scenario

### 2.1 I want to add an asset

**You must pass the 3 questions first.** A YES to any one of them means stop.

| # | Question | If YES |
| --- | --- | --- |
| Q1 | Does it overlap in role with an existing hook/rule/skill or with a **Claude Code built-in** | extend the existing one, use the built-in, or add a thin layer over the built-in for only what is missing (**compose**) |
| Q2 | Is it now unnecessary because the model got better | stop |
| Q3 | Are you changing something that worked fine for no good reason | stop |

**The "built-in" in Q1 is actually checked.** `/code-review` · `/simplify` · `/security-review` ·
`skill-creator` · `/init` · `/run` · `/loop` are provided by Claude Code. **Do not build an asset that competes
with them.** There are only three decisions — **replace with native · keep the custom · compose.**

If it passes, keep the **priority among remedies**:

```
1. edit an existing document (add 1~3 lines)   ← most preferred
2. extend existing hook logic
3. add functionality to an existing script
4. write a new script                          ← last resort
```

Then **always verify the reach path**:

- if it loads conditionally, does `paths:` include the actual edit path
- if it is a plugin asset, is it a **component type Claude Code supports**
  (`skills`/`commands`/`agents`/`hooks`/`mcpServers`/`outputStyles`/`lspServers` — **there is no `rules`**)
- if it is a file that must exist in the project, does `orangekit-init` have an installation step for it
- **does it reach in every preset/stack combination** — a universal norm does not go in a preset-specific skill

Finally, **declare it in the graph**. Without the declaration doctor catches it as an "undeclared skill/hook".

### 2.2 I added or changed an intervention (hook · rule · skill · briefing)

**Write 2 lines in the commit message or PR. No exceptions.**

| Line | Content |
| --- | --- |
| (a) | **the failure being blocked** — observed repeating at least twice |
| (b) | **the risk of ruining something that worked** |

**If you cannot write (a), it is a hypothesis and not a pattern — do not add it.**
Do not hardcode the right answer for one case; keep only interventions that get reused on the next task too.

> 📌 If it is worth adding while not literally satisfying (a), **state that fact in the commit**.
> Writing "decided on a structural gap rather than an observation count" is better than passing over it
> quietly — the next person can then re-evaluate it.

### 2.3 Fixing a rule card

1. Check that the `paths:` frontmatter still fits — too wide and it spins every session, too narrow and it does not reach
2. Set the `<!-- orangekit-rule-version: X.Y.Z -->` stamp to the current version
3. **Do not put a `paths:`** on `workflow-routing.md` (doctor `--fast` fails it)
4. A change in line count → the claim "T0 N lines + T1 M cards L lines" in `README.md` goes stale — doctor cross-checks it
5. **Do not write paths in the plugin repository's frame of reference** into a card body — the consumer does not have those files.
   Use the `<plugin-root>/…` notation

### 2.4 Fixing a skill

- **A description is a resident cost** — a budget of 26 totaling 12,000 bytes. Increase it and every session pays
- The body is loaded only on invocation, so the detail goes in the body
- A skill-only script goes in `skills/<skill>/scripts/` and is invoked with **`${CLAUDE_SKILL_DIR}`**.
  Home-made notation is not substituted and fails on the consumer side (doctor detects it)
- Root `scripts/*.sh` is **for hooks, doctor and installers only**. Put a checking script there and doctor's
  self-lint raises false positives on its regex strings (the illustrated manual generator in `scripts/gen/` is an exception — it is not shell and has nothing to do with consumers)

### 2.5 Fixing a hook — preventing silent failure

**Actually run what is below. It cannot be skipped.**

1. Source `scripts/lib/common.sh` and start with `orangekit_begin`
   - the root only via `orangekit_root()`. `BASH_SOURCE` and `dirname ../..` are **forbidden**
   - numbers pass through `orangekit_num()`. `|| echo 0` is **forbidden**
2. Output only via `orangekit_emit_context` / `orangekit_emit_block`
   - **the supported fields differ per event, and an unsupported field is silently ignored**
   - `Stop` does not support `decision`/`reason` → `continue` + `systemMessage`
   - plain stdout from `PreCompact`/`SessionEnd` does not enter the context → JSON is required
3. Confirm `doctor.sh --default` + `--self-test` pass
4. If you registered it in `hooks.json`, **add the node/edge to `workflow.graph.json` too**

### 2.6 Writing a checking script (something that is not a hook)

**The convention differs from a hook's.**

| Item | Convention |
| --- | --- |
| `common.sh` | **do not source it** — `set -Eeuo pipefail` and the ERR trap conflict with "run every check to the end" |
| instead | **copy** `ok/warn/bad/sec` + `num()` + `--help`=header comment from `doctor.sh` and state `return 0` |
| why `return 0` | the original `bad`/`warn` return 1 when `$2` is empty, so `A && warn || ok` **runs both sides** |
| exit codes | `0` pass · `1` defect · `2` **undecidable** |
| reference implementations | `skills/ui-ux-design/scripts/ui-probe.sh` · `design-sync.sh` |

### 2.7 You built a guard — prove that it blocks

**Alive ≠ working.**

1. Does a fixture with a planted defect **receive exit 1 (or 2)**
2. And does it receive it **for the intended reason** (the reason-string cross-check is built into the self-test)
3. **Prove the exemptions with the same rigour** — is a circumvention-attempt fixture still blocked

> ⚠️ **An exemption is decided on the first token.** Exempt by string containment (`*x*`) and
> `…doctor.sh …; psql -c "DROP TABLE"` passes wholesale (an actual incident). When commands are joined by a
> connector (`;` `&&` `||`), **each segment is decided separately**.

> 📌 **Do not leave a real credential shape in a fixture file.** GitHub push protection will block the push.
> Use the `@@FILL<n>@@` placeholder and let `_fx_fill()` in `doctor.sh` assemble it at run time —
> nothing is left in the file and the block proof loses none of its rigour.

### 2.8 A guard has 3 states

| State | Action |
| --- | --- |
| violation confirmed | block |
| no violation confirmed | pass |
| **undecidable** (no tool · no input · offline) | **do not block**; report explicitly that it is undecidable and pass |

**Fold undecidable into blocking and it becomes a false positive, a false positive makes the user turn the hook
off, and a hook that is off blocks nothing.** Do not assert either absence or presence.

### 2.9 You renamed, moved or deleted an asset — look at the side of the name that is gone

If reach path verification looks at "does the new name arrive", this looks at **"the things that pointed at the
old name"**. A renamed asset sits neatly under its new name and **always passes the reach check** — the residue is
left on the side of the name that is gone.

1. **Settle the list of disappearing names first** — the source is
   `git diff --diff-filter=RD --name-only`, not memory
2. **Sweep the whole repository** — the whole thing, not `.claude/`.
   `README.md` · `docs/` · `guides/` · `dev/docs/` · `workflow.graph.json` are the places that get left out
3. **Confirm 0 hits with a command** — writing "checked exhaustively" is not evidence

> Measured: the completion condition was written as "0 across the whole repository" but the command that was run
> looked at only two places, and the old name was left in exactly the `dev/` that was missed. **The command is the fact; the sentence is not.**

### 2.10 Retiring an asset

| Target | Method |
| --- | --- |
| a `.claude/` customization in a **consumer project** | move it to `.claude/deprecated/` + put an expiry date in the filename (14 days by default). If nothing goes wrong, confirm the deletion; if something does, restore. **A retirement decision always needs user approval** |
| an asset of **this repository** | git guarantees the rollback, so delete without a shadow copy |

### 2.11 Bumping the version — **it is not 4 places but 5 steps**

```
① bump 4 places at once   plugin.json · package.json · the README badge · marketplace.json (2 places)
② commit
③ claude plugin validate .
④ git push origin main
⑤ claude plugin tag --push
```

**Stop at ① and the consumer receives nothing.** Consumers receive a version by tag.

| Caution | Content |
| --- | --- |
| `orangekit-marketing` in `marketing/` | **an independent version** — it is not bumped along with these 4 places |
| `orangekit-harness` in `harness/` | **an independent version** — only harness authors install it, so it is unrelated to a consumer release |
| guide verification on a version bump | **`--regress`** instead of `--self-test` (regression on the shipped assets) |
| if the push is blocked | it may be GitHub push protection — see the fixture caution in §2.7 |

### 2.12 A defect came up / a false positive came up

| Situation | Path |
| --- | --- |
| a user criticized the code, the approach or the workflow | record it in `docs/lessons.md` **immediately** (the format is in `rules/lessons.md`) |
| 3 or more in the same category | **asset promotion** — build the corresponding device and physically move it to `lessons-archive.md` |
| a false positive | always write the `device:` line — `doctor --lessons` counts **by device** |
| 2 or more false positives from the same device | **narrow the condition rather than adding a rule** |
| a general harness review | `/harness-evaluation` → `dev/docs/harness-evaluation/vN.md` — **only in the `orangekit-harness` plugin** (installed only by people who build the harness) |

> 🔁 **Re-evaluating against the built-ins is periodic.** P6-② of `/harness-evaluation` throws
> "is this custom asset still needed" again. It is skipped only when the previous decision is within 30 days
> **and** there have been 0 harness asset commits since — **the date alone is not enough to skip it.**

---

## 3. The diagnostic tool — an index of `doctor.sh` by mode

| Mode | What it answers | When |
| --- | --- | --- |
| `--fast` | structure checks (hook format · rule budget · dangling · manifest · numeric claims) | always |
| `--graph` | graph verification (unreachable nodes · dangling edges · store consumption paths) | when you touched the graph |
| *(no arguments)* | `--fast --graph` | the default |
| `--self-test` | injects **real stdin fixtures** into the hooks and compares the effect | when you touched a hook or a guard |
| `--consumer` | demonstrates the consumer layout (the cache path + running the hooks in an empty project) | when you touched a hook or an installer |
| `--usage` | hook heartbeats · skill invocations · edge traversal | checking the instrumentation |
| `--lessons` | lesson category aggregation + promotion candidates + **contraction candidates from false positives per device** | periodically |
| `--inventory` | an asset inventory by area (no judgement) | the input to `/harness-evaluation` |
| `--all` | all of the above | before a release |

### The mandatory combination after a change

```bash
npm test                            # doctor --default · --self-test · render proof
bash scripts/doctor.sh --consumer   # if you touched a hook or an installer
bash skills/stack-guide-generator/scripts/guide-gate.sh --self-test   # the guide harness
bash skills/stack-guide-generator/scripts/pack-smoke.sh --self-test
bash skills/ui-ux-design/scripts/design-sync.sh --self-test           # token cross-check
```

### The "numbers written by hand" that doctor watches for you

Numbers written by hand into a document **are certain to go stale.** What doctor cross-checks against reality:

- "N nodes · N edges" · "Skills N" · "T1 N cards L lines" in `README.md`
- the graph `kind` table · "N nodes · N edges" · "T0 injects N lines" in `docs/harness-anatomy.md`
- the T0 budget figure (the `T0_BUDGET` constant in `doctor.sh` is canonical)
- the agent `tools:` list ↔ the tables in README and the anatomy document
- the skill pill list in the illustrated manual `docs/manual/user.html` ↔ the **name set** of `skills/`+`harness/skills/` (a set, not a count — both missing and phantom)
- the illustrated manual's "what security-check blocks — N patterns" ↔ the number of block-reason titles in the hook

> 💡 If you added graph nodes or edges, **fix the numbers in README and the anatomy document too.** If you do not,
> doctor `--default` fails. That is a feature.

---

## 4. The 8 invariants that are never broken

| # | Invariant | If broken |
| --- | --- | --- |
| ① | **undecidable ≠ block** | false positive → the user turns the hook off → zero blocking power |
| ② | **do not make a copy** (a single canonical source + references) | drift. The failure mode that killed v2 |
| ③ | **verify the reach path** | declared and reaching nobody (697 lines × 4 months) |
| ④ | **a guard proves that it blocks** (the reason included) | a dead device pretending to be alive |
| ⑤ | **a machine cross-checks the numbers in a document** | a false sentence gets distributed |
| ⑥ | **do not touch what belongs to the consumer without an explicit request** (`AGENTS.md` · `.github/` · `docs/`) | loss of trust |
| ⑦ | **existing code patterns beat the plugin guide** | the harness silently overwrites the project |
| ⑧ | **the project can only raise the safety floor** (reversibility classification · verification duties · secret boundaries) | the safety devices become bypassable |

**⑦ and ⑧ are a pair.** There are two layers and they run in opposite directions:

| Layer | Content | Rule |
| --- | --- | --- |
| **the safety floor** | reversibility classification · verification duties · secret boundaries · decision points | the project can **only raise** it |
| **procedure and form** | stack practices · skill workflows · naming · document format | **the project wins** |

---

## 5. Recurring traps — drawn from `lessons.md`

| Trap | What actually happened | Prevention |
| --- | --- | --- |
| **Putting a universal norm in a preset-specific asset** | 0 reach in other stack combinations | if it is universal, a **T1 card** is the distribution vehicle |
| **Not following the old name after a rename** | a false sentence was distributed for 4.5 months | the back-trace in §2.9 |
| **Declaring a capability in SKILL.md with no implementation** | `web-asset-generator` claimed an "AI mode" for four months with no script, no arguments and no key check anywhere | when you write a feature, write **the invocation path in the same place**, or point at an asset that actually exists. A machine counts the numbers, but **nobody looks at a capability declaration** |
| **Assuming an external capability without an actual call** | 3 web sources agreed, so a plan was built on the belief that "Codex can generate images", and in the smoke test the tool itself was absent | installation check → authentication check → **tool list check** → an actual call. The first three are preconditions for the fourth, not substitutes for it |
| **Deleting a duplicate and deleting the target of a watching check with it** | the check quietly became meaningless | when you delete something, check the checks that were watching it |
| **Measuring with a tool that is not the execution path and stacking a redesign on top** | a plan wrong from its premise | measure **on the execution path** |
| **Using a subagent's measurement without re-verifying it** | a decision on stale grounds | re-verify on the 4 axes of "reference freshness" |
| **The request was to add a case but the plan swelled into a harness redesign** | scope explosion | only what was requested |
| **Counting something that never had a chance as a non-firing** | the first session begins with "the hook is broken" | get the denominator right |

> 📌 **Take an earlier diagnosis or review report as a hint only.** If it says "N Criticals", adopt only
> **what you re-verified one by one against the current canonical source** as still unresolved.

---

## 6. What **cannot** be done in this repository

**Real-world verification cannot be done here.** This repository has no consumer. So **whether the rules
actually reach a consumer project cannot be confirmed here.**

When you verify by installing the plugin into a new project, **always confirm that the T1 cards were actually
installed into `.claude/rules/`** — that one thing is exactly what v2 missed for four months.

| What to confirm | How |
| --- | --- |
| a successful install ≠ an asset arriving | the Skills count in `claude plugin details` |
| rule cards arriving | look at the consumer's `.claude/rules/` with your own eyes |
| hooks actually firing | `doctor --usage` on the consumer |

---

## Appendix — commit conventions

- Commit **only when the user asks**
- End the message with a `Co-Authored-By:` trailer, but **do not hardcode the model name** —
  use the model that actually did the work (the runtime supplies that value)
- If you added or changed an intervention, the **2 lines** of §2.2 must be in the body

## Further reading

- [Harness anatomy](harness-anatomy.md) — the **design rationale** for each device (the companion to this document)
- [Platform contract](platform-contract.md) — what Claude Code guarantees. **Do not assert from memory**
- [User manual](user-manual.md) — how users use this
- [Presets Guide](presets.md) — axis-based guide assembly
- `docs/lessons.md` · [lessons-archive.md](lessons-archive.md) — past failures
