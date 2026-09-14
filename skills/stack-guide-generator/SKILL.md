---
name: stack-guide-generator
description: Generates frontend-guide/backend-guide skills into the project's .claude/skills/, matched to the project's tech stack combination (frontend · backend type · cloud · DB · data access · auth). Use when orangekit-init calls it after the stack has been chosen, when the user asks to "generate guides", for a "stack guide", or to "change the tech stack", and when starting on a stack no preset covers (AWS · MongoDB · SvelteKit and the like).
---

# Stack Guide Generator

Generates a project-owned guide skill from the confirmed stack combination.
The structure follows the `assets/guide-skeleton.md` generation spec; the content is filled from knowledge of the combination.

> **Principle: build the body first, verify it, and only then install.** The failure mode this
> skill replaces is producing a skill (a placeholder) whose description promises what the body cannot keep.
>
> **`dev/docs/skill-review/` is the canonical source for measured evidence** — wall clock, tokens, defect classes, and
> reversibility verdicts all live there. Only **rules** live here. A copy is a source of drift.

## Process principles (derived from the 2026-08-21 A/B measurement)

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
| `notes` | The axis preset notes (serverCode · securityBoundary · policyEngine · language) **＋ dimensions that are not axes** (deliveryModel · clientKind · pwa · nativeStack). The entire input for combination dependencies and conditional slot decisions |

| `need` item | Meaning | What to build |
| --- | --- | --- |
| `seam:frontend` · `seam:backend` | The packs are assembled and only the seam is missing | That axis's seam + hub (3 files per axis) |
| `frontend` · `backend` | There is no pack, or it is unfinished | That axis in full (hub + every resource) |

**Write `status` as `running` when you start.** If the session dies, that state remains and
the `session-brief` hook reports it to the next session — the device that keeps 20 minutes from vanishing silently.

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

If orangekit-init has run, `techStack.presets` (the two axis choices) and `techStack.frontend`/`backend` are already
filled in. **Read both axes and treat them as a combination** — generating from one axis alone yields guides that
have not taken each other into account (see combination dependencies below).

| Dimension | Example choices | Dependency rule |
| --- | --- | --- |
| **Product form** | web · hybrid app · native family · API-only | **Fix this first** — it splits the frontend choices, and the derived value `clientKind` splits the backend-guide slots. If `techStack.deliveryModel` exists it is already fixed |
| Frontend | Next.js · React+Vite · SvelteKit · none (API-only) | If the product form is "native family" there is no matching axis pack, so generate everything with `nativeStack` as the input |
| Backend type | BaaS (Supabase · Firebase) · self-built on cloud · framework built-in | If `techStack.presets.backend` exists it is **already fixed** — do not ask again. If this skill is invoked standalone and there is no preset, this is a required question |
| Cloud/hosting | AWS · GCP · Azure · Vercel · self-hosted | Required when self-built is chosen |
| DB | PostgreSQL · MySQL · MongoDB · DynamoDB | For BaaS, infer automatically and only confirm; for self-built, a required question |
| Data access | Prisma · Drizzle · SQLAlchemy · SDK directly | After the DB is fixed |
| Auth | Supabase Auth · NextAuth · Cognito · self-built | Tied to the backend type |

Record the confirmed combination in `techStack.backend` of `orangekit.config.json` (the schema's backendType · cloudProvider · database · dataAccess · auth fields).

## Step 2: Generation scope and branching — look up the axis packs first

**The prebuild unit is the axis, not the combination.** There are 45 combinations but only 14 axes (5 frontend ·
9 backend), and most of a guide's content is a function of one axis alone. So **build only what is missing.**

```bash
ls "${CLAUDE_PLUGIN_ROOT}/guides/frontend/" "${CLAUDE_PLUGIN_ROOT}/guides/backend/"
ls "${CLAUDE_PLUGIN_ROOT}/guides/seams/"
# If a pack exists, check whether it is still right today — meaningful **only on a first install**
bash "${CLAUDE_PLUGIN_ROOT}/scripts/guide-freshness.sh" --pack "${CLAUDE_PLUGIN_ROOT}/guides/<axis>/<pack>"
```

**Rot is judged by the `pkgs` major, not by the date.** If six months pass and no major has risen it is not stale;
if a framework major rises after two months it is stale. `fixesVariants` is the handling boundary:

| Package that rose | Meaning | Action |
| --- | --- | --- |
| One caught by `fixesVariants` (framework · ORM) | **The pack's premise changed** | Do not fix it in a consumer session. Install at the declared major and report it as a plugin update |
| Any other package | Partial rot | Re-author **only the affected resources** + `--pack` + `pack-smoke` + a focused audit B (A and C cover the changed files only) |
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
> Currently shipped: `nextjs+supabase` · `react-vite+aws-container` · `vue+node-api`.
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
| Both axis packs + a prebuilt seam | **No generation** — `install-guide.sh` assembly only | 0 lines |
| Both axis packs · no seam | Assemble the packs, then **generate the seam only** (3 files per axis) | ~1,100 lines/axis |
| A pack on one axis only | Assemble that axis + generate its seam; for the other axis **generate hub + every resource** | Mixed |
| No pack | Generate both sides in full (the existing path) | ~2,300 lines/axis |
| Frontend `none` (API-only) | backend side only |
| Backend `none` (static/SPA + external API) | frontend side only (including API client patterns) |
| Both axes `none` | Do nothing |
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

| frontend-guide slot | `web` | `web`+`pwa` | `hybrid` | `native` |
| --- | --- | --- | --- | --- |
| Offline · install | Empty | Service worker · manifest · offline cache · install prompt · update strategy | Owned by the shell | No axis pack applies — generate everything |
| Shell boundary | Empty | Empty | Shell wiring · native bridge boundary · deep links · store review · forced update | — |

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

### Step 3-1: Generation delegation — three layers, parallel by coupling cluster

**Read `assets/generation-delegation.md` and follow it exactly.**

## Step 4 · 4-1: Machine verification gate · execution verification — the main session runs them itself

The generator also runs the same gate before returning, but **the report that it ran is itself a self-report** (principle 5).
**Read `assets/verification-gate.md` and follow it exactly.**

## Step 5: Independent adversarial audit (principle 5)

Passing the machine gate does not settle the install. What the machine cannot catch — inaccurate guidance, rule conflicts between the hub
and a resource, holes in a security judgement — needs a layer equivalent to human eyes.

Fill in the template in `assets/audit-prompt.md` and launch **three audits in parallel**.
Do not give the auditors the generation conversation context — the audit is independent only if they read the artifacts alone.

**Why three-way**: measured, one audit read all 1,946 lines exhaustively and took 20 minutes. The three paths that actually
caught defects are independent of each other, so splitting loses nothing — the biggest find (open redirect) falls wholly into A,
and the 5 false version claims fall wholly into B.

| Audit | Input | Responsibility |
| --- | --- | --- |
| **A. Execution** | The working directory of `pack-smoke.sh --online --keep` + `vector-report.tsv` + the pack | Security · cut surfaces, **whatever can be confirmed by running it**. It starts from the report, so it does not build a scratch project from nothing. If `tsc` is **still** skipped (offline), filling that in is A's first job |
| **B. Version claims** | The TSV produced by `--claims-out` | The version-claim part of accuracy. Rule each line true / false / unverifiable. **Over 40 entries, split evenly and launch 2~3 B audits** (`n=$(wc -l < claims.tsv); split -l $(( (n+1)/2 ))` — `-n l/2` is GNU-only and fails on macOS) — the entries are independent of each other, making this the only audit that loses nothing when split |
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
2. Repair only confirmed defects (critical and high are mandatory; medium and low are the user's call).
   **The ledger already assigned file ownership, so grouping by clusterId means there are no write conflicts** —
   send all of a cluster's findings together in **one** `SendMessage` per cluster, concurrently
3. After repairing, **run Step 4 again** — a repair creating new defects is a common failure mode
4. If a critical defect cannot be repaired, do not install; get the user's decision

## Step 7: Stamp and report

- Record the generation stamp in each SKILL.md (the skeleton's format — attach it only to generated artifacts)
- Report to the user: the 2 (or 1) generated skills · the resource count · **every gate WARN and the reason for**
  **each REVIEW verdict** · **the audit results and what was repaired** · **the list of empty slots** (if any) · "auto-triggers from the next session on"
- On a regeneration request: compare the stamp's stack= value against the new combination and report which dimensions changed;
  if a manual edit is detected, show a diff of the edited part and get the user's confirmation

### Close the handed-off job (required if you read one in Step 0)

Close it **only after 0 gate FAILs and a finished audit and repair.** There is an order — put it in the cache first, then delete:

```bash
# 1) Load the audited seam into the cache — the next project on the same combination generates nothing
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" --save-seam "<combo>"

# 2) Close the job. If the file remains, session-brief keeps reporting it as unfinished
rm -f .orangekit/guide-job.json
```

If you did not finish, do not delete it; leave the reason — it is the basis for the next session to pick it up
(`status` to `failed`, and one sentence in `reason` saying what was blocked and why).

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
