---
name: orangekit-init
description: Initial setup for an ORANGEKIT Devkit project. Creates orangekit.config.json and CLAUDE.md. Use when setting up ORANGEKIT Devkit for the first time in a new project.
disable-model-invocation: true
---

# /orangekit-init — ORANGEKIT project initial setup

## Purpose
Creates this project's ORANGEKIT Devkit configuration files (`orangekit.config.json`, `CLAUDE.md`) and initializes the `dev/` directory structure.

## Procedure

### Step 0: Measure the repo once (before asking — to cut down what you ask)

**Read before you ask.** Asking about things you could have found out is where most of the interview
time goes. Sweep the following in one pass and pre-fill the defaults for Steps 2, 4, 4.5 and 4.7:

```bash
ls -a                                   # existing code · toolchain traces
cat package.json 2>/dev/null            # framework · packageManager · scripts · deps
cat pyproject.toml requirements.txt 2>/dev/null
ls pnpm-lock.yaml yarn.lock package-lock.json bun.lockb uv.lock poetry.lock 2>/dev/null
ls src app packages services apps 2>/dev/null   # sourceDir · repoTopology
cat tsconfig.json 2>/dev/null | head -20        # importAlias · strict
git remote get-url origin 2>/dev/null           # vcsPlatform — github.com / gitlab.com
```

What measurement settles: project name · framework · language · package manager · build/test/lint
commands · source directory · importAlias · repo topology · backend axis (inferred from deps) ·
code hosting platform.

If the remote URL contains `github.com`, **settle on** `github`; if `gitlab.com`, `gitlab`
— do not ask. Only ask in the third call when it is self-hosted or there is no remote to decide from.
**A new empty project has nothing to measure, so the preset defaults take that place.**

### Step 0.5: Environment check — `jq`

This harness's verification hook (`build-gate`) and `doctor --graph` only work fully when `jq` is
present. Without it the plugin still installs and runs, but both safeguards **degrade silently,
without a single error** (macOS does not ship it, and Windows does not include it in Git Bash either).

```bash
command -v jq >/dev/null 2>&1 && jq --version || echo "MISSING"
```

- **If present**, move on to Step 1 without saying anything.
- **If missing**, say so briefly and ask whether to install it (a plain confirmation is enough — do
  not spend `AskUserQuestion` budget):

  > "`jq` is missing, so build verification and graph verification start in a degraded state. Install it now?"

  Detect the package manager and pick the command (use the first one found):

  | Detected | Install command |
  | --- | --- |
  | `command -v brew` | `brew install jq` |
  | `command -v winget` | `winget install --id jqlang.jq -e --source winget` |
  | `command -v apt-get` | `sudo apt-get install -y jq` |
  | `command -v dnf` | `sudo dnf install -y jq` |
  | `command -v apk` | `apk add jq` |
  | none of the above | cannot automate — point to https://jqlang.org/download/ and skip |

  For paths that need `sudo`, first try `sudo -n <command>` without a password. If that fails
  (a password prompt would freeze the tool), **give up on running it** and merely tell the user
  the command to run in their own terminal, then move to the next step.

  A refusal or a failed install **does not block initialization** — say "Continuing without the
  install. You can install it later with `<command>`" and proceed to Step 1.

  This step covers **the `jq` install only**. If the check itself behaves strangely on Windows
  (command not found, and so on), the cause may be a missing Git Bash, which is not what this step
  fixes — point to [`docs/windows-setup.md`](../../docs/windows-setup.md).

### Step 1: Check for existing configuration

Check whether these files exist at the project root:
- `orangekit.config.json` — if present, confirm: "Already configured. Reconfigure?"
- `CLAUDE.md` — if present, confirm whether to back up and overwrite

### Interview protocol — only pull forward answers that change a later question's list

Steps 2, 4, 4.5 and 4.7 originally had 3 mandatory waits plus 5 conditional ones. The Step 0 measurement fills
most of them, so **ask only about what is left, in batches.** Asking one at a time is what spends the most of a person's time.

The batching rule is **dependency, not count**. `AskUserQuestion` collects the answers of one call
**simultaneously**, so an earlier answer that **changes a later question's option list cannot go in
the same call.** The tool's limits are **4 questions · 4 options**.

| Call | Questions batched | Why this order |
| --- | --- | --- |
| **1st — what are you building** | ① product form ② backend type ③ response language ④ experience level | ① splits the frontend list, ② splits the backend detail list |
| **2nd — what are you building it with** | ⑤ frontend (filtered by ①) ⑥ backend detail (filtered by ②) ⑦ TS/JS language or PWA ⑧ repo topology | can only be asked once the lists are settled |
| **3rd — what are you putting it on** (conditional) | ⑨ deployment target (when it is a self-hosted-server framework) ⑩ undecided backend dimensions ⑪ code hosting (only if Step 0 failed to decide — `github` · `gitlab`) ⑫ whatever measurement missed | ⑨ depends on ⑥ |

- **When a measured value exists, put it first as the default option** — most of the time the user just confirms and moves on
- **Do not make the third call if there is nothing to fill.** Pre-built combinations usually finish in two
- Ask only questions whose answers branch. Implementation details like "should we use the pre-built one or generate?" are not asked
- Ask the first question **in product terms** — "pick a frontend" requires already knowing the answer,
  while "what are you building" is something anyone can answer

### Step 2: Preset selection (interactive)

A stack is made of a **frontend axis and a backend axis**, with **dimensions** that are not axes layered on top
(product form · language · deployment target). Axes pick the pack; dimensions turn that pack's **conditional slots** on and off.

```
① What are you building — this choice sets the lists for the later questions:
  1. Web           — reached through a browser. No install
  2. Hybrid app    — one web codebase shipped as both web and a store app (Capacitor, etc.)
  3. Native family — React Native · Flutter · Swift · Kotlin
  4. API only      — no user-facing screens
```

**What this question settles** is not just the frontend list. `deliveryModel` and its derived value
`clientKind` (`browser` for web, `app` for the other three) split **the slots of the backend and infrastructure
guides** too — whether the token goes in a cookie or secure storage, whether the idempotent batch ingest,
push and API version negotiation sections come alive. **It is information that is unreachable unless you ask.**

```
② Pick a frontend:            ← ① splits the list

  ▸ If ① is "Web" or "Hybrid app":
    1. nextjs      — Next.js 15 App Router + React 19 + Tailwind v4 + shadcn/ui + Zustand
    2. react-vite  — React + Vite SPA (no SSR) + Tailwind + React Router + TanStack Query + Zustand
    3. vue         — Vue 3 Composition API + Vite SPA (no SSR) + Tailwind + Vue Router + Pinia
    4. vanilla     — no framework, standard DOM + ES modules (landing pages · widgets · lightweight sites)

  ▸ If ① is "Native family" — **there is no matching axis pack.** Take the actual technology,
    record it in `techStack.nativeStack`, and send the frontend axis down the **generation path**:
    1. React Native   2. Flutter   3. Swift / Kotlin   4. Other (free input)

  ▸ If ① is "API only" — do not ask. The frontend axis is `none`

   └ Language: TypeScript (default) / JavaScript — confirmed after the preset is chosen
   └ If ① is "Web", also confirm PWA (service worker · offline cache · install prompt)

③ Pick a backend type — **these are not three interchangeable names but three different shapes**:
  1. BaaS            — the vendor supplies DB, auth and storage together. There is a policy engine in the data layer
  2. Serverless assembly — you compose managed services yourself. **There may be no row-level policy engine**,
                     so the application layer carries more of the checking
  3. Self-hosted server  — you run a resident server. The application layer is the only boundary
  4. None            — no backend / consuming an external REST API

  ↳ 1. BaaS — which vendor:
      1. supabase        — PostgreSQL + RLS + Auth + Storage + Realtime
      2. firebase        — Firestore + Auth + Storage + Cloud Functions

  ↳ 2. Serverless assembly — the cloud is the runtime model:
      1. aws-serverless  — Lambda + API Gateway + DynamoDB + Cognito
      2. gcp-serverless  — Cloud Run/Functions + Firestore + Identity Platform

  ↳ 3. Self-hosted server — pick the framework first:
      1. aws-container   — Hono + Drizzle · ECS/Fargate + RDS PostgreSQL + Cognito
                           (a finished product including the AWS infrastructure. On-premises
                            portability is assumed, so AWS coupling stays in the infrastructure layer only)
      2. fastapi         — **Python**: FastAPI + SQLAlchemy 2.0 + Pydantic v2 + Alembic
      3. node-api        — Express 5 + PostgreSQL + Prisma
      4. node-nest       — NestJS 11 + PostgreSQL + TypeORM 1 + class-validator
                           (modules, DI and decorators set the structure — it is not a variant of Express)

      **Only `fastapi` is Python; the other three are TypeScript** — the toolchain splits, so the
      commands differ from the frontend axis.

      ↳ If you picked `fastapi`, `node-api` or `node-nest`, also pick the **deployment target (server setup)**:
          1. Undecided / cloud-agnostic (default) — the same guide wherever you deploy
          2. AWS                          — ECS/Fargate · EC2, etc.
          3. Other (free input)           — GCP · Azure · Vercel · on-premises
        `aws-container` already settles AWS, so this question is not asked.
```

**Record the product form in `techStack.deliveryModel`** (`web` · `hybrid` · `native` · `api-only`).
For "Web" also fill `techStack.pwa`; for "Native family" fill `techStack.nativeStack`.
And **write the derived value into the config alongside it**:

> `clientKind = (deliveryModel === 'web') ? 'browser' : 'app'`

If each pack re-derives it on its own the descriptions diverge, so **decide it in one place and let
the packs read only this value.** Hybrid and native are all the same from the backend's point of
view — not "a browser talking to a server" but **"an app talking to an API"**.

| Slot | `browser` | `app` |
| --- | --- | --- |
| Client auth transport | cookie session · CORS · CSRF defense | **Bearer + secure storage** (not cookies) |
| Idempotent ingest | empty | **alive** — offline batch sync is assumed |
| Push delivery | empty | alive (FCM/APNs) |
| API version negotiation | empty | alive — old app versions keep running |

**An empty slot is the normal path.** A web project's backend guide having no push section is not a
defect; it is the dimension working correctly.

> **Conflict warning — "Hybrid app" × `nextjs`**: a Capacitor shell carries static assets, so
> `output: 'export'` is forced and **Server Actions and Route Handlers cannot be used.** When this
> combination comes up, tell the user and offer the choice of ⓐ switching to `react-vite` or
> ⓑ using Next.js as a static export while moving the server features to the backend axis. **Without
> asking for the product form there is no way to detect this conflict.**

**Record the deployment target in `techStack.backend.cloudProvider`** — not a new field but a
dimension already in the schema (`null` when "undecided"). When this value is empty a cloud-agnostic
guide ships; when it is filled, Step 4.5 and Step 9.5 treat that cloud's infrastructure guidance as a requirement.

> **Why ask for the type first** — "AWS" is not a backend framework but a deployment target. Yet
> treating the cloud as a **freely combinable axis** alongside frontend and backend breaks two things.
> ⓐ `aws-container` (a Hono container) and `aws-serverless` (Lambda handlers) share only the cloud;
> **the frameworks themselves differ** — "same framework, just swap the cloud" does not hold.
> ⓑ It conflicts with the decision to make the pre-built unit an axis rather than a combination
> (`docs/presets.md`), and combinations explode. So **infrastructure is treated as an independent
> dimension only in the resident-server family** — for serverless and BaaS the cloud is the architecture, not something to separate.

**Language (TypeScript/JavaScript) is a dimension, not a preset, and so is the product form.** Axes
pick which pack to use; dimensions **turn that pack's conditional slots on and off** — language splits the
type-standard slot, product form splits the offline, shell, auth-transport and push slots. That is why
**a pack itself must hold for any combination of dimensions, and specialization happens at generation time.**
Nail dimension-specific content into a pack as prose and that pack tilts toward one form and becomes wrong guidance for every other combination.

> **Why two axes**: guide content is not a function of one axis but **a function of the combination**.
> The same Supabase paired with Next.js centers on Route Handlers and Server Actions; paired with a
> React+Vite SPA it centers on Edge Functions and direct browser calls — **an entirely different
> guide**. Both axes must be settled before a guide that accounts for each of them can be made.

`frontend: none` is the result of choosing "API only" in ① — it is a consequence of the product
form, not an option on the frontend axis, so it is not asked in ②. The combination
`frontend: none` + `backend: none` corresponds to the former `blank` preset.

### Step 3: Load preset defaults (merge)

Read three files and merge them in this order (later overrides earlier):

1. `${CLAUDE_PLUGIN_ROOT}/presets/base.json` — shared domains · security patterns
2. `${CLAUDE_PLUGIN_ROOT}/presets/frontend/<choice>.json`
3. `${CLAUDE_PLUGIN_ROOT}/presets/backend/<choice>.json`

Merge rules:

- `additionalStack` is **accumulated**, not overwritten
- `domains.sourceDir` prefers the frontend axis's value. If the frontend is `none`, use the backend
  axis's `sourceDir`. If both axes exist and the values differ, confirm with the user
- Each preset's `notes` is not written into the config — in Step 9.5 it is **passed to the guide
  generation agent as combination context** (the basis for making a guide that accounts for both axes)

### Step 4: Collect project information (interactive)

Ask the user for the following (show the preset default where one exists):

1. **Project name** (required)
2. **Response language** — 4 options + "Other" (the free input `AskUserQuestion` provides automatically)

   | Display | `language` | `languageLabel` |
   | --- | --- | --- |
   | 한국어 | `ko` | `한국어` |
   | English | `en` | `English` |
   | Bahasa Indonesia | `id` | `Bahasa Indonesia` |
   | Tiếng Việt | `vi` | `Tiếng Việt` |
   | Other (free input) | the BCP-47 tag for the input | that language's **endonym** (its own name for itself) |

   A value that arrives through "Other" is normalized by the model — "Thai" · "ภาษาไทย" → `th` / `ภาษาไทย`.
   If the tag cannot be settled, leave `language` empty and fill only `languageLabel`.
   **Write both values into the config.** `session-brief.sh` reads them to substitute
   `{{RESPONSE_LANGUAGE}}` in the T0 operating rules — if they are not written here the language choice never arrives.

   All this choice settles is the **final output language**. Analysis and reasoning are always in
   English, and technical terms that are standard in English across the industry (`Bottom Sheet` ·
   `GNB` · `middleware`) stay in English whichever language is chosen — the canonical source for this norm is T0.
3. **Experience level** — senior / mid / junior (default: senior)
4. **Framework, language and package manager per axis** (confirm the merged preset defaults)
5. **Build/test/lint commands** (confirm the preset defaults)
6. **Source directory** (confirm the result of the Step 3 merge rules)
7. **Shared package path** (required for `monorepo` and `msa` — see Step 4.7. Skipped for `single`)

**Combinations with two toolchains** (for example react-vite + fastapi — TypeScript/npm and Python/uv) have
different commands per axis. In that case take the per-axis commands separately and confirm the
**project-level commands** (`techStack.commands`) on their own — build-gate and health-check read those values, so they must be filled.
In a monorepo the project-level command is often a root script that runs both axes together.

### Step 4.5: Fill the backend's undecided dimensions

The backend **type** was already settled in Step 2 — do not ask again here. Fill only the dimensions
the chosen backend preset left empty:

| Backend axis | Already settled | What to ask here |
| --- | --- | --- |
| `supabase` | backendType · database · dataAccess · auth, all of them | nothing — show and confirm |
| `fastapi` | backendType · database · dataAccess | **auth method** (self-issued JWT · OAuth provider · session) · hosting (optional) |
| `node-api` | backendType · database · framework (Express 5) · ORM (Prisma) | **auth method**. The framework and ORM are nailed down by the pack — anything else is `node-nest` or the generation path |
| `node-nest` | backendType · database · framework (NestJS 11) · ORM (TypeORM 1) · validation (class-validator) | **auth method**. Whether the guard reads a session cookie or a bearer token is a function of the frontend axis |
| `aws-container` | defaults for every dimension | nothing — show and confirm. Changing the defaults (RDS PostgreSQL · Drizzle · Cognito) leaves the pre-built set and takes the generation path |
| `aws-serverless` · `gcp-serverless` | defaults for every dimension | any dimension where a different service is used (e.g. DynamoDB→RDS) |
| `firebase` | every dimension | nothing — show and confirm |
| `none` | — | if an external API is used, its auth method (where the token is kept is the security point) |

If a request comes up to switch to a combination outside the presets (MongoDB · Prisma · Cognito, etc.), take
the dimensions on the spot and record them in `techStack.backend` — a preset is a starting point, not a ceiling.
In that case the combination leaves the pre-built set, so Step 9.5 takes the generation path.

### Step 4.7: Confirm the repo structure (interactive)

If there is existing code, first show the value inferred from measurement (`ls` + a look at the main directories) as the default and merely take a confirmation:

```
Confirming the repo structure:

1. monorepo — root app + shared packages (packages/)                (default)
   ↳ When code is used in two or more places. Web+admin, app+landing, shared UI · types · utils
   ↳ packages/ is classified Costly, so edits pick up one more review step

2. single   — one app
   ↳ When there is nothing to share yet. Prototypes · single services
   ↳ If packages/ shows up later, you move up to monorepo then (easy to reverse)

3. msa      — several services (services/ · apps/)
   ↳ When there are several deployment units. API and event contracts between services are managed separately

If it is hard to choose — is there code right now that two or more places use?
  Yes → 1   ·   No → 2   ·   Deployed separately → 3
```

- **Measurement beats the default.** If an existing repository has no `packages/` or `services/`,
  offer `single` as the default. The `monorepo` default applies **only to new projects and when measurement is undecidable**
- The shared package path (Step 4 item 7) is **skipped only when `single` is chosen** — `monorepo` and `msa` require it.
  Without that path Step 7.5 cannot fill the structure card's `paths:`, and an empty `paths:`
  means that card is never loaded over shared code again
- The result is used for `domains.repoTopology` in Step 5 and for the structure card in Step 7.5

> **Why the options carry explanations** — with only a default and no basis for judgement the user
> just presses the default, and a one-app project starts out carrying an empty `packages/`.
> The deciding question is not scale but the single question **"is there code right now that two or
> more places use?"** — ask by scale and you get "it will probably grow", which is not a basis.
>
> And what structure protects is **only up to the review requirement**. What actually tells you
> "I fixed A and B broke" is B's tests; structure only makes it possible to run those tests independently.

### Step 5–6: Create orangekit.config.json · CLAUDE.md

**Read `assets/config-and-claude-md.md` and follow it exactly.**

### Step 7: Install the T1 rule cards (required — do not skip)

Install the plugin's rule cards into the project's `.claude/rules/`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-rules.sh"
```

Cards installed:

| File | Load condition |
| --- | --- |
| `workflow-routing.md` | **every session, unconditionally** (no `paths`) — task routing P0–P6 + reference freshness |
| `code-change.md` | editing `src/**` `app/**` `packages/**` `lib/**` |
| `security.md` | editing `src/**` `app/**` `packages/**` `lib/**` |
| `reversibility.md` | editing source · migrations · workspace |
| `harness-change.md` | editing `.claude/**` `scripts/**` `hooks/**` |
| `lessons.md` | editing source · `.claude/**` · `scripts/**` · `dev/docs/**` |
| `doc-dependency.md` | editing `dev/docs/{prd,database,design,architecture,api}/**` |
| `data-modeling.md` | editing DB paths such as `supabase/**` `**/migrations/**` `db/**` `prisma/**`. It holds only §1–8; the ten patterns are moved down to `.claude/references/data-modeling/` so **only what is needed** is read |
| `ui-design.md` | editing `**/components/**` `**/*.{css,scss}` `**/app/**/page.{tsx,jsx}` `**/app/**/layout.{tsx,jsx}` |

> This table must reflect the real frontmatter in `rules/`. When a card is added or changed, fix this too
> — `doctor --fast` detects a card-count mismatch.

**Always verify after installing**:

```bash
ls .claude/rules/
```

Zero files means the install failed. Report to the user and stop.

> **Skipping this step is recovered in the next session** — the `session-brief` hook automatically
> runs `install-rules.sh --missing-only` when `orangekit.config.json` exists and cards are missing.
> Run it here anyway: work that needs the rules may follow immediately in this session, and the hook
> installs **only what is missing**, it does not refresh outdated versions.
>
> The always-on norms (T0) are not a file; the `session-brief` hook prints them every session.
> They are plugin-owned, so they update automatically and the project cannot modify them.

### Step 7.5: Create project-specific rule cards (project-owned)

Where Step 7's cards are **plugin-owned** (auto-refreshed by a version stamp), this step's two cards
are **project-owned** — they hold this project's real structure and conventions, and the project manages them from then on.

1. Read `${CLAUDE_PLUGIN_ROOT}/templates/rules/project-structure.template.md`
2. **If there is existing code, measure the real tree** (`ls` + the main directories 2–3 levels deep) —
   do not fill it in by guessing. For a new project, fill in the target structure from the preset + the Step 4.7 topology
2.5. **Fill the "dependency direction" section** — if there is existing code, measure the direction
   imports actually flow; if new, write the direction of the preset topology. If there are no layers,
   write "single layer — not applicable". **Do not force one into existence** — write a layer into
   the card that does not exist and `orangekit-reviewer` will report violations that do not exist
3. Substitute or remove every placeholder and guidance comment and save it under `.claude/rules/`
   as `project-structure.md`
4. `${CLAUDE_PLUGIN_ROOT}/templates/rules/code-conventions.template.md` the same way —
   keep **only the one stack block** matching the preset and keep the shared blocks (naming · code
   style · commit conventions). If existing lint settings or CLAUDE.md carry project-specific
   conventions, confirm with the user and fold them in, then save as `code-conventions.md`
5. Check that both cards' `paths:` frontmatter points at the **real source directory** (the Step 4
   input) — if paths are wrong the card is never loaded.
   **Also check the paths the topology requires** — for `monorepo` the shared package path, for
   `msa` the service roots, must actually exist in `paths:`. **If they do not, do not save the card**;
   go back to Step 4.7 and Step 4, settle the paths, and generate again.
   A card that covers only the source directory never once appears over shared code —
   such a card is worse than no card (it makes you believe there is one)

> Do not put an `orangekit-rule-version` stamp in these two cards — that marks them project-owned.
>
> **The protection mechanism is not the stamp but name non-collision.** `install-rules.sh` iterates
> only the plugin's `rules/*.md` (`for f in "$SRC"/*.md`), so as long as `rules/` has no file of the
> same name, they never become candidates. Therefore **do not create `project-structure.md` or
> `code-conventions.md` in the plugin's `rules/`** — the moment you do, the unstamped target is read
> as `0.0.0` and the project's copy is overwritten (a `.bak` remains, but it is a silent loss).

### Step 8–9.5: dev/ · .gitignore · securing the stack guides

**Read `assets/scaffold-and-guide.md` and follow it exactly.**

### Step 10: Completion report

```
ORANGEKIT Devkit initial setup complete!

Files created:
  ✅ orangekit.config.json
  ✅ CLAUDE.md
  ✅ .claude/rules/ (N plugin rule cards + project-specific project-structure · code-conventions)
  ✅ dev/ directory structure

Guides (copy the `status:` line from Step 9.5 verbatim — do not report a half as finished):
  ✅ .claude/skills/<axis>-guide      — skill complete (complete)
  ⏳ .claude/skills/<axis>-guide/     — resources only · awaiting the seam (resources)
  ⏳ <axis>                           — needs generating (generate)

Verification:
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh"

Next steps:
  1. Review CLAUDE.md and fill in project-specific information
  2. Restart Claude Code and the harness activates
```

## Cautions

- This skill creates files at the project root
- If a `CLAUDE.md` already exists, always confirm whether to back it up
- Secret blocking is **built into** the `security-check.sh` hook — it is not a project configuration item
