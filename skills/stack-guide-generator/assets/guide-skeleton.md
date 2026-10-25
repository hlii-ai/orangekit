# Guide generation spec (Guide Skeleton Spec)

The structure the generated frontend-guide / backend-guide must follow.
It was derived from the proven skeleton of nextjs-frontend/backend-guide, and since the 2026-08-21 rebasing (A/B v2)
those originals themselves follow this spec too — spec and originals are mutually consistent.
There are currently 3 prebuilt pairs (`nextjs`×`supabase`, `react-vite`×`aws-container`,
`vue`×`node-api`).

> **Sync obligation**: when a stack-independent category (security · repeated UI ·
> testing, etc.) is added to any pair of prebuilt guides (the proven originals), reflect it in the matching slot of this spec.
> The three pairs differ on whether the data layer has a policy engine (only `supabase` has one; the other two do not), so
> **only what holds in common across all three is a universal category** —
> putting a statement that is true on one side only into a slot contract contaminates the artifacts of other combinations.
> **This obligation was broken once, and measured** (2026-08-23): the "auth/middleware boundary" slot
> nailed down "authorization is applied in two layers" unconditionally, which demanded exactly the opposite guidance
> in artifacts on an axis with no policy engine. It was fixed into a conditional statement — when planting a stack premise
> into a slot contract, **name the field that reads that premise alongside it**.
> **The spec is the ceiling an artifact can reach** — an item that is not here is not guaranteed in a generated guide.
> This holds not only for body sections but **equally for the resource layer**: when a new resource category appears in an original, or
> a stack-independent deepening category is added to an existing resource, reflect it in the resource slot table below too.

## Stack core card — what must be followed lives only here

**The card is the canonical part of the guide. The skill is a reference.** Whether to read a skill body is the model's call — in
measurement (guide A/B, 2026-10) it skipped it 2 times out of 3 on easy tasks. A `paths:` card is injected by the harness when a
matching file is read (3/3). Generic pattern prose did not raise scores, and a guide example value (a UUID id) overrode a project
convention. **The better models get, the more generic prose becomes an anchor with no benefit.**

Each pack or generated guide has one card per axis (`guides/<axis>/<pack>/RULES.md` → on install `.claude/rules/stack-<axis>-<pack>.md`).

| Admission condition (all of them) | Content |
| --- | --- |
| Class | `[consistency]` a decision point · `[security]` where this stack leaks · `[performance]` integrity or performance that breaks silently — outside these three it is not on the card |
| Why models get it wrong | One "— why models get it wrong:" line per item. If you cannot give the reason, the model already knows it |
| Evidence | `<!-- evidence: <policy id · measurement doc · vector · guide-ab item> · model-gap: observed\|not-observed -->` |
| No duplication | Do not rewrite the universal rules (`security.md` · `data-modeling.md` · `code-change.md`) — write only **how** this stack gets them wrong |

- **A consistency item is a decision point, not a value.** Write it like "path prefix · id type · envelope · status codes follow existing
  code and the spec; if there is none, decide once and write it in `code-conventions.md`". Do not nail the pack's example values (`/api` · `{ data }`) onto the card
- The first line is "the project spec and `code-conventions.md` take precedence over this card"
- Budget: body (frontmatter and comments excluded) **at most 3,000 characters · 12 items.** Over budget, do not pick items — drop the less important ones
- Keep a `model-gap: not-observed` item only when the security or integrity damage is large. **When the model changes, measure again with a
  no-guide arm and drop the not-observed items that passed first** — a card that only grows becomes a general guide again

## Separating structure from content

- **Structure (stack-independent)**: section skeleton · order · format. Every item in the table below. Not changeable at generation time
- **Content (stack-specific)**: the actual knowledge that fills each slot. Derive it only from the confirmed stack combination.
  Leaking content from another stack (e.g. a Supabase pattern into an AWS guide) is a self-verification failure

## Required sections (fixed order)

| # | Section (structure) | Content slot | Budget |
| --- | --- | --- | --- |
| 1 | frontmatter | `name:` matches the directory name · description takes the form "what it covers + Use when creating or modifying <task list>". **The gating prefix follows the distribution form**: a guide generated and installed into a project is for that project alone, so it **does not use** the `[Preset:]` prefix or a preset-confirmation sentence. A guide distributed as a plugin and exposed to several stacks (the 2 original nextjs-* guides) **does use** it, to prevent misfires | ≤450 characters (of the description value, excluding the `name:` line) |
| 2 | `## Quick Start` — 2 task-level checklists | The checklist names (New Component / New Route Handler, etc.) and their items are derived from the stack | 6~9 items each |
| 3 | `## Architecture Overview` | The stack's components and responsibility boundaries | ≤30 lines |
| 4 | `## Directory Structure` | The conventional layout for that stack (if the project has a real structure, that takes priority) | ≤30 lines |
| 5 | `## Core Principles (N Key Rules)` — numbered rules + code examples | 5~8 rules. One good/bad code pair per rule. **backend must include input-validation and auth/authorization rules; frontend must include a repeated-UI extraction (shared layout) rule** — these two categories are universal across stacks. The backend auth/authorization rule includes **no existence leakage**: a missing resource and a lack of permission must look like the same response from outside — responding differently lets an unauthorized user enumerate which resources exist (this holds whether the authorization mechanism is RLS, a policy engine, or an ORM scope) | ≤20 lines per rule |
| 6 | `## Common Imports` | The stack's standard import block | ≤30 lines |
| 7 | 1 supplementary section (frontend: component template / backend: HTTP Status + Anti-Patterns) | Chosen per stack | ≤40 lines |
| 8 | `## Navigation Guide` — **task→resource mapping table** | Rows of "what you are trying to do → the file to read". Every file in resources/ must appear at least once | Covers every resource |

## resources/ splitting rules

- The file count is **derived from the slot count**, not from stack complexity: 7 required slots (fewer when merged) +
  0~3 optional slots = **6~10 files**. Fewer than 6 only comes out of merging required slots 3 or more times, and
  merging makes files bigger, colliding with the 300-line ceiling, so it is not recommended
- The backend type (BaaS / self-built) affects **only the number of optional slots in backend-guide**: a BaaS combination
  has fewer infrastructure concerns and converges on 6~7 files, while a self-built combination lands at 8~10 files.
  **The frontend-guide file count is independent of the backend type** — UI concerns (routing · styling · state · performance ·
  types) do not shrink because the backend is a BaaS
- Each file ≤300 lines. Over that, a TOC at the top of the file
- File names are task-centred (`api-endpoints.md`, `database-patterns.md`) — no listing of technology names.
  **A slot the seam fills uses the axis pack's `seamSlots` name verbatim, without exception** — if the names diverge here,
  it breaks the moment a consumer looks a file up by its slot (guide-gate compares them)
- The data-access and auth resources carry content **for the confirmed combination only**
- **Each resource includes a misuse list for its category** — "the correct shape" alone is not enough.
  Two formats work: ① a version idiom comparison table (old habit → current shape), ② a confusion-pair list (APIs and patterns
  close enough in meaning to be chosen wrongly, with the exact condition for applying each). Write only misuses actually
  observed on the confirmed stack and version — do not write generic "common mistakes"

### Resource slot table (stack-independent — derived from the 20 original resources)

A slot is **a coverage obligation, not a file obligation.** Give each required slot a dedicated file or
merge it into another file — even when merged, the Navigation Guide must carry a row for that task.
Keep to the file-count budget (6~10) by merging. A slot name is a concept; file names are named task-first.

> **The bar for filling a slot (2026-10-22)** — a slot is a reference place one looks up to read "how is this wired on this stack".
> **Do not write generic patterns, library usage or tutorial-style explanation the model already knows.** What stays in a slot is only
> ① wiring true only on this stack and version (encapsulation boundaries · config keys · version idioms) ② code that proves a card item
> ③ symbols the pack's policies and ledger require. What must be followed goes on the "Stack core card" above, not in a slot — in a slot alone it may go unread.
> **State at the spot that an example's chosen values (id type · path prefix · envelope · status codes) are "the choice for a new project"** —
> an example that gets read acts more strongly than a rule file (guide A/B re-measurement: the example's `uuid('id')` beat "follow the existing code").

**frontend-guide required slots, 7:**

| Slot | Content contract |
| --- | --- |
| Component patterns | Includes the repeated-UI extraction (shared layout) rule — a deepening of the hub principle. **Put a pre-creation search obligation into the extraction rule**: before creating a new shared component, search the shared directory and reuse what is already there — most duplication comes from a failure to search, not a failure to extract. Design tokens a shared component owns (height · typography · spacing) are defined in that one component only, and call sites control them through props alone |
| Data fetching | This stack's standard fetching layer + the boundary forbidding direct calls from components. **Present the means of enforcing that boundary as well** — put an explicit marker on server-only modules so that entering the client bundle is promoted to a build error. A boundary that exists only as discipline breaks silently: some server code bundles without error when imported from the client, and the failure then appears not as a build failure but as a runtime failure or a leaked secret |
| Routing | Route definition · nesting · protected routes |
| State management | The criterion separating local from global + the chosen tool's subscription pattern |
| Styling | This stack's styling system and its forbidden patterns |
| Loading/error states | Handling the 3 states loading · empty · error (may be merged into component patterns) |
| Complete example | One feature end to end (a list + create flow is recommended) |

**backend-guide required slots, 7:**

| Slot | Content contract |
| --- | --- |
| API endpoints | This stack's standard handler shape + the request/response contract |
| Data access | Query/client patterns only — table design is a reference row pointing at the T1 data-modeling card (no copying, and **write the card's real path into the reference** — a reference without a path is unreachable). **Present mutations (update/delete) in a form that checks the affected row count** — responding to a 0-row mutation as a success is this layer's signature trap |
| Input validation | The validation library's patterns + duplication in DB constraints. **Environment variables are input too**: keep one validated module so that app code cannot read environment variables directly, and make a missing or malformed value fail **at boot time** rather than at first use. That module also enforces that a server-only secret never lands in a client-exposed prefix (`NEXT_PUBLIC_*` · `VITE_*` and other names inlined into the bundle), and public variables and secrets keep separate schemas |
| Auth/middleware boundary | Where the auth check sits · the authorization boundary — a deepening of the hub's security principle. **How many layers of authorization defence there are is set by `dataLayerPolicyEngine` in `pack.json` — this slot contract does not set it**: if a policy engine **exists** (RLS · row security), place it alongside an application-layer ownership filter and trust neither side as a standalone defence. If it **does not** (a self-built server on a trusted connection, etc.), the application layer is **the only boundary** and a missing ownership filter is itself a data leak — writing "the data layer backs it up" here makes it exactly the opposite guidance. Include **the auth flow (login · signup · logout) and the return after login**: preserve the blocked path and send the user back after authentication, but verify that the return path is an internal path (`//host` · `/\host` · an injected control character parse as an external URL in the browser — a string prefix check alone is not enough). Generalize the authentication failure response — distinguishing the reason for failure leaks whether the account exists. For unauthenticated handling, **match the response form to the path**: API paths return the auth error envelope, page paths return a redirect |
| Error handling | Status code mapping + this stack's error code table |
| Testing | This stack's standard test tools and patterns |
| Complete example | One endpoint end to end, validation → handling → response |

**app-guide required slots 6** (when there is an app axis — `presets.app` is neither `none` nor `undecided`):

| Slot | Content contract |
| --- | --- |
| Screens · navigation | This stack's screen definitions · stack/tab navigation · deep links. For a hybrid RN shell, **the transition rules between native screens ↔ webview screens** are the center of this slot |
| Bridge contract | Required only for a hybrid RN shell (empty is normal otherwise). **Verify the origin on receipt** of a webview message — accept without verification and any page loaded in the webview can call native features. The message schema lives in the shared contract package and follows the bridge section of the Step 3-0 contract file verbatim |
| Data · auth transport | The API client layer + **tokens in the platform secure storage** (Keychain · Keystore · secure-store) — plaintext storage (AsyncStorage · shared_preferences · UserDefaults · SharedPreferences) is forbidden. Offline resends carry an idempotency key (paired with the backend-guide idempotent ingest slot) |
| Permissions · device features | Runtime permission requests paired with manifest declarations (Info.plist · AndroidManifest · app.json), and the fallback flow on denial. Only whichever of location · camera · push the project uses |
| Release · update | Store review · what OTA can cover (RN only; native module changes cannot) · forced update paired with API version negotiation |
| Complete example | One screen end to end: entry → data load → an action that needs a permission → showing the result |

**Optional slots** (0~3 depending on stack complexity and confidence): file organization · performance · language/type standards ·
architecture deep-dive · frontend testing · stack-specific mechanisms (a framework's mutation mechanism,
patterns specific to a data platform, etc.)

**Empty-slot rule**: leave even a required slot empty when you cannot summon a pattern you are confident in — the principle that an empty slot
beats wrong content outranks the slot table. But **silent omission is forbidden**: state
"empty slot: <name>" in the generation report so the lessons loop has something to fill.

## Verification — by the generator before returning, and by the main session in Step 4 (dual ownership)

Every item in this spec a machine can check is **owned entirely by the script** (the check list is
`scripts/guide-gate.sh --help`). The verdict has 3 levels, FAIL / WARN / REVIEW, and **if a FAIL remains,
do not install.** Only two things cannot be judged by a machine and must be upheld by a person:

1. Does the description promise only content that **actually exists** in the body (preventing a repeat of the placeholder incident)
2. Was a required slot left empty for lack of confidence stated in the report as "empty slot: <name>"
   (**silent omission = failure**, a reported empty slot = pass)

## Generation stamp format

One line immediately after the SKILL.md frontmatter:

```
<!-- orangekit-guide: generated YYYY-MM-DD stack=<frontend>+<backendType>+<database>+<dataAccess> pkgs=<pkg>@<major> <pkg>@<major> ... -->
```

On regeneration, compare this stamp against the file's modification time to detect a manual edit. Carry **every**
third-party package the guide imports in `pkgs=` — for a missing package the version drift check has nothing to compare against,
so its staleness never becomes visible (the gate catches omissions as a WARN).

## Verification baseline (prebuilt guides only)

A **prebuilt guide** distributed by the plugin (an original that evolves by hand, not a generated artifact) carries a baseline
line at the top of SKILL.md instead of a generation stamp:

```
<!-- orangekit-guide-baseline: verified YYYY-MM-DD <pkg>@<major> <pkg>@<major> ... -->
```

- It declares **which major versions this guide's guidance was verified against**
- `orangekit-init` compares the majors against the project's `package.json` and reports to the user only when they
  disagree (it **does not ask** whether to regenerate — the user has no basis for judging staleness)
- When auditing and repairing a guide, update the `verified` date and the version list along with it

> This is the channel for responding to rot. Measured, a prebuilt guide went undetected for months while carrying deprecated APIs
> and idioms from an earlier major — without a baseline, staleness is invisible.
