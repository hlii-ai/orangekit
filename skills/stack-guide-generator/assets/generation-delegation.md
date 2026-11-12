<!-- An asset used only by stack-guide-generator. Called from the matching Step in SKILL.md.
     Kept in the body, all 505 lines would be pulled in at the moment Step 0 is read. -->

# Step 3-1: Generation delegation — three layers, parallel by coupling cluster

## Contents

- Three-layer delegation (L0 · L1 · L2)
- Combination dependencies — the two guides are functions of each other

One agent per guide writing ~2,300 lines **serially** measured 36.6 minutes. The contract discipline stays as it is
and **only who writes layer 2** widens to the file level. The main session does not write them itself so that
the verification in Steps 4~5 does not turn into self-grading (principle 5).

| Layer | What it does | Concurrency |
| --- | --- | --- |
| **L0 contract** (main session) | The Step 3-0 contract file + **merging the pack's `ledger.md` requires and `policies.md`** + **declaring the symbol ledger** (assigning in advance which symbols each file owns) | 1 |
| **L1 resources** | One subagent **per coupling cluster**. Input = the frozen L0 + the stack specification + the structure template | As many in parallel as there are clusters |
| **L2 integration** | The complete example. It **assembles from the declared ledger alone**, so it can run at the same time as L1 | 1 per axis, in parallel with L1 |

**Why the concurrency is safe.** Measured, parallel isolated generation broke because the two guides failed to agree
on the wire contract, and the fix is Step 3-0. Widening from 2 to N does not grow that risk —
**because L1 starts only after L0 has frozen every cross-file matter.** The newly created risk is
inconsistency between sibling resources, and the gate's dangling · ledger · env · policy checks are already cross-file checks.

**The fan-out unit, the pilot wave, the coherence pass, and the rollback criteria are the same as in Step 2-A.** That is the canonical source, so
it is not copied here — the price of parallelism (the wording consistency serial work gave for free, an L0 error spreading
across everything, repair round trips) and its mitigations are all there.

> **Running L2 in parallel with L1 is a change of discipline.** The old spec was "maintain the ledger while writing and
> assemble the complete example from the ledger alone"; this changes it to "**declare** the ledger in L0 and have L1 and L2 both honour it".
> If L1 departs from the declaration the gate's ledger check catches it, and what has to be repaired is then limited to the
> complete example alone. If departures are frequent, put L2 back behind L1 (+5 minutes of critical path).

What to hand over: **the confirmed stack specification for every axis being generated** (versions included — for the app axis, `techStack.app` · `appShell` · the app preset notes) · the Step 2 combination dependency items
(where the server code lives · the security boundary · whether there is a policy engine · the language) · **the full text of the Step 3-0 contract file**
(for two or more guides, identical in all of them down to the wording — for a hybrid RN shell, the bridge contract file too, to the frontend and app generators) · **the package manager** (the preset's `packageManager`) ·
**the list of pinned packages and major versions** (this becomes `pkgs=` in the generation stamp — without it the later drift
check has nothing to compare against) · absolute paths to the spec and the gate script · the output location ·
the generation rules below · "return the final text as data (file list · line counts · slot mapping · empty slots · **the ledger**)".

**Tell the agent building frontend-guide about the backend axis** too (and the reverse likewise).
Told about one axis only, it either cannot fill the data-fetching and auth slots or fills them wrongly.

**What not to hand over**: the interview conversation context, talk of other presets (blocking context inertia).

Generation rules (instruct the subagent with these verbatim):

1. Read `assets/guide-skeleton.md` and build the skeleton of the 8 required sections
2. **Write in dependency order, and maintain the symbol ledger as you write (contract → consumption → integration).**
   About 70% of the 55 measured cases were an ordering problem, not a lack of knowledge (writing both sides and never comparing them).
   Change the order and that class becomes structurally impossible:
   - **Layer 1 · contract**: write the wire contract · the env schema · the domain schema/types **first**.
     They are the single canonical source every later resource references
   - **Layer 2 · consumption**: as you write a resource, **enter each newly introduced project-local symbol in the ledger**
     (library APIs excluded). The row format is `| symbol | defining file | consumers |` —
     e.g. ``| `requireOwner` | auth-boundaries.md | api-endpoints.md, complete-example.md |``
   - **Layer 3 · integration**: assemble the complete example **from the ledger alone**. Do not use a symbol that is not in the ledger
     (no undefined calls), and a symbol with no consumer is either consumed here or deleted (no ghost definitions)

   The ledger is part of the returned data — the gate uses this table to machine-compare the actual definitions and uses
3. Fill the content slots with knowledge of the confirmed combination:
   - Write only verifiable facts (standard patterns at the level of official documentation), and write them declaratively
   - A structure that actually exists in the project (directories · configuration) takes priority over convention
   - Do not write a pattern you are not confident in — an empty slot beats wrong content
   - **Follow `assets/pack-resource-template.md` for format. Do not open another pack or guide.**
     The old spec put up the firewall "reference the format only, never copy content" as an instruction and
     **it failed under measurement (2026-08-23)** — a broken `safeReturnTo` was copied verbatim from the react-vite pack
     into the vue pack, and the same defect was in all four shipped copies. An instruction does not block it
   - **Always write the security primitives (path validation · token comparison · escaping · redirects) fresh.**
     Actually run **every** relevant vector in `assets/security-vectors.md` against your implementation and
     include the results (vector · input · output · verdict) in the returned data. The gate's
     `check_security_shapes` blocks known vulnerable shapes with a FAIL, but **what it blocks is only the**
     **shapes it already knows**. Carrying defence wording over from a combination whose data-layer policy engine is the opposite
     inverts its meaning — read `dataLayerPolicyEngine` in `pack.json` first
   - **Tag version claims** — when you write something of the form `added in vN / removed in vN` · `now requires` · `no longer`,
     put `<!-- verified: evidence -->` or `<!-- unverified -->` on the same line or the line before.
     The gate collects untagged claims and hands them to audit B (measured: 5 of this class were false)
4. Organize resources/ according to the spec's **resource slot table** — cover that guide's required slots (7 for frontend · backend, 6 for app)
   with dedicated files or by merging (leave a slot you are unsure of empty, but state it in the report), and
   split into the 6~10 files derived from the slot count, mapping every one of them in the Navigation Guide
   **What must be followed goes on the core card, not in a resource** — follow the admission conditions (class · why models get it wrong ·
   evidence · no duplication) and the budget of the spec's "Stack core card". Generic patterns and library usage the model already knows
   go neither in resources nor on the card
5. Output location: the project's `.claude/skills/frontend-guide/` · `.claude/skills/backend-guide/` · `.claude/skills/app-guide/`,
   plus one core card per axis at `.claude/rules/stack-<axis>-<stack name>.md` (for an axis with a pack the installer already put it there — do not write it. For an axis with no pack, the generator does not write the card either — a card written from model knowledge is not evidence.
   The main session makes it separately with `rules-authoring.md`)
6. **Run the gate yourself before returning** — reach **0 FAILs** with `guide-gate.sh --guide <path> --generated`
   and then return. Do not fix WARNs and REVIEWs; **report them with a reason attached**
   - **The generator's scope cap: writing + the gate, and no further.** Installing packages (`npm i` and the like) · `tsc` · starting a DB ·
     running tests or mutations are **not done** — execution verification belongs to the main session's Step 4-1 (`pack-smoke.sh`) and
     audit A. Measured (a consumer project, Windows): when the delegation instruction also asked for install and `tsc`, the backend
     generator went on to run an embedded PostgreSQL · vitest · mutations, and **a single agent took 62 minutes and 340k tokens**.
     Put this line into the delegation prompt verbatim — without it the generator widens "checking" on its own
7. **For a relational DB, link to the data-modeling card — do not copy it.** The canonical source is
   the T1 rule card (`data-modeling.md` under `.claude/rules/`), which orangekit-init installs for every preset
   and which loads automatically on a `paths:` match (supabase · migrations · migration · db · prisma · drizzle · alembic · `*.sql`).
   Put only the following into the backend-guide you generate:
   - 1 row in the Navigation Guide: table and migration design → a pointer to the data-modeling card (auto-loaded)
   - **An RDB that is neither PostgreSQL nor MySQL**: state one line — "take only the principles from card §5 and
     the dialect tables in the pattern files, and substitute this stack's syntax" (the card already gives PG and MySQL side by side)
   - **NoSQL (MongoDB · DynamoDB)**: the card lies dormant because paths do not match — write that DB's modeling
     patterns (document design · partition keys, etc.) directly into the resource from knowledge of the combination

   > Why the canonical source is not copied or adapted into a skill resource: a copy is a source of drift
   > cut off from plugin updates. A single card + a version stamp update is v3's distribution method.

## Combination dependencies — the two guides are functions of each other

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
