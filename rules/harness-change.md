---
paths:
  - ".claude/**"
  - "scripts/**"
  - "hooks/**"
---
<!-- orangekit-rule-version: 3.29.0 -->
<!--
  paths fires **only in a consumer project** (the plugin repository has no .claude/rules/).
  So the list holds only paths that are true in the consumer layout — the consumer's .claude/ assets·hooks·scripts·
  harness documents. Putting rules/·skills/·guides/·templates/·presets/·docs/·
  marketing/·harness/·workflow.graph.json — which exist only in the plugin repository — here makes this card
  spin uselessly and eat 4,000 tokens every time a consumer edits **their own** docs or skills. Reach inside this repository is handled by the table in CLAUDE.md.
-->

# Harness Change Card

Loaded when you touch a hook·rule·skill·agent·script.

> **Path notation** — `<plugin-root>/…` is an asset the plugin shipped (the absolute path is on the
> "self-test" line of every session briefing). `.claude/…` is project-owned. This card is loaded in
> **both** the plugin repository and consumer projects, so never write a relative path that is true
> in only one of them — that is the deployment-context falsehood "Post-Change Back-Trace" below warns about.

> **The core: what a Script can do goes to a Script, what only an LLM can do goes to the LLM.**

## Three Questions Before Adding

| # | Question | If YES |
| --- | --- | --- |
| Q1 | Does it overlap in role with an existing hook/rule/skill/**Claude Code built-in** | **Stop** — extend the existing one, use the built-in, or thinly layer only the missing part on top of the built-in (composition) |
| Q2 | Is it unnecessary now that model capability has improved | **Stop** |
| Q3 | Are you changing something that already works well for no real reason | **Stop** |

Actually check the "built-in" in Q1. `/code-review`, `/simplify`, `/security-review`,
`skill-creator`, `/init`, `/run`, `/loop` are provided by Claude Code. **Do not build assets that
compete with them.**

**Built-ins keep getting better along with the model.** So this comparison is not asked once and done —
throw it again every time you touch an asset.
There are three verdicts: **replace with the native one · keep the custom one · compose.** Pick the third and the custom part must be
**a thin layer wrapping** the built-in; it must not reimplement what the built-in already does.

## Priority of Solution Means

```
1. Edit an existing document (add 1~3 lines)   ← most preferred
2. Extend existing hook logic
3. Add a feature to an existing script
4. Write a new script                          ← last resort
```

## Verify Platform Behavior Before Asserting It

Before assuming "Claude Code behaves like this", **read `<plugin-root>/docs/platform-contract.md`**
(substitution variables · component auto-discovery · `.claude/rules/` loading · per-event output specs · subagents).
If it is not there, **check the official documentation and add it with the source URL and the date checked.** Do not assert from memory.

> Without this discipline, home-made variable notations that never get substituted grew to 28 places, and
> not knowing `.claude/rules/` was a native feature, work routing was put somewhere with no update path.

## A Guard Has Three States — do not fold undecidable into block

| State | Action |
| --- | --- |
| Violation confirmed | Block |
| No violation confirmed | Pass |
| **Undecidable** (a dependency tool is missing · no input · offline) | **Do not block.** Report explicitly that it is undecidable, and pass |

Folding undecidable into block produces a false positive, and **a false positive makes the user switch the hook off,
and a hook that is off blocks nothing.** Do not assert absence, and do not assert presence.
(Precedent: `UNDECIDABLE` in `<plugin-root>/scripts/build-gate.sh` ·
`<plugin-root>/scripts/guide-freshness.sh --offline`)

**Decide an exemption by the first token — never exempt by substring match (`*x*`).** An exception in a guard opens on
"what does this command run" (the first token·subcommand), and when a command is chained with a connector (`;` `&&` `||`),
each segment is judged separately. An exemption that passed anything with `doctor.sh` somewhere in the command let
`…doctor.sh …; psql -c "DROP TABLE"` through whole (evaluation v6 · E-21) — an exemption must be proven by a fixture
as strongly as the blocking point itself (a bypass-attempt fixture → exit 2).

## Preventing Silent Failure (mandatory)

If you created or changed a hook·script, **actually run the following**. No skipping.

1. source `<plugin-root>/scripts/lib/common.sh` and start with `orangekit_begin`
   (for your own hook outside the plugin, do not depend on this lib — implement the same discipline yourself:
   exit 2 when the root cannot be resolved, numeric validation, per-event output specs)
   — get the root only through `orangekit_root()`. `BASH_SOURCE`, `dirname ../..` are **forbidden**
   — put numbers through `orangekit_num()`. `|| echo 0` is **forbidden**
2. Emit output only through `orangekit_emit_context` / `orangekit_emit_block`
   — the supported fields differ per event. An unsupported field is **silently ignored**
   — Stop does not support `decision`/`reason` (use `continue`+`systemMessage`)
   — for PreCompact/SessionEnd, plain stdout does not enter the context (JSON is required)
3. `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/doctor.sh" --default` + `--self-test` → confirm they pass

## Two Lines of Intervention Rationale — an intervention with no re-run evidence is unfinished

If you added or changed an intervention (hook·rule·skill·briefing, whichever), write two lines in the commit message or the PR.

| Line | Content |
| --- | --- |
| (a) | **The failure you are blocking** — observed repeating two or more times |
| (b) | **The risk of breaking something that worked** |

If you cannot write (a), it is a hypothesis, not a pattern — do not add it.
Do not hardcode the right answer for an individual case. Keep only interventions that get reused in the next task as well.

And `--self-test` must pass. **A plausible fix and an effective fix are different things,
and only the re-run separates them.** Apply the "prove the block" discipline above not only to guards but to
every intervention.

## Reach Path Verification

When you add a rule·checking device, immediately confirm **that the file really loads at the intended moment**.

- For `paths:` conditional loading, does the target file's paths include the actual edit path
- Does the session briefing's "hooks n/n OK" actually report that number — registration alone is not life

## Post-Change Back-Trace — look at the side of the name that vanished

Where the previous section asks **whether the new name reaches**, this one looks at **the things that pointed at the old name**.
Renaming·moving·deleting are one kind of event. A renamed asset sits neatly under its new name, so it
**always passes "Reach Path Verification"** — the leftovers stay on the vanished name's side, and with no check looking there
they are never caught. ("Post-Change Back-Trace"·"Propagating the Same Pattern" in `code-change.md` are the app-code counterpart.)

1. **Fix the list of vanishing names first.** Do not pull it from memory —
   `git diff --diff-filter=RD --name-only` and the filenames in `.claude/deprecated/` are the source of the list.
   Leave a placeholder (`<the things we retired>`) and whoever fills it in misses one, and a missed name is the same as having no check at all
2. **Sweep the whole repository.** Not only `.claude/` but the entire repository —
   `README.md`·`docs/`·`dev/` are where things get left out
3. **Confirm zero hits with a command.** Writing "checked everything" on a checklist is not evidence

> **The command is the fact; the sentence is not.** Measured: the completion condition for port Phase 4 said "references to the old
> name are zero across **the whole repository**", but the command that actually ran looked only at `.claude/` and `CLAUDE.md`.
> `dev/`, present in the instruction, was missing from the verification command, and that is exactly where the old name survived.

## Deciding an Asset Is Absent — a three-location search

To declare that an Agent·Skill·Hook·plugin "does not exist", check **all three** places:

1. The project-local `.claude/`
2. The plugin cache `~/.claude/plugins/cache/`
3. The marketplace `~/.claude/plugins/marketplaces/`

Do not conclude "absent" after looking at one. Especially not before creating a new asset on the strength of that absence.

## Retirement Protocol — shadow mirror

When retiring a **consumer project's** `.claude/` asset (a rule·skill·hook customization), do not delete it right away.
Move it to `.claude/deprecated/` and stamp the expiry date into the filename (default 14 days):

```
.claude/skills/foo/SKILL.md → .claude/deprecated/skills_foo_SKILL.md.shadow-expires-2026-09-03
```

If nothing breaks before expiry, confirm the deletion; if something breaks, restore it in place (rollback).
Expired ones are reported by `doctor --lessons`. A retirement decision always goes through user approval.

## The Agent Exception

Agents do not inherit `.claude/rules/`. Norms an agent needs are written
**directly into that agent's prompt**. Do not try to substitute a rule file for that.
But do not let two places assert the same norm — one place is the original and the other is a quotation.
