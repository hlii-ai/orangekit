<!-- orangekit-rule-version: 3.28.0 -->
<!--
  A harness-authoring-only card. It is what was split out of `rules/harness-change.md` (the consumer card)
  as **the parts a consumer cannot execute** — a consumer owns neither workflow.graph.json, nor orangekit-init's
  install steps, nor the preset branches, nor the plugin repository. Leaving those in the consumer card means
  they read unexecutable instructions every time they fix a hook in their own project.

  This file is not installed into `.claude/rules/` (install-rules.sh looks only at rules/*.md).
  Reach inside this repository is handled by the "Read before you work" table in CLAUDE.md.
-->

# Harness Authoring Card — **only when building** the plugin

Read the consumer card (`rules/harness-change.md`) first. The three questions · priority of solution means ·
the three-state guard · preventing silent failure 1–3 · the two lines of intervention rationale · the
three-location search for asset absence · the retirement protocol are canonical there. **Do not copy them here.** This card holds only what is added on top.

## Re-deciding on built-ins is periodic

Q1 of the consumer card's "Three Questions Before Adding" is not asked once and done —
**P6-② of `/harness-evaluation` asks it again periodically** (skipped only when the previous decision is within 30 days **and**
there have been 0 harness asset commits since — never skipped on the date alone).

## Preventing silent failure — the fourth item

On top of 1–3 in the consumer card (common.sh · emit format · doctor passes):

4. If you registered it in hooks.json, add the node and edges to `workflow.graph.json` too
   — add `phase` if the node is caught by a Phase in the routing card, and if it leaves a file, add `produces`
   and the edge that reads that artifact as well (doctor --graph compares them)

## Reach path verification — the plugin items

On top of the consumer card's `paths:` check:

- If the asset goes into the plugin, **is it a component type Claude Code supports**
  (`skills`/`commands`/`agents`/`hooks`/`mcpServers`/`outputStyles`/`lspServers` — **there is no `rules`**)
- If the file must exist in the project, does `orangekit-init` have an install step for it
- **If there is a preset/stack branch, does it reach under every combination** — do not put a universal norm
  inside one preset-only skill (the T1 card is the universal distribution vehicle). Shipping copies is a drift
  source and therefore the last resort — prefer a single canonical source plus references

> In v2, 697 lines of rules reached no project for 4 months. The cause was the absence of this verification.

## Post-change back-trace — the shipping context

**A sentence that was true in the original context becomes false in the shipping context.** Preset markers, your own project name,
and consumer layout paths are that class — it was not written wrong; it was written right and became wrong by moving, so
the sentence itself reads naturally and no human eye catches it. **If you brought an asset over from another repository, re-read its body.**
The "port leftovers" section of `doctor --fast` looks on your behalf at the three of these a machine can decide (a skill name in a consumer path ·
a leaked repository name · **a plugin-context path in a rule card body**).

## Retirement — the plugin repository does not use shadows

However, **assets of the plugin repository itself** are deleted without a shadow, because git guarantees the rollback —
shadows are for consumer-project customizations, which have no rollback reminder.

## There are three skill roots — where you put it is who receives it

| root | plugin | who receives it |
| --- | --- | --- |
| `skills/` | `orangekit-product` | **consumers** — install it and every one of them shows up in the command list |
| `marketing/skills/` | `orangekit-marketing` | marketing workers (independent version) |
| `harness/skills/` | `orangekit-harness` | **only the people who build this plugin** (independent version) |

When creating a new skill, **the first thing you settle is not the name but the root.**
There is one test: **does this skill have anything to do in a consumer project.** If not, it belongs in `harness/skills/`.

**There are two costs and they are independent — `disable-model-invocation` turns off only one of them.**

| cost | when it applies | with `dmi: true` |
| --- | --- | --- |
| description residency (tokens every session) | when the model can invoke it | **becomes 0** |
| one line in the command list | as long as it sits in `skills/` | **stays as it is** |

So attaching `dmi` does not make it acceptable to keep it in `skills/`. `harness-evaluation` is that case —
residency is 0, but sitting in `skills/` means a consumer **sees `/harness-evaluation`, presses it, and fails**
(that skill exits 2 with "nothing to evaluate" when `scripts/doctor.sh` is absent).
**Not handing people a command they cannot use** is the reason for this separation, not the budget.

`doctor`'s hygiene checks look at all three — a separation that creates a blind spot for the checks is not an improvement.
Conversely, the description budget and the "declaration ↔ reality" skill count count only `skills/`.
