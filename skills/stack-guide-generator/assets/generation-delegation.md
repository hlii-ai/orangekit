<!-- An asset used only by stack-guide-generator. Called from the matching Step in SKILL.md.
     Kept in the body, all 505 lines would be pulled in at the moment Step 0 is read. -->

# Step 3-1: Generation delegation — three layers, parallel by coupling cluster

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
(for two or more guides, identical in all of them down to the wording) · **the package manager** (the preset's `packageManager`) ·
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
5. Output location: the project's `.claude/skills/frontend-guide/` · `.claude/skills/backend-guide/` · `.claude/skills/app-guide/`
6. **Run the gate yourself before returning** — reach **0 FAILs** with `guide-gate.sh --guide <path> --generated`
   and then return. Do not fix WARNs and REVIEWs; **report them with a reason attached**
   - **The generator's scope cap: writing + the gate, and no further.** Installing packages (`npm i` and the like) · `tsc` · starting a DB ·
     running tests or mutations are **not done** — execution verification belongs to the main session's Step 4-1 (`pack-smoke.sh`) and
     audit A. Measured (a consumer project, Windows): when the delegation instruction also asked for install and `tsc`, the backend
     generator went on to run an embedded PostgreSQL · vitest · mutations, and **a single agent took 62 minutes and 340k tokens**.
     Put this line into the delegation prompt verbatim — without it the generator widens "checking" on its own
7. **For a relational DB, link to the data-modeling card — do not copy it.** The canonical source is
   the T1 rule card (`data-modeling.md` under `.claude/rules/`), which orangekit-init installs for every preset
   and which loads automatically on a `paths:` match (supabase · migrations · db · prisma · drizzle).
   Put only the following into the backend-guide you generate:
   - 1 row in the Navigation Guide: table and migration design → a pointer to the data-modeling card (auto-loaded)
   - **A non-PostgreSQL RDB (MySQL and the like)**: state one line — "take only the principles from the card's
     PG-specific sections (§5 · 10 · 14 · 16 · 18) and substitute this stack's syntax"
   - **NoSQL (MongoDB · DynamoDB)**: the card lies dormant because paths do not match — write that DB's modeling
     patterns (document design · partition keys, etc.) directly into the resource from knowledge of the combination

   > Why the canonical source is not copied or adapted into a skill resource: a copy is a source of drift
   > cut off from plugin updates. A single card + a version stamp update is v3's distribution method.
