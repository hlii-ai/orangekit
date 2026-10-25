# Presets Guide

Presets are split into **three axes: web screens (frontend) · app · backend**. `/orangekit-init` asks only for
the axes the product shape needs, and the fixed combination determines the guide skills.

> **Why several axes**: because guide content is not a function of one axis but **a function of the combination**.
> The same Supabase, paired with Next.js, centers on Route Handlers and Server Actions; paired with a
> React+Vite SPA it centers on Edge Functions and direct browser calls — a completely different guide.
> Every axis must be fixed first before a guide that accounts for the others can be built.
> The app axis is separate from the web screen axis because, as with a hybrid RN shell, **both live in one product**.

## Frontend axis (`presets/frontend/`)

| name | stack | where server code lives |
| --- | --- | --- |
| `nextjs` | Next.js 15 App Router + React 19 + Tailwind v4 + shadcn/ui + Zustand | built into the framework (Route Handlers · Server Actions) |
| `react-vite` | React + Vite SPA (no SSR) + Tailwind + React Router + Zustand | none — owned entirely by the backend axis |
| `vue` | Vue 3 Composition API + Vite SPA (no SSR) + Tailwind + Vue Router + Pinia | none — owned entirely by the backend axis |
| `vanilla` | no framework — standard DOM + ES modules (Vite bundle) | none |
| `none` | no frontend (API-only project) | — |

**Language is a dimension, not a preset.** Every frontend preset defaults to TypeScript
(`vanilla` alone defaults to JavaScript), changeable at `/orangekit-init` Step 4. Pick JavaScript and the
guide's type-standard slot is replaced by JSDoc conventions and runtime schema validation, and the generated-types section drops out.

## Product shape is a dimension too (`techStack.deliveryModel`)

**The first thing `/orangekit-init` asks** is not the framework but **what you are building** —
web · mobile app · API-only. Instead of a technical question you must already know the answer to, a product
question anyone can answer comes first, and that answer narrows the list in later questions. A mobile app splits by approach in the next question.

| value | meaning | web screen axis | app axis |
| --- | --- | --- | --- |
| `web` | reached through a browser. Installable if `pwa: true` | all 4 | `none` |
| `hybrid` | web screens inside an app shell. The shell approach is `appShell` | all 4. **But `nextjs` is forced to static export** | `none` for Capacitor, `react-native` for an RN shell |
| `cross-platform` | native iOS and Android UI from one codebase | `none` (that axis if there is a separate web) | `react-native` · `flutter` |
| `native` | built per platform | `none` (that axis if there is a separate web) | `ios-swift` · `android-kotlin` · `native-dual` |
| `api-only` | no user-facing screen | `none` | `none` |

**The hybrid app shell (`appShell`)** — `capacitor` (almost no shell code) · `rn-webview` (RN only wraps a
webview) · `rn-native-screens` (native screens such as maps and camera are mixed into the RN shell). With the RN
family, web screens and app code live **in one product**, so both the web screen axis and the app axis are used.

**Why it is a dimension and not an axis** — because it **turns conditional slots in existing packs on and off**
rather than adding packs. As an axis, the pre-built set would grow as a product and exceed an auditable count.

The derived value **`clientKind`** (`browser` for `web`, `app` for the rest) is what splits the backend
guide. From the backend's point of view hybrid, cross-platform and native are all the same — it is not "a browser talking to a
server" but **"an app talking to an API"**.

| slot | `browser` | `app` |
| --- | --- | --- |
| client auth transport | cookie session · CORS · CSRF | Bearer + secure storage |
| idempotent collection | empty | active (offline batch sync) |
| push delivery | empty | active (FCM/APNs) |
| API version negotiation | empty | active (old app versions keep running) |

**An empty slot is the normal path.** A web project's backend guide having no push section is not a defect but
the dimension working. So **a pack must hold under any combination of dimensions, and specialization happens at
generation time** — bake dimension-specific content into a pack and it becomes wrong guidance for the rest.

## Backend axis (`presets/backend/`)

The backend comes in **three shapes** — these are not peer entries that differ only by name.

| name | shape | stack | security boundary |
| --- | --- | --- | --- |
| `supabase` | BaaS | PostgreSQL + RLS + Auth + Storage + Realtime | RLS is the last line. With no policy, **everything is blocked** |
| `firebase` | BaaS | Firestore + Auth + Storage + Cloud Functions | Security Rules are the last line. With no rules, **everything is open** (the exact opposite of RLS) |
| `aws-serverless` | serverless assembly | Lambda + API Gateway + DynamoDB + Cognito | **no row-level policy engine** — the application-layer check is effectively the only boundary |
| `aws-container` | own server | ECS/Fargate + ALB + RDS PostgreSQL + Drizzle + Cognito (OIDC) | **no row-level policy engine** — a missing ownership check is a data leak. AWS dependence is kept to the infrastructure layer only, so an on-premises port is possible |
| `gcp-serverless` | serverless assembly | Cloud Run/Functions + Firestore + Identity Platform | IAM/token verification + Security Rules (if there is a direct access path) |
| `fastapi` | own server | **Python** · FastAPI + SQLAlchemy 2.0 + Pydantic v2 + Alembic + pytest | the application layer is the only boundary |
| `node-api` | own server | Express 5 + PostgreSQL + Prisma + Zod | the application layer is the only boundary |
| `node-nest` | own server | NestJS 11 + PostgreSQL + TypeORM 1 + class-validator | the application layer is the only boundary. An **array `where` means OR**, so ownership must be repeated on every branch |
| `fastify` | own server | Fastify 5 + PostgreSQL + Drizzle + Zod | the application layer is the only boundary. The auth hook applies **only inside the plugin context that registered it** |
| `rust-axum` | own server | **Rust** · Axum + Tokio + SQLx + PostgreSQL — **no pre-built pack** | the application layer is the only boundary. Check the auth layer's scope (`route_layer`) on every router |
| `none` | — | no backend / consuming an external REST API | where the external API token is stored is the danger point |

**Whether the data layer has a policy engine is the biggest divider of guide content.** With one, the
application check is defense in depth; without one, a missing ownership check is a data leak. Swapping the two
descriptions creates a false sense of safety, so this value is always passed at generation time.

`frontend: none` + `backend: none` corresponds to the former `blank` preset.

## App axis (`presets/app/`)

| name | stack | used for |
| --- | --- | --- |
| `react-native` | Expo + React Native + Expo Router + TanStack Query + Zustand | cross-platform · hybrid RN shell |
| `flutter` | Flutter + Riverpod + go_router + Dio | cross-platform |
| `ios-swift` | Swift + SwiftUI + Swift Concurrency | native (iOS only) |
| `android-kotlin` | Kotlin + Jetpack Compose + Coroutines + Hilt | native (Android only) |
| `native-dual` | iOS (Swift) + Android (Kotlin), two codebases | native (both) |

**The only app axis pack is `react-native`** — something is pre-built only when it can be registered as an audit target.
`react-native` assembles its pack and generates only the seam (API client · auth · complete example, plus the bridge for a hybrid shell).
The app seam is a function of the shape (`appShell`·`deliveryModel`), so the cache splits by shape too. For the other app values,
all of `app-guide` takes the generation path. A preset supplies only defaults (framework · commands · directories) and combination context (notes).

## Custom · undecided

Every axis value is either a preset name or one of the three below. **Never invent a preset name.**

| value | meaning | guide |
| --- | --- | --- |
| `custom` | user-defined — a stack not on the list. Its real name goes in that axis's `framework` | generation path |
| `undecided` | not chosen — to be decided later | not built (later, via `/stack-guide-generator`) |
| `none` | not applicable | none |

## Combination → guide mapping — the pre-built unit is the axis

Combinations number 5×9 = **45**, but axes number **14** (frontend 5 · backend 9). And most guide content is a
function of **one axis alone**, not of the combination — React component patterns and styling are the same
whether the backend is Supabase or AWS. So the pre-built unit is the axis, not the combination.

```
guides/
  frontend/<axis>/   PACK.md · resources/ · ledger.md · policies.md · pack.json
  backend/<axis>/    (same)
  seams/<combo>/     only the parts that genuinely depend on the combination — data fetching · auth · full examples
```

In a project the two are assembled and installed as `.claude/skills/frontend-guide` · `backend-guide`:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" \
  --frontend <pack> --backend <pack> [--seam <combo>]
```

| state | behavior | time |
| --- | --- | --- |
| both axis packs + pre-built seam | assembly only — completes inside init | seconds |
| both axis packs · no seam | pack assembly + generate the seam only (3 files per axis) | init exits immediately |
| only one axis has a pack | that axis is assembled, the other is fully generated | init exits immediately |
| no packs | both sides fully generated | init exits immediately |
| `none` × `none` | nothing (Core skills only) | — |

The axis packs currently held are **4 frontend** (`nextjs` · `react-vite` · `vue` · `vanilla`) and
**9 backend** (`supabase` · `firebase` · `aws-serverless` · `aws-container` ·
`gcp-serverless` · `fastapi` · `node-api` · `node-nest` · `fastify`), with 3 pre-built seam pairs.
With these 13, **44 of the 45 choices receive at least one axis as a finished product** —
the only one that receives nothing is `none` × `none`.

**init's default is to install only the stack rule files** (`install-guide.sh --rules-only`). The detailed guide skills are asked
about once by init and built only if chosen. Even then init does not wait for the guide — if generation is needed it leaves a job in `.orangekit/guide-job.json`
and exits, installing only after generation, audit, and repair are done — half-finished guides are not installed.
If the session is cut off, the next session's briefing reports the unfinished work.

**For an axis with no pack**, init asks one three-way question — rule file only (recommended) · rule file + detailed guide · create nothing. The rule file holds
only items backed by the official docs (`guide-gate.sh --rules-card` checks the URL · date · installed version), and if there is no evidence it is not created. It is
project-owned (no stamp), so the installer does not overwrite it.

> Rationale: one measured generation run took **54 minutes before repair**, and at the end of it both auditors
> still ruled it not installable (`dev/docs/skill-review/contract-first-e2e-2026-08-22.md`). There is no reason
> to tie the first impression of an install to that duration — a guide is needed when the first component is
> written, not at the moment init finishes.

**Whether to use a pre-built version or generate is decided by the system — it is not asked.** Because leaking
implementation detail to the user turns it into a question they cannot answer. What *is* asked is only
**whether to spend the time now** (with the measured cost), because that is a decision about the user's time.

### Pack hub — combinations that need no seam (v3.35.0)

A pack that follows the standard wire contract (`guides/contracts/http-standard.md`) does the seam's job itself:
the API client, complete example and endpoints go in `resources/`, auth in `variants/auth/<self-issued|oidc>/`,
and the hub in `HUB.md`. The installer picks the variant from the notes' `authKind` and `appShell`, and when every axis
is on the same contract it lays down the hub and **completes with zero generation**. Only variants the pack lacks
(hybrid shell bridge · other auth) remain as `variantGaps`, and only those files are generated. Current pack hubs:
`react-vite` · `fastify` · `react-native`.

### Seam cache — built once per combination

A seam is used by exactly one combination and **decays on the major version of both axes** (about 2x a pack's
rate), so it is poor economics as a pre-built target. It is cached instead:

```
~/.claude/orangekit/seam-cache/<combo>@<plugin-version>/{frontend,backend}/
```

After generation → gate → audit → repair, put it in with `install-guide.sh --save-seam <combo>`.
**From the second project on the same combination it is a 1-second assembly with no generation.** A cache entry
is also a candidate for later promotion into a pre-built seam.

Two things are observed:
- **Only verified output goes in.** Put unverified output in and every later project on that combination
  inherits the same defect — the cache becomes an amplifier of defects
- **Pack-owned files do not go into the cache.** If they do, the plugin's pack updates are shadowed by the
  cache and never arrive

### Update reach — except that stack premises are pinned by the project

The installer does stamp-based idempotent updates but **nobody calls it again** — it is invoked only from
`orangekit-init` and `orangekit-migrate`. So raising the plugin version leaves a long-installed project on its
old copy. And yet "always update to the latest" is also wrong:

> **A project builds its code on the stack premises of its starting point.** If the plugin pack has moved to
> `next@16` patterns and this project is on 15, the update is not stale — it is guidance **that is wrong for
> this project.** Raising a version is the project's decision, made when it raises its dependencies.

So **what is pinned is the "stack premise", not the "accuracy of the guidance".** The decision uses the pack
stamp's `pkgs=<package>@<major>`:

| state | behavior |
| --- | --- |
| same pkgs major · pack version raised | **update** — a defect or security fix within the same premise |
| pkgs major differs | **do not update** — the premise has moved. The project decides |

Evidence the first row is real: a pre-built guide carried a privilege-escalation vulnerability for months. That
was not a version issue but a defect, and it must reach projects using the same stack.

This policy operates in two places together — left as a message alone, it would not be enforced:

- `session-brief` compares every session and reports **only on a mismatch** (a fix prompts a rerun; a moved
  premise says explicitly "this will not be updated")
- `install-guide.sh` **returns without touching the pack** when the major differs. To override knowingly, `--force`

T1 rule cards carry no stack premise (code-change discipline · reversibility · lessons), so for them being
always current is correct without this gate.

### Packs come in two shapes

| shape | example | character |
| --- | --- | --- |
| symbol-surface | `backend/aws-container` (5 resources, 1,191 lines) · frontend packs | defines project modules. The seam imports them |
| pattern-knowledge | `backend/supabase` (2 resources, 380 lines) | teaches **how to use** a vendor SDK. It defines no modules |

A thin BaaS axis is natural — the "backend guide" for that combination is mostly about the host runtime
(handlers · middleware · error envelopes), and that is decided by the frontend axis.

### Pack boundaries are enforced by machine

Shipping them split creates two new classes of defect. The gate checks both:

| check | what it catches | source file |
| --- | --- | --- |
| pack interface | a symbol the pack consumes that the seam does not define | `requires` in `ledger.md` |
| policy ledger | the seam violating a cross-file invariant the pack declared | `policies.md` |

The second matters most — of 57 measured audit findings, **26** were of the class "the place that declares a
policy and the place that enforces it differ, and nothing obliges anyone to compare them". Symbols had a
ledger; policies had no matching device.

### The criterion for adding pre-built targets

Pre-building everything per combination would mean **45 guides (about 90,000 lines)**. There is measured
evidence: 2 guides accumulated a privilege-escalation vulnerability, deprecated APIs, and leftovers from a
previous major version, and **went undiscovered for months**; finding them took 3 audit agents and 2 repair
agents. An un-audited pre-built version decays and is **worse than no guide** — because it makes wrong guidance trusted.

So the criterion is not a count but a condition: **pre-build only what can be registered for regular audit.**
The axis unit meets that condition — 12 is an auditable number, and auditing one frontend pack improves the 9
combinations it enters, while one backend pack improves 5.

### Obsolescence check — compared, not asked

Axis packs and seams declare a verification baseline at the top of the file:

```
<!-- orangekit-pack: frontend/nextjs v3.12.0 verified 2026-08-21 next@15 react@19 zod@4 ... -->
```

`/orangekit-init` **compares major versions** against the project's `package.json` and reports which package
differs and how, only when they diverge. On a match it says nothing. It does not ask "shall I regenerate?"
because the user has no basis for judging whether a guide is stale, so that question becomes noise.

## Merge rules

`/orangekit-init` merges three files in this order (later overwrites earlier):

1. `presets/base.json` — shared `domains`
2. `presets/frontend/<choice>.json`
3. `presets/backend/<choice>.json`

- `additionalStack` is **accumulated**, not overwritten
- `domains.sourceDir` takes the frontend axis first, and the backend axis if the frontend is `none`
- Each preset's `notes` is not recorded into the config; it is **passed to the guide-generating agent as combination context**

## Combinations with two toolchains

A combination like `react-vite` × `fastapi`, with different languages and package managers, has different
commands per axis. The config records these per axis, but **the project's representative commands**
(`techStack.commands`) must be filled in — that is the value `build-gate` and `health-check` read.

## Custom stacks

For a combination not in the presets, pick the nearest axis in `/orangekit-init` and change dimensions at
Step 4.5, or call `/stack-guide-generator` directly and specify the dimensions. Either way it goes through the
same verification loop and a project-owned guide is generated.
