---
name: fix-issue
description: Issue-tracker-driven bug fixing (issue context injected automatically). Use when the user asks to "fix an issue", "fix issue", "fix #123", "resolve issue". Given an issue number, it collects the context automatically via the gh (GitHub) or glab (GitLab) CLI. manual invocation only.
disable-model-invocation: true
---

# Fix Issue

Collects an issue's context automatically and injects it into the bug-fix workflow.

**Host detection** — read `techStack.vcsPlatform` from `orangekit.config.json`. If absent,
check whether `git remote get-url origin` contains `github.com` or `gitlab.com`. If it is still unclear,
ask the user. GitHub has PRs, GitLab has MRs, and **an MR is referenced as `!N`, not `#N`**.

## Workflow

### Step 1: Collect the issue context

Confirm the issue number and collect information with the host's CLI:

```bash
# GitHub
gh issue view <NUMBER> --json title,body,labels,assignees,comments
gh pr list --search "<NUMBER>" --json number,title,state      # related PRs (if any)

# GitLab
glab issue view <NUMBER> --output json
glab mr list --search "<NUMBER>"                              # related MRs (if any)
```

What to extract:

- **Title**: the core summary of the issue
- **Body**: reproduction steps, expected behavior, actual behavior
- **Labels**: bug/feature/priority classification
- **Comments**: additional context, debugging attempts

### Step 2: Work out the reproduction conditions

Identify the following in the issue body:

| Item               | What to extract                         |
| ------------------ | --------------------------------------- |
| Reproduction steps | Steps to Reproduce, or the ordered list |
| Expected behavior  | Expected Behavior                       |
| Actual behavior    | Actual Behavior                         |
| Environment        | Browser, OS, version, and so on         |
| Error message      | Stack trace, console log                |

If the information is insufficient: ask the user to fill the gaps (do not guess).

### Step 3: Find the relevant code

Based on the keywords, error messages, and file paths from the issue:

1. **From the error message**: Grep for the error string
2. **From the domain**: infer the domain from the issue label/title → search that directory
3. **From the stack trace**: read the mentioned file:line directly

### Step 4: Diagnosis — the reproduction loop

The reproduction steps in the issue body are something you **read**, not something you **ran**.
Follow "fixing a bug — the reproduction loop comes before the hypothesis" in `.claude/rules/code-change.md`
exactly (that card is the canonical source for the criteria):

Actually run one command that goes red → minimize it → 3-5 falsifiable hypotheses →
instrument one variable at a time → if there is a proper seam, write the regression test first.

**Stop condition** — if you cannot build the loop, do not fall back on guessing.
Write down what you tried and ask the issue author for a reproduction environment or a captured artifact (HAR · log dump · recording).
Logs pasted into issue comments may contain secrets — mask them as `<REDACTED>` when quoting.

### Step 5: Fix and verify

From here on, follow the normal build (implementation) rules (the code-change card loads automatically on edit):

1. Fix based on the confirmed hypothesis
2. Clean up the code with `/simplify`
3. Verify with `pnpm build && pnpm test` and re-run the Step 4 loop to confirm it is green
4. Confirm every `[DEBUG-` instrument has been removed

### Step 6: Report the result

```
Issue fix report
================

Issue: #<NUMBER> — <title>
Reproduction loop: [the one command actually run]
Root cause: [the confirmed hypothesis — 1-2 lines]

Files changed:
- <file path>: [summary of the change]

Verification:
- Build: [PASS/FAIL]
- Tests: [PASS/FAIL]
```

## When invoked without an issue number

If no issue number is given:

1. Show the list of open bug issues — GitHub: `gh issue list --state open --label bug`,
   GitLab: `glab issue list --state opened --label bug`
   (GitLab's state value is **`opened`**, not `open`)
2. Ask the user to pick an issue
3. Once picked, proceed from Step 1

## Cautions

- The host CLI (`gh` or `glab`) must be authenticated — if it is missing or unauthenticated, tell the user and
  have them paste the issue content directly, then proceed from Step 2
- Do not trust the issue context completely — always confirm against the code
- Fix only what the issue states — no unrelated refactoring or improvement
