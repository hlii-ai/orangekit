---
name: stack-guide-generator
description: Writes a stack rule file (.claude/rules/stack-*.md) for a stack with no pack (Rust · Flutter · SvelteKit and the like), backed by the official docs (default), and on request generates detailed guide skills (frontend/backend/app-guide) into the project's skills directory. Use when orangekit-init calls it after the stack has been chosen, or when the user asks for "stack rules", to "generate guides", for a "stack guide", or to "change the tech stack".
---

# Stack Guide Generator

Creates a project-owned asset for the confirmed stack — by default a **stack rule file**, on request a **detailed guide skill**.
A guide skill's structure follows the `assets/guide-skeleton.md` generation spec; the content is filled from knowledge of the combination.

> **Principle: build the body first, verify it, and only then install.** The failure mode this
> skill replaces is producing a skill (a placeholder) whose description promises what the body cannot keep.
>
> **`dev/docs/skill-review/` is the canonical source for measured evidence** — wall clock, tokens, defect classes, and
> reversibility verdicts all live there. Only **rules** live here. A copy is a source of drift.

## Mode — the rule file is the default

| Mode | When | What to follow |
| --- | --- | --- |
| **rules** (default) | init chose "rule file only" for an axis with no pack · a request for "stack rules" · a call that names no mode | **Read `assets/rules-authoring.md` and follow it as written.** Skip Steps 0~7 below |
| **full** (detailed guide) | `.orangekit/guide-job.json` exists · the user explicitly asked for a "detailed guide" or "generate guides" | Steps 0~7 below |

Rule generation writes **only items backed by evidence from outside the model (official doc URL · check date · installed version)**, and creates no file if it cannot back even one.
The evidence is a measurement: the detailed guide did not raise scores and a small rule file scored the same (guide A/B, 2026-10),
and the universal rules (L1) alone blocked the known pitfalls (T-D "L1 only", 3 runs at 23/23, 2026-10-25). Full mode stays because pack authoring (Step 2-A) uses those assets.

## Process principles (derived from the 2026-08-21 A/B measurement) — full mode

The generation method alone does not produce quality. **Generation + a verification loop are one set.** The evidence is
A/B v1~v3 in `dev/docs/skill-review/` — in every round, artifacts that had "self-reported a pass" turned out
to carry further real defects.

| # | Principle | Measured evidence |
| --- | --- | --- |
| 1 | **No adaptation; fresh generation from the spec** | The adapted draft failed 4 items of the install gate. The cause was not content leakage but **context inertia** (inheriting traits that are right for the original and wrong for the generated artifact) |
| 2 | **Slot contracts down to the resource layer, not the hub alone** | Artifacts from before the slot table were broken hubs referencing 5~6 resources that did not exist |
| 3 | **Volume is not quality** | The 1,800-line generated copy beat the 3,000-line original. Accumulation without audit piles up rot along with it |
| 4 | **Everything a machine can catch, catch with a machine** | Most of the detected defects were caught by grep rather than by judgement (dangling · leakage · budget · cut surfaces · signatures) |
| 5 | **Generator ≠ verifier** | The generating agent self-reported a pass on every item each time, yet an independent audit found defects |
| 6 | **Audit reports are also subject to reconfirmation** | Some of the auditor's findings were misjudgements (spec compliance ruled a violation) |
| 7 | **Do not run up against the budget ceiling** | In a file that has reached 300 lines, the next change lets the budget, not the author, pick what gets deleted |
| 8 | **What must be followed goes on the card; what the model already knows goes nowhere** | The guide A/B (measured, 2026-10): generic patterns did not raise scores, the skill body went unread on easy tasks, and a 1.65KB card scored the same as the full guide. Spec "Stack core card" |

## Step 0: Is there a handed-off job (if there is, that is the input)

If `install-guide.sh` left a `.orangekit/guide-job.json`, it is both the input for fixing the dimensions and the scope
instruction. If there is none, go to Step 1.

```bash
cat .orangekit/guide-job.json 2>/dev/null
```

| Field | Use |
| --- | --- |
| `combo` | The confirmed combination. **Do not** ask the axis questions of Step 1 |
| `need` | What to build. The vocabulary below maps 1:1 onto the rows of the Step 2 branch table |
| `packs` | Paths of the assembled packs. That axis is an "axis that has a pack", so read the three files in Step 2 |
| `app` | The app axis value (`presets.app`). If it is not `none`, `app-guide` is a target — if a pack exists, its path is carried in `packs.app` |
| `auditRound` | How many audit rounds have been launched so far. **At 1, launch no more audits** ("Audit and repair budget") |
| `notes` | The axis preset notes (serverCode · securityBoundary · policyEngine · language · appNotes) **＋ dimensions that are not axes** (deliveryModel · clientKind · pwa · appShell · nativeStack). The entire input for combination dependencies and conditional slot decisions |

| `need` item | Meaning | What to build |
| --- | --- | --- |
| `seam:frontend` · `seam:backend` · `seam:app` | The packs are assembled and only the seam is missing | That axis's seam + hub (as many as the axis's `seamSlots`). **If that axis is in `variantGaps`, write only that variant file**, then carry over the pack's `HUB.md` as the hub and add only that file's row to Navigation — the API client and complete example are already in the pack |
| `frontend` · `backend` | There is no pack, or it is unfinished (including `custom`) | That axis in full (hub + every resource) |
| `app` | The app pack is missing or unfinished (including `custom`) | `.claude/skills/app-guide/` in full. The input is `techStack.app` + the notes in `presets/app/<name>.json` (for `custom`, the entered framework) |
| `refresh:frontend` · `refresh:backend` · `refresh:app` | Assembly finished on the verified major, and the registry has a higher major | **After every other need is done, last of all** ask the user (Step 7), and if chosen rewrite only the affected files of the completed install at the new major — "Step 2-B: refresh" below |

**Write `status` as `running` when you start.** If the session dies, that state remains and
the `session-brief` hook reports it to the next session — the device that keeps the time spent on generation from vanishing silently.

```bash
python3 - <<'PY'
import json; p='.orangekit/guide-job.json'; j=json.load(open(p))
j['status']='running'; json.dump(j, open(p,'w'), ensure_ascii=False, indent=2)
PY
```

> **Closing it is this skill's responsibility too** (Step 7). If there is a place that writes it and none that closes it, that notice
> becomes permanent noise — which is exactly what happened.

## Step 1: Fix the dimensions

Priority: `techStack` in `orangekit.config.json` → interview only for the dimensions still missing.

If orangekit-init has run, `techStack.presets` (the per-axis choices) and `techStack.frontend`/`app`/`backend` are already
filled in. **Read every axis and treat them as a combination** — generating from one axis alone yields guides that
have not taken each other into account (see combination dependencies below).

| Dimension | Example choices | Dependency rule |
| --- | --- | --- |
| **Product form** | web · hybrid · cross-platform · native · API-only | **Fix this first** — it splits the screen axes, and the derived value `clientKind` splits the backend-guide slots. If `techStack.deliveryModel` exists it is already fixed |
| Web screens | Next.js · React+Vite · SvelteKit · none | `none` when only a cross-platform or native app is built |
| App | React Native · Flutter · Swift · Kotlin · none | `techStack.presets.app`. A hybrid has it only when `appShell` is the RN family. If a `guides/app/<name>/` pack exists, it is assembled and only the seam is built |
| Backend type | BaaS (Supabase · Firebase) · self-built on cloud · framework built-in | If `techStack.presets.backend` exists it is **already fixed** — do not ask again. If this skill is invoked standalone and there is no preset, this is a required question |
| Cloud/hosting | AWS · GCP · Azure · Vercel · self-hosted | Required when self-built is chosen |
| DB | PostgreSQL · MySQL · MongoDB · DynamoDB | For BaaS, infer automatically and only confirm; for self-built, a required question |
| Data access | Prisma · Drizzle · SQLAlchemy · SDK directly | After the DB is fixed |
| Auth | Supabase Auth · NextAuth · Cognito · self-built | Tied to the backend type |

**Reading an old config** — a config without `presets.app` carries the pre-3-axis meaning: read a `hybrid` with no `appShell` as
`capacitor`, and a `native` whose `nativeStack` is RN or Flutter as `cross-platform` (the canonical conversion is
"App axis migration" in `orangekit-migrate`).

Record the confirmed combination in `techStack.backend` of `orangekit.config.json` (the schema's backendType · cloudProvider · database · dataAccess · auth fields).

## Step 2: Generation scope and branching — look up the axis packs first

**The prebuild unit is the axis, not the combination.** There are 45 combinations but only 14 axes (5 frontend ·
9 backend), and most of a guide's content is a function of one axis alone. So **build only what is missing.**

```bash
ls "${CLAUDE_PLUGIN_ROOT}/guides/frontend/" "${CLAUDE_PLUGIN_ROOT}/guides/backend/" "${CLAUDE_PLUGIN_ROOT}/guides/app/" 2>/dev/null
ls "${CLAUDE_PLUGIN_ROOT}/guides/seams/"
# If a pack exists, check whether it is still right today — meaningful **only on a first install**
bash "${CLAUDE_PLUGIN_ROOT}/scripts/guide-freshness.sh" --pack "${CLAUDE_PLUGIN_ROOT}/guides/<axis>/<pack>"
```

**Rot is judged by the `pkgs` major, not by the date.** If six months pass and no major has risen it is not stale;
if a framework major rises after two months it is stale. `fixesVariants` is the handling boundary:

| Package that rose | Meaning | Action |
| --- | --- | --- |
| One caught by `fixesVariants` (framework · ORM) | **The pack's premise changed** | The pack is not fixed (it is the maintainer's periodic refresh target). Assemble at the declared major, and if the user chooses to apply it, move **only the installed copy** with Step 2-B |
| Any other package | Partial rot | The same — after assembly, if applying is chosen, move **only the affected resources** of the installed copy with Step 2-B |
| No major rose | Fresh | Assemble as is (0 lines) |

**Do not run this on an existing project.** `install-guide.sh` already enforces "the project fixes the stack
premise" — the project piled its code on the stack it started with, and a pattern from a different major is not stale
guidance but guidance that is **wrong for this project**. That is why
`--check-freshness` judges only when there is no `assembly.json` (= a first install).

> **The normal path for a seam is runtime generation.** Lowering the prebuild unit from combinations (32) to axes (13)
> was the point of v3.12.0, and prebuilding seams per combination as well amounts to reversing that
> decision. Generate **once** per combination and put it in the cache with `install-guide.sh --save-seam`, and
> from the second project on the same combination there is no generation at all.
>
> **The criterion for prebuilding anyway** is not speed but the audit-and-repair loop — not making every user
> repeat the loop the maintainer went through once. Ship only when **all** of the following hold:
> ⓐ a combination judged to be used often ⓑ the maintainer finished the audit and repairs to the end
> ⓒ **it is included in the seam regression of `--self-test`** — if it is not re-verified automatically every time
> a pack is fixed, a prebuilt seam becomes a source of drift.
> Currently shipped: `nextjs+supabase` · `react-vite+aws-container` (since v3.35.0 **backend only** — the frontend is the react-vite pack hub) · `vue+node-api`.
>
> **Pack hubs replace seams (v3.35.0).** A pack that follows the standard wire contract (`guides/contracts/`) carries the API client,
> complete example and endpoints inside the pack, carries auth as `variants/auth/<method>/`, and carries its hub as `HUB.md`.
> When the other axis is on the same contract too, that combination completes with no seam. Currently: `react-vite` · `fastify` · `react-native`.
> The more of the remaining HTTP packs move to this shape, the more combination seams are left only for real combination dependencies such as BaaS and hybrid shells.
>
> **The cache tells you the promotion candidates.** The same combination piling up in `~/.claude/orangekit/seam-cache/`
> is itself the evidence of frequency — the maintainer picks from that list. Instead of prebuilding 28 combinations,
> promote **only what demand has proven**. Promotion procedure: move the cached copy into `guides/seams/<combination>/`
> → put it through the three audits → fold it into the seam regression of `--regress`. Miss the last step
> and that seam silently diverges every time a pack is fixed.

**Before using a pack, check `fixesVariants` in `pack.json` against the project's confirmed dimensions.**
An axis pack nails down variants such as framework and ORM (`aws-container` is Hono + Drizzle,
`node-api` is Express + Prisma, `node-nest` is NestJS + TypeORM). If the confirmed combination differs, what the project gets is **not something missing
but something wrong** — do not assemble; send it down the generation path, or ask the user whether to change the variant.
If `fixesVariants` is `{}` that is a declaration that no variant is nailed down, so assemble as is.

| State | Action | Lines generated |
| --- | --- | --- |
| Pack hub (`HUB.md`) + all variants resolved + same wire contract | **No generation** — the installer lays down the pack hub and the auth variant | 0 lines |
| Pack hub + some variants unresolved (`variantGaps` — e.g. a hybrid shell bridge, an auth method the pack lacks) | Generate only those variant files | 1–2 files |
| Both axis packs + a prebuilt seam | **No generation** — `install-guide.sh` assembly only | 0 lines |
| Both axis packs · no seam | Assemble the packs, then **generate the seam only** (3 files per axis) | ~1,100 lines/axis |
| A pack on one axis only | Assemble that axis + generate its seam; for the other axis **generate hub + every resource** | Mixed |
| No pack | Generate both sides in full (the existing path) | ~2,300 lines/axis |
| Frontend `none` (API-only) | backend side only |
| Backend `none` (static/SPA + external API) | frontend side only (including API client patterns) |
| Both axes `none` | Do nothing (only app-guide if there is an app axis) |
| An axis is `undecided` | Do not build that axis — a guide for an undecided stack is not written by guesswork |
| There is an app axis | If an app pack exists, assemble it + **generate only the app seam**; otherwise generate `app-guide` in full. The app seam is a function of the shape (`appShell`·`deliveryModel`), so the cache splits by shape too. For a hybrid RN shell, frontend-guide's shell slot holds **only the bridge contract**, and app-guide owns the native screen patterns — if both guides write the same section they diverge |
| An existing generated copy | Compare stamps as in Step 7 — on detecting a manual edit, do not overwrite; present a diff |

### The three files you must read on an axis that has a pack

Shipping the pack and the seam separately makes two new defect classes: **symbols the pack uses but the seam does not give**, and
**seam text that breaks a policy the pack declared**. The gate checks both, so read them before generating.

| File | What to hand the generating agent |
| --- | --- |
| `guides/<axis>/<pack>/ledger.md` | The full `requires` table — **the list of symbols the seam must export**. If the kind is `project`, export it; if `library`, bind the import; if `cross-axis` · `generated`, do not build it |
| `guides/<axis>/<pack>/policies.md` | The Machine checks table + the full "what humans must uphold" section — if the seam breaks one it is a gate FAIL |
| `guides/<axis>/<pack>/pack.json` | `exampleDomain` (fixes the domain vocabulary) · `seamSlots` (names of the files to build) · `resources` (the pack resource rows to carry in the Navigation Guide) |

**The seam writes the hub (`SKILL.md`) too.** Carry the `<!-- pack-slot: ... -->` blocks over **verbatim**
from the pack's `PACK.md`, and newly write only the slots in the "for the seam to fill" table at the end of the file. Rewriting a pack
fragment makes it diverge from the other combinations and the pack loses its meaning.

### Combination dependencies — the two guides are functions of each other

**Change one axis and the other axis's guide changes too.** Measured: with the same Supabase backend,
pairing it with Next.js centred the guide on Route Handlers · Server Actions · middleware session refresh,
while pairing it with a React+Vite SPA centred it on Edge Functions · direct browser calls · RLS as the sole defence —
**a completely different backend-guide** came out.

The two things you must always hand the generating subagent:

| Item | Source | Effect on the two guides |
| --- | --- | --- |
| **Where the server code lives** | `notes.serverCode` of the frontend preset | The whole "standard handler shape" slot of backend-guide. If the frontend has a server runtime, there; if not, in BaaS functions · serverless functions · a self-built server |
| **Where the security boundary is** | `notes.securityBoundary` of the backend preset | The auth/authorization slots on both sides. With a server runtime, an application-layer check + a data-layer policy as a double defence; with an SPA, the data-layer policy is effectively the only boundary |
| **Whether the data layer has a policy engine** | `notes.securityBoundary` · `dataModeling` of the backend preset | **The variable that splits things most.** If there is one (RLS · Security Rules), write on the premise of a double defence; if there is none (DynamoDB and the like), write on the premise that a missing application-layer ownership check is itself a data leak. Get this wrong and the guide makes the reader believe they are safe |
| **Whether the language is TS or JS** | `techStack.frontend.language` · `notes.language` of the preset | Whether the type-standard slot lives or dies. For JS, replace that slot with JSDoc conventions · runtime schema validation, and do not include a generated-types section |
| **Whether the client is a browser or an app** | `techStack.clientKind` (derived from `deliveryModel`) | Whether four backend-guide slots live or die. See the table below |
| **What the product form is** | `techStack.deliveryModel` · `pwa` | Whether the offline · shell slots of frontend-guide live or die. See the table below |

**Slots split by the product form (`deliveryModel`)** — the pack merely holds the slots and **the generator decides**
**whether each is filled or left empty.** Nailing form-specific content into the pack as prose turns it into wrong guidance in every other combination.

| frontend-guide slot | `web` | `web`+`pwa` | `hybrid` | `cross-platform` · `native` |
| --- | --- | --- | --- | --- |
| Offline · install | Empty | Service worker · manifest · offline cache · install prompt · update strategy | Owned by the shell | With no web screen axis there is no frontend-guide at all — app-guide |
| Shell boundary | Empty | Empty | `capacitor`: shell wiring · native bridge boundary · deep links · store review · forced update / `rn-*`: **only the web side of the bridge contract** (the rest is app-guide) | — |

| app-guide slot | `hybrid` + `rn-webview` | `hybrid` + `rn-native-screens` | `cross-platform` · `native` |
| --- | --- | --- | --- |
| Screens · navigation | A single webview container | Transition rules between native screens ↔ webview screens | The whole app |
| Bridge contract | App-side receipt · origin verification | The same + the path by which native screens read web state | Empty |
| Permissions · device features | Push · permissions | Push · permissions · maps · camera · location | The whole app |
| Release | Store + what OTA can cover | The same | The same (Flutter · Swift · Kotlin have no OTA) |

| backend-guide slot | `clientKind: browser` | `clientKind: app` |
| --- | --- | --- |
| Client auth transport | Cookie session · CORS · CSRF defence | **Bearer + secure storage** (not cookies) |
| Idempotent ingest | Empty | **Lives** — offline batch sync is the premise. A resend must not be applied twice |
| Push delivery | Empty | Lives (FCM/APNs) |
| API version negotiation | Empty | Lives — because older app versions keep running |

**An empty slot is the normal path.** A web project's backend-guide having no push section is not a defect
but the result of the dimension working — forcing an empty slot full invents a requirement the project does not have.

**Conflict detection — `hybrid` × `nextjs`**: a Capacitor shell carries static assets, so
`output: 'export'` is forced and Server Actions · Route Handlers cannot be used. When this combination arrives,
**state the constraint** in the guide and write it with the server features placed on the backend axis.

**Whether a policy engine exists is not one line of wording but the premise of the whole guide.** Carrying the
"RLS is the backup, so the application check is a double defence" wording used in a BaaS combination straight
over to a combination with no policy engine makes it exactly the opposite guidance — the security axis of the Step 5 audit is what catches this contamination.

The frontend-guide slots **data fetching · routing/auth · complete example** depend on the backend choice.
The backend-guide slots **API endpoints · complete example** depend on the frontend choice.
The remaining slots (styling · state management · component patterns / data access · validation · testing) close
inside the axis — they largely hold up when the combination changes.

## Step 2-B: refresh — moving an installed guide to a new major

**Fix the installed copy, not the pack — and only once the installed copy is complete.** The pack (plugin-owned) is raised by the
maintainer's periodic check; only the gap in between is filled in the project's `.claude/skills/<axis>-guide/`. If generation
(seams · hub) remains, **finish it on the verified major first** — changing the version mid-generation makes the seams re-read the
changed pack, or leaves only the seam files on the old version.

**Recompute the targets from the completed install.** `stale` in `guide-job.json` was built at assembly time from the pack alone and
does not know the seam · hub files. So recompute per axis:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/guide-freshness.sh" --guide .claude/skills/<axis>-guide --json
```

The last column of the TSV's `major_up` rows lists every installed file where that package appears (pack resources · variants · seams).
This mode does not know the pack premise, so use `stale[].premise` (the pack's `fixesVariants`). The rewrite scope is those files
only — rebuilding the whole pack brings back the generation time that was just removed.

| `stale` row | Scope | Note |
| --- | --- | --- |
| `premise: false` (partial rot) | only the resources in `files` | usually a few test·tooling files |
| `premise: true` (pack premise — framework·ORM) | all of `files` + the hub's description of that package | a large scope. init showed the cost with ⚠ |
| a row with empty `files` (toolchain — `typescript` · `@types/node`) | no rewrite | the guide text has no version-specific idioms. Raise only `pkgs=` in the hub stamp |

**Order**: run it **after** Step 7 has loaded the seams into the cache — the cache must stay on the verified-major edition so the next
project on the same combination gets the same starting point. Then ask question ②, and if chosen run the procedure below before
closing the job.

The procedure uses the same discipline as generation: delegate the affected resources per cluster to generators (based on the new major's
**official migration guide** — tag the version claims) → the Step 4 gate → skip `pack-smoke`, since it works against the pack and
not the installed copy, and have audit A typecheck against the new major → one audit → one repair.
When done, write **the new major** into the hub stamp's `pkgs=` and into `assembly.json` — from then on the installer's stack-premise
pinning (`pinned`) does not overwrite it with the pack's old major. **Do not load the seams into the cache again after refresh** —
following the order above, the cache already took the verified-major edition before refresh.

**init is not the only time to refresh.** In a project where code has piled up, the baseline is not the registry's latest but
**the major the project actually installed** (a guide ahead of the code is wrong guidance). When `session-brief` reports a package whose
major in `package.json` has risen above the guide's `pkgs=`, write only that package as `stale` and run the same procedure.

## Step 2-A: Authoring an axis pack — the maintainer path

Creating a missing axis pack is **for maintainers only.** This path does not run in a consumer project,
so the canonical source was split out: **read `assets/pack-authoring.md` and follow it exactly.**

What is there: the L0 contract freeze (including the shape column) · coupling-cluster fan-out · the pilot wave ·
L1 instructions · L2 · L3 fan-in and the coherence pass · rollback criteria · measurement obligations.

> If the pack already exists, skip this section. `install-guide.sh` assembles it.

## Step 3: Generation — delegate to isolated subagents (principle 5)

### Step 3-0: If you are building both guides — fix the wire contract first (required)

**The price of isolated generation is that the two guides fail to agree with each other.** Measured: generating the frontend and
the backend in parallel isolation left the response envelope, the pagination, and the authorization-failure status codes all
misaligned, so the complete example and the form error flow were wholesale unrunnable. Isolation is there to block
**context inertia**; it does not mean cutting the contract too.

So the main session fills in `assets/wire-contract.template.md` (the 5-item form) as **one scratch**
**file** and pastes **the full file verbatim into both sides** rather than summarizing. Step 4's `--pair`
compares both against that same file, so the text handed over and the text checked must be the same. Even when generating only one side,
if the counterpart already exists, read it and fill in the same form (skip only when there is none).
**If the project has its own spec (`dev/docs/api/` etc.), copy from it instead of inventing** — there is a measured case where
an invented contract created fields that did not exist and cost one more repair round.
**app-guide receives the same contract file** — the app is a client calling the same API too. For a hybrid
RN shell, add one more section to the contract file for **web ↔ native bridge messages** and paste it into both frontend-guide and
app-guide (`--pair` compares only frontend and backend, so this section is checked by the Step 5 audit).

### Step 3-1: Generation delegation — three layers, parallel by coupling cluster

**Read `assets/generation-delegation.md` and follow it exactly.**

## Step 4 · 4-1: Machine verification gate · execution verification — the main session runs them itself

The generator also runs the same gate before returning, but **the report that it ran is itself a self-report** (principle 5).
**Read `assets/verification-gate.md` and follow it exactly.**

## Audit and repair budget — once · lighter models · a fixed work location

Generation **sets** quality; audit and repair **confirm** it. If confirming costs more than generating, the order has been
inverted. Measured (a consumer project, 2026-10-14): after the repair the model launched 5 second-round audits on its own,
each audit spent 45k~100k tokens within its first minute, and 11 working folders were left at the **drive root**.
That is what happens when the spec sets no cap, no model and no location. The four below are **caps, not options**.

**① Audit → repair happens once.** Launch audits A · B · C (all of Step 5) once, repair the confirmed `critical` · `high`
once, and that is the end. **Do not launch audits again** — there is no regression audit either. Defects the repair newly
creates are caught only by re-running the Step 4 gate (mechanical).

- **Before** launching the audit, set `auditRound` in `.orangekit/guide-job.json` to 1. If the session is cut off and
  picked up again, keep using this value — **at 1, launch no more audits**
- A `critical` still left after the repair **does not block the install** — write it in a "Known defects" section at the very top
  of the hub (so a model reading the guide does not copy that pattern) and put it on the first line of the completion report
- Gate FAILs are fixed in the same repair. If the gate is still FAIL after the repair, that axis goes down to
  `.orangekit/failed-guides/` under `install-guide.sh`'s existing rule and is reported — the loop does not
  run again

**② Run audit and repair on lighter models.** Set it with the `model` argument of the `Agent` tool. In an environment where
that model is unavailable, drop the argument and inherit.

| Stage | `model` | Why |
| --- | --- | --- |
| Generation (L0 · L1 · L2) | not set (the main model) | This is the stage that sets guide quality — saving here grows the repair load |
| Audit A (execution) · C (cross-file · security) | `sonnet` | It involves security judgement |
| Audit B (version claims) | `haiku` | A line-by-line true/false lookup |
| Repair | `sonnet` | The findings are already concrete in the TSV, so it is execution more than judgement |

When the generator and the auditor are different models, principle 5 (generator ≠ verifier) actually gets stronger.

**③ The work location is `.orangekit/scratch/` and nowhere else.** Every directory audit and repair creates goes under
`.orangekit/scratch/<purpose>-<axis>/` (e.g. `audit-A-frontend` · `repair-backend`).
**Never create them outside the project · at the drive root · in `/tmp`.** Do not give each audit its own npm cache;
share a single `npm_config_cache=.orangekit/scratch/npm-cache`. init put `.orangekit/` in gitignore,
so it is not committed, and Step 7 deletes `.orangekit/scratch/` wholesale.

**④ At most 3 run concurrently.** The audit stage's subagents are the three, A · B · C. Only B is split in 2, and only when the version
claims **exceed 80** — never further.

## Step 5: Independent adversarial audit (principle 5)

Passing the machine gate does not settle the install. What the machine cannot catch — inaccurate guidance, rule conflicts between the hub
and a resource, holes in a security judgement — needs a layer equivalent to human eyes.

Fill in the template in `assets/audit-prompt.md` and launch **three audits in parallel**. Model, work location and rounds follow
the "Audit and repair budget" above.
Do not give the auditors the generation conversation context — the audit is independent only if they read the artifacts alone.

**Why three-way**: measured, one audit read all 1,946 lines exhaustively and took 20 minutes. The three paths that actually
caught defects are independent of each other, so splitting loses nothing — the biggest find (open redirect) falls wholly into A,
and the 5 false version claims fall wholly into B.

| Audit | Input | Responsibility |
| --- | --- | --- |
| **A. Execution** | The working directory of `pack-smoke.sh --online --keep` + `vector-report.tsv` + the pack | Security · cut surfaces, **whatever can be confirmed by running it**. It starts from the report, so it does not build a scratch project from nothing. If `tsc` is **still** skipped (offline), filling that in is A's first job. **Scope cap**: up to type-checking · linting · running the security vectors on the guide's code fences — no mutation testing · bundling (`expo export`, etc.) · devices or simulators · assembling the whole app; only mark it "needs on-device check" |
| **B. Version claims** | The TSV produced by `--claims-out` | The version-claim part of accuracy. Rule each line true / false / unverifiable. **Split in 2 only when there are more than 80 entries** (`n=$(wc -l < claims.tsv); split -l $(( (n+1)/2 ))` — `-n l/2` is GNU-only and fails on macOS) — the entries are independent of each other, making this the only audit that loses nothing when split |
| **C. Cross-file** | The full pack text + `policies.md` + `ledger.md` | Self-contradiction · slot contracts · ghost symbols · **mismatch between what a policy declares and what a resource actually does** (the measured 26-case class) · vocabulary and wording consistency |

**Do not split A or C.** A is an execution sharing one working directory, and C's value is exhaustiveness
itself — two C audits that each read half cannot compare the cluster boundary.

**Give all three audits the full gate output** (so they do not re-count spec compliance).
**C owns exhaustive reading outright** — A and B receive only narrow inputs, so only C can perform the cut-surface method
("read the full text, collect the suspicious names, confirm with grep").
Give C A's execution report as well.

**On an axis assembled from a pack, narrow the audit scope.** Pack files are assets the plugin audited in advance, so
they are not audited again in every project. Give the auditor `packFiles` from `assembly.json` and
instruct them like this:

> The files below are **baseline assets**: `<packFiles>`. Do not re-judge whether their content is right or wrong;
> look **only at the interaction between the seam files and this baseline** — does the seam use a pack symbol in the wrong
> shape, does it state something that conflicts with a policy the pack declared, does it write the opposite of what the pack assumed (whether a policy engine exists ·
> where the server code lives). For the rest, audit only the seam files, exhaustively.

This narrowing removes most of the audit cost (the volume to read drops by half or more). But
**look harder at the pack ↔ seam boundary** — it is the surface newly created by shipping them separately.
**The gate now builds the version-claim list** (the inventory from `check_claims`). Do not collect it
by hand — when exhaustiveness rests on a person's diligence, things get missed. That list is the entire input to audit B.
Generation discipline cannot block wrongly confident knowledge — the model does not know that it is wrong.

## Step 6: Repair — only after reconfirming the audit findings (principle 6)

**Auditors are wrong too.** Measured, part of the audit report was a misjudgement. Therefore:

0. **The audit emits defects as TSV** (`file · line · severity · clusterId · summary · how to reconfirm`).
   If the main session reads prose and has to re-classify and re-route it, that much becomes a round trip — the measurement
   ruled that "what dominates the wall clock is not volume but **the number of verification round trips**"
1. Run each finding's `how to reconfirm` exactly as written and **confirm it yourself**. A finding that does not confirm is not
   repaired; leave that fact in the report
2. Of the confirmed defects, repair **only those with impact**. For petty repairs the cost of audit and re-verification exceeds the gain:

   | Severity | Criterion | Handling |
   | --- | --- | --- |
   | `critical` | A security defect (auth · tokens · redirects · injection · secret exposure) · guide code that does not compile or run · a wire-contract mismatch between the two guides | Repaired |
   | `high` | A wrong API or version claim that breaks when followed · guidance that contradicts a policy | Repaired |
   | `medium` · `low` | Wording consistency · example enrichment · a missing reference note · gate WARN/REVIEW | **Not repaired.** Record each as one line under "Known defects", and do not ask the user |

   **The ledger already assigned file ownership, so grouping by clusterId means there are no write conflicts** —
   send all of a cluster's findings together in **one** `SendMessage` per cluster, concurrently
3. After repairing, **run Step 4 again** — a repair creating new defects is a common failure mode.
   **Do not launch audits again** — "Audit and repair budget" ①: audit → repair happens once
4. A `critical` still left after the repair does not block the install — put it in the "Known defects" section at the top of the hub and on the first line of the completion report

## Step 7: Stamp and report

- Record the generation stamp in each SKILL.md (the skeleton's format — attach it only to generated artifacts)
- Report to the user: the generated skills (whichever of frontend · backend · app were generated) · the resource count · **every gate WARN and the reason for**
  **each REVIEW verdict** · **the audit results and what was repaired** (including the number of rounds) · **known defects** (a remaining `critical` goes on the first line) · **the list of empty slots** (if any) · "auto-triggers from the next session on"
- On a regeneration request: compare the stamp's stack= value against the new combination and report which dimensions changed;
  if a manual edit is detected, show a diff of the edited part and get the user's confirmation

### Close the handed-off job (required if you read one in Step 0)

Close it **only after 0 gate FAILs and a finished audit and repair.** There is an order — put it in the cache first, then delete:

If generation is done and need contains `refresh:*`, ask init's question ② (update to the latest majors / keep the verified majors —
`orangekit-init` Step 9.5 "② The latest-majors question") **after 1) loading the cache and before 2) closing the job**, and if chosen
run Step 2-B. A job with no generation (need is `refresh:*` only) starts straight from the question.

```bash
# 1) Load the audited seam into the cache — the next project on the same combination generates nothing
#    The app seam goes in too. The app value and shape are read from guide-job.json (app · notes), so this comes before 2)
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" --save-seam "<combo>"

# 2) Close the job. If the file remains, session-brief keeps reporting it as unfinished
rm -f .orangekit/guide-job.json

# 3) Clean up the audit and repair workspace — left behind, the next generation mistakes stale artifacts for material
rm -rf .orangekit/scratch
```

If you did not finish, do not delete it; leave the reason — it is the basis for the next session to pick it up
(`status` to `failed`, and one sentence in `reason` saying what was blocked and why). **Delete `.orangekit/scratch/` in this case too** —
`failed` is a finished state, and the user does not know large temporary files are being left on their disk. The basis for picking
it up is `guide-job.json` and the installed guides, not scratch. Scratch is left only when the session was
**cut off midway** (`running`), and then `session-brief` reports its size and the delete command.

> **Do not put a seam with a known `critical` left in the cache** — install it, but do not hand it down to the next project.
>
> **Do not put an unverified artifact in the cache.** Every later project on that combination inherits the same defect
> and the cache becomes an amplifier of defects. Call `--save-seam` only after the audit passes.

## After generation — rot is made by time

A guide that is accurate today goes stale once a library major rises. Measured, the original with the most accumulated
field validation was the one carrying deprecated APIs, older-version idioms, and security defects, and **for months**
**nobody found them until an audit was explicitly run.**

- **`scripts/guide-freshness.sh` decides staleness** — it compares `pkgs` in `pack.json` (or
  `orangekit-guide-baseline` in the installed copy) against today's major in the registry, and narrows down to
  **which resource files the risen package appears in**. Rot is not a problem of the whole pack but of the few
  files that use that name. Offline or a failed lookup is an **explicitly reported non-verdict**, not
  "no rot"
- If a major rose, run the Step 5 audit on that resource again. For a **prebuilt guide** the
  `orangekit-guide-baseline` line supplies what to compare against, so after the audit and repair always update the `verified` date and
  the version list (without that update the next check misses the staleness)
- **Keep** `doctor`'s "baseline older than 6 months" warning — it is the only signal available offline, and
  the `verified` date carries a separate fact, namely "when was the audit run"
- Record defects found in use in `docs/lessons.md` — once 3 or more accumulate, doctor reports them
  as promotion candidates (decide whether to raise them into a rule card or to fix the guide)
