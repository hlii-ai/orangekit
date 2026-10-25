<!-- An asset used only by orangekit-init. SKILL.md calls it in procedure order.
     Kept in the body, all 486 lines would enter the context before the interview even ends. -->

# Step 8–9.5: dev/ · .gitignore · securing the stack guides

### Step 8: Create the dev/ directory

```
dev/
├── active/     # work in progress
├── archive/    # completed work
├── docs/       # project documents
│   ├── prd/
│   ├── architecture/
│   ├── api/
│   ├── database/
│   ├── research/
│   ├── business/
│   ├── service/
│   └── design/
```

> Do not copy the document templates into the project — `/dev-docs-generator` uses
> `skills/dev-docs-generator/assets/doc-templates.md` as the canonical source. A copy would diverge.
>
> The remaining artifact directories (`council/`, `harness-evaluation/`, etc.) are created by the
> owning skill the first time it writes. git does not even track empty directories, so do not pre-create them.

### Step 9: Update .gitignore

Add the following entry to `.gitignore` (skip if already present):
```
.orangekit/
```

### Step 9.5: Install the stack rule files · the detailed guide is opt-in (1 question)

**init's default is to install the stack rule files only.** What must be followed (consistency decision points · where security
leaks on this stack · integrity that breaks silently) goes from the pack's `RULES.md` into `.claude/rules/stack-<axis>-<pack>.md`
and is injected automatically through `paths:`. A stack with no pack has no rule file either, and only the universal rules
(`security.md` and the other T1 cards) apply. **The detailed guide skills (hub · resources) are built only when the user chooses them.**

> Basis (the measured guide A/B, 2026-10): the scores on 4 tasks were the same with and without the detailed guide, and a case
> appeared where a skill example's chosen value (a UUID id) overrode an existing convention. Meanwhile, the pitfalls the model
> missed (NUL · values leaking into error logs) were blocked by a small rule file.
> Generation takes about 1 hour for 2 axes — init is not tied to something whose benefit was not measured.

> Basis: one measured generation run took **54 minutes before repairs** (`dev/docs/skill-review/contract-first-e2e-2026-08-22.md`)
> and even at the end both auditors ruled it uninstallable. There is no reason to tie the first impression of installing to that time —
> a guide is needed when the first component or first handler is written, not the moment `init` ends.

#### One call and it is done — do not decide anything here

Whether the pack is usable · whether a seam exists · which axis to run the gate on · what is left
is **all decided by `install-guide.sh` from the data it reads itself.** Deciding it again in prose
here makes the copies diverge — and they did: in the 25 combinations with no pre-built seam, the
previous version of this section became **a rule that deleted the resources just assembled**.

```bash
# Pass the presets' notes for both axes — a guide is not a function of one axis but of the combination.
# Where the server code lives (frontend axis) · where the security boundary is · whether the data layer
# has a policy engine (backend axis) jointly determine the content of both guides.
# Pass the non-axis dimensions here too — deliveryModel and clientKind decide whether the conditional slots
# (offline · shell · auth transport · idempotent ingest · push · API version negotiation) live or die. Without them
# the slots freeze at their defaults and browser guidance ships to an app project
mkdir -p .orangekit && cat > .orangekit/preset-notes.json <<'JSON'
{ "serverCode": "<frontend preset notes>", "securityBoundary": "<backend preset notes>",
  "policyEngine": <true|false>, "language": "<TypeScript|JavaScript>",
  "deliveryModel": "<web|hybrid|cross-platform|native|api-only>", "clientKind": "<browser|app>",
  "pwa": <true|false>, "appShell": "<hybrid only>", "nativeStack": "<when there is an app axis>",
  "appNotes": "<app preset notes — when there is an app axis>",
  "authKind": "<self-issued|oidc|baas|any other value>" }
JSON

`authKind` records the auth answer from Step 4.5 **folded into this vocabulary** — it is the key a pack picks its auth variant by:
`self-issued` (the server handles sign-in and issues tokens itself — its own JWT) · `oidc` (an external IdP — Cognito · Auth0 · Keycloak ·
Identity Platform and the like; the server only verifies tokens) · `baas` (Supabase Auth · Firebase Auth). If none of the three fits,
write the answer as-is in lowercase-hyphen form — the installer leaves a value the pack lacks as a generation target, so do not force a fold.

SEAM=""
[ -d "${CLAUDE_PLUGIN_ROOT}/guides/seams/<frontend>+<backend>" ] && SEAM="--seam <frontend>+<backend>"

# Pass the axis values exactly as in the config's presets — custom is a generation target; undecided and none are skipped
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" \
  --frontend <presets.frontend> --backend <presets.backend> --app <presets.app> \
  --rules-only --notes .orangekit/preset-notes.json
```

`preset-notes.json` is written even when only the rule files are installed — if the detailed guide is chosen later, the same file picks the variants (auth method etc.).
The single `status:` line at the end of the output is the whole result:

| Status | Meaning |
| --- | --- |
| `rules` | there is a pack — its rule file was installed (if the pack has no `RULES.md`, there is nothing to install) |
| `generate` | the pack is missing or unfinished — no stack rule file, only the universal rules apply. It is the subject of the three-way question below |
| `skip` | that axis is `none` or `undecided` (not chosen) |

`--rules-only` does not write `.orangekit/guide-job.json` — the detailed guide is a choice, not unfinished work.

#### The question is asked once — three-way if the `status:` line has `generate`, two-way if not

**When there is a `generate` axis (a stack with no pack · custom)** — group those axes and ask only once.
"Detailed guide only" measured weakest, so it is left out of the options.

```
<axis> <stack> has no prebuilt rules. How should the guide for this stack be made?
 1. Rule file only (recommended · about 5-10 min) — applied automatically when the matching code is edited; lowest cost and the same score in measurement
    No examples or wiring, and only items backed by the official docs go in (it needs web lookups, and if no item has evidence the file is not created)
 2. Rule file + detailed guide (about 1 hour) — examples and wiring to look up and read / costly to generate, and there was a case where an example's value overrode an existing convention
 3. Create nothing — only the universal rules (L1) apply
```

- **1** — call `stack-guide-generator` in **rules mode** for each `generate` axis (its "Mode" section · `assets/rules-authoring.md`).
  Do not create `.orangekit/guide-job.json` — it is a 5-10 minute synchronous job, and no file is written before the gate passes, so there is nothing to clean up.
  Zero items with evidence is not a failure — carry "no item with evidence — only the universal rules apply" into the report
- **2** — do 1 first, then run the "Detailed guide path" below
- **3** — stop here. Leave "<axis> — only the universal rules apply" in the completion report
- An axis with a pack already received its rule file, so it drops out of this question. When axes with and without a pack are mixed, the question names **only the axes without one**
- The generated card is project-owned (no stamp), so `install-guide.sh` does not overwrite it on the next run

**When there is no `generate` axis** — every axis either received a rule file from a pack or is `skip`. Ask only the two-way question below.

#### The detailed guide question (once · default No)

```
Stack rule files installed: <list of installed .claude/rules/stack-*.md, or "none — universal rules only">

Also build the detailed guide skills (frontend/backend/app-guide — a wiring and examples reference)?
  Expected time: a few minutes of assembly for an axis with a pack, about 30 minutes per axis if a seam is needed, about 1 hour for an axis with no pack
  Note: in measurement the detailed guide did not raise scores, and there was a case where an example's chosen value overrode an existing convention

  1. No (recommended) — start with the rule files only. Ask for "generate guides" later and they will be built
  2. Yes — build them now
```

**If 1, stop here.** Leave one line in the completion report: "Detailed guide: not installed (opt-in) — ask for "generate guides" if needed".
**If 2, run the "Detailed guide path" below exactly as before.**

#### Detailed guide path (when opt-in was chosen)

Call it again without `--rules-only` — the rule files are already the same edition, so they stay as "same — skipped":

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" \
  --frontend <presets.frontend> --backend <presets.backend> --app <presets.app> $SEAM \
  --gate --notes .orangekit/preset-notes.json
```

| Status | Meaning | What to do here |
| --- | --- | --- |
| `complete` | finished as a skill and passed the gate | nothing |
| `resources` | resources only — awaiting the seam (**a normal intermediate state**) | nothing |
| `generate` | the pack is missing or incomplete, so full generation is needed | nothing |
| `pinned` | kept the stack assumptions of an already-installed guide | nothing |
| `skip` | that axis is `none` or `undecided` (not chosen) | nothing |

- **Do not write `.orangekit/guide-job.json` by hand.** If work remains the script writes it, and if
  not it deletes it. It is the side that knows what is left per axis
- **Exit code 1** (gate FAIL) means that axis has been moved down to `.orangekit/failed-guides/`.
  Just report it and **let init continue** — the T1 rule cards already work without a guide
- **The baseline comparison is the script's job too** (on by default, first install only). Assembly always finishes on the
  major the pack **verified**; when the registry has a higher major, the script records `refresh:<axis>` in what is left
  and the package · majors in `stale`. Do not judge by hand — carry it into question ② after completion

#### If work remains — ask twice, in order: ① generation ② (after completion) the latest majors

**Apply the latest majors only after the skills are complete.** Changing versions mid-generation either makes the seams re-read
the changed pack, or leaves the seam files alone on the old version so one guide mixes versions. So generation always finishes on
the single major the pack **verified**, and the completed install is raised afterwards — the targets are recomputed from the
completed install too, so pack files · seam files · the hub are all caught.

**① The generation question** — only after the detailed guide was chosen, and when need contains `seam:*` · `frontend` · `backend` · `app`:

```
Settled combination: <frontend> × <backend>
Guide status: frontend=<status> · backend=<status>
Remaining: <need without refresh:*>
Expected cost: generating <number of seam:* entries in need> seam(s) — measured at about 1 hour for 2 axes (audit included),
               longer on Windows (Git Bash). Hundreds of thousands of tokens per background agent.
(init itself is complete. The T1 rule cards and the assembled pack resources already work without the guides)

  1. Build now
  2. In the next session
```

**Do not drop the expected-cost line, and do not shrink the numbers.** The measurement (`dev/docs/skill-review/contract-first-e2e-2026-08-22.md`:
generating 2 axes took 37 minutes + 17 minutes of audit, macOS) is the basis. There is a real case where "about 20 minutes" was said without
basis, the user chose to build now, and then waited an hour — the value of this question lies in letting the user choose with the accurate cost in view.

If they build now, call `stack-guide-generator` — **there is no need to marshal arguments.** That skill reads
`.orangekit/guide-job.json`, completes the guides, and asks question ② right there (its Step 7).
For the next session, stop here — the `session-brief` hook reports unfinished work.

**② The latest-majors question** — for a combination with nothing to generate (complete via the pack hub), skip ① and init asks
**immediately**. For a generated combination, `stack-guide-generator` asks after generation ends.
**Ask only when a major has actually risen** — if `stale` is empty, or recomputing on the completed install finds 0 rises, finish
without asking. If it cannot be judged (lookup failure · offline), say "latest majors not checked (offline)" in one line and do not
ask — undecidable is folded neither into "risen" nor into "latest".

```
The guides are complete. They are currently written for the versions below.

Packages with a newer version (<N>):
| Guide | Package | Guide now | Latest | Files to rewrite |
| --- | --- | --- | --- | --- |
| frontend | react | 18 | 19.3.1 | 4 |
| frontend | vite | 5 | 8.3.4 | 2 |
| backend | fastify-plugin ⚠ | 5 | 6.0.1 | 2 |
⚠ the framework itself changes, so the rewrite is larger

  1. Update to the latest versions — react 19 · vite 8 · fastify-plugin 6 (rewrites only <total> files)
  2. Keep the current versions — shows the install command pinned to react 18 · vite 5 · fastify-plugin 5
```

**Always write versions as numbers.** "Major" or "latest major" alone does not tell the user what changes or by how much
(a real complaint). The table values come straight from the TSV of `guide-freshness.sh --guide --json` — "Guide now" is the declared
major, "Latest" is the latest stable version, "Files to rewrite" is the file count in the last column. Put **the package names and
version numbers themselves** into both options too (with many rows: the 5 with the most affected files + "and N more"). Keep rows
with 0 files (tools like typescript) in the table as "0 — only the version label changes". In sentences the user sees, say "version",
not "major".

If 1, run `stack-guide-generator`'s "Step 2-B: refresh". If 2, print the install line built from the pack's `pkgs` majors as-is
(e.g. `npm i react@18 react-dom@18 vite@5`) — a guide is right only when what it teaches matches what the project installs.
When the project raises a dependency later, `session-brief` reports it and the same refresh runs then.
If 2 is chosen and the only remaining work is `refresh:*`, close the job (`rm -f .orangekit/guide-job.json`) — left in place, it is
reported as unfinished work every session.

> Why only these two questions are asked: **whether to spend the time now, and whether to move to an unverified major, are the
> user's decisions**, so the system cannot answer for them. "Pre-built or generated", by contrast, is an implementation detail and is not asked.

#### The bar for adding more pre-built material

The pre-built unit is **an axis, not a combination**. Pre-building per combination is unmaintainable,
and an unaudited pre-built guide rots and is **worse than no guide** (it makes wrong guidance trusted).

> **Pre-build only what can be registered for periodic audit.** An axis pack meets that bar —
> audit one pack and every combination using that axis improves together.
