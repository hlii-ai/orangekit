---
name: codex-claude-loop
description: A dual-AI loop that cross-verifies code independently with OpenAI Codex. Use when the user has requested or accepted an external-model lens during an Irreversible review, or when the user asks for code-quality verification. Source is sent to an external model, so never run it without prior consent.
---

# Codex-Claude Engineering Loop

A dual-AI quality-assurance loop in which Claude Code implements and Codex verifies.

> Shared workflow (Steps 1/3/4/6, error handling, best practices): see `references/shared-workflow.md`

## Two execution paths, one credential

| Path | Condition | How it runs |
| --- | --- | --- |
| **Plugin mode** (recommended) | The official OpenAI `codex` plugin is installed — `/codex:setup` shows in the skill list | `/codex:review` · `/codex:adversarial-review` |
| **CLI mode** (fallback) | No plugin, only the `codex` CLI | `codex exec -s read-only "…"` |

Both paths use **the same `codex` CLI and the same credentials** (`~/.codex/auth.json`). Authenticate only through codex's
own `codex login` — **this skill stores a key nowhere.**

> **Why not an environment variable** — `export OPENAI_API_KEY` does not survive into the next Bash call (shell state
> is not preserved), a command that writes to `~/.zshrc` is blocked by this harness's `security-check` hook as
> "hardcoded API key", and per the official docs an API key only takes effect once you **log in** with `codex login --with-api-key`.
> All three were confirmed by reproduction (eval v7 · E-45).

## Workflow

### Step 0: Readiness check — three states (same discipline as a guard)

**Plugin mode**: run `/codex:setup`. If `ready: true`, proceed. Otherwise show the user that output's
`nextSteps` (install · `codex login`) verbatim, and if authentication is needed go to "Authentication" below.

**CLI mode**: decide by **running it**, not by its existence — `command -v` misjudges an install where only the wrapper
remains and the binary is gone (ENOENT) as "available".

```bash
codex --version    # exit 0 = runnable. A failure means not installed or not runnable
codex login status # exit 0 = authenticated
```

| Verdict | Action |
| --- | --- |
| Runnable · authenticated | Proceed |
| Runnable · not authenticated | The "Authentication" section |
| Not runnable (not installed · ENOENT) | Run `npm install -g @openai/codex` **after the user confirms**. If they decline, skip |
| **Undecidable** (offline · timeout) | **Do not block.** State the reason and skip this skill — record in the review report that you proceeded without cross-verification |

### Authentication — use `codex login` only

Pick the method with **a single** `AskUserQuestion`.

| Method | Command | Notes |
| --- | --- | --- |
| ChatGPT account (Recommended) | The user runs `codex login` in a terminal (opens a browser) · if that is blocked, `codex login --device-auth` | No key typed |
| OpenAI API key | Take the key and run `printf '%s' "<key>" \| codex login --with-api-key` | codex keeps it in `~/.codex/auth.json` |

- After applying it, **re-check with `codex login status`**. Do not proceed unless it exits 0.
- If you take an API key in conversation, **that key stays in the transcript** — say so before they type it, and recommend rotating it afterwards.
- Do not write a key into `~/.zshrc` · `.env` · `orangekit.config.json` · `settings.json`.

### Step 0.5: Consent to external transmission — never skipped

This skill **sends code outside the repository.** Before running, show what leaves and get consent.

| What is sent | Scope | Notes |
| --- | --- | --- |
| Plan review (Step 2) | Plan text only | No source included |
| Code review · re-verification | **The `git diff` output** | The whole tree is not sent — limited to the diff |

- Even when the user invoked it directly, **state the transmission scope**. `orangekit-reviewer` only
  **proposes** this skill and never runs it — running it always follows the user's acceptance
- Stop if secrets or credentials appear in the diff (the `security-check` hook only watches file writes —
  it does not watch external transmission)

### Steps 1-4: shared workflow

Follow Steps 1, 3, and 4 of `references/shared-workflow.md`.

### Step 2: Plan review (Codex)

**Plugin mode**: hand the plan text to `/codex:rescue`, stating explicitly that this is a **read-only review**
(rescue defaults to write-enabled — asking only for review/diagnosis makes it run read-only)

**CLI mode**:

```bash
codex exec -s read-only "Review the following implementation plan and identify its problems:

[Claude's plan]

Review for:
- logic errors
- missing edge cases
- architectural flaws
- security concerns"
```

**Do not pin a model** — use Codex's default. Use `-m <model>` only when the user asks.

### Step 5: Cross review (Codex)

**Plugin mode**:

- `/codex:review` — standard code review (working tree or `--base <ref>`)
- `/codex:adversarial-review` — a review that also doubts the implementation approach and design premises
- Asynchronous: check progress with `/codex:status`, fetch the result with `/codex:result`

**CLI mode**:

```bash
codex exec -s read-only "Review the following code changes:

$(git diff)

Review for:
- bugs
- performance issues
- adherence to best practices
- security vulnerabilities"
```

**Hand Codex's result to `receiving-code-review`** — do not accept it blindly; verify it against the actual
code before adopting. Fix Critical immediately, discuss architectural changes with the user, document the decisions.

## Command reference

### Plugin mode

| Command                     | Purpose                                    |
| --------------------------- | ------------------------------------------ |
| `/codex:setup`              | Install/auth readiness check (`ready`)     |
| `/codex:review`             | Standard code review                       |
| `/codex:adversarial-review` | Questions design decisions + risk analysis |
| `/codex:rescue`             | Delegate investigation/fix work to Codex   |
| `/codex:status`             | Check background job progress              |
| `/codex:result`             | Fetch the result of a finished job         |
| `/codex:cancel`             | Cancel an active background job            |

### CLI mode

| Stage       | Command pattern                                                     | Purpose                           |
| ----------- | ------------------------------------------------------------------- | --------------------------------- |
| Readiness   | `codex --version && codex login status`                             | Runnable · authenticated          |
| Auth        | `codex login` · `printf '%s' "<key>" \| codex login --with-api-key` | ChatGPT · API key                 |
| Plan review | `codex exec -s read-only "Review this plan: [plan]"`                | Check logic before implementing   |
| Code review | `codex exec -s read-only "Review: $(git diff)"`                     | Codex verifies the implementation |
| Re-verify   | `codex exec -s read-only "Confirm the fix: $(git diff)"`            | Re-check after the fix            |

### Key CLI flags

| Flag           | Use                                              |
| -------------- | ------------------------------------------------ |
| `-s read-only` | Read-only sandbox (the default for verification) |
| `-m <model>`   | Pick a model — only when the user asks for it    |
| `--json`       | JSON output (for pipeline integration)           |
| `-o <path>`    | Write the result to a file                       |
