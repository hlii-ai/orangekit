# AI Review Loop — shared workflow

This file is the body of the `codex-claude-loop` workflow. Per-provider differences (CLI commands · authentication ·
prerequisites) are defined by SKILL.md.

## Core philosophy

- **Claude Code**: architecture design, implementation, fixes
- **External AI**: verification, code review, quality assurance
- **Continuous cross-verification**: each AI reviews the other's work

## Shared Steps

### Step 1: Make the plan (Claude)

1. Write a detailed plan for the work
2. Separate the implementation stages clearly
3. Document the assumptions and potential issues

### Step 3: Feedback loop

When the external AI finds an issue:

1. Summarize the external AI's concerns for the user
2. Revise the plan based on the feedback
3. Confirm with the user
4. Repeat Step 2 if needed

### Step 4: Implementation (Claude)

Once the plan has been validated:

1. Claude implements the code with the Edit/Write/Read tools
2. Split the implementation into manageable units
3. Include error handling at each stage
4. Document what was implemented

### Step 6: Iterative improvement

1. After the external AI review, Claude applies the fixes
2. On a substantial change, send it back to the external AI for re-verification
3. Re-verify **at most twice**. After two rounds, unresolved Critical items go to the user as a tie-break
   (the same discipline as council-review's re-query rule — unbounded iteration only burns tokens)

## Error handling

1. Stop on an abnormal exit code from the external AI CLI
2. Summarize the external AI's feedback and decide the direction
3. For major architectural changes, changes touching many files, or backward-incompatible changes, confirm with the user before proceeding

## Best practices

- **Always validate the plan** before implementing
- **Never skip the cross review** after a change
- Keep the **handoff between AIs explicit**
- Document **who did what**
