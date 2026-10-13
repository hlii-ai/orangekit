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

### Step 9.5: Secure the stack guides (no questions · does not hold init up)

**init does not wait for the guides.** A combination that finishes by assembly is completed here;
if generation is needed, the script registers the job.

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
  "appNotes": "<app preset notes — when there is an app axis>" }
JSON

SEAM=""
[ -d "${CLAUDE_PLUGIN_ROOT}/guides/seams/<frontend>+<backend>" ] && SEAM="--seam <frontend>+<backend>"

# Pass the axis values exactly as in the config's presets — custom is a generation target; undecided and none are skipped
bash "${CLAUDE_PLUGIN_ROOT}/scripts/install-guide.sh" \
  --frontend <presets.frontend> --backend <presets.backend> --app <presets.app> $SEAM \
  --gate --notes .orangekit/preset-notes.json
```

The single `status:` line at the end of the output is the whole result:

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
- **The baseline comparison is the script's job too** (on by default). If the output shows a major
  bump, do not judge by hand — **report it verbatim**. Do not ask whether to regenerate: the user has
  no way to know whether the guide is stale, so they answer by feel, and the question becomes per-session noise

#### If work remains — ask one thing and stop

```
Settled combination: <frontend> × <backend>
Guide status: frontend=<status> · backend=<status>
Remaining: <the need from guide-job.json, verbatim> — build it now, or in the next session?
(init itself is complete. The T1 rule cards already work without the guides)
```

If they say to continue, call `stack-guide-generator` — **there is no need to marshal arguments.**
That skill starts by reading `.orangekit/guide-job.json` and closes the file when it finishes.
Otherwise stop here. The `session-brief` hook reports unfinished work in the next session.

> Why only this one question is asked: **whether to spend 20 minutes now is a decision about the
> user's time**, so the system cannot answer for them. "Pre-built or generated", by contrast, is an implementation detail and is not asked.

#### The bar for adding more pre-built material

The pre-built unit is **an axis, not a combination**. Pre-building per combination is unmaintainable,
and an unaudited pre-built guide rots and is **worse than no guide** (it makes wrong guidance trusted).

> **Pre-build only what can be registered for periodic audit.** An axis pack meets that bar —
> audit one pack and every combination using that axis improves together.
