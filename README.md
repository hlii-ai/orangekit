# OrangeKit Claude Code Devkit

AI Native Dev Harness for Claude Code — reversibility-axis workflow, self-testing hooks, graph instrumentation.

![version](https://img.shields.io/badge/version-1.1.0-blue)
![license](https://img.shields.io/badge/license-MIT-green)

## What it is

A Claude Code plugin. It classifies code work by **reversibility** so that only as much process as the
class requires is applied, and it verifies for itself that the harness is still alive.

There is one design principle — **a component proves its own existence or it dies.**
In v2, 10 of 11 hooks were silently dead for four months from path-computation errors and output-format
mismatches, and nobody noticed. v3 was rebuilt so that failure is structurally impossible.

> **Why each device sits where it does, in the shape it does**, is written up in
> [Harness Anatomy](docs/harness-anatomy.md) — it explains the 5 hooks, the 3 rule tiers, the 6 loops
> and the graph engineering starting from the failure each one blocks, then shows all four at once in a walkthrough that traces a single task end to end.

## Quick Start

> 🪟 **On Windows, check this before installing** — this plugin's hooks are registered in the form
> `"bash <script>"`, so without **Git for Windows** (Git Bash) they do nothing at all, silently and
> without an error (WSL users are unaffected). A 5-minute install guide a non-developer can follow →
> [`docs/windows-setup.md`](docs/windows-setup.md)

### 1. Install the Plugin

Two lines. The first registers this repository as a marketplace (once per machine); the second
installs the harness from it.

```bash
claude plugin marketplace add hlii-ai/orangekit
claude plugin install orangekit-product@orangekit
```

The three names are independent of each other, and none of them is the repository name by accident:
`hlii-ai/orangekit` is the **repository**, the `@orangekit` suffix is the **marketplace** name
(`.claude-plugin/marketplace.json` → `name`), and `orangekit-product` is the **plugin**
(`plugins[].name`).

> **What the marketplace reads is `origin/main`.** Only a version whose release tag
> (`orangekit-product--v{version}`) and main merge are both finished reaches consumers. To work from
> a branch that is not merged yet, register a local clone instead of the remote:
>
> ```bash
> claude plugin marketplace add <path to this repository>
> ```

**The harness evaluation skill is not shipped to consumers.** `/harness-evaluation` is a tool only for people who **build** this plugin, so it was split out into `orangekit-harness` — there is no need to install it.

**The marketing skills are a separate plugin.** The same marketplace also carries `orangekit-marketing`
(5 skills — AI prompts · scroll-driven site · SEO 3-Mode · web assets), and it ships on an
**independent version**. It was split off from the dev harness because of the context budget — a skill
description is resident every session even if you never use that skill, so skills unrelated to
development eat a development session's budget. Install it only when you need it:

```bash
claude plugin install orangekit-marketing@orangekit
```

### 2. Initialize Your Project

Run Claude Code in your project directory, then:

```
/orangekit-init
```

It runs interactively:
- **Pick the product shape** — web · mobile app · API-only. It asks about the product before the technology, and this answer narrows the lists in the questions that follow. A mobile app then splits into hybrid (web screens + app shell) · cross-platform · fully native
- Pick a preset — web screen axis (nextjs·react-vite·vue·vanilla·none) + app axis (react-native·flutter·ios-swift·android-kotlin·native-dual) + backend axis (supabase·firebase·aws-serverless·aws-container·gcp-serverless·fastapi·node-api·node-nest·fastify·rust-axum·none)
- If it is not on the list, type it in as **custom**; if you are not sure, pick **get a recommendation** or **decide later**
- Before writing any file, it shows a **confirmation summary** and asks you to confirm
- Collect project information
- Generate `orangekit.config.json` + `CLAUDE.md`
- **Install rule cards into `.claude/rules/`** ← new in v3
- Create the `dev/` directory structure

### 3. Verify

Run exactly the command on the **'self-test'** line shown in a new session's briefing
(it prints an absolute path based on where the plugin is installed):

```bash
bash "<plugin-root>/scripts/doctor.sh"
```

`pass N · warn N · fail 0` means everything is fine. If there are failures, it prints what broke and why alongside them.

## Classifying work — reversibility

Work is not classified by size (lines, files). Size demands human judgement, so it drifts, and it
**looks at the wrong variable** — a 5-line migration is more dangerous than a 400-line refactor.

> What follows is a **quotation** of `templates/operating-contract.md`. That file is the canonical
> source; where the values diverge, it is the one that is right.

| Class | Decision (path-based) | Requirement — and who does it |
|--------|------------------|------|
| **Irreversible** | `**/migrations/**` · auth/RLS · payments and settlement · production data | `orangekit-reviewer` multi-perspective fan-out + user confirmation + rollback procedure |
| **Costly** | shared packages · public API · type contracts · `**/api/**` · `**/actions.ts` · `**/middleware.ts` · generated files | `orangekit-reviewer` required (no self-review) |
| **Reversible** | everything else, test code included (the default) | Go straight ahead. Finish with `/completion-review` |

**The 4 entry conditions** — intent clear · context current · impact radius known · verification path exists.
If all four hold, implement immediately with no preparation work. Do not produce a document for a condition already met.

**The two axes are orthogonal.** The reversibility class decides *how much to verify*, and the
**task routing table (P0~P6)** in `.claude/rules/workflow-routing.md` decides *what to produce in
what order*. That card has no `paths:`, so it is **loaded unconditionally every session**.
A Phase number marks order, not obligation — when the 4 entry conditions hold, P0~P3 are skipped.

## Components

| Layer | Count | Contents |
|------|-----|------|
| **Hooks** | 5 scripts / 6 registrations | SessionStart · PreToolUse · Stop · PreCompact · SessionEnd · PostToolUse |
| **Rules** | T0 41 lines + T1 9 cards 1,089 lines | T0 is injected by a hook at all times (plugin-owned). Of T1, `workflow-routing` is **always on, every session**; the rest load conditionally on a path match |
| **Agents** | 2 | `orangekit-planner` (no writes) · `orangekit-reviewer` (read-only) |
| **Skills** | 26 | Survey · planning · implementation · verification · security · PR workflow + stack guide generator + skill enhancer (the 5 marketing skills are split into `orangekit-marketing`, the 1 harness evaluation skill into the `orangekit-harness` plugin) |
| **Presets** | 3-axis 5+5+11 | Web screens: nextjs·react-vite·vue·vanilla·none / App: react-native·flutter·ios-swift·android-kotlin·native-dual / Backend: supabase·firebase·aws-serverless·aws-container·gcp-serverless·fastapi·node-api·node-nest·fastify·rust-axum·none |

### Hooks

| Hook | Event | Role |
|----|--------|------|
| `session-brief` | SessionStart | Injects the operating contract + **auto-installs missing T1 cards** + HEAD · uncommitted changes · open tasks + **hook liveness status** |
| `security-check` | PreToolUse | Blocks hardcoded secrets and destructive commands (exit 2) — across the whole Edit · Write · Bash path |
| `build-gate` | Stop | Blocks when a source edit was not followed by a build or test run |
| `handoff` | PreCompact · SessionEnd | Preserves task state on compaction and on exit |
| `track-skill` | PostToolUse | Instruments skill invocations — so that nothing is culled without measurement |

Every hook shares `scripts/lib/common.sh`. If the project root cannot be determined it
**does not guess — it blocks with exit 2**, and it records every run in `.claude/.orangekit/hookrun.log`
so that the next session briefing reports dead hooks.

### The 3 rule tiers

| Tier | Medium | Owner | Auto-update |
|------|------|------|-----------|
| **T0** always on | printed by the `session-brief` hook | plugin | ✅ |
| **T1** always on | `.claude/rules/workflow-routing.md` (no `paths:` → loaded every session) | project | drift detected by version stamp |
| **T1** conditional | `.claude/rules/*.md` (`paths:` match) | project | drift detected by version stamp |
| **T2** reference | plugin skills | plugin | ✅ |

Putting T0 in hook output is the key — it is plugin-owned, so it updates automatically while staying
always loaded, which makes drift, where the rules grow independently inside the project, structurally impossible.

On top of that, `/orangekit-init` generates **2 project-owned cards** (project-structure ·
code-conventions) — filled in with the repo topology (single / monorepo / MSA), the measured tree
and conventions matching the preset; they carry no version stamp, so plugin updates do not reach them.

### Agents

| Agent | Tools | What becomes structurally impossible |
|----------|------|---------------------------|
| `orangekit-planner` | Read, Grep, Glob, WebSearch, WebFetch | Churning out unnecessary documents (no Write) |
| `orangekit-reviewer` | Read, Grep, Glob, Bash | Moving or editing files without authorization (read-only) |

Without the permission, the violation is impossible. Removing permission comes before instructing.

### 26 skills — what invokes them

The canonical source for invocation conditions is the Phase table in `.claude/rules/workflow-routing.md`. Below is a quotation of it, and
`doctor --fast` fails if a skill name is missing from that table.

| What invokes it | Skill |
| --- | --- |
| **Phase table** (P0~P6) | `brainstorming` · `research` · `business-planner` · `service-planner` · `council-review` · `prompt-enhancer` · `prd-generator` · `dev-docs-generator` · `test-driven-development` · `completion-review` · `codex-claude-loop` |
| **Doc dependency** (when `dev/docs/prd/` is edited) | `prd-reviewer` |
| **description** (the model fires it when the condition holds) | `receiving-code-review` · `security-review` · `shortcut-ledger` · `pr-prep` · `codebase-survey` · `ui-ux-design` · `image-generator` · `skill-enhancer` |
| **Another skill or hook** | `stack-guide-generator` (← `orangekit-init` · session briefing) |
| **The user only** (`disable-model-invocation` — description not resident) | `orangekit-init` · `orangekit-migrate` · `health-check` · `fix-issue` · `execution-dashboard` |

## Self-test — `doctor`

It is designed on the premise of a project with no CI. It is a single command a user can type themselves.
In a consumer project, use `<plugin-root>/scripts/doctor.sh` (the session briefing prints the absolute path).
Plugin asset checks (--fast · --graph · --self-test) look at the plugin root; project state
checks (--usage · --lessons) look at the current project, automatically.

```bash
bash scripts/doctor.sh              # structure checks + graph verification (when developing the devkit repo)
bash scripts/doctor.sh --self-test  # injects per-event fixtures into the hooks → compares the effect
bash scripts/doctor.sh --graph      # unreachable nodes · dangling edges · missing error edges
bash scripts/doctor.sh --usage      # hook liveness · skill invocations · edge traversal
bash scripts/doctor.sh --lessons    # lesson aggregation + promotion candidates
bash scripts/doctor.sh --all        # everything
```

What it checks:
- **Forbidden idioms** — `BASH_SOURCE`-relative root computation, `|| echo 0` fallbacks
- **Hook output format** — use of a JSON field the event does not support (Stop's `decision`/`reason`, etc.)
- **Rule reachability** — assets that are declared but have no path by which to reach the project
- **Dangling references** — links pointing at files that do not exist
- **Agent contract** — whether `name` · `description` · `tools` · `model` are all present
- **Manifest consistency** — a single source for the version, unimplemented config fields

## Graph declaration

`workflow.graph.json` declares the nodes (agents · skills · hooks), the edges (transition conditions)
and the **error edges** in machine-readable form. Currently 49 nodes · 90 edges.

`doctor --graph` verifies:
- whether every edge's target actually exists
- whether any node has no inbound edge (= an unreachable asset)
- whether every execution node declares an error edge (if the failure path is not in the graph, the failure vanishes silently)

`doctor --usage` aggregates the edges actually traversed. "This skill is not used" becomes **a measurement, not a claim**.

## Zero-Config Mode

It works without `orangekit.config.json`. The 5 hooks and the reversibility-axis workflow are always active.
Adding configuration turns on:
- per-project secret patterns
- build/test command recognition (`build-gate` then names the concrete command)

## Stack guides — the preset is a default, the combination is a choice

A preset does not pin the backend. `/orangekit-init` confirms the backend type (BaaS · self-built on
cloud · framework built-in), the cloud, the DB (PostgreSQL, MongoDB and so on), data access and auth, then
generates the `frontend-guide` and `backend-guide` skills matching the settled combination into the
project's `.claude/skills/` (`stack-guide-generator`). Only the three combinations with a pre-built version (`nextjs`×`supabase`,
`react-vite`×`aws-container`, `vue`×`node-api`) use the plugin original as-is. Whether to use a pre-built version or
generate one is **decided by the system from the combination; it does not ask.** When the stack changes,
regenerate with `/stack-guide-generator`.

## Available Presets

| Preset | Stack | Skills |
|--------|-------|--------|
| `nextjs` × `supabase` | Next.js 15 + Supabase + Tailwind + shadcn/ui | Uses the pre-built version |
| `react-vite` × `aws-container` | React+Vite SPA + ECS/Fargate + RDS PostgreSQL + Drizzle | Uses the pre-built version |
| `vue` × `node-api` | Vue 3 SPA + Express 5 + PostgreSQL + Prisma | Uses the pre-built version |
| `none` × `none` | Custom | No guide (Core only) |
| Every other combination | The combination of the axes (including the app axis · `fastify` · `rust-axum` · custom) | Guide is **generated** (verification loop included) |

## Project Override — precedence for the user's assets

**The norm first** — ahead of any file mechanism, the precedence the model follows is stated explicitly
(`.claude/rules/workflow-routing.md`, "Instruction precedence", loaded every session). The two layers
run in opposite directions:

- **The safety floor** (reversibility classification · verification duties · secret boundaries · decision points) — a project can **only raise**
  it. Lowering it requires an explicit request from the user.
- **Procedure and form** (the guide pack's stack practices · skill workflows · naming · document format) —
  **the project wins.** The order is user request → project `CLAUDE.md` · `AGENTS.md` →
  project `.claude/rules/` · `docs/` → **the existing code patterns in the repository** → plugin guides and skills.

The last arrow is the point — **existing code patterns beat the plugin guide.** Where the shape the
guide recommends differs from the shape the repository actually uses, follow the repository. And the
`AGENTS.md` · `CODEX.md` · `.github/` · `docs/` and pre-existing `CLAUDE.md` the consumer already had are **not edited
without an explicit request** (non-invasive).

Below is the mechanism that backs that norm at the file level.

| Asset | Precedence mechanism |
|------|--------------|
| Rules (`.claude/rules/`) | **Project-owned** — install-rules preserves a user-modified copy when it detects one (version stamp) |
| Hooks (`settings.json`) | Project hooks and plugin hooks **both** run (coexistence, no conflict) |
| Skills | Plugin skills **coexist** as `orangekit-product:name`, project skills as `name`. If you need strong precedence, **a different name + a boundary declaration in the description** is the sure thing — that is exactly why this plugin keeps the stack guide only as the project's `frontend-guide` and keeps the plugin side as **axis packs** (`guides/`) rather than skills — if the names do not collide there is no precedence fight at all |

Customization example:

```bash
mkdir -p .claude/skills/my-brainstorming
# Write a custom SKILL.md — state in the description "prefer this skill for brainstorming"
```

Do not edit the plugin files themselves — an update overwrites them. Do all customization on the
project side (`.claude/`); the plugin is designed to respect it.

## Upgrading from v2

```
/orangekit-migrate
```

It removes dead hooks, rearranges the rules into 3 tiers, and renames the agents.
It checks with `doctor --default` after each step as it goes, and preserves project-specific assets.

### Key v2 → v3 changes

| Item | v2 | v3 |
|------|-----|-----|
| Hooks | 11 (many void from output-format violations such as Stop's `decision`/`reason`) | **5, every one self-testing** |
| Rules | the generator copied them into `.claude/rules/` (3 unconditionally loaded + 11 conditional) | **T0 41 lines + T1 1,089 lines, installation demonstrated by `install-rules.sh`. The always-on/conditional split is kept** |
| Verification strength | S/M/L size judgement | **reversibility axis (decided by path)** |
| Phase | P0~P6 (`.claude/rules/task-workflow.md` loaded always) | **P0~P6 kept** — moved to `workflow-routing.md`, the always-loaded property preserved |
| Agents | no frontmatter, access to every tool | **full contract + least privilege** |
| Skills | 37 | **26** (removed only what native does better; added the guide generator, the enhancer and the shortcut ledger) |
| Verification | none | **`doctor`, 5 modes** |
| Graph | scattered through prose | **`workflow.graph.json` + instrumentation** |

**Removed**: `persistent-loop` · `loop-keyword-detector` (→ native `/loop`) ·
`skill-generator` (→ `skill-creator` — the methodology is equivalent, but only the native one offers measured A/B evaluation) ·
`requesting-code-review` (→ native `/code-review`; the plan and PRD cross-check moved to `orangekit-reviewer`) ·
3 PostToolUse trackers

**Not removed**: even where a native equivalent exists, it is **kept when the coverage differs**.

| Skill | What the native one does not cover |
| --- | --- |
| `/security-review` | The built-in is branch-diff only and explicitly excludes secrets. This skill covers the full-codebase audit, dependency CVEs and payment security |
| `/receiving-code-review` | The built-in *produces* findings. There is no counterpart that *critically verifies* the findings you receive |
| `/harness-evaluation` (the `orangekit-harness` plugin — not in the devkit) | `doctor` measures (hook liveness · dangling · budget); this skill judges (is the design good · is it overkill for the current model) |
| `/shortcut-ledger` | The built-in `/simplify` shrinks code you have **already written**. There is no counterpart that tracks whether the ceiling on a deliberately left shortcut has expired (the norm for before you write is `code-change.md`, "The implementation ladder") |
| `/codebase-survey` | The built-in `/init` creates `CLAUDE.md` **once**. `orangekit-init` also measures only once, at the very start, and the two project-owned cards it makes (`project-structure` · `code-conventions`) have **neither an update path nor a drift detector.** This skill is that update path, and it only measures and describes — it does not prescribe structure |
| `/pr-prep` | The built-in `/code-review` handles the **defects** in a diff, `orangekit-reviewer` the **contracts**, `/completion-review` the **documents**. **There is no counterpart that writes the PR body** — the form where the reversibility class decides the mandatory sections (rollback procedure · call sites · grounds for intervention) is specific to this harness |

> **The test**: "a native equivalent exists" is evidence of overlap, not evidence of inferiority.
> To propose retiring something you must open both bodies of text and compare their coverage, and what
> you compare against must be the best, undamaged version.

## Next Steps

- [Illustrated manual](https://orangekit.vercel.app/manual/) — the task map and the administrator map
- [User manual](docs/user-manual.md) — **what to use when, by kind of task** (journey-oriented)
- [Operations manual](docs/operations-manual.md) — for administrators: the procedures and runbooks for fixing and maintaining the harness
- [Harness anatomy](docs/harness-anatomy.md) — **why** the hooks, the 3 rule tiers, the loops and the graph **are implemented the way they are**
- [Configuration Reference](docs/configuration.md) — every option in `orangekit.config.json`
- [Presets Guide](docs/presets.md) — preset details
- [Windows install guide](docs/windows-setup.md) — the Git for Windows and `jq` prerequisites, and the verification checklist

## License

MIT
