---
name: pr-prep
description: Prepares a change so it can be raised as a PR/MR — collects the diff, judges the reversibility class, runs the verification commands, and writes a body with the sections that class requires (rollback procedure, call sites, intervention rationale). Use when the user asks to "prepare a PR", "prepare an MR", "open a PR", or for the "PR body".
---

# PR Prep

**The body is not a summary; it is the list of what a reviewer needs in order to judge.**

> **Boundary** — finding defects in the diff is the built-in `/code-review`, checking contract and spec alignment is
> `orangekit-reviewer`, and bringing documents up to date is `/completion-review`. This skill owns what none of those three
> produce: **the change-request body and its preconditions**. It does not fix code — if you find a defect,
> report it and go back to build.

**Host detection** — read `techStack.vcsPlatform` from `orangekit.config.json`. If absent,
check whether `git remote get-url origin` contains `github.com` or `gitlab.com`. If it is still unclear,
**ask the user** — everything up to Step 6 is the same either way, so the moment to ask is Step 7.
GitHub has PRs, GitLab has MRs.

## Step 1: What changed

```bash
git rev-parse -q --verify HEAD >/dev/null 2>&1 || { echo "0 commits — nothing to raise"; exit; }
git rev-parse --abbrev-ref HEAD
git log --oneline "$(git merge-base HEAD main 2>/dev/null || echo HEAD~1)"..HEAD
git diff "$(git merge-base HEAD main 2>/dev/null || echo HEAD~1)"..HEAD --stat
```

Some repositories have a base branch other than `main`. Confirm with `git symbolic-ref refs/remotes/origin/HEAD`,
and if there is none, ask the user — **a diff built on a guessed base produces the wrong PR.**

**If the current branch is the base branch, stop.** A branch has to be created first, and that is the user's decision.

## Step 2: Judge the reversibility class

The canonical source for the decision table is **"reversibility classification" in the T0 operating rules**, injected at session start.
Do not copy it here. Judge by the **paths** that changed — not by the number of diff lines.

If two or more apply, take the higher one. When in doubt, treat it as Costly.

## Step 3: The class decides the body's sections

| Class | **Required** in the body |
| --- | --- |
| Reversible | Summary · Changes · Tests |
| Costly | + **Impact radius** — the list of call sites (only what you actually confirmed with grep) |
| Irreversible | + **Rollback procedure** — the concrete order for undoing it on failure, and where data is lost |

If you touched `.claude/**` · `scripts/**` · `hooks/**` · `rules/**` · `agents/**` · `skills/**`,
**two lines of intervention rationale** are additionally required (`.claude/rules/harness-change.md`):

- (a) **the failure being prevented** — one observed at least twice
- (b) **the risk of breaking something that was working**

If you cannot write (a), it is a hypothesis, not a pattern. Say so in the body, or revert the change.

**If a required section cannot be filled, the work is unfinished.** Do not leave an empty heading and move on —
an Irreversible change request whose rollback procedure reads "(none)" gives the reviewer nothing to judge on.
Report that state and stop.

## Step 4: Actually run the verification

**Run** `techStack.commands` from `orangekit.config.json` (build · test · lint) **and put the results in the body.**
"It was written" is not "it works".

| Result | How to write it in the body |
| --- | --- |
| Pass | The command + `✓` |
| Fail | The command + a summary of the failure output. **Do not create the PR/MR; report instead** |
| No command | "No verification path" + the manual check procedure. Do not write it down as a pass |

Writing the third one down as a pass is the most common lie. Do not claim something exists when it does not.

## Step 5: Cite the prior decisions

If `docs/decisions.md` holds a decision related to this change, cite it on the Decisions line
(the canonical source for the format is `.claude/rules/reversibility.md`).

Before citing it, **re-verify against the current canonical source** — the code may have changed since the decision
(`.claude/rules/workflow-routing.md`, "reference freshness"). Do not include a citation you have not re-verified.

## Step 6: The body

```md
## Summary
<why this change is needed — not what you did>

## Changes
- <file group> — <what changed and how>

## Tests
- <command> — <result>

## Risks / Notes
- <reversibility class> — <the path that justifies it>
- <known limitations · what was left out of scope>

## Rollback            ← required for Irreversible
1. <the order for undoing it>
- Where data is lost: <state it if any, otherwise "none">

## Impact              ← required for Costly and above
- Call sites: <the list confirmed with grep>

## Intervention        ← required when harness paths changed
- Failure being prevented: <one observed at least twice>
- Risk of breaking: <what was working>
```

**Do not include** an empty section. A heading with nothing under it reads to a reviewer as
an omission.

## Step 7: Propose, no further

Show the body to the user and run the command **only after they confirm.**
Creating a PR/MR is an outbound act beyond the repository — undoing it takes a human hand.

**GitHub**

```bash
gh pr create --base <base> --title "<title>" --body-file <file>
```

**GitLab** — the default is the push option. No separate CLI install or authentication is required.

```bash
git push -o merge_request.create \
         -o merge_request.target=<base> \
         -o merge_request.title="<title>" origin HEAD
```

Push options reliably carry only the title and the target branch. **Write the body file regardless of which path you take** —
that is this skill's artifact. Tell the user the path so they can paste it into the created MR, and
if they want `glab`, use it then:

```bash
glab mr create --target-branch <base> --title "<title>" --description-file <file>
```

If the host cannot be determined in the end, **write the body file and stop there.** Do not run either command
on a guess.

If a push is needed, **do not force-push.** If it looks necessary, report the reason first —
the `security-check` hook blocks force-pushing a shared branch.

## Ceiling

Changes is **at most 12 lines, one per file group**. Do not list every file —
`--stat` already does that, and what the reviewer reads is what the grouping means.
Going over is a signal that the commit is too large, so propose splitting it.
