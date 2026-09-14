---
name: execution-dashboard
description: Use when you want to see which skills, rules, and hooks were referenced during this session. Presents a timeline plus a per-category summary. Triggered by keywords such as "execution trace", "execution flow", "what did you reference?", "which skills did you use?". manual invocation only.
disable-model-invocation: true
---

# Execution Dashboard

Tracks the Skills/Rules/Hooks/Agents/documents used in the current session and produces a timeline plus a per-category summary report.

## Workflow

### Step 0: Pull in the instrumentation logs (deterministic data)

Read the `.claude/.orangekit/` logs the v3 hooks recorded to get exact execution data:

| Log | Written by | Content |
| --- | --- | --- |
| `.claude/.orangekit/skilluse.log` | track-skill (PostToolUse) | Skill invocations |
| `.claude/.orangekit/hookrun.log` | Every hook (common.sh) | Hook runs · exit codes |
| `.claude/.orangekit/graph.log` | Hooks (orangekit_edge) | Graph edge traversal |

```bash
tail -200 .claude/.orangekit/skilluse.log .claude/.orangekit/hookrun.log .claude/.orangekit/graph.log 2>/dev/null
```

### Step 1: Analyze the session (semantic data)

Read the conversation backwards and extract Skill invocations, Rule references, Hook runs, Agent calls, and document lookups.

**Mark the source on every item** — mixing what came from the logs (`instrumented`) with what was inferred from the conversation (`inferred`)
makes this report unusable as evidence. When the two disagree, the instrumentation wins.

### Step 2: Build the timeline

One line per event, in time order. Items with a log entry take their places first; inferred items are slotted in between.

```
| Time | Kind | Name | Result | Source |
| --- | --- | --- | --- | --- |
| 14:02 | Hook | session-brief | exit 0 | instrumented |
| 14:03 | Skill | codebase-survey | done | instrumented |
| 14:11 | Rule | code-change.md | referenced | inferred |
```

If the time is unknown, leave `--` and keep only the order — **do not invent a time.**

### Step 3: Per-category summary

Fold into five groups: Skill · Rule · Hook · Agent · documents.

```
| Category | Calls | Items (in call order) |
| --- | --- | --- |
| Skill | 2 | codebase-survey · completion-review |
| Hook | 5 | session-brief ×1 · build-gate ×3 · track-skill ×1 |
| Rule | 3 | workflow-routing · code-change · reversibility |
| Agent | 0 | — |
| Documents | 4 | CLAUDE.md · docs/harness-anatomy.md … |
```

Do not drop a category with zero calls; leave it as `0 | —` — **the absence is itself an observation.**

### Step 4: Output

Present the two tables in this order: **summary table first, timeline second.** Then one paragraph
on what stands out (for example: "3 of the 5 hook runs were build-gate — source changed often").

If there are no instrumentation logs and everything is inferred, **say so on the report's first line.**

## Cautions

- If the conversation is long, analyze only the most recent 50 messages
- Do not infer information that is not in a system reminder — omit it instead
- If the `.claude/.orangekit/` logs are missing, skip Step 0 and analyze the conversation only (state in the report that the data is inferred)
