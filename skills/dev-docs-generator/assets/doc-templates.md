# The three dev document templates (plan · context · tasks)

## plan.md

```markdown
# Plan: {feature name}
- Source document: {PRD path, or "none (straight to Reversible)"}
- Reversibility class: {verdict + the path that justifies it}

## Approach
{How it will be implemented — 3-7 lines. If alternatives were considered, one line each on why they were rejected}

## Impact radius
| File/domain | Nature of the change |
| --- | --- |

## Verification path
{How you will know it worked — build/test/manual check commands}
```

## context.md

```markdown
# Context: {feature name}

## SESSION PROGRESS (append-only — do not overwrite earlier records)
- {YYYY-MM-DD} {what was done / what is next / what is blocked}

## Decision record
| Decision | Rationale | Date |
| --- | --- | --- |
```

## tasks.md

```markdown
# Tasks: {feature name}

## Scope — required
- In: {what this work touches}
- Out: {what it does not touch — prevents scope creep}

## Slices
<!-- Cut each slice vertically — through schema, API, UI, and tests, so it demonstrates behavior by itself.
     Cutting one layer horizontally (all the models, then all the APIs) leaves nothing to show in between. -->

### S1. {slice title}
- Blocked by: none — can start immediately
- What works when it is done: {what becomes functional from the user's point of view}
- Contract: {only when both sides are in play — which row of wire-contract.md §4 it uses}
- [ ] {task item — with a clear completion condition}

### S2. {slice title}
- Blocked by: S1
- What works when it is done: {…}
- [ ] {…}
```

### Slice rules

| Rule | Content |
| --- | --- |
| Vertical | Cut thinly through every layer, not one layer. When it is done it must be **demonstrable and verifiable on its own** |
| Size | **As much as fits in a single fresh context**. If it exceeds that, split it |
| Blocked by | Name the slices that must be finished before this one starts. If none, write "none" |
| Preparatory work | If a prefactor makes the implementation easier, put it in as the **first slice** |
| Inner order | Follow "the inner order of a single feature" in `workflow-routing.md` — contract → mock UI verification → backend → remove the mock. Do not restate it here |
| Done | "Demonstrable on its own" **does not mean demonstrable on top of a mock** — if the mock this slice stood up in place of the contract is still there, it is not done. Permanent test doubles such as payments or email do not count |

**The task order is a frontier** — any slice whose blockers are all finished can be picked up.
The numbering is dependency order, not mandatory order.

### Exception: a wide refactoring is not cut vertically

Work where **one mechanical edit breaks thousands of call sites at once** — renaming a column, changing a shared type —
cannot land any vertical slice green. Do not force it into a tracer bullet; arrange it as
**expand → migrate → contract**.

| Stage | Content | Blocked by |
| --- | --- | --- |
| ① Expand | Add the new shape **next to the old one** — nothing breaks | none |
| ② Migrate | Move call sites in blast-radius units (per package, per directory). The old shape is still there, so CI is green after every batch | ① |
| ③ Contract | Delete the old shape once the remaining call sites reach zero | every batch of ② |

If even a batch cannot be green on its own, keep the order but share an integration branch and
promise green **only at the final integration and verification slice**.
