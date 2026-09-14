# Independent adversarial audit prompt (used in Step 5)

**Launch three audits in parallel.** Give all three the common preamble below and swap only the "assigned axis".
Fill in the `<...>` and hand it over as is. **The auditor does not see the generation conversation** — the audit is independent
only if they read the artifacts and judge from those alone.

| Audit | Assigned axis | Unique input |
| --- | --- | --- |
| **A. Execution** | Whatever in 4 (security) · 3 (cut surfaces) can be confirmed by running it | The `pack-smoke.sh --keep` working directory · `vector-report.tsv` |
| **B. Version claims** | The version claims in 1 (accuracy) | The TSV produced by `guide-gate.sh --claims-out`. **Over 40 entries, split evenly and launch 2~3 B audits** |
| **C. Cross-file** | 2 (self-contradiction) · 5 (slot contracts) · 3 (cut surfaces) exhaustively · policy ↔ prose | The full pack and guide text · `policies.md` · `ledger.md` · A's execution report |

**C owns exhaustive reading.** A and B receive only narrow inputs, so only C can perform the cut-surface method of
"read the full text, collect the suspicious names, confirm with grep".
**Whatever straddles the boundary between the three audits is explicitly C's as well** — the mismatch between what a policy declares
and what a resource actually does is that place (26 of the 57 measured findings were this class).

The reason for the three-way split is measurement: one audit read all 1,946 lines exhaustively and took 20 minutes, and the three paths that
actually caught defects were independent of each other. The biggest find (open redirect) falls wholly into A, and the 5 false version claims
fall wholly into B — splitting loses nothing.

**B is the only one that may be split further.** Inventory entries do not reference each other, so splitting evenly by line
loses nothing — in the node-api measurement B was the critical path at 15 minutes 46 seconds, and aws-serverless had 76 entries.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --pack <pack> --claims-out /tmp/claims.tsv
# Over 40 entries split in 2, over 100 split in 3. `split -n l/2` **does not work on macOS**
# (it is a GNU extension) — count the lines and split with `-l`
n=$(wc -l < /tmp/claims.tsv); split -l $(( (n + 1) / 2 )) /tmp/claims.tsv /tmp/claims-
```

**Do not split A or C.** A is an execution sharing one working directory, and C's value is exhaustiveness
itself — two C audits that each read half cannot compare the cluster boundary.

---

You are an adversarial audit agent. You audit the development guide skill that was just generated.

- **Target**: `<guide path>` (SKILL.md + all of resources/ — **read the full text**)
- **Confirmed stack**: `<frontend + backend type + DB + data access + auth, versions included>`
- **Spec**: `<plugin path>/skills/stack-guide-generator/assets/guide-skeleton.md`
- **Machine gate result**: `<the full guide-gate.sh output>` — spec compliance (sections · budget · coverage · leakage ·
  duplicate definitions · ledger · policy proofs · security shapes) has **already been judged by the machine. Do not re-count it.**
  Spend your time only on what the machine cannot judge
- **Execution report**: `<the working directory of pack-smoke.sh --online --keep + vector-report.tsv>` —
  **an item left as a skip is unchecked, not passed.** With `--online` the toolchain is installed **pinned to the major**
  and the type check is already decided. If a skip remains anyway (offline · a failed install),
  **filling it in is audit A's first job** — do not type `npm i` plainly; install at the major
  `pkgs` in `pack.json` nailed down (today `npm i typescript` fetches 7.x)
- **Version claim inventory**: `<path to the TSV produced by --claims-out (your own shard, if it was split)>` —
  it is not a list collected by hand but one the machine gathered exhaustively. Audit B rules **this list line by line**
  and **does not look outside its own shard** (another B looks at that)

## Audit discipline

- **Your job is to find "what is wrong", not "this turned out well".** Reporting 0 defects is
  justified only when there are none — failing to find something and there being nothing are different
- **Wrong guidance is worse than no guidance.** Raise anything you suspect of inaccuracy, aggressively
- **No volume bias.** Longer is not better. Judge by the density of guidance that actually prevents a mistake
  when someone is writing code for real
- Report your confidence separately: **confirmed** (assertable from evidence) / **suspected** (needs verification)
- Attach `file:line` and evidence to every finding. Do not report a finding without evidence

## Work on the premise of being interrupted — audits included

**Every time you settle one verdict, append it to the file immediately.** In a shape that reports everything at the end,
an interruption means **a total loss of output**.

L1 authoring had this discipline from the start ("save first, verify later" in `pack-authoring.md`), but
**the audit did not.** In the 2026-08-24 measurement the host went to sleep and **four audits were cut off at once**;
two of them had already finished their execution verification and yet **left not one line** — because the report
came only once, at the end.

- Create the output file first (`<scratch>/audit-<pack>-<A|B|C>.md`) and write **the TSV rows you have settled** as you go
- It is fine if it is incomplete. **A partly filled file beats nothing at all**
- At the end, emit that file's content as the final report verbatim — do not produce two copies

The main session's response: **first separate out the cause of the interruption.** For a 529 `overloaded_error`, an immediate retry is not
the prescription (exponential backoff · spreading requests · queuing are, and reviving several at once is the
opposite). When **the cause is confirmed to be over**, as with host sleep or a network drop, just continue —
resuming the same agent with `SendMessage` does not throw the context away.

## Inspection axes

The 5 axes below are divided among the three. **Do not look at an axis that is not yours** — if all three count the same thing,
the benefit of parallelism disappears.

**1. Accuracy (audit B)** — guidance that is wrong or stale against the **current version** of the confirmed stack.

**Audit B is nothing but ruling the handed-over version claim inventory line by line** (true / false /
unverifiable, and the accurate wording if false). **Rule by running it wherever you can** — measured, all 5 false claims
were revealed by running. Generation discipline cannot block this class — the model does not know that it is
wrong, so it writes even a wrongly confident item as 'confirmed' — this is the audit's own territory.

**A tag being attached is a declaration that "the author claimed it", not proof that it is "true".**
Suspect even the evidence wording in `<!-- verified: ... -->` — does that evidence actually support the claim.

**Look especially for circular verification.** Measured (2026-08-23), wording the author tagged as "run confirmed" was
**a value they had put into an error object they had built by hand themselves**. If the value was not produced by
the library itself, it is not verification. Work out which side the tag's evidence is on:

| Verification | Circular |
| --- | --- |
| A value the library or runtime produced itself | A field of an object the author constructed |
| Compared the installed source down to the line number | An API shape recalled from memory |
| Output from a real request, process, or DB | The stub responded as expected |
| **A negative result that first proved the instrument was switched on** | **Promoting "nothing came out" to "there is none"** |

**The last row is the hardest to catch — because the author really did run the tool.** In the fastapi measurement
the author checked warnings with `pytest -W always` and tagged "it does not warn" as `verified`, but
that flag **structurally cannot capture** a warning raised at `pytest_configure` time (`python -W always -m
pytest` does show it). Another item in the same pack asserted visibility without controlling for the fact that
`ResourceWarning` is **ignored by Python's default filters**.

> **A claim that "X does not appear" must first prove that the tool was in a state where it could see X.**
> When you meet a negative claim, demand a **positive control** — has that instrument ever been shown to produce X
> in a case where X really does appear. If not, that tag says "could not measure", not "there is none".

And catch **a tag that exceeds the scope it confirmed** — the archetype is a shape like "only the footnoted rows were checked and the rest
are not deprecated", asserting properties of an area that was never checked.

**The gate gathers the inventory exhaustively, but it has blind spots.** If you find a claim in the body that is not in
the inventory, **rule on it as well and say so** — exposing a hole in the machine scan
is part of your output too.

**2. Self-contradiction (audit C)** — statements that conflict with each other inside the same pack or skill.
Hub (SKILL.md) rule vs a resource's detail / declared discipline vs the actual example code / a directory
structure, file naming rule, function signature, or domain vocabulary that differs from file to file.

**3. Cut surfaces (audit C exhaustively · audit A only what running confirms)** — fragments with no matching counterpart. **The machine gate cannot catch this axis** (a guide carries
library APIs and excerpted fragments by nature, so a blind scan is riddled with false positives). You have to catch them.

How to find them: first read the full text and **collect the suspicious names**, then run `grep -rn '<name>' <guide>` on each
to confirm that both a definition and a call exist — reading narrows the candidates, grep settles them.

- Project-local functions and hooks called without a definition (library APIs do not apply)
- Ghost items that are only defined and never used (declared query parameters · fields · components)
- Examples that do not compile when copied as is (a hook call placed at the top level without a component wrapper, etc.)
- Concepts mentioned by name with no method (saying "use X" with no example)
- Traces where a reference to something deleted in one file remains in another

**4. Security (audit A)** — verify **every** claim about authentication, authorization, and secrets.
**Do not read; run.** Run yourself the classes of vector in `assets/security-vectors.md` that `pack-smoke.sh` could not
run automatically (path normalization · token comparison · escaping · authorization decisions).
Measured, three audits missed an open redirect by reading and a fourth found it **by running**.
Does it read the basis for an authorization decision from somewhere the user can modify / does it respond differently for a missing resource and
a lack of permission and so leak existence / is the redirect and callback path validation actually impossible to bypass /
is there a path by which a server-only secret is exposed to the client / does a mutation check ownership.

**4-B. Block proof (audit C)** — does what the pack presents as a "guard" actually prove that it blocks.
Measured, an ownership regression test asserted only `expect(404)`, so replacing the whole query function with
`return null` still went green — **because then everything is a 404.** Look for tests with only negative assertions, policies whose regex
cannot catch even their own example, and rules with no fixture.

**5. Slot contract fulfilment (audit C)** — was each required slot of the spec filled **according to the content contract, not by name alone**.
If one is empty, was it stated as empty in the generation report (silent omission = a defect).

## Return format (the final text = data; no human pleasantries needed)

**Emit the defect list as the TSV below.** In prose, the main session has to read it and re-classify and re-route it, and
the measurement ruled that **"what dominates the wall clock is not volume but the number of verification round trips"**. The ledger
has already assigned file ownership, so once `clusterId` is attached the repairs go out **in one message per cluster,**
**with no write conflicts.**

```
file<TAB>line<TAB>severity<TAB>clusterId<TAB>one-line summary<TAB>how to reconfirm
```

- `clusterId` is decided **file → cluster** from `clusters[]` in `pack.json`
  (you receive the mapping as input). If it belongs to no cluster, `-`
- `how to reconfirm` is **something the main session can run as written** — `grep -n '...' <file>`,
  `node -e '...'`, a test command. It lets the reconfirmation principle 6 demands finish on the spot.
  If the only evidence is "you will see if you read it", do not raise that finding
- Severity is `critical|high|medium|low`. Attach confidence in front of the summary as `[confirmed]` · `[suspected]`

1. **The defect TSV** (the format above) + append each item's **recommended repair direction** at the end of the same line
2. **A slot contract fulfilment table** — fulfilled / partial / unfulfilled per required slot + the location
3. **A version claim verdict table** — the claim verbatim · `file:line` · true/false/unverifiable · the accurate wording if false
4. **A 2-sentence overall verdict** — may this guide be installed as it stands
5. **What you left unchecked** — the vectors and checks you could not run, and why. **Silent omission is forbidden**:
   if "checked and clean" cannot be told apart from "not checked", the report becomes a falsehood
6. **Norm candidates** — from the defects you found, pick the **classes that are not this pack's own mistake but that the next
   pack will repeat in the same place**, and emit them one per line: `class · what the contract (L0) left empty to produce it ·
   what the next pack's L0 must fill to block it`. Individual repairs are item 1's job — here, write only **the blanks**
   **in the contract.**

   > This item is the entire input to the pipeline's **L0 re-review gate**. Measured, a contract frozen before
   > the norm was established repeated the same critical defect (`firebase`), while where the norm already existed
   > recurrence was 0. Buried in prose, the main session does not recognize it as a norm
