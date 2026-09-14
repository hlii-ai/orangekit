---
name: skill-enhancer
description: Hardens a skill to harness grade — first rules on keep · boundary split · switch to manual · merge · delete, then injects boundary declarations, behavioral contracts, failure paths, machine checks and wiring into the kept ones only. Use right after creating or improving a skill with skill-creator, when hardening an existing skill, or when an eval detects a defect. For creation and the A/B eval loop, use skill-creator.
---

# Skill Enhancer

Promotes a skill from an **isolated artifact** to **a node in the graph**.
`references/superiority-patterns.md` is the original for the definitions, evidence and injection
methods of the 6 patterns and for the overlap ruling procedure — read it before the Step 0 ruling.

> **Boundary**: creation, test prompts and A/B benchmarks are skill-creator's territory.
> This skill covers only the dimensions that eval loop cannot score — behavior on failure,
> the division of labor with neighboring tools, token discipline. They do not overlap; they connect.

## Step 0: The keep ruling — it comes before hardening

**Hardening a skill that is about to disappear is the most expensive outcome.** A description is
resident every session even if the skill is never invoked once, so its existence is a permanent cost.
Q1–Q3 in `rules/harness-change.md` are a **pre-addition** gate, so they were never thrown at an existing skill again. Throw them here:

| # | Question | If YES |
| --- | --- | --- |
| Q1 | Does its role overlap an existing skill, hook or **native built-in** | go to "Overlap ruling" below |
| Q2 | Has the model improved enough that this is now unnecessary | **delete** candidate |
| Q3 | Is it already working well and you are changing it for no reason | **keep** (no change) — stop here |
| Q4 | Is it reachable from the routing card and the graph | NO means **switch to manual** or missing wiring |

There are five rulings, and **the reversibility class decides who executes**:

| Ruling | Execution | Class |
| --- | --- | --- |
| **Keep** | proceed to Step 1 (= harden) | Reversible |
| **Switch to manual** | `disable-model-invocation: true` — keep the body, make only the description non-resident | Reversible |
| **Boundary split** | do not merge; declare a P1 boundary in both descriptions | Reversible |
| **Merge** | two into one + remove one + move the routing and graph edges | **Costly — confirm with the user** |
| **Delete** | remove the skill + drop it from routing, the graph and the presets | **Costly — confirm with the user** |

Narrow it down by machine first:

```bash
# Q4 — routing and graph reachability (0 for both is a switch-to-manual candidate)
grep -c "\`/<target>\`" .claude/rules/workflow-routing.md "${CLAUDE_PLUGIN_ROOT:-.}/rules/workflow-routing.md" 2>/dev/null
jq --arg n "<target>" '[.edges[] | select(.to == $n)] | length' "${CLAUDE_PLUGIN_ROOT:-.}/workflow.graph.json"
# Resident cost — the bytes this skill charges every session
awk '/^---$/{n++;next} n==1 && /^(name|description):/{p=1} n==1 && /^[a-z_-]+:/ && !/^(name|description):/{p=0} n==1&&p{print} n>=2{exit}' <target>/SKILL.md | wc -c
```

**If the ruling is anything but keep, do not go down to Step 1.** Report only the ruling and its
basis, and stop — merges and deletions propagate to consumers immediately, so the user chooses.

### Overlap ruling — preserving the advantage decides the conclusion

"They overlap" is an observation, not a ruling. First **extract both sides' advantages as a list**, then ask in order.
Reverse the order and the side that has the advantage is erased first.

1. Are A's advantages **entirely contained** in B → YES means **absorb** (remove A). In practice, rare.
2. Are the two sides' advantages used **in different situations** → YES means **boundary split**. ← the default
3. If neither, **merge** — but honor the obligation below.

**② is the default because of cost asymmetry.** If a merge is wrong, what is lost is an advantage and it is hard to reverse.
The cost of not merging is one description line each (small, and the budget has room).

**The merge obligation**: before executing, build an **advantage comparison table** (extracted items ×
whether the combined version holds them), and if even one item did not carry over, do not merge. "Merge and judge afterward" is not allowed — by then one side is already erased.

**Executing a boundary split** does not end with keeping both. Assigning the overlapping stretch to a
sentence and thereby eliminating it is part of the same move — the procedure is in catalog P1's "4 steps to eliminate the overlapping stretch".

## Step 1: Subtraction — machine ruling first

Subtract before you harden. All four below are **ruled by machine** — left to the model's judgement,
16 empty sections survived in the repository:

```bash
# Empty section heading (a heading with no body, followed by a heading at the same or shallower level)
awk '/^```/{f=!f;prev="";next} f{next} /^#+ /{l=index($0," ")-1; if(l>=2&&prev!=""&&l<=pl) print "EMPTY: "prev; prev=(l>=2?$0:""); pl=l; next} NF{prev=""}' <target>/SKILL.md
# Unjustified imperative vocabulary — look only for uppercase MUST and you miss the MANDATORY / Iron Law family entirely
grep -nE 'MUST|ALWAYS|NEVER|MANDATORY|Iron Law|No exceptions|always|never' <target>/SKILL.md
# Does Pitfalls break the Step sequence (reading order and execution order diverge)
grep -nE '^#{2,3} .*(Pitfalls|Caution)|^### Step' <target>/SKILL.md
# Orphan resources · what the description promised but the body does not have
bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/doctor.sh" --fast 2>&1 | grep -E 'orphan resource|empty section heading'
```

Imperative vocabulary is **not deleted by default** — attach a reason, or, when that reason is already
in the T0 norms or a hook, it is a duplicate and comes out. If there is anything to subtract, show the list, confirm, then remove.

## Step 2: 6-pattern diagnosis — machine ruling first

After reading the catalog, start with what a machine can rule on (`<target>` = the skill directory):

```bash
# P3 — no iteration ceiling (a mention of iteration or retry with no ceiling falls short)
grep -nE 'repeat|retry|again|until|iterate' <target>/SKILL.md | grep -vcE 'at most [0-9]|ceiling'
# P4 — no machine command at a judgement step (number of code blocks against number of Steps)
grep -c '^### Step' <target>/SKILL.md; grep -c '^```' <target>/SKILL.md
# P5 — routing variable violation (the severity grade table is a false positive — exclude it when reading)
grep -nE 'Small|Medium|Large' <target>/SKILL.md
# P6 — no guidance on when to read a resource
ls <target>/references <target>/resources 2>/dev/null; grep -c 'when to read' <target>/SKILL.md
```

Lay the model's judgement on top of the machine ruling: use the catalog's **applicability matrix**
to settle the skill's type, and look deeply only at whether the patterns "required" for that type are met.
**Do not invent a pattern that is not in the matrix.**

## Step 3: Apply the hardening — only what applies

Apply only the patterns the diagnosis ruled as falling short, following the catalog's "injection method".

- Each injection follows **the target skill's vocabulary and style** (hardening must not look grafted on)
- P3's ceiling numbers and P2's prohibition wording are **derived from the nature of that skill's work** —
  do not copy the catalog examples
- Record any pattern not applied as "not applicable — basis" (no silent omissions)

## Step 4: Self-test — revert on failure

- [ ] After hardening, does every promise in the description still exist in the body
- [ ] Does each newly added iteration ceiling, demotion rule and prohibition carry a reason
- [ ] Are all four Step 1 commands at zero hits (has what was subtracted not come back)
- [ ] Line count: SKILL.md ≤ 300 lines after hardening (over that, split into resources or redo the subtraction)
- [ ] **Description byte attribution**: if there is a net increase, is that increase explained by a
      P1 boundary or a P5 invocation contract. An unexplained net increase is reverted — P1 and P5
      structurally lengthen the description, and that cost is charged unconditionally every session

```bash
awk '/^---$/{n++;next} n==1 && /^(name|description):/{p=1} n==1 && /^[a-z_-]+:/ && !/^(name|description):/{p=0} n==1&&p{print} n>=2{exit}' <target>/SKILL.md | wc -c
```

- [ ] If doctor is present (plugin or repository): `bash "${CLAUDE_PLUGIN_ROOT:-.}/scripts/doctor.sh" --default` passes
- [ ] If a graph file is present: `--graph` passes after adding the node and edges

If even one fails, revert that injection and report the failing item.

## Step 5: Report + description handoff

- The Step 0 ruling and its basis (if it is not keep, the report ends here)
- Per-pattern result table: `pattern | diagnosis | applied / not applicable | where changed`
- Hardening diff summary: N lines added / **N lines deleted** (zero subtraction means Step 1 was skipped) /
  **description N bytes before → N bytes after**

### The description is handed to skill-creator — the order is fixed

skill-creator's final step, Description Optimization (`run_loop.py` → `best_description`), and this
skill's P1 and P5 **write to the same field.** Whichever runs later silently wins. There is one order:

**The hardening's description injection first, the optimizer second.** And in the eval set handed to
the optimizer, **always include the near-misses the P1 boundary created as should-not-trigger** —
leave them out and the optimization can erase the boundary sentence while the score appears to rise.

Hardening with a large behavioral change (P2, P3) **should be verified A/B, before and after, through
skill-creator's eval loop** — only measurement proves the hardening actually won. The baseline here is the pre-hardening snapshot.
