---
name: dev-docs-generator
description: Use right after the PRD is finished, when the pre-implementation dev docs (plan, context, tasks) are needed. Creates the plan, context, and tasks documents in the dev/active/ folder. For new feature work, extending an existing feature, and refactoring. This is Phase 3 of the CLAUDE.md workflow.
---

# Dev Docs Generator

A skill that creates the dev docs (plan, context, tasks) in the `dev/active/` folder.

## Handling the input

| Invocation context                                       | Input                         | Behavior                                        |
| -------------------------------------------------------- | ----------------------------- | ----------------------------------------------- |
| Called from orangekit-planner with a PRD path            | PRD file path + requirements  | Generate the dev docs against the PRD           |
| Called directly by the user via `/dev-docs-generator` (refactoring, etc.) | User requirements only | Generate from project analysis alone, no PRD |
| A PRD already exists                                     | The `dev/docs/prd/` path      | Find the existing PRD automatically and use it  |

## Workflow

### Step 1: Identify the work type and decide the document scope

**Decide whether it is needed at all first**: if the work finishes in one session, do not create a workspace
(reversibility.md — "only when it spans sessions"). Continue below only when it spans sessions:

| Work type | Documents to create |
| --- | --- |
| New feature (PRD exists) | plan + context + tasks |
| Refactoring/extension | plan + tasks (context once decisions start accumulating) |
| Bug fix (multi-session) | tasks only |

### Step 2: Check for existing documents

If the same slug already exists in `dev/active/`, update the existing documents instead of creating new ones.
If a similar piece of work exists in `dev/archive/`, point to it as a reference.

### Step 3: Create the folder and documents

**When both sides are in play, the contract comes before the slices.** If this work builds both the frontend and the backend from scratch,
pull steps 1 and 2 of "the inner order of a single feature" in `workflow-routing.md` forward to here — read the screen × field table
(service plan Step 4-4, or pull it from the screens section of the PRD if there is none) and write `dev/docs/api/wire-contract.md`.

- For the form, use the **§0-§5 section titles and the "contract values only in lists and table rows" rule** from
  `${CLAUDE_PLUGIN_ROOT}/skills/stack-guide-generator/assets/wire-contract.template.md` as they are. That file's preamble (isolated guide
  generation, gate comparison) and its `exampleDomain` instruction are for guide generation, so do not carry them over. Fill in §6 auth
  surface only when the backend does its own authentication.
- **If it already exists, do not rewrite it** — add only this feature's entities, endpoints, and error codes to §0 and §4.
- The domain model is covered to the logical level by contract §0 plus the screen × field table.
- **If the feature creates or changes tables**, make the first item of the backend slice in tasks.md
  "DB design `dev/docs/database/<slug>.md` → migration". Write the physical design into that document,
  table by table — writing a design from your head straight into the migration means no rule card reaches it
  (a `paths:` card comes up only when read). The moment you write to that path, the `data-modeling` card is summoned.

Create them in `dev/active/<slug>/` using the three forms in `assets/doc-templates.md`.
The **Scope** section of tasks.md is mandatory — orangekit-reviewer checks compliance with Scope.

For each slice, fill in **Read first** — pass the file paths that slice will create or edit to
`bash "${CLAUDE_PLUGIN_ROOT}/scripts/security-check.sh" --owning <path…>` and the rule cards and skills that own them come out, using the
**same judgement** as the prior-knowledge gate (do not write a copy of that judgement by hand). Read them when you start the slice,
and the send-back and rewrite right before a write do not happen. Do not read them all at session start —
the farther they are from the point of writing, the more the rules get buried.

Group the checklist into **vertical slices** — each slice cuts thinly through every layer so it can be demonstrated on its own,
fits into a single fresh context, and declares its predecessor slices under `Blocked by`. A wide refactoring is
the exception to this rule and is arranged as expand → migrate → contract. The form and the criteria are in the template file.

### Step 4: Confirm with the user

Present the list of generated documents plus the approach summary from the plan, and get it confirmed.

## Artifact verification

- Do the three documents have the template's required sections?
- Does tasks.md have a Scope section?
- Does each slice state `Blocked by`, and does one slice fit into a single fresh context?
- If the work touches both frontend and backend, does `dev/docs/api/wire-contract.md` exist with this feature's endpoints in §4?
- Is the plan's verification path an executable command?
- Does each slice have `Read first` (if the `--owning` output is empty, "none")

## Reference documents

- Document templates: [assets/doc-templates.md](assets/doc-templates.md)
- Contract form: `${CLAUDE_PLUGIN_ROOT}/skills/stack-guide-generator/assets/wire-contract.template.md` — do not keep a copy
- Existing active work: `dev/active/` · archive: `dev/archive/`
