# Platform Contract — what Claude Code guarantees

This file is **the canonical source for the platform behavior the harness depends on**. When a rule, skill,
hook, or script assumes "Claude Code behaves this way", that assumption must live here.

> **Why this file exists**
> In v3, platform behavior was declared from memory and defects repeated — 28 sites of self-invented variable
> notation that is never substituted; work routing placed where there is no update path because nobody knew
> `.claude/rules/` was a native feature; the premise, untrue, that "the rules never reached any project".
> All three would have been stopped by a single look at the official docs.

## How to use this file

1. **Look here before claiming anything about platform behavior.**
2. If it is missing, **check the official docs and add it with the source URL and the check date.**
   Hearsay, memory, and "it is probably so" do not go in.
3. If an entry turns out to be wrong, **fix it and refresh the date.**
   `doctor --fast` warns when a check date is more than 180 days old — the platform moves.

---

## 1. Substituted variables

checked: 2026-08-24 · source: https://code.claude.com/docs/en/skills

| variable | value | where |
| --- | --- | --- |
| `${CLAUDE_SKILL_DIR}` | the skill's own directory | personal · project · **plugin** skills alike |
| `${CLAUDE_PLUGIN_ROOT}` | plugin install directory | **in plugin skills only** |
| `${CLAUDE_PROJECT_DIR}` | project root | skills · hook environment variables |
| `${CLAUDE_PLUGIN_DATA}` | plugin data directory | plugin skills |

**There are only two places substitution happens** — (a) a skill's markdown body and (b) the Bash rules in
`allowed-tools` frontmatter. Use the same variable in both and you can run a bundled script with no permission prompt.

> **Self-invented notation substitutes nothing.** Notation like `<skill-dir>` · `<Base directory>` passes in
> this repo because the relative path happens to line up, but in a consumer the skill lives in the plugin
> cache (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/skills/<name>/`),
> so the call fails. `doctor --fast` detects it.

## 2. Plugin component auto-discovery

checked: 2026-08-24 · source: https://code.claude.com/docs/en/plugins-reference

| component | default path | nature of the manifest key |
| --- | --- | --- |
| skills | `skills/` · `commands/` · root `SKILL.md` | **adds to the default** — `"skills": "./skills/"` scans the same place twice (harmless but unnecessary) |
| agents | `agents/` | **replaces the default** |
| commands | `commands/` | **replaces the default** |
| hooks | `hooks/hooks.json` | auto-discovered. **If the manifest points at the same file again it is judged a duplicate and the plugin load is rejected** |

`rules` **is not a plugin component type.** A plugin's `rules/` is not deployed automatically, so
`scripts/install-rules.sh` installs it into the project's `.claude/rules/`.

## 2.4 Skill frontmatter — the switches that set resident cost

checked: 2026-09-02 · source: https://code.claude.com/docs/en/skills

**A description is resident even if the skill is never invoked.** Two fields decide whether it is resident.

| frontmatter | can the user invoke it | can the model invoke it | description resident |
| --- | --- | --- | --- |
| (default) | yes | yes | **resident** |
| `disable-model-invocation: true` | yes | **no** | **not resident** |
| `user-invocable: false` | no | yes | resident |

That is, **put `disable-model-invocation: true` on a manual invocation only skill and the per-session cost becomes 0.**
Without it, the description value stays resident no matter how clearly the body says "manual only" —
**this is where declaration and billing diverge**, and this repo actually did that (5 of them as of v3.24.0).

> **Caution — the estimator in `claude plugin details` does not reflect this flag.**
> Measured (2026-09-03 · v3.25.0): the 5 skills carrying the flag were still counted as always-on at 70–140
> tokens, and that value scaled with description length. Hooks are shown separately as `no model context cost`,
> so it does know how to model a zero cost — this flag alone appears to be missing.
> The table above is the official docs' declaration and the estimator is a projection, so **follow the
> declaration** and do not try to verify the savings with the `details` number. The fact that the two diverge is recorded here.

The trap in the other direction: put this flag on a skill that the routing table (`rules/workflow-routing.md`)
or `phase` in `workflow.graph.json` names for automatic firing and **the model can never invoke it, breaking the routing.**
Check both places before attaching it (`doctor --fast`'s "manual-only agreement" looks on your behalf).

Other fields that affect cost or behavior:

| field | effect |
| --- | --- |
| `description` + `when_to_use` | truncated together at **1,536 characters** (tunable via `skillListingMaxDescChars`). Past that, the tail disappears |
| `paths` | a skill, like a rule card, can be made conditional on a path |
| `context: fork` (+ `agent`, `background`) | runs the skill **in an isolated subagent** — the body and intermediate artifacts never enter the main window |
| `model` · `effort` | model and effort level applied to that skill's turn only |
| `allowed-tools` · `disallowed-tools` | tools allowed/blocked for the duration of that skill's turn |

**The body loads only when invoked, and reference files load only when read** — the official recommendation is
to keep SKILL.md under 500 lines and push detail into neighboring files.

## 2.5 Marketplace — one repo, several plugins

checked: 2026-09-01 · source: https://code.claude.com/docs/en/plugin-marketplaces

A single `marketplace.json` can host **several plugins living in subdirectories of the same
repository**.

| fact | detail |
| --- | --- |
| `source` | a **relative path** beginning with `"./"`. Resolved against the **marketplace root** (= the directory containing `.claude-plugin/`) |
| `../` | **not used** — nothing outside the marketplace root can be referenced |
| sub-plugin manifest | each plugin directory **must have its own `.claude-plugin/plugin.json`** |
| version | **independent** per plugin. It need not match the marketplace's `metadata.version` |

This repo has that shape — `orangekit-product` (`source: "./"`) · `orangekit-marketing`
(`source: "./marketing/"`) · `orangekit-harness` (`source: "./harness/"`) coexist.
**The reasons for separating are not the same — there are two, and they save different things.**

| separation | what it saves | rationale |
| --- | --- | --- |
| `orangekit-marketing` | **context budget** | 3 of the 5 are model-invocable, so their descriptions are resident. Skills unrelated to development eat a development session's budget |
| `orangekit-harness` | **the command list** | `harness-evaluation` is `dmi: true`, so its resident cost is **0** (§2.4). It was still separated because putting it in `skills/` means a consumer **sees and presses a `/harness-evaluation` they cannot use** — outside the source repo it exits 2 with "nothing to evaluate" |

As the table in §2.4 says, `dmi: true` turns off **the resident cost only**. The line in the command list stays,
so attaching `dmi` does not make it acceptable to keep a skill a consumer cannot use in `skills/`.

**One trap that follows** — if `doctor`'s version comparison scrapes **every** `"version"` in `marketplace.json`,
it reads as requiring someone else's plugin version to match our baseline too and **fails as a false positive.**
Narrow the comparison to the entry whose name matches `plugin.json` (`doctor.sh`, "manifest").

## 3. `.claude/rules/` loading

checked: 2026-08-24 · source: https://code.claude.com/docs/en/memory

`.claude/rules/` is **a Claude Code native feature**. It is not a convention the harness invented.

| frontmatter | load time |
| --- | --- |
| **no** `paths:` | **unconditionally at every session start** — same priority as `.claude/CLAUDE.md` |
| `paths:` present | **when Claude reads a matching file**. Not on every tool call |

`paths` is a glob and supports brace expansion. User-level `~/.claude/rules/` loads **before** project
rules (= the project takes precedence).

> The moment you attach `paths:` it becomes conditional. **Norms needed before work starts** (what to build in
> what order; the check right before citing previously written material) are needed at a point where no file has
> been opened yet, so they must not carry `paths`.

## 4. CLAUDE.md loading

checked: 2026-08-24 · source: https://code.claude.com/docs/en/memory

- Loads `CLAUDE.md` · `CLAUDE.local.md` from the working directory and **every directory above it** at startup
- Ones in **subdirectories** load when a file in that directory is read
- Block-level HTML comments are **removed before context injection** (safe for maintainer notes)
- Recommended size under 200 lines. Files over 4 MiB are skipped wholesale
- Delivered **as a user message**, not as a system prompt — it is context, not enforcement.
  Anything that must be blocked is built as a hook

## 5. Output format per hook event

checked: 2026-08-24 · source: https://code.claude.com/docs/en/hooks

**Only three events turn plain stdout into context** —
`SessionStart` · `UserPromptSubmit` · `UserPromptExpansion`.

| event | can block | output |
| --- | --- | --- |
| `SessionStart` | no | **plain stdout becomes context** |
| `PreToolUse` | yes (exit 2) | `hookSpecificOutput.additionalContext` |
| `Stop` / `SubagentStop` | yes | **`decision` and `reason` unsupported.** Use `continue` · `systemMessage` · `additionalContext` |
| `PreCompact` | yes (exit 2) | **plain stdout does not enter the context** → JSON required |
| `SessionEnd` | no | plain stdout is a debug log line |
| `PostToolUse` | — | JSON |

Unsupported fields are **silently ignored.** So "it printed" is not "it was delivered".
`doctor --fast` detects per-event format violations.

### 5.1 Firing frequency — not the format but **when it arrives**

checked: 2026-08-26 · source: https://code.claude.com/docs/en/hooks

| event | when | per session |
| --- | --- | --- |
| `Stop` | **when Claude finishes responding** — the point one user prompt completes | as many as there are prompts |
| `PreToolUse` / `PostToolUse` | per tool call | as many as there are tool calls |
| `SessionStart` | start and resume (`startup`/`resume`) | 1–2 |

> **`Stop` does not arrive per tool call.** Call tools 20 times in one turn and answer at the end, and
> `Stop` fires **once**. This fact was missing from the contract, so evaluation v5 produced a false
> positive — it read `hookrun.log` mid-turn, saw no `build-gate` record, and declared "the Stop hook has
> never once run in real use". In fact that turn simply had not ended,
> and when the turn ended the record landed in the same second.
>
> **A gap in instrumentation has the same shape as a dead hook.** What separates them is "was there an
> opportunity for the event to occur?", and that is answered by **the firing condition**, not by the log.

### 5.3 timeout — the default and the fate of exceeding it

checked: 2026-09-12 · source: https://code.claude.com/docs/en/hooks

The default timeout for a `command` hook is **600 seconds** (`prompt` 30 · `agent` 60. The `UserPromptSubmit`
family drops to 30, and `MessageDisplay` to 10). Lower it per hook with the `"timeout": <seconds>` field.

> Claude Code cancels a `command`, `http`, or `mcp_tool` hook that reaches its `timeout`,
> discarding the hook's output, so on most events a timed-out hook renders no decision.
>
> A timed-out `command` hook doesn't block the tool call. The call continues through the
> normal permission flow, so don't count on a stalled hook to act as a gate.

| fact | implication for this harness |
| --- | --- |
| On timeout the output is **discarded**, with no error shown | a form of silent failure — if a hook slows down, the briefing or the block quietly vanishes |
| A `PreToolUse` timeout **does not block** (fail-open) | if `security-check` exceeds 15 seconds, that call passes unchecked. A gate's strength depends on finishing inside the timeout |
| 600 seconds by default | undeclared, a stalled hook holds a session for 10 minutes — `hooks/hooks.json` declares 10–30 seconds per hook |

## 5.2 The shell that runs hooks on Windows

checked: 2026-09-05 · source: https://code.claude.com/docs/en/hooks · https://code.claude.com/docs/en/setup

Every `command` in `hooks/hooks.json` is a literal string (e.g. `"bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-brief.sh"`).
**What interprets and runs that string** is decided by the `shell` field, and the default varies by OS:

> Defaults to `"bash"`, or to `"powershell"` on Windows when Git Bash isn't installed.

| environment | shell interpreting the hook | fate of the `"bash script.sh"` string |
| --- | --- | --- |
| macOS · Linux · WSL | bash | runs as written |
| native Windows + Git for Windows installed | Git Bash | runs as written |
| native Windows + Git for Windows **absent** | PowerShell | PowerShell tries to find `bash` as an executable, and if it is not on PATH **the hook does not run** |

The install guide states the same conclusion:

> [Git for Windows] enables the Bash tool by providing Git Bash. Without Git for Windows,
> Claude Code runs shell commands via the PowerShell tool.

**Implication for this harness** — all 5 hooks (`session-brief` · `security-check` · `build-gate` · `handoff` ·
`track-skill`) follow the `"bash ..."` pattern. On native Windows without Git for Windows this is not a matter of
**some verification degrading to undecidable**, as with a missing `jq`; **all 5 hooks may never run at all** —
the most severe form of the "quiet disarming" this repo guards against.
(For reference, the Git Bash shipped by Git for Windows includes `grep` · `awk` · `sed` but does not include
`jq` — that needs a separate install.)

Consumer-facing install guidance is handled by `docs/windows-setup.md` and the "If you are on Windows"
callout in the README.

## 6. Subagents

checked: 2026-08-24 · source: https://code.claude.com/docs/en/sub-agents

- The `tools:` frontmatter is an **allowlist**. A tool not in it cannot be used —
  if `Skill` is not in the list, that agent **cannot invoke skills**
- **But an allowlist alone does not block writing.** Measured (2026-09-07 · v3.26.0):
  `orangekit-planner`, declaring only `tools: Read, Grep, Glob, WebSearch, WebFetch`, had
  **Write and Edit as well** at execution time. In the same session `orangekit-reviewer`, which has
  `disallowedTools: Write, Edit, NotebookEdit`, matched its declaration. The cause was not determined — recording the fact without guessing.
  **To block writing for certain, use `disallowedTools` alongside it.** Claim "a violation is impossible because
  the permission is absent" on an allowlist alone and that claim quietly becomes false
- The main conversation's auto memory is not inherited by subagents
- Agents do not inherit `.claude/rules/` → write the norms they need directly into the prompt
