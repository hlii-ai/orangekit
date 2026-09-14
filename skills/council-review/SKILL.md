---
name: council-review
description: For planning decisions that are expensive to reverse (business direction, architecture choice), analyzes technical/business/UX perspectives in parallel and produces one integrated recommendation. Use for "multi-perspective analysis", "council review", "three-lens review".
---

# Council Review

Analyzes a planned feature **in parallel** from three perspectives — technical, business, UX — then **detects and reconciles conflicts** between them into an integrated recommendation. The point is to avoid the bias of sequential analysis and raise the blind-spot detection rate.

> **Boundary** — the three perspectives here look at a **planning decision** that has not been written yet. Looking at the diff of
> code already written through the correctness · security · reversibility lenses is `orangekit-reviewer`'s Irreversible fan-out.

<HARD-GATE>
The integrated recommendation from the three-perspective analysis must not be passed to the next stage without user confirmation.
Always pass it on only after the user confirms.
</HARD-GATE>

## Workflow

### Step 1: Identify the input and check the prerequisites

| Input situation | Steps to run |
|----------|----------|
| Invoked with a service plan from service (via orangekit-planner) | Step 2 → Step 3 → Step 4 → Step 5 → Step 6 |
| Invoked directly by the user (a service plan exists) | Step 2 → Step 3 → Step 4 → Step 5 → Step 6 |
| Invoked with no service plan | Tell the user: "Available once service is complete." → stop |

**Prerequisite**: `dev/docs/service/service-plan-<name>.md` must exist (concrete requirements are needed as the object of analysis).

### Step 2: Assemble the context

Collect the artifacts from ideation through service into a combined context brief (~500 words).

**What to collect:**
- `dev/docs/service/service-plan-<name>.md` (required) — functional requirements (FR-xxx), non-functional requirements (NFR-xxx), key screens, data model
- `dev/docs/business/business-plan-<name>.md` (if present) — business model, KPIs, revenue structure
- `dev/docs/research/<topic>.md` (if present) — market/competitor/technology research results

### Step 3: Dispatch the three perspective agents in parallel

Invoke three Task tool subagents **simultaneously** (parallel execution is the point).

For the prompt to hand each subagent, see `references/perspective-prompts.md`.

**Collecting responses and handling failures:**
- All three succeed → go to Step 4
- One fails → proceed with two responses (mark the failed perspective "not analyzed" in the report)
- Two or more fail → BLOCKED, report the failure to the user
- On NEEDS_CONTEXT → re-dispatch only that agent with the extra information (at most once)

### Step 4: Conflict detection

Compare the three responses across six decision dimensions.

**The six decision dimensions:**

| Dimension | What is compared |
|------|----------|
| Scope | Each perspective's position on what to include or exclude |
| Priority | What should be implemented first |
| Architecture | The technical approach |
| Timeline | Effort and complexity estimates |
| Risk | The core risk as each perspective sees it |
| Trade-offs | Quality vs speed, cost vs features, and so on |

**Verdict criteria:**
- **ALIGNED**: all three point the same way → record as an agreed item
- **PARTIAL**: two agree + one differs → adopt the majority, record the minority view
- **CONFLICTED**: all three differ, or two core perspectives oppose each other → go to Step 5

### Step 5: Re-query (when CONFLICTED exists, at most once)

**Re-question** the opposing perspectives on the dimensions judged CONFLICTED.

- Re-question that perspective's agent with the Task tool (sequential execution)
- Reconciled → change to PARTIAL
- Cannot reconcile → mark "unresolved" (ask the user to tie-break)
- **No second re-query** — if it is still unresolved after one, report it as is

### Step 6: Produce the integrated report and confirm with the user

**Save path**: `dev/docs/council/council-review-<name>.md`

**Record the decision separately.** The report is *analysis*; what the user chose is a *decision*.
Nobody goes looking for the analysis file later, but the decision will certainly be asked about again.
Once the user has confirmed, leave the chosen outcome as one entry in `docs/decisions.md` —
the canonical source for the format and the ceiling is "decision records" in `.claude/rules/reversibility.md`.
**Write down the rejected options and why** (that is the part needed later).

**User confirmation:**
```
The three-perspective Council Review is complete.

## Summary of the analysis
- Aligned (ALIGNED): [N] dimensions
- Partial (PARTIAL): [N] dimensions
- Unresolved (UNRESOLVED): [N] dimensions

Confirming this result passes it to the prompt-enhancement stage.
```

## Reference documents

- Per-perspective prompt templates: `references/perspective-prompts.md`
- Integrated report output format: `assets/council-report-template.md`
- Service plans live in `dev/docs/service/`
- Council Reviews live in `dev/docs/council/`
