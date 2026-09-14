---
name: prd-reviewer
description: Diagnoses the quality of an existing PRD and derives improvements. Supports both single and modular PRDs, checking implementation alignment, requirement clarity, internal consistency, and design principles, and producing a report that names where each fix belongs. Required after a PRD edit (the doc-dependency card triggers it).
---

# PRD Reviewer

A skill that diagnoses the quality of an existing PRD document and derives improvements with the exact place each one belongs. It supports both single PRDs and modular PRDs (prd-overload + Phase Sub PRDs + Shared documents).

## Workflow

### Step 1: Pick the PRD + detect its type + choose the diagnostic scope

#### 1-1: Pick the PRD

| Situation                 | Behavior                                                      |
| ------------------------- | ------------------------------------------------------------- |
| The user names a PRD file | Proceed with that file                                        |
| No PRD file named         | Search `dev/docs/prd/`, present the list, let the user choose |

#### 1-2: Detect the PRD type automatically

| Detection condition                                                 | PRD type    | Diagnostic mode           |
| ------------------------------------------------------------------- | ----------- | ------------------------- |
| `prd-overload.md` present + `phases/` and `shared/` folders present | **Modular** | 6-axis diagnosis (A-F)    |
| A single `.md` file                                                 | **Single**  | 5-axis diagnosis (A-D, F) |

#### 1-3: Choose the diagnostic scope

| Diagnostic scope         | Description                                                                                       | Steps to run                     |
| ------------------------ | ------------------------------------------------------------------------------------------------- | -------------------------------- |
| Full diagnosis           | Every axis (single: A-D+F, modular: A-F)                                                          | Step 2 A→B→C(→E)→F → Step 3→4    |
| A specific section       | Focused diagnosis of the section the user names                                                   | Step 2 A→B→C (scoped) → Step 3→4 |
| Implementation check     | Centered on the gap against the codebase                                                          | Step 2 D → Step 3→4              |
| Modular structure        | Cross-document consistency against prd-overload (modular only)                                    | Step 2 E → Step 3→4              |
| Verification after edits | Consistency + design-principle check right after a PRD edit. Triggered by the doc-dependency card | Step 2 C→E(modular)→F → Step 3→4 |

### Step 2: Diagnose PRD quality

Read the target PRD and diagnose it. For every issue found on any axis, **always record its location in the PRD (section name + the content in question)**.

**Reporting bar — falsifiability**: to raise something as an issue you must be able to write down *the point where that sentence makes
the implementation diverge*. "It might be…" is a guess, not an issue. If you cannot write it, do not report it.

#### A. Structural completeness

Do the required sections of the template (`skills/prd-generator/assets/prd-template.md`) actually exist?
A section with a heading and an empty body **counts as absent** — a section that pretends to exist is worse.

```bash
grep -nE '^#{1,3} ' <PRD>            # section list
grep -cE '^\| *FR-[0-9]' <PRD>       # number of FR rows (0 means an A Critical)
```

- [ ] Are problem definition · goals/non-goals · functional requirements · constraints · open questions all present?
- [ ] Is **non-goals** non-empty? (a PRD that never closes its scope spreads without limit during implementation)

#### B. Requirement clarity

Is every single FR **verifiable through its acceptance criteria?** The test is one question: "can this sentence alone
decide pass or fail?"

- [ ] Does each FR have acceptance criteria · a priority (MoSCoW)?
- [ ] Are the failure and exception paths written down? (an FR with only the happy path is Important)
- [ ] Are there numbers where numbers are needed? ("fast" → "p95 within 500ms")

Raise vague wording **only when it has a real effect on the implementation** (Pitfall 3).

#### C. Internal consistency

Is the same fact written differently in two places? **Most PRD defects come from here.**

```bash
grep -noE '[0-9][0-9,.]*(%|ms|s|USD|IDR|Rp|users|items)' <PRD> | sort -t: -k2 | uniq -f1 -D  # the same figure in conflict
grep -nE 'FR-[0-9]+' <PRD> | sort -u                                          # FR references ↔ definitions
```

- [ ] Are the numbers the same in every section · are the state transitions free of contradiction?
- [ ] Is the terminology unified? — do not stop at one grep; cover **abbreviations, synonyms, and compound-noun variants**
- [ ] Do the in-document links and section references actually exist?

#### D. Implementation alignment (implementation-check mode)

The gap between what the PRD says and what the code does. **Write down only what you confirmed by reading the code** —
"it looks unimplemented" is not an issue.

- [ ] Did you find the implementation site (file · function) for each FR / mark it unimplemented when you could not?
- [ ] Is there anywhere the code has run ahead of the PRD (behavior not in the document)?
- [ ] When you find a gap, **do not decide which side is right** — put it to the user as a choice

#### E. Modular structure consistency (modular PRDs only)

- [ ] Does the Phase list in `prd-overload.md` match what is actually in `phases/`?
- [ ] Are the declared dependencies between Phases free of cycles?
- [ ] Does every item in `shared/` have **exactly one original**? (if several Phases restate the same definition, that is Critical)

```bash
ls phases/ ; grep -nE '^\| *Phase' prd-overload.md   # declared ↔ actual
```

#### F. Design-principle alignment (single and modular alike)

Does the PRD conflict with the principles declared in the project's `CLAUDE.md` and `.claude/rules/`?
**Do not stop at a literal reading of a principle; follow it through to its structural effect on the implementation.**

- [ ] Do requirements whose reversibility class is Irreversible (migrations · auth · payments) describe a rollback?
- [ ] Does the PRD demand an approach different from the one the project already uses? (and if so, is the rationale written down?)

### Step 3: Produce the diagnostic report

**Severity criteria:**

| Severity  | Criterion                                                                  | Examples                                                                                       |
| --------- | -------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| Critical  | Directly affects the implementation direction; a contradiction or an error | Conflicting numbers, contradictory state transitions, mixed terminology, broken document links |
| Important | Unclear enough to cause confusion during implementation                    | Ambiguous requirements, missing exception cases, missing FR↔Screen mapping                     |
| Minor     | Quality and readability improvements                                       | Section order, format consistency, small typos                                                 |

### Step 4: Apply the PRD updates

Apply only the improvements the user approved.

### Step 5: Completion report

```
PRD diagnosis and update complete.

PRD type: [single / modular]
Findings: Critical [N] / Important [N] / Minor [N]
Applied: [N] of [M]
Document version: [before] → [after]
Back-check: [passed / N remaining]

File: [PRD file path, or the modular structure listing]
```

## Pitfalls

- On axis F, do not stop at a literal reading of the principle — trace its structural effect on the implementation
- When checking terminology consistency, do not stop at one grep — search abbreviations, synonyms, and compound-noun variants
- Do not raise vague wording such as "appropriate" or "as needed" as Critical on its own — the test is whether it has a real effect on the implementation
