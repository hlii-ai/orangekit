# Authoring an axis pack (the maintainer path)

This is the **canonical source for Step 2-A** of `stack-guide-generator`. Read it only when creating a missing axis pack —
this path does not run in a consumer project, so it was split out of `SKILL.md` (there is no reason to keep 133 maintainer-only
lines in a file that loads on every trigger).

`dev/docs/skill-review/` is the canonical source for measured evidence. Only the rules live here.

This is the path for creating a missing axis pack. **Without this section the vue pack authoring became improvisation and took
64 minutes 3 seconds with a single agent, serially** (measured 2026-08-23. The parallelism Step 3-1 designed was never
used once).

> **Invariant: parallelism changes only the authoring method, and not one item of the pass criteria.**
> A pack ships only after 0 `--pack` FAILs · a `pack-smoke.sh` pass · the three audits.
> So the symptom when parallelism fails must not be "a bad pack ships" but
> **"it gets sent back at the gate and the round trips increase"**. To make that hold, the gate directly catches the two
> defect classes specific to parallelism (vocabulary divergence · duplicate passages) — L0's vocabulary policy below and the gate's
> `check_duplicate_fences`.

### L0 — freezing the contract (main session, serial, once)

The main session writes it itself. Because it is **the contract, not the content**, it does not conflict with principle 5 (generator ≠ verifier).

| Output | Content | Why it is frozen here |
| --- | --- | --- |
| `pack.json` | `exampleDomain` · `pkgs` (majors included) · `resources[]` (file names + nav) · `seamSlots` · **`fixesVariants`** · `dataLayerPolicyEngine` | L1 cannot start while the file split and the domain vocabulary are still open |
| The **declaration copy** of `ledger.md` | `provides` (symbol → **assigned defining file + shape**) · `requires` (kind · shape · reason) | Assign ownership only and **leave the shape empty, and a sibling cluster guesses the signature** |
| The `directory-structure` slot of `PACK.md` | The directory tree | Every resource references those paths |
| The **draft** of `policies.md` | The policies the axis sets (security · framework idioms) + the **vocabulary policy** | L1 has to know in advance which rules it could break |

#### What must be answered at the moment of the L0 freeze — the three a machine cannot judge

The following are semantics, so no regex catches them. **Left as prose somewhere they drift, so answer them at the moment the contract
is frozen** — that is the cheapest point, and the pilot wave verifies those answers for real.
The 2026-08-24 audit paid for leaving these three empty with 3 critical defects and 4 false tags.

| What to ask | What L0 writes down | What happens if it is left empty |
| --- | --- | --- |
| **Where the authorization decision goes** | The ownership decision comes **before any parsing, deserialization, or conversion**. An axis with `dataLayerPolicyEngine: false` makes **a test proving that absence, non-ownership, and corruption all produce the same envelope** a required slot | The converter ran ahead of ownership, producing **422 for a corrupted document / 404 for a missing one** — 422/404 became an oracle of existence (gcp measurement, 3 critical) |
| **What the subject of an observation is** | When quoting a limit, size, or time figure, write **the raw text the observation tool printed** and that text's subject together into the tag | A "field value limit (1048487)" was promoted into a "document size limit (1 MiB)". They are different limits and the emulator separates them with different messages |
| **What a fake backend does not imitate** | L0 nails down in advance the list of what an emulator or stub does **not** reproduce: quotas · index enforcement · sharding · IAM · credentials · container lifetime | A "credential-free emulator admin path" was promoted into a "server credential path" — the conclusion is true, but **that measurement is not what established it** |

> **The input path for these three already exists.** The **norm candidates** item of the audit prompt emits, for every pack,
> "what the next pack's L0 must fill". All that changed is that **the place those candidates arrive** was
> made into this table — buried in prose, the main session does not recognize them as norms.

**The pack does not settle the authentication method.** Session cookie or bearer token is a function of whether the frontend axis has a server
runtime — **a function of the combination, not of the axis**. Put `requireAuth` and `useAuth`
into `requires` and `auth-boundaries` into `seamSlots` (the precedent of aws-container and vue).
What L0 fixes is not "which method" but **the shape the pack assumes** (the shape column of requires).

**Fill the "shape" column in `provides` too — assigning ownership alone is not enough.** Measured (2026-08-23),
a sibling cluster called `getTask(ownerId, id)` as `getTask(id, ownerId)`, and because both arguments were
`string`, **neither TypeScript nor the gate caught it** and every single-item lookup returned 404. The ledger
must freeze not only "who defines it" but **"what shape it has"** — the `requires` table had
this column from the start, and only `provides` lacked it. What to write alongside when nailing a shape down:
argument **order** (mandatory when two or more arguments share a type) · the return · what it throws on failure ·
**what the caller must wire up** (e.g. `shutdown(server)` performs draining, so it must be called **inside**
a signal handler — without that one line, an example came out that exits the instant it boots).

**Write "which source file it goes in" into the shape column.** The ledger assigns "which **resource file**
owns it", but that is ownership of the document, not **the path of the code**. In the fastapi measurement
C2 wrote `from app.obs.logging import health_router` while C3 defined it in `app/obs/health.py`, and
the assembled copy broke — **the gate cannot catch this either** (the ledger check looks only at resource files). What caught it was
running the type checker. When the source path a symbol will sit in is not obvious (when the same resource shows
two or more files), nail the path down in the shape column. This is the third of the three "places where the shape column stays silent", and
it was foretold in node-api and then recurred exactly as predicted in fastapi.

**Do not use an optional group in the regex of a `require` policy.** `respond(\.fail)?\(` is satisfied by the success path's
`respond(...)` alone and **never measures the failure path it was meant to verify** (audit A measurement).
In the same class, the bare `ownerId:` of `ownership-in-query` was satisfied by a single line of TypeScript parameter annotation.
Check **what the regex lets through** not with one proof example but also with **a string that must not be**
**let through** — if that passes, the policy is dead.

**Narrow a `require` policy's scope down to the owning file.** The `scope` column of `policies.md` accepts **`file:<file name>`**
besides `guide` and `seam`. Left as `guide`, a require **degenerates** into "passes if it appears anywhere in the pack
at all", **and grows more toothless as the files multiply** — in the fastapi measurement, audit C showed by running that even after deleting
the owning file's `rowcount` check outright, two sibling files carried the same string and the policy passed.
Narrowed, that deletion surfaces as a REVIEW that names the policy (not a FAIL —
the gate treats a missing require as a REVIEW). **Get the file name wrong and the gate blocks it as a FAIL** —
lumping a scope of 0 files together as "deferred until after assembly" surfaced in that same measurement and was repaired alongside.

**When you issue a discipline, issue the contexts where it does not apply along with it.** Establish an axis principle (e.g. "ownership lives
in the `WHERE`") and leave the exception contexts empty, and the resources that fall under those exceptions (deploy-time code ·
migrations · admin tasks) read as though they break the discipline — and they read the other way round as well, so readers
fight over which side to believe.

**L0 issues the vocabulary policy.** Derive the synonym traps from `exampleDomain` and put them into `policies.md`
as `forbid` rows — splitting the clusters splits the vocabulary (measured: `task` 217 times ↔
`note` 166 times), and the gate has to catch that:

```
| `vocab-task` | forbid | guide | `\bnote(s)?\b` | — | `const notes = []` | Vocabulary is Task/tasks (issued by L0) |
```

Bundle the L0 output into **a single scratch file** and paste **the full text** into every L1/L2 without summarizing.

> **That bundle is a copy, and copies drift.** If you fix L0 after the fan-out (which always happens once an audit finds
> an L0 defect), **rebuild the bundle and state to the agents that continue writing what changed.**
> In the fastapi measurement the bundle stayed stale, and a resumed agent, working from that tree,
> **revived a critical defect that had already been repaired**. Writing "the canonical source is `guides/<axis>/<pack>/`" at the head
> of the bundle keeps a resumption from fighting over which side to believe.

### Dividing into clusters — the fan-out unit is not the file

**Separating coupled files is the main price of parallelism.** In serial authoring a later file reads the earlier ones and
matches vocabulary, tone, and example variable names for free; parallelism loses that.

**L0's ledger reveals the clusters** — if a symbol's defining file and its consuming file differ, they are coupled.
In the vue pack, 6 files → 3 clusters (`styling`+`component-patterns` / `loading-error-states`+
`types-and-testing` / `routing`+`state-management`). When a cluster is 1 file, the unit is the file.

### The pilot wave — fan out only after verifying L0 for real

Parallelism removes the author's self-correction path. A serial author realizes at the third file that "this assignment is wrong",
while parallelism **throws away every cluster at once on a wrong L0.**

1. Run **only one** cluster first — the one whose contract is heaviest
2. Run `guide-gate.sh --pack` and see whether the L0 assignment actually holds
3. If L0 needs fixing, fix it **here** (what you throw away is one cluster's worth)
4. Fan out the remaining clusters on the settled L0

### L1 — resource authoring (parallel by cluster)

Hand over: **the full L0 text** · `assets/pack-resource-template.md` · the confirmed stack specification (versions included) ·
the axis premises (where the server code lives · the security boundary · **whether the data layer has a policy engine** · the language) ·
its own cluster's slot contract · the output path.

**What not to hand over**: paths of other packs, the interview context, a sibling cluster's draft.

Instruct the L1 agent with this verbatim:

> - Follow `assets/pack-resource-template.md` and nothing else for format. **Do not open another pack or guide.**
> - **Do not re-check by hand what the gate checks** — dangling references · the line budget ·
>   duplicate exports · env coverage · ledger comparison · forbidden keywords · policy regexes. You cannot see the whole
>   pack, so **you cannot run them meaningfully either.** After fan-in, the main session runs them in 3 seconds.
>   Measured, 52 rounds of generator self-verification caught **0** real defects
> - Spend your time only on **the accuracy of the content** and **whether the code you wrote actually works**
> - For cross-file references use **only what L0 assigned** (you do not know a sibling's final content)
> - Write the security primitives fresh and actually run the vectors of `assets/security-vectors.md` against them.
>   Carry the results (vector · input · output · verdict) in the returned data
> - Attach `<!-- verified: evidence -->` or `<!-- unverified -->` to version claims
> - **To write "X does not appear", show a positive control first.** If you have not once confirmed a case where X
>   really does appear with that instrument, your negative result is not "there is none" but
>   "could not measure" (measured: `pytest -W always` structurally cannot catch a warning raised at
>   `pytest_configure` time, and the author tagged that as "it does not warn")
> - **Work on the premise of being interrupted: write the file first, verify afterwards.** Save as soon as you finish
>   one section. Writing everything at once after all verification is done loses everything on an interruption — leaving a value
>   you are unsure of as `<!-- unverified: reason -->` and saving is the honest output, and **a partly filled**
>   **file beats nothing at all**

**"Save first" is not discipline but a recovery device.** In the 2026-08-24 session an API overload incident interrupted
subagents **eight times** (across 3 agents). The agent that received this instruction **left behind** one 233-line file,
while the agent that did not **left not one line** across three interruptions — because it started with verification every time and
never reached a save. What is at stake is not a wall-clock loss but **a total loss of output**.

Nail down the main session's response along with it: **when interruptions repeat, do not retry immediately.** The canonical source
(`shared/error-codes.md`) prescribes for a 529 `overloaded_error`: **exponential backoff · a different model ·
spreading requests · queuing**. An immediate retry is none of those four. And **do not launch two**
**at once** — during an incident, concurrency is the opposite of spreading requests.

### L2 — hub fragments (parallel with L1)

The remaining `pack-slot` blocks of `PACK.md`. It **assembles from L0's declared ledger alone**, so it does not wait for
L1. If L1 departs from the declaration, the gate's ledger check catches it and the repair is limited to the hub alone.

### L3 — fan-in (main session, serial)

0. **For repairs, continue the same L1 agent with `SendMessage`.** A fresh `Agent` call throws the context
   away and makes it read the files from scratch — the measurement ruled that "what dominated the wall clock was not volume but **the
   number of verification round trips**", so this one line protects much of the gain from parallelism
1. `bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --pack <pack path> --claims-out <TSV>` → repair until 0 FAILs
2. `bash ${CLAUDE_SKILL_DIR}/scripts/pack-smoke.sh --pack <pack path> --keep --online` → execution verification.
   `--online` moves the type check from audit A to here (it installs at the major the pack nailed down)
3. Complete `policies.md`: look at the L1 output, add the content-derived policies, and **fill in each row's `proof example`**
4. Three audits in parallel (Step 5). **Over 40 claims, split only B evenly and launch 4~5 of them** (`split -l $(( (n+1)/2 ))` — `-n l/2` is GNU-only) —
   inventory entries do not reference each other, so splitting loses nothing
5. **Group the repairs by `clusterId` from the audit TSV and send them concurrently.** The ledger has already
   assigned file ownership, so there are no write conflicts — all of a cluster's findings in one message per cluster

**When the findings are many, do not re-delegate the clusters; settle it with one coherence pass** — a single agent
reads the full pack and does **only vocabulary unification · removal of duplicate passages · cross-reference fixes** (no content authoring).
So the worst-case cost of parallelism is bounded at `cluster parallelism + one coherence pass`.

### Pack pipelining — write the next pack's L0 during the main session's waiting time

The stretches where the main session is active are **L0 (about 9 min) · fan-in/gate (about 5 min) · coherence and recording (about 10 min)**, while
the pilot · fan-out · audit · repair (60 minutes or more together) are **waiting**. Write the next pack's L0 in that wait.

```
Pack A:  L0 ─> pilot ─> fan-out ─> fan-in ─> audit ─> repair ─> record
Pack B:         L0 ────────────────────────> [re-review] ─> pilot ─> fan-out ─> …
                                               ↑
                            Pack A's audit compares **only the newly established norms**, fixes L0 and
                            re-issues the bundle. It runs alongside pack A's repairs, so the wait is 0
```

- **Fix the depth at 2.** At 3 or more the main session ends up holding three packs' contracts at once —
  in node-api **7 L0 defects** were already observed, and 2 of them were the main session's own errors
- **While writing pack B's L0, do not read pack A's audit report.** Mixing contract writing with reconfirming findings
  makes both worse. Handle the audit results after pack B's L0 is frozen
- **Re-review L0 right before pack B's fan-out** (below)
- **Even when building adjacent axes back to back, nothing leaks into L1.** Take the benefit of adjacency only from the main
  session's L0 knowledge — putting up the firewall as an instruction failed under measurement

#### The L0 re-review gate — pipelining delays the propagation of norms

**A contract frozen after a norm was established held it; one frozen before repeated the same defect.**
`firebase` became the natural experiment — the `fastapi` audit established two norms, one **before** firebase's
L0 freeze and one **after**:

| Class | Norm status | Result |
| --- | --- | --- |
| Asserting an enumeration as a **value** · argument order | Existed **before** the freeze | **0 recurrences** |
| **Source path** | Raised **after** the freeze | **Recurred exactly — 2 critical** |

The lesson is not the content of the norm but **when it propagates**. But deferring pack B's L0 until after pack A's audit
makes the pipelining disappear — the wait it was meant to remove is exactly the audit stretch.

So **instead of deferring the freeze, insert a re-review.** The pilot wave is already the gate "fan out only after verifying L0
for real", so **no stage is added; one item is attached to that gate**:

1. Extract **only the newly established norms** from pack A's audit report (individual findings are pack A's business —
   do not reconfirm them here. The rule above, that mixing makes both worse, applies as is)
2. Check pack B's L0 against those norms. With 0 norms the gate takes 0 seconds
3. If you fixed something, **re-issue the bundle and state what changed** (an L0 bundle is a copy and
   it drifts — a norm that already exists)

**Measurement obligation**: the number of new norms ↔ the number of L0 fixes they forced. In `firebase` this value was
(2 norms → 0 fixes) and 2 critical defects followed. If the fix count stays 0, remove the gate —
a gate that yields nothing is only a cost.

### Rollback — by measurement, not by impression

If any one of the following is observed, roll the next pack's default back to serial (1 cluster) and leave the reason.
The other improvements (the template · smoke · the gate · the three-way audit split) are independent of parallelism and stay as they are.

| Criterion | Threshold |
| --- | --- |
| Parallelism-specific FAILs and REVIEWs at fan-in | Not settled by one coherence pass |
| Repair round trips | More than 3 |
| Audit C's cross-file findings | More than the same class in the previous measurement |
| Generation critical path | Fails to beat the previous measurement |
| L0 defects per pack (the ones the pilot caught) | More than 7 — roll the pipeline depth back to 1 |
| Cross-pack contamination during pipelining (one pack's vocabulary or premises mixing into another) | Even one — roll the depth back to 1 |

### When bringing in a new toolchain, assume the harness knows only one language

In fastapi (the first Python axis), **all 18** FAILs the gate and smoke produced **were false positives**, and the cause was a single one:
the checkers were written in TypeScript shapes. Definition detection (`const` only), import sourcing (`^import` only),
stub generation (the `@/` alias only), `pkgs` extraction (missing 0.x minors) — every shipped pack was TS, so **a synthetic
fixture structurally could not have revealed it.**

So on the first pack of a new toolchain, **always run the pilot wave**, and before declaring a fan-in FAIL
to be a "pack defect", **first suspect that the checker does not know that language.** And every time you repair one,
leave a fixture in that language in `--self-test` — so the next pack does not pay the same price again.

### Once you have fixed the harness, run the regression against the shipped assets

**A synthetic fixture catches misses; the real thing catches false positives.** All 7 gate defects showed up only in real use,
and the synthetic fixtures passed all four of them. So `--regress` actually checks every shipped pack and seam
— `--self-test` (fast) while fixing the harness, **`--regress` before shipping**.

**Measurement obligation**: record in `dev/docs/skill-review/` the wall clock per stage (L0 / pilot / remaining clusters / L2 / L3) · subagent
tokens · tool calls · the count of audit findings per class · the actual values of the 4 rollback criteria
above. **Do not write "it got faster" without measurement** —
the previous session's estimate (20~40 minutes) was proven wrong by a measured 64 minutes.

## Pack refresh — major bumps (maintainer, periodic)

**This is where a consumer init's refresh cost is brought to zero.** When a pack goes stale, every consumer pays the
same rewrite separately at init (stack-guide-generator Step 2-B). So `harness-evaluation` runs
`guide-freshness.sh --pack` over every pack on each evaluation, and a bump lands here.

| Kind of bump | What to do |
| --- | --- |
| partial rot (outside `fixesVariants`) | rewrite only the affected files from `--json` → raise that major in `pkgs` |
| pack premise (inside `fixesVariants` — framework·ORM) | **reopen from L0**: freeze `pkgs` · ledger shapes (signatures may have changed) · policy regexes (idioms may have changed) at the new major, then rewrite the affected resources |
| toolchain (`typescript` · `@types/node` · 0 affected files) | raise only `pkgs` and confirm just the typecheck with `pack-smoke --online` |

The basis is **each package's official migration guide**, and version claims get tags (audit B looks at them).
The pass bar is the same as authoring — `--pack` FAIL 0 · `pack-smoke --online` · audit (once). When done,
raise `packVersion`·file stamps·the `verified` date and release. **If wire values changed**,
raise `wireContractSince` to that edition too (the installer's contract pinning looks at that value).

> **A prerelease is not the latest.** Some packages have an rc on the `latest` tag (prisma 8.0.0-rc) —
> `guide-freshness.sh` falls back to the highest stable release for its verdict. Do not raise a pack to follow an rc.
