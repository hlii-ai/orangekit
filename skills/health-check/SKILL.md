---
name: health-check
description: One-shot project status check (build, lint, typecheck, tests, SonarQube static analysis). Use when the user asks for a "status check", "health check", "build check", or "project status". manual invocation only.
disable-model-invocation: true
---

# Health Check

Checks the project's build, lint, typecheck, test, dependency, and static-analysis (SonarQube) status in one pass and produces
a structured report. Static analysis runs **only after asking the user**, and only when it is detected.

## Workflow

### Step 1: Decide the scope of the check

| Scope           | Trigger                               | Steps to run            |
| --------------- | ------------------------------------- | ----------------------- |
| Full check      | Default, "everything", "health check" | 2 → 3 → 4 → 5 → 5.5 → 6 |
| Build only      | "build check", "check the build"      | 2 → 6                   |
| A specific item | The user names an item                | That Step → 6           |
| Static analysis | "sonar", "static analysis"            | 5.5 → 6                 |

### Step 2: Build and typecheck

`${CLAUDE_SKILL_DIR}` is substituted by Claude Code — it resolves wherever the skill is installed (personal, project, or plugin):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/build-parser.sh build
```

- The command comes from `techStack.commands.build` in `orangekit.config.json`, or is resolved automatically from `package.json` scripts
- Build errors are structured as JSON (file · line · message, up to 40) — raw logs do not go into the context
- On success, confirm `"success": true`

### Step 3: Lint

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/build-parser.sh lint
```

- ESLint errors/warnings structured as JSON
- Classified by severity (error/warning)

### Step 4: Run the tests

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/build-parser.sh test
```

- Summarize the test results (passed/failed/skipped counts)
- Failed tests include the file name and the test name

### Step 5: Dependency check

Identify the package manager from the lockfile and run it (pnpm-lock.yaml→pnpm audit, yarn.lock→yarn audit,
package-lock.json→npm audit, uv.lock→pip-audit, and so on. If there is none, skip this Step):

```bash
pnpm audit 2>&1   # example — substitute the manager you identified
```

- Classify vulnerabilities as Critical/High/Medium/Low
- Recommend immediate action when Critical/High are present

### Step 5.5: Static analysis (SonarQube) — ask, then run

**Detection** — enter only if at least one of these is true:

```bash
ls sonar-project.properties 2>/dev/null
jq -r '.techStack.commands.sonar // empty' orangekit.config.json 2>/dev/null
command -v sonar-scanner
```

If none of them is, **skip it without demanding an install.** Leave a single line under "not checked" in the report —
so that the absence of a tool is not folded into the absence of defects.

**If it is detected, ask the user. Do not run it without asking** — the analysis uploads source to a server
(if the server is remote, state the transmission scope) and takes several minutes:

| Choice | Action |
| --- | --- |
| Analyze only | Run it → put the results in the report only. Do not touch the code |
| Analyze + auto-fix | Run it → Step 5.6 (fix regression) |
| Skip | Not run. Record it in the report as "not checked — user deferred" (distinct from undecidable) |

**Running it**:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/build-parser.sh sonar
```

- `SONAR_HOST_URL` and `SONAR_TOKEN` are taken **from environment variables only**. Writing them into config or a file
  makes the `security-check` hook block it as a secret write
- `undecidable: true` in the output is **not a failure but an undecidable verdict** (no scanner, no server, no token, analysis incomplete).
  Copy the `reason` into "not checked" in the report verbatim and **do not record it as Good**

### Step 5.6: Fix regression — do not fix anything here

Enter this only when the user chose "Analyze + auto-fix".

**Do not fix Sonar issues as given.** A rule engine does not know the project context — the false-positive filter comes first.
Hand the issue list to `receiving-code-review`. Verification (Step 2) → handling by severity (Step 3) →
re-entering build (Step 4) is **already what that skill does. Do not reimplement it here.**

Severity mapping:

| Sonar | Harness |
| --- | --- |
| BLOCKER · CRITICAL | Critical |
| MAJOR | Important |
| MINOR · INFO | Suggestion (record only) |

**What is never auto-fixed** — issues on paths that are expensive to reverse are **reported only**:
`**/migrations/**` · auth/RLS · payments and settlement · `**/api/**` · `**/actions.ts` · `**/middleware.ts`.
Those paths belong to `orangekit-reviewer` (`.claude/rules/reversibility.md`) — they are not a place to touch on a rule engine's
mechanical verdict without a human check.

**At most one re-analysis.** Once the fixes are done, run Sonar exactly one more time to confirm the issue count dropped, then stop.
The termination predicate is `zero new issues OR the one re-analysis is spent`, and the remaining issues go to the user.
Do not run a second re-analysis — an unbounded fix loop is a defect.

### Step 6: Produce the report

Write the report in this format:

```
Project status report
=====================

Checked at: [YYYY-MM-DD]
Scope: [full/build/specific item]

Build         [PASS/FAIL] — N TS errors
Lint          [PASS/FAIL] — N errors, N warnings
Tests         [PASS/FAIL] — N passed, N failed, N skipped
Dependencies  [PASS/WARN] — Critical N, High N
Static anal.  [PASS/FAIL/not checked] — Blocker N, Critical N, Major N

Overall status: [Good/Caution/Danger]

--- Details ---

[Show details for FAIL items only]
```

## Deciding the overall status

| Status  | Condition                                                                               |
| ------- | --------------------------------------------------------------------------------------- |
| Good    | Every item PASS. **If anything is not checked, do not write Good**                      |
| Caution | Only lint warnings, only Low/Medium vulnerabilities, or only Sonar Major and below      |
| Danger  | Build failure, test failure, Critical/High vulnerabilities, or a Sonar Blocker/Critical |

## Cautions

- build-parser.sh emits JSON, which is more token-efficient than the raw build log
- Each check is independent — if one fails, the rest still run
- Show details only for FAIL items, to keep the output minimal
- Do not mix "not checked" with "PASS" — recording something you could not see for lack of a tool as a pass makes the report a lie
