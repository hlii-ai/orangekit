---
name: orangekit-migrate
description: Converts a project running the ORANGEKIT Devkit v2 harness to v3. Removes dead hooks, rearranges the rules into three tiers, and renames the agents. Use when the user asks for a "harness migration", "v3 conversion", or "orangekit upgrade"; manual invocation only.
disable-model-invocation: true
---

<!-- orangekit-doctor: allow-stale-refs
     This document lists, by name, the files to remove from v2.
     Those paths are supposed to not exist, so exclude them from the dangling check. -->

# /orangekit-migrate — v2 → v3 migration

## Purpose

Converts a project running the v2 harness to the v3 structure.

**Why it is needed**: v2 placed rules directly in the project's `.claude/`, and 10 of its 11 hooks
were silently dead from path-calculation errors and output-format mismatches. v3 moves those assets
into plugin ownership so they update automatically, and removes the dead hooks.

## Step 1: Diagnose the current state

**Measure** what is there first. Do not delete on a guess.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --default
```

Then check the project-side assets:

```bash
ls -1 .claude/rules/ 2>/dev/null
ls -1 .claude/hooks/ 2>/dev/null
ls -1 .claude/agents/ 2>/dev/null
grep -c 'hooks' .claude/settings.json 2>/dev/null
```

## Step 2: What to remove (replaced or retired by v3)

### Dead hooks — `.claude/hooks/`

The hooks below **did not work in v2 because of path-calculation errors**, or emitted an invalid output format.
v3's five hooks are supplied automatically by the plugin, so the project copies are removed.

| File | Reason for removal |
| --- | --- |
| `session-start-validator.sh` | Miscalculated root → integer comparison collapsed. Replaced by `session-brief` |
| `stop-guard.sh` | Emitted `decision`/`reason`, which Stop does not support → never blocked once. Replaced by `build-gate` |
| `pre-compact-saver.sh` | PreCompact plain-text stdout never reaches the context → ineffective. Replaced by `handoff` |
| `post-tool-use-*.sh` (three of them) | Scanned all of `/tmp` on every tool call. The consumer was removed too, so they are pointless |
| `pre-tool-use-guard.sh` | Did not fire, because the absolute/relative path regexes did not match |
| `stop-trace-summary.sh` | Disabled by default + its consuming log was removed |
| `persistent-loop.sh` · `loop-keyword-detector.sh` | Duplicates the native `/loop` and the `ralph-loop` plugin |

**Remove those hooks' registrations from `.claude/settings.json` as well**. The plugin manages them through `hooks/hooks.json`.

> `security-check.sh` was the one hook in v2 that actually worked. If there is a project copy you
> may remove it (the plugin supplies one), but **if project-specific secret patterns have been added,
> show those patterns to the user and get confirmation first.**

### Retired rules — `.claude/rules/`

| File | What happens to it |
| --- | --- |
| `task-workflow.md` · `task-workflow-detail.md` | → verification intensity moves to `reversibility.md`, and **Phase routing (P0-P6) moves to `.claude/rules/workflow-routing.md` (an always-on card)**. Only the S/M/L sizing judgement is retired |
| `modification-guardrails.md` | → split into `code-change.md` + `harness-change.md` |
| `self-improvement.md` | → `lessons.md` (the Act loop is performed by `doctor --lessons`) |
| `agent-governance.md` | → deleted. The norms moved into the agent prompts |
| `decision-autopilot.md` · `-detail.md` | → deleted. Only the core survives, condensed into the T0 operating rules |
| `claude-md-authoring.md` | → deleted |
| `execution-transparency.md` | → deleted |

**Before removing anything**: check each file for content the project added itself, and
if there is any, show it to the user and confirm where it should go. Promoted rules may have accumulated here.

### Old agents — `.claude/agents/`

`planning-agent.md` · `review-agent.md` → replaced by the plugin's `orangekit-planner` · `orangekit-reviewer`.
Remove the project copies if they exist.

## Step 3: Install the v3 rules

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-rules.sh"
```

Check after installing:

```bash
ls -1 .claude/rules/
```

## Step 4: What to keep (do not touch)

- `.claude/rules/code-conventions.md` · `project-structure.md` — project-specific
- Any domain rules under `.claude/rules/` the project wrote itself
- `.claude/skills/` project overrides
- All of `dev/` (work documents · PRDs · archive)
- `docs/lessons.md`
- `CLAUDE.md` — but see Step 5 below

## Step 5: Clean up CLAUDE.md

A v2 CLAUDE.md very likely references files that have been deleted.

1. References to `.claude/rules/task-workflow.md` → remove (the operating rules are injected automatically at session start)
2. **Keep the P0-P6 Phase table**, but update it against the Phase table in the installed
   `.claude/rules/workflow-routing.md` — the call targets changed from `planning-agent`/`review-agent` to
   `orangekit-planner`/`orangekit-reviewer`, and the intensity of P5 is set by the reversibility class
3. The S/M/L sizing table → remove (the reversibility class replaces it)
4. Remove every link that points at a file that no longer exists

## Step 6: Verification (required)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --default
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" --self-test
```

**If failures are not zero, the migration is not finished.** Report the remaining failures to the user.

## Step 7: Report

```
v3 migration complete

Removed: N hooks · N rules · N agents
Installed: N rule cards in .claude/rules/
Preserved: [list of project-specific assets]

doctor --default: N passed · N warnings · N failures

Needs confirmation:
- [items that required a user decision]
```

## Cautions

- **Always read a file before deleting it**, and if the project added content, get the user's confirmation
- Do not delete everything at once; go category by category and check with `doctor --default` after each step
- Starting from a clean `git status` makes it easy to undo

## After the migration: stack guides

A v2 project has no stack-specific guides. Once the migration is done, tell the user:

- If `orangekit.config.json` has no `techStack.backend` axis, recommend running `/stack-guide-generator`
  (it confirms the backend type, DB, and data access, then generates frontend/backend-guide)
- For the `nextjs` × `supabase` combination the plugin's prebuilt guides cover it, so no generation is needed

## Two-axis preset migration (old single-axis config)

If `techStack.preset` holds an old single-axis name and `techStack.presets` is absent, convert as follows.
Do not delete the old field — `preset` stays as a backward-compatible notation.

| Old `preset` | New `presets` | Notes |
| --- | --- | --- |
| `nextjs-supabase` | `{frontend: "nextjs", backend: "supabase"}` | |
| `react-vite` | `{frontend: "react-vite", backend: "none"}` | The old preset's backend was only a "REST API client" — if there really is an own backend, confirm with the user and correct it to `supabase`/`fastapi` |
| `python-fastapi` | `{frontend: "none", backend: "fastapi"}` | If there is a separate frontend, confirm and correct |
| `blank` | `{frontend: "none", backend: "none"}` | |

Handle these at the same time as the conversion:

- Create `techStack.frontend` and copy the existing top-level `framework` · `language` · `packageManager` ·
  `commands` into it (if the frontend is `none`, copy them into the backend axis instead)
- **Leave the top-level `commands` alone** — it is the project-wide value that build-gate and health-check read
- Update `preset` to the composite notation `"<frontend>+<backend>"`
