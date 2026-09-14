<!-- An asset used only by stack-guide-generator. Called from the matching Step in SKILL.md.
     Kept in the body, all 505 lines would be pulled in at the moment Step 0 is read. -->

# Step 4 · 4-1: The machine verification gate and execution verification

The generator also runs the same gate before returning, but **the report that it ran is itself a self-report** (principle 5).

If you authored an axis pack, check it **first with `--pack`, before assembly** (the fan-in point of Step 2-A).
Only the checks that close inside the axis run; explicitly report that whatever is a function of the combination (`requires` satisfaction · `--pair` ·
policies scoped to seam) was skipped.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --pack <pack path> --claims-out <TSV path>
```

`--claims-out` exports the version-claim inventory to a file. It is **the entire input to audit B**, and the gate's
temporary directory is deleted on exit, so without it everything past the 40th entry disappears.

For an assembled copy, run the following.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --guide <guide path> --generated \
  --pm <package manager> --ledger <the ledger the generator returned> --forbid <stack keywords absent from the confirmed combination> \
  --assembly <guide path>/assembly.json      # only on an axis assembled from a pack — see below
# If you built both guides, contract coherence too — an audit that reads one side cannot catch this mismatch
bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --pair --contract <the Step 3-0 contract file> \
  --frontend <frontend path> --backend <backend path>
```

**Leave `--assembly` out and the pack boundary check turns off entirely.** Give it the `assembly.json`
that `install-guide.sh` left and two checks switch on:

| Check | What it catches |
| --- | --- |
| Pack interface | The seam does not define the pack's `requires` → the pack's examples cannot run |
| Policy ledger | The seam breaks a cross-file invariant the pack declared (**26 of the 57 measured audit findings were this class**) |

**What the gate came to own (v3.13.0)** — moved over from prompts and from human memory:

| Check | What it replaced |
| --- | --- |
| Asserting the `proof example` column of the policy table | "build a defect fixture per policy and run it to see whether it is caught" — **this dominated the wall clock of the vue authoring.** Now it is asserted in milliseconds |
| `check_security_shapes` | The two recurring shapes of open redirect. They are axis-independent shapes rather than a per-pack policy, so the gate body owns them |
| `check_claims` | Collecting the "version claim list" for the auditor by hand. It is now gathered exhaustively as WARNs + an inventory |
| `check_duplicate_fences` | The duplicate passages parallel authoring creates. The ledger sees symbols only, never passages (REVIEW) |
| `fixesVariants` ↔ `pkgs` coherence | The pack not declaring the variant it nailed down, leaving nothing to compare at assembly time |
| Enforcing the "shape" column of `provides` + comparing argument counts | **The single cause of 2 critical defects.** Assign only the owning file and a sibling cluster guesses the signature |
| `check_blocking_proof` | A test presented as a "guard" that asserts only negatives and passes even when the implementation is failed wholesale (REVIEW) |
| The **prebuilt seam regression** of `--self-test` | A shipped asset at combination granularity, so it must be checked every time a pack is fixed — assemble it and run the assembled-copy gate and `--pair`. `--pack` alone does not switch on `requires` satisfaction or policies scoped to seam |
| The **shipped-pack regression corpus** of `--self-test` | A synthetic fixture **cannot catch a false positive.** All 4 defects in this gate showed up only in real use — now, if a new check false-positives on the real thing, the self-test goes red immediately |

Policy checks apply only to the output of `codelines()` — counting prose, comments, or anti-pattern examples makes them all
false positives (8 confirmed during development). When a regex produces a false positive, what to fix is not the code but
**the pack's `policies.md`**: designate an exception file, or narrow the regex.

**If even one FAIL remains, do not install** — send the failing items back to the subagent to repair and
run it again. Carry WARNs into the Step 7 report. For REVIEWs, **justify or repair each item**:
this is the place a machine cannot judge, so a silent pass is a defect passing.

### Step 4-1: Execution verification — there is a class that reading does not catch

**Measured (2026-08-23), almost every defect left after passing every item of the machine gate was caught**
**by running it.** The auditor built a real project in scratch and ran vue-tsc and node to find them —
open redirect · `:key` remount · a missing msw import · a spread in the test harness ·
the `test` key of `defineConfig`. That voluntary act is promoted into a stage of the pipeline.

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/pack-smoke.sh --pack <pack path> --keep --online
```

**`--online` moves the type check out of audit A and into this stage.** Without it `tsc` stays skipped and
audit A's first job becomes an npm install, putting that wait on the audit's critical path. `--online` installs
`pkgs` from `pack.json` **pinned to the major** — typing `npm i typescript` plainly
installs 7.x today, while the pack settled on 5. With no network it is an **explicitly reported skip**, not
a FAIL (offline availability is this script's premise).

| What it does | Note |
| --- | --- |
| Restores to a real file only **the fences that claim a complete file** with `<!-- file: path -->` | Trying to compile every excerpt turns into a swamp of false positives. The claim is the author's opt-in |
| Fills unresolved imports from the ledger's `requires` with stubs | Looked at as a pack alone, seam symbols are always unresolved |
| Syntax check (`node`'s type stripping — offline) | JSX and SFC are not stripping targets, so they are **explicitly reported as unchecked** |
| Type check (`tsc`) | With `--online` it installs at the major the pack nailed down and runs. Without it, **the skip is reported explicitly** — unchecked, not passed |
| Runs the 12 return-path vectors of `assets/security-vectors.md` | **The biggest measured find was this class.** Confirms all of them: 10 blocked · 2 legitimately passing |

**Hand the working directory left by `--keep` and `vector-report.tsv` straight to audit A** —
much of the cost of an auditor building a scratch project from nothing is already paid here.

Toolchain profiles live at `scripts/profiles/<name>.sh`. There are currently two, **`node-ts` and `python`**, and
one is selected automatically from the extension of the restored unit. For a toolchain with no profile, the script reports
the skip explicitly — silent omission is forbidden.

**To run a type checker you must put it in `pkgs`.** `--online` installs only `pkgs`, so
without `typescript@N` tsc stays skipped, and without `pyright@N` · `mypy@N` the Python type check
stays skipped — and that skip is not a pass but **unchecked**.

#### Running the schema (guides that pinned a validation library)

The worst measured defect was a schema that stacked `partial()` and `default()` so that **a partial update overwrote the fields**
**it had not sent with default values** — the syntax was perfect and only running it revealed the problem. If the guide pinned a
validation library, install just that in scratch and have it parse the schema code fences:

| Input | What to confirm |
| --- | --- |
| An empty object | Are the required fields actually rejected |
| A partial update carrying one field | **Are the remaining fields left unfilled, silently** |
| An unknown key included | Which is it — passed, stripped, or rejected — and does it match the guide's description |

If the result differs from the guide's description, what to fix is not the schema but **that description**.
