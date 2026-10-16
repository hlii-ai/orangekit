# ORANGEKIT harness anatomy — what was built, and why that way

This document is a **design rationale**. Where `README.md` covers "what to install and how to use it",
here we cover "why this device exists, and why it sits in exactly that place in exactly that shape".

There is one way to read it. Every device in this harness answers a **failure that actually happened in v2**.
So each section starts not from a feature description but from **the failure it means to block**. Without
the failure a device just looks complicated; with the failure, most of them are the minimal form.

> **Canonical-source convention** — the "canonical" line at the head of each section names the file where that fact actually lives.
> This document is not a copy but a **reading surface**, and where the values diverge the canonical source is right.
> Copies are a source of drift — that is this repository's consistent position, and this document is no exception.

**Cross-check against reality** — hooks 5 · T1 rule cards 9 · skills 26 · graph nodes 49 · edges 90
(`doctor --fast` cross-checks this line against reality. Numbers written by hand are certain to go stale.)

| Section | What it covers |
| --- | --- |
| [00](#00--why-it-looks-like-this) | The 3 failures of v2 and the one design principle that came out of them |
| [00-a](#00-a--the-user-view--when-does-this-harness-block-me) | **The user view** — what changes after installing, and what to do when you are blocked |
| [01](#01--the-5-hooks--intervention-points-on-the-time-axis) | The 5 hooks — five intervention points on the time axis |
| [02](#02--the-3-rule-tiers--load-time--ownership) | The 3 rule tiers — load time × ownership |
| [03](#03--the-6-loops--five-are-gates-one-is-a-flywheel) | The 6 loops — five are gates, one is a flywheel |
| [04](#04--graph-engineering--what-a-checklist-cannot-answer) | Graph engineering — what a checklist cannot answer |
| [05](#05--a-single-task-walked-through--where-the-four-devices-are-visible-at-once) | A single task walked through — the four devices in one narrative |
| [06](#06--agents--skills--guides) | Agents · skills · guides |
| [07](#07--doctor--the-proving-device) | `doctor` — the proving device |
| [07-a](#07-a--render-proof--a-passing-build-is-not-evidence-that-the-screen-appears) | **Render proof** — the axis that proves the screen with Playwright |
| [08](#08--operations) | Operations — version bumps · adding assets · the limits of this repository |

---

## 00 — Why it looks like this

**Canonical**: `README.md` · `dev/docs/port-to-origin/00-README.md` · `rules/harness-change.md`

v3 is not a refactor of v2 but **a response to three failures**.

### Failure ① — 10 of 11 hooks were dead for four months

More important than the fact that they were dead is that **nobody knew**. A hook exits 0 quietly even when
it fails, and producing no output at all is indistinguishable from normal operation. There were three causes
(`scripts/lib/common.sh:6-9`):

1. The root path was computed relative to `BASH_SOURCE` — the moment it shipped as a plugin it pointed outside the repository
2. A `|| echo 0` fallback put 2 lines where 1 line belonged, collapsing the integer comparison
3. Output used a JSON field the event does not support — **it was silently ignored**

### Failure ② — 697 lines of rules never reached any project

697 lines were written under `rules/`, and there was **no path at all** for them to enter a consumer project.
The component types of a Claude Code plugin are only `skills`/`commands`/`agents`/`hooks`/`mcpServers`/
`outputStyles`/`lspServers` — **there is no `rules`.** Yet the generated `CLAUDE.md` declared
"`.claude/rules/task-workflow.md` applied automatically" —
**a document claimed a file existed that did not.**

### Failure ③ — a hand-placed copy grew independently

In one project the rules did work, because the user had copied them in by hand. And so that copy grew
independently of the plugin — `agent-governance` went from 53 lines to 199, **+275%**.
Fixing the plugin does not change that project, and what that project learned does not come back
to the plugin.

### The one principle that came out of this, and the four derived disciplines

> **A component proves its own existence or it dies.**

| Discipline | Meaning | Where it is implemented |
| --- | --- | --- |
| A component does not vouch for itself | A hook saying "I am alive" is not evidence. **Another** component reads the log and reports | Every hook heartbeats into `hookrun.log` → `session-brief` reports the survival rate |
| A guard has 3 states | violation / no violation / **undecidable**. Folding undecidable into blocking makes a false positive, and **a false positive makes the user turn the hook off, and a hook that is off blocks nothing** | `build-gate`'s `UNDECIDABLE` · the reason `orangekit_emit_notice` is separate from `orangekit_emit_block` |
| Alive ≠ working | A hook exiting 0 does not mean it blocks. Check that a fixture with a planted defect is blocked **for the intended reason** | the positive fixtures of `doctor --self-test` — the exit code and the **expected reason** are cross-checked together (`ORANGEKIT_FX_WHY=1` shows that reason) |
| Nothing is culled without measurement | Deleting on "this skill does not seem to be used" leaves no grounds for reversing it | the `track-skill` hook → the never-invoked list of `doctor --usage` |

Know these four and most of the remaining sections read as "so that is why that is there".

---

## 00-a — The user view — when does this harness block me

**Canonical**: `templates/operating-contract.md` · `rules/workflow-routing.md` · `hooks/hooks.json`

If the previous section is "why it looks like this", this one is **"so what appears on my screen"**.
Know the three things below and the rest can wait until you need it.

### What changes after installing — even if I do nothing

The 5 hooks and the reversibility axis already run without `/orangekit-init` (Zero-Config). Four things change.

| When | What | What I experience |
| --- | --- | --- |
| Session start | `session-brief` | branch · uncommitted · open tasks · hook liveness are printed, and the operating contract is injected |
| **Just before** writing a file | `security-check` | hardcoded secrets and irreversible commands are blocked **before execution** |
| Ending a turn | `build-gate` | blocked if you edited source and did not run a build or test |
| Compaction · exit | `handoff` | progress is saved to `dev/handoff/` so the next session picks it up |

Running `/orangekit-init` adds **stack-matched guides** and **build command awareness** (the gate names the
exact command) on top.

### When you are blocked — what to do

**There are only three blocks, and all three say what to do next in the message.** Read the message before looking for a workaround.

| Block | Meaning | Next action |
| --- | --- | --- |
| `❌ Blocked: hardcoded <secret>` | The value is on the wrong side | Move it into a gitignored `.env` — **there you may write it**. If it is not in `.gitignore` yet, adding it first opens the path |
| `❌ Blocked: <destructive command>` | Something irreversible is about to happen | Use the "safe alternative" in the message, or state the impact and the rollback procedure and get user confirmation |
| `N source files changed but no build or test was run` | written ≠ working | Run the command the message names. If `orangekit.config.json` exists, **that project's actual command** is printed |

**Some notices do not block** — "cannot be decided" (no jq, no transcript) and "no trace of a render check"
(§07-a) are **information, not a block.** If you do not need them, walk past.
Not folding undecidable into blocking is a consistent discipline of this harness — repeated false
positives make the user turn the device off, and **a device that is off blocks nothing.**

### What is demanded of me — the reversibility class decides

The same harness **folds to a different depth** depending on the nature of the work. The decision is not size but **path**.

| What I touched | Class | What additionally happens |
| --- | --- | --- |
| Everything else (the default) | Reversible | Nothing. Go straight ahead |
| `**/api/**` · shared packages · type contracts | Costly | `orangekit-reviewer` reads the diff **independently** |
| `**/migrations/**` · auth/RLS · payments | Irreversible | 3-lens cross-check + **user confirmation** + rollback procedure |

**Most work is Reversible and gets no procedure at all.** The places that get heavy are only the places
that are hard to reverse, and that is the purpose of this axis.

### When the harness gets in my way — the project wins

Where the shape the guide recommends differs from the shape the repository actually uses, **follow the repository.**
"Instruction precedence" in `rules/workflow-routing.md` is canonical; in summary, the two layers run in opposite directions.

- **The safety floor** (reversibility classification · verification duties · secret boundaries) — a project can **only raise** it
- **Procedure and form** (stack practices · workflows · naming) — **the project wins**

If you want to replace a skill wholesale, put one with the same name in the project's `.claude/skills/<name>/` —
a project file always beats the plugin.

### Where to start reading

| What you want to do | Where to go |
| --- | --- |
| Install and get started | [`docs/getting-started.md`](getting-started.md) |
| Choose my stack | [`docs/presets.md`](presets.md) |
| Check that the harness is healthy | `bash <plugin-root>/scripts/doctor.sh` — the absolute path is printed on the **last line of every session briefing** |
| What invokes what, and when | the Phase table in `.claude/rules/workflow-routing.md` (auto-loaded every session) |

---

## 01 — The 5 hooks — intervention points on the time axis

**Canonical**: `hooks/hooks.json` · `scripts/*.sh` · `docs/platform-contract.md`

### What a hook is and why it is special

A hook is a shell script that the Claude Code **runtime** executes on a particular event. There is one
decisive difference from a skill or a rule — **the model does not invoke it.** Even if the model forgets the
instruction, even if the context is full, even if the model judges otherwise, the hook runs.

So the share a hook takes in this harness is fixed: **whatever must hold without the model's cooperation.**
Conversely, putting something that needs semantic judgement into a hook makes it a false-positive machine trying to adjudicate the world with a regex.
That boundary is the one line at the head of `rules/harness-change.md` —
**"What a Script can do goes to a Script, what only an LLM can do goes to the LLM."**

### The 5 are not 5 features but **5 moments**

Read the hooks as a feature list and you cannot tell why there are exactly five. Lay them on the time axis and it is obvious.

| Moment | Hook | Event | Does it block | Why this position is needed |
| --- | --- | --- | --- | --- |
| When a session opens | `session-brief` | SessionStart | No | The moment when no file has been opened yet — the only place the norms can go |
| **Just before** writing a file | `security-check` | PreToolUse | **Yes (exit 2)** | Find it after the write and it is already on disk |
| When trying to end a turn | `build-gate` | Stop | **Yes (`continue:false`)** | The last gate between "written" and "works" |
| When the context is about to vanish | `handoff` | PreCompact · SessionEnd | No | Compaction and exit arrive without warning. Only the runtime knows the moment |
| After a skill is used | `track-skill` | PostToolUse (`Skill`) | No | The fact of use is observable only at that moment |

The same division is expressed as the **4 intervention points** in `harness/skills/harness-evaluation/SKILL.md` —
① opening briefing ② decision moment ③ action checkpoint ④ after-the-fact recovery. **The same failure lands
differently depending on which point you put it at** is a recurring claim of this harness, and the 5 hooks are
the minimal set that covers those points without a gap.

### 6 registrations, 5 scripts

A single `handoff.sh` is hooked to both the PreCompact and SessionEnd events. So the **denominator of the
survival rate is the number of distinct scripts (5), not the number of registration entries (6).** This looks
trivial and was an actual defect (`scripts/session-brief.sh:70-73`): with 6 as the denominator, the numerator
(the distinct hook names left in the log) can **structurally never** reach it, so a shortfall warning fires
every session. **A warning that never turns off teaches people to ignore warnings** — the failure mode this harness guards against most.

---

### ① `session-brief` — SessionStart

**What it does** (`scripts/session-brief.sh`)

1. **Prints the T0 operating contract to stdout.** SessionStart is one of the three events where plain stdout
   becomes context directly (the others are UserPromptSubmit and UserPromptExpansion). That property holds up
   the whole of the 3 rule tiers — see [§02](#02--the-3-rule-tiers--load-time--ownership).
2. The session briefing — branch · HEAD · number of uncommitted changes · open workspaces.
   At the same time it snapshots the working tree into `session-baseline.txt` — as `path+mtime+size`.
   **Names alone are not enough**: a set of names carries "is it dirty" and not "did it change", so source
   that was already uncommitted at session start kept the gate silent no matter how much it was edited (fixed in v3.27.0).
   **This file is the baseline by which `build-gate` decides "what changed this session".**
3. **Hook liveness status** — the denominator of the warning is only the hooks in `hooks.json` **with no `matcher`**.
   A hook with a matcher (PreToolUse · PostToolUse) has no chance to fire unless that tool is used, so using the
   total count as the denominator gives a user who never invokes a skill **a permanently displayed warning with no
   way to fix it**. The first session is decided not by the absence of a file but by the number of `session-brief`
   rows accumulated in the log — `orangekit_begin` creates the log before the decision, so the "if absent" branch was unreachable.
   On a shortfall it shows **the names of the missing hooks as well**, points at `doctor --self-test`, and emits the
   `session-start→doctor` edge. (The "live hooks N/M" of `doctor --usage` uses the total count but is
   instrumentation that does not warn, so it stays as it is.)
4. **Auto-installs** missing T1 rule cards — it keeps two gates.
   ⓐ Only when `orangekit.config.json` exists (a globally installed plugin must not write `.claude/rules/`
   into every repository the user opens — the existence of the config is the consent)
   ⓑ `--missing-only` (an automatic run must not silently overwrite a user-modified copy).
5. Guide pack freshness · unfinished guide work · a nudge for an unconfigured project · the self-test entry point (absolute path).
6. Lesson promotion candidates (3 or more in a category) · a notice when 30 days have passed since the last harness evaluation.

**Why it exists** — v2's `session-start-validator` computed the root wrongly, ended with exit 0 while its
integer comparison was broken, and the only output that survived was a workflow recommendation the user had
**forbidden**. In v3 this hook takes on three things: the place where norms go in, the place that confirms
rule installation actually happened, and **the place that reports the liveness of the other hooks.**

Number 4 matters especially. Leave rule installation as a skill instruction only (`orangekit-init` Step 7) and
**the moment the model skips that step, the norms never arrive.** Failure ② was exactly that shape, so
installation came down into a hook, which needs no cooperation from the model.

---

### ② `security-check` — PreToolUse (`Edit|Write|MultiEdit|Bash`)

**What it does** — this hook has **two axes**.

1. **Secret placement** — it searches the content about to be written for secret patterns, and on a hit it
   writes the reason to stderr and blocks the tool call itself with **exit 2**. AWS · GitHub · Stripe · Toss Payments · KakaoPay ·
   OpenAI · Anthropic · Google · Supabase (new-style keys and legacy JWT) · PEM private keys ·
   GCP service account JSON · secrets inside `package.json`.
2. **Destructive commands** — is something irreversible about to happen right now. The reversibility
   classification (T0) decides by **edit path**, so it is in principle unable to catch **destruction that touches
   no file at all**, like `DROP TABLE`. That blind spot is this axis.

**Why it exists** — it is **the only hook that worked** in v2. The reason became a design guideline:
*it needs no project root to decide*, so it was unaffected by the broken root computation.
v3 preserves that property — this hook alone does not use `orangekit_begin` and keeps running even when root resolution fails
(`security-check.sh:17-20`). **Failing to find the root must never be a reason to turn off the security check.**

**Four things to learn from the design**

- **Why `Bash` is in the matcher** — the paths by which the model writes a file are not only Edit/Write.
  Write via heredoc or redirection and the gate's effective coverage **depends on the model's tool choice**
  (evaluation v5 · E-20). A gate with a way around it is not a gate.
- **But it does not scan every Bash command** — it looks only at commands that **write a file**, that is, ones
  with `tee`/`dd`/`>`. Look at read commands too and **an investigative command like `grep 'AKIA[0-9A-Z]{16}' .`
  gets blocked as a false positive.** False positive → turn the hook off → zero blocking power. Between widening
  coverage and creating false positives, this hook consistently avoids the latter.
- **In destructive commands it separates "reading", "authoring" and "executing"** — the same string appears in
  three positions. `grep 'DROP TABLE' supabase/migrations/` is **investigation**,
  `cat > 0003.sql <<'EOF' … EOF` is **authoring**, and only `psql -c "DROP TABLE …"` is **execution**.
  Without separating the three, this gate makes it impossible to either write or read a migration.
  (In fact, while building this gate, the command writing its own fixture was blocked — `_authoring_cmd`
  came out of that.) And the decision is **3-state**: if the target branch of a force push cannot be confirmed,
  it does not block but explicitly reports "undecidable" and lets it through.
- **It separates blocking from warning** — a missing schema validation, `dangerouslySetInnerHTML`, and editing
  `.env` produce **warnings only**. For instance an existing sanitize import in the same file may not be visible
  in this diff. Not folding what cannot be established into a block is the 3-state discipline applied.
- **An exemption is granted only where it is proven** (v3.26.0) — the **legitimate destination** of a secret is a
  gitignored `.env` file, but the only path condition was `package.json`, so writing there was blocked too.
  The block message told you to "move it to `.env.local`" while blocking that very file — a contradiction, and
  "register the key in an environment variable", the most common legitimate task, was impossible. Now `git check-ignore`
  exempts secret blocking **only for `.env*` files it has confirmed to be ignored**. It does not exempt when
  undecidable (no git · outside the repository · untracked), so **this relaxation is in no case worse than before** —
  it opens only when proven. That is why it does not conflict with "do not fold undecidable into blocking":
  it is not blocking something new, it is **not granting a new exception**. As a side effect `.env.example` is meant
  to be committed and so is not ignored, and remains blocked — placeholders pass and real keys are blocked.
  A Bash heredoc has no `file_path` and is therefore not eligible for the exemption.

That regexes can reach only this far is stated explicitly too. Where the problem is not the **value** of the
secret but its **placement** (exposure to the client via a `NEXT_PUBLIC_` prefix, and so on), the hook cannot
catch it, so the T1 card `rules/security.md` takes it — the line where script and LLM are divided.

---

### ③ `build-gate` — Stop

**What it does** (`scripts/build-gate.sh`)

1. If `stop_hook_active` is true, pass immediately (infinite-loop prevention).
2. Compare `session-baseline.txt` with the current snapshot using `comm` to pick out only the files
   **changed this session**, then keep only source extensions (excluding `.config.`/`.test.`/`.spec.`).
3. **The decision is 3-state.** If `jq` is missing or the transcript cannot be read → announce
   "cannot be decided, not blocking" via `orangekit_emit_notice` and pass.
4. Parse the transcript JSONL, extract **only the commands of the assistant's Bash tool calls**, and check
   whether a build/test/typecheck/lint command was actually there.
5. If not, read the real commands from `orangekit.config.json`, give concrete guidance, and block with `continue:false`.

**Why it exists** — v2's `stop-guard` **never once blocked.** There were two reasons, and each left a
different lesson:

| v2's mistake | Lesson | v3's answer |
| --- | --- | --- |
| Output `{"decision":"block"}` — Stop does not support this field | **An unsupported field is silently ignored.** The output format differs per event | `orangekit_emit_block` emits only `continue:false`+`systemMessage` |
| `tail -200 transcript \| grep -qE "(build\|test)"` — passes if the word "test" appears anywhere in the conversation | **The presence of a string is not evidence of execution** | Parse the JSONL and look only at `input.command` of `tool_use` entries with `name=="Bash"` |

The first gave rise to `orangekit_emit_*` in `common.sh`, and the second gave rise to this harness's whole
"evidence, not declaration" attitude.

---

### ④ `handoff` — PreCompact · SessionEnd

**What it does** (`scripts/handoff.sh`) — it builds markdown from the branch · HEAD · list of uncommitted
changes (up to 12) + per-task progress in `dev/active/` (counts of `- [x]`/`- [ ]`) and 5 remaining tasks, and
puts it in `additionalContext`. On SessionEnd it also leaves a file at `dev/handoff/<UTC>.md` and rotates,
keeping only the 10 most recent.

**Why it exists** — v2's `pre-compact-saver` output with a plain `echo`. **PreCompact stdout does not enter
the context.** That is, it preserved nothing for four months, and so the user had to create 7
`SESSION-HANDOFF` files by hand.

That this hook handles two events in one script is also deliberate. What has to be preserved is the same, and
the only difference is "does it go back as context (PreCompact)" versus "is it also left as a file (SessionEnd)".
Two scripts asserting the same content is itself a source of drift.

---

### ⑤ `track-skill` — PostToolUse (matcher `Skill`)

**What it does** (`scripts/track-skill.sh`) — it appends one line with the invoked skill name and the UTC time
to `skilluse.log`, emits the `build→track-skill` edge, and rotates past 5000 lines.
That is all.

**Why it exists** — without it, "cleaning up unused skills" is guesswork forever. The v2 audit had to treat
"the output directory is empty" as evidence of use. To keep the discipline **nothing is culled without
measurement**, the measuring device has to actually exist.

v2 had three PostToolUse trackers too, but they **scanned all of `/tmp` on every tool call** and did not
measure the thing that was actually needed. Reducing three to one changed not the performance but **the
existence of a consumer** — there is a `doctor --usage` that reads this log. Put in graph discipline,
**a store with no node reading it is pure cost and a source of drift**, and this hook is the case on the
other side.

---

## 01-a — The shared substrate `scripts/lib/common.sh`

**Canonical**: `scripts/lib/common.sh`

The first line of the header states this file's nature — **"the purpose is not convenience but the elimination of silent failure."**
Three devices correspond 1:1 to the three causes of v2's death.

| v2's cause | Device | Behaviour |
| --- | --- | --- |
| Root computed relative to `BASH_SOURCE` | `orangekit_root()` | Tries `CLAUDE_PROJECT_DIR` → stdin's `.cwd` → `git rev-parse --show-toplevel` in that order and, **if all fail, does not guess but aborts with exit 2** |
| `\|\| echo 0` put 2 lines where 1 belonged | `orangekit_num()` | Strips whitespace, caps at 18 characters, yields `0` if it is not a number. The leading whitespace of macOS `wc -l` dies here too |
| A JSON field the event does not support | `orangekit_emit_context/block/notice` | **The function picks** the correct shape for each event |

### Output format — where hooks get it wrong most often

| Event | The shape that enters the context |
| --- | --- |
| SessionStart · UserPromptSubmit · UserPromptExpansion | **plain stdout** |
| PreCompact · SessionEnd · Stop · SubagentStop · PostToolUse | `{"additionalContext": …}` |
| PreToolUse | `{"hookSpecificOutput":{"hookEventName":…,"additionalContext":…}}` |
| Stop, blocking | `{"continue":false,"systemMessage":…}` — **`decision`/`reason` are unsupported** |

So that nobody has to memorize this table the function picks instead, and `doctor --fast` separately lints the
hook scripts and fails them if they use a field the event does not support. **Instead of the document, the code
and the check each asserting the same fact, the code executes, the check enforces, and the document quotes.**

### Why `emit_block` and `emit_notice` were separated

They could have been one function with a flag. They were separated **to block, at the type level, the mistake of
folding undecidable into blocking** (`common.sh:135-137`). The 3-state discipline is not kept when it lives only
in a document — it is kept when the function you have to call is a different one.

### Why two hooks do not use `orangekit_begin`

`security-check` and `track-skill` obtain the root best-effort themselves instead of using `orangekit_begin`
(root resolution + heartbeat), and keep going even when that fails. **Because a failure to resolve the root must
not stop secret blocking or instrumentation.** Rather than applying a rule everywhere for the sake of consistency,
this is a case of making an exception where the rule harms the purpose and **writing the reason for the exception into the code**.

### The 4 instrumentation files

| File | Written by | Read by | Rotation |
| --- | --- | --- | --- |
| `.claude/.orangekit/hookrun.log` | every hook (`orangekit_heartbeat`) | the survival rate in `session-brief` · `doctor --usage` | 2000 rows → most recent 1000 |
| `.claude/.orangekit/graph.log` | hooks (`orangekit_edge`) | edge traversal in `doctor --usage` | — |
| `.claude/.orangekit/skilluse.log` | `track-skill` | the never-invoked list in `doctor --usage` | 5000 rows → most recent 2500 |
| `.claude/.orangekit/session-baseline.txt` | `session-brief` | `build-gate` | overwritten every session. **One** thing, `orangekit_worktree_snapshot` in `common.sh`, owns the creation and comparison formula — two copies of it were the root of the v3.27.0 defect |

There is **only one** reason the location can be redirected with `ORANGEKIT_STATE_DIR` / `ORANGEKIT_HANDOFF_DIR`:
when `doctor --self-test` injects fixtures the hooks really do run, so without isolation
**it writes into the very log it is measuring.** Then "which path actually executes" stops being a measurement and
becomes a self-assertion (evaluation v3 · E-09, v5 · E-13). It is the trace of finding and fixing an instrument
contaminating its own measurement.

---

## 02 — The 3 rule tiers — load time × ownership

**Canonical**: `templates/operating-contract.md` · `rules/*.md` · `docs/platform-contract.md` §3

### First: what is the problem

Rules are not hard to **write**; they are hard to **get read**. And there are two failures here that pull in
opposite directions.

| Failure | What it is | The naive fix | The opposite failure that fix creates |
| --- | --- | --- | --- |
| **Never arrives** | The rules do not reach the project (v2's 697 lines) | the plugin owns them and injects them automatically | the project cannot adapt them to its own situation |
| **Drift** | the project's copy grows independently (+275%) | the project owns them as files | a plugin update never arrives |

**The tiers are not an importance ranking.** They are the combination of two axes — **when is it loaded** × **who owns it**.
Put each norm in the cell that matches its nature and both failures are solved at once.

| Tier | Medium | Load time | Owner | Update method | Size |
| --- | --- | --- | --- | --- | --- |
| **T0** operating contract | the **stdout** of the `session-brief` hook | every session unconditionally, before any file is opened | plugin | automatic (the project cannot touch it) | a 42-line budget for the file (4 comment lines included) · actually injects 37 lines |
| **T1 always on** | `.claude/rules/workflow-routing.md` (**no** `paths:`) | every session (native behaviour) | project | drift detected by version stamp | measured by `doctor --inventory` |
| **T1 conditional** | `.claude/rules/*.md` (`paths:` match) | when Claude **reads a matching file** | project | version stamp | varies by card (measured by `doctor --inventory`) |
| **T2 reference** | plugin skills · axis guides | **only when invoked** | plugin | automatic | only the description is resident |

### Why T0 is hook output rather than a file

This is the core move of the design. T0 is not a file but **output generated every session**, so:

- **The project cannot modify it** → drift is **structurally** impossible. Blocked by structure, not by discipline.
- **The plugin owns it, so it updates automatically** → nothing fails to arrive either.
- The price is the **budget**. It is resident unconditionally every session, so it must not go past 42 lines, and
  `doctor --fast` enforces that cap. **Going past it does not truncate the text** — the hook has no truncating code and
  prints the whole file. The cap is not a runtime cut but **a check at authoring time**.
  And exceeding it is not "delete something" but **a decision point** — ① move it down to T1 (loses always-on) ② compress it (risks losing information)
  ③ raise the budget (raises the per-session cost); the user picks. "When you go over budget" below is canonical.
- A check that looks only at line counts **lets deletion through instead.** So **anchor checks** on the 6 norm sections sit alongside it.
- **Because it is output, it can differ per project.** `session-brief.sh` substitutes `{{RESPONSE_LANGUAGE}}` in the "Language" section
  with `project.language` from `orangekit.config.json` — as a file, the response language would be fixed for every consumer.
  `doctor --fast` enforces that the placeholder and the substituter **coexist**, and `--consumer` demonstrates the actual substitution.

What goes into T0 is decided by this budget too — **only what must already be known before work begins**:
Reversibility classification · Work entry (the 4 entry conditions) · Minimal change · Verification · Decision point · Language. And that table
is **the canonical source for the reversibility class**. `README.md` and `agents/orangekit-planner.md` only **quote** it.

### When you go over budget — do not delete

When `doctor --fast` emits "T0 operating contract N lines — exceeds budget 42 lines", **do not delete a norm to
make room.** T0 is auto-injected and auto-updated every session, so a deletion **propagates to consumers
immediately and silently**, and unlike T1 there is no safety net that preserves a user-modified copy by version stamp.

| Choice | What is kept | What is lost |
| --- | --- | --- |
| ① **Move it down to a T1 card** | reach into the project | **always-on** — it appears only when you touch that path. If "when is it needed" does not line up with the file path, it never appears at all |
| ② **Rewrite it shorter** | always-on · reach | information — the decision criteria can be shaved off while compressing |
| ③ **Raise the budget** | always-on · reach · information | per-session cost — `doctor.sh`'s cap goes up with it. The deterrent dulls by that much |

When choosing ①, **choose by "when is it needed", not by line count** — check that the card's `paths:` actually
covers the moment that norm is needed. (Precedent: "reference freshness" was moved down with `paths: src/**`, and the
moment it was really needed — quoting a document or a review report — has nothing to do with editing `src/`, so it never appeared.)

Deleting a section outright is blocked by the anchor check. To delete one you must also fix
`agents/orangekit-planner.md` · `rules/reversibility.md` and this document, which quote that section as canonical.

### Why T1 is a project file

`.claude/rules/` is a **native feature of Claude Code** (`docs/platform-contract.md` §3).
The presence or absence of `paths:` in the frontmatter becomes the load switch:

| Frontmatter | Load time |
| --- | --- |
| no `paths:` | **unconditionally at every session start** — the same precedence as `.claude/CLAUDE.md` |
| `paths:` present | when Claude **reads a matching file** (not on every tool call) |

It was made project-owned **because the project has to be able to fix it**. Drift is reconciled instead by the
`<!-- orangekit-rule-version: X.Y.Z -->` stamp. The 4-state decision of `install-rules.sh`:

| State | Action |
| --- | --- |
| file absent | install |
| same version, identical content | skip |
| same version, **different content** | **treat as a user-modified copy and preserve it** |
| lower version | back up as `.bak`, then update |

The automatic run in `session-brief` uses `--missing-only`, so **it does not look at the version at all** — an
automatic run silently overwriting a user-modified copy never happens, and an update is only **reported**, with a person running it.

### Why T2 is on-demand

Make the bodies of 26 skills resident and there is no context left. What is resident is only each skill's
`description`, and even that has its budget measured in characters by `doctor --usage`.
**Norms have to be resident and procedures can arrive when invoked** — that division is the boundary between T1 and T2.

### Resident cost

Only what costs what, and when, is written here. **The numbers are not written down** — an earlier version of this table had
five of its six numbers stale (evaluation v6 · E-31), and the measurements are produced fresh each time by
`doctor --usage` (resident bytes) and `doctor --inventory` (lines and on-invoke cost per card and skill).

| What | When it costs |
| --- | --- |
| T0 operating contract | every session (plugin — doctor enforces a 42-line cap) |
| `workflow-routing.md` | every session (project — includes "Instruction precedence") |
| the 8 conditional cards | only when you touch the relevant `paths:` |
| references linked from a card | only when you actually design that pattern |
| skill descriptions | every session (manual-only ones are non-resident via `disable-model-invocation`) |
| agent descriptions | every session (plugin — **there is no non-resident switch**. `platform-contract.md` §6.1) |
| skill bodies and references | **only when invoked** — the "on-invoke B" column of `--inventory` |

**The descriptions of manual-invocation-only skills are not made resident.** Put
`disable-model-invocation: true` in the frontmatter and that skill becomes uninvokable by the model, and in exchange
its description drops out of every session's context (`docs/platform-contract.md` §2.4).
Write "manual invocation only" in the body and leave the flag off and **the declaration and the billing diverge** —
`doctor --fast`'s "manual invocation only declaration ↔ resident flag agreement" cross-checks both directions, and
because attaching the flag to a target of automatic invocation (the routing table · the graph `phase` · a call from
another skill) breaks routing, that direction is blocked too.

**Of the norm documents, only two are resident every session: T0 and `workflow-routing`.** That the rules as a whole (the count is canonical in README's "Components"
table and doctor cross-checks it) are not resident is the practical effect of the 3 tiers.

---

## 02-a — The 9 cards and two traps

**Canonical**: `rules/*.md`

| Card | `paths:` trigger | What it blocks |
| --- | --- | --- |
| `workflow-routing.md` | **none (always on)** | Starting without knowing what to produce in what order (P0~P6) + using a stale artifact as grounds (reference freshness) + **the harness overwriting the project** (instruction precedence · non-invasive) |
| `code-change.md` | `src/**` `app/**` `packages/**` `lib/**` `apps/**` `services/**` `ios/**` `android/**` | **Rewriting what already exists** (the implementation ladder — reuse in the repository → standard → platform native → an existing dependency → one line) · residue left after a fix · failure to propagate a pattern · unverified wiring, "existing ≠ running" · adding a dependency without authorization |
| `security.md` | same | What a regex hook **cannot** catch — the **placement** of a secret, `NEXT_PUBLIC_`/`VITE_` exposure, input and authorization boundaries, XSS, open redirects |
| `reversibility.md` | `src/**` `supabase/**` `**/migrations/**` `dev/active/**` | What you do **after** the class is decided · access policy decision points · **the choice at a decision point evaporating** (decision records) |
| `harness-change.md` | `.claude/**` `scripts/**` `hooks/**` | The harness only ever growing · silent failure · assets with no reach path (the plugin-authoring parts were moved down to `harness/rules/harness-authoring.md`, and release reach to §08) |
| `lessons.md` | code · harness · document paths generally | Taking a criticism and not recording it · declaring a promotion while no asset changes |
| `doc-dependency.md` | `dev/docs/{prd,database,design,architecture,api}/**` | The 6-edge document dependency graph being left open |
| `data-modeling.md` | `supabase/**` `**/migrations/**` `db/**` `prisma/**` `drizzle/**` | Relational modelling norms (they naturally sleep in a NoSQL project) |
| `ui-design.md` | `**/components/**` `**/*.{css,scss}` `**/app/**/page.{tsx,jsx}` `**/app/**/layout.{tsx,jsx}` | Taking the first search hit as the result — settling into the 3 default clusters · no signature · going straight to code without review · UI copy written in system vocabulary · **treating a passing build as evidence of a render** (§6) |

### Trap ① — `workflow-routing.md` must not be given a `paths:`

The moment it gets one it becomes conditional and **does not appear at session start.** But this card is needed
"before work begins", so it has to be there already **at the moment when no file has been opened yet**. Hence the
warning comment at the top of the file, and `doctor --fast` **fails** the moment a `paths:` appears in this file.
The comment speaks to a person and doctor enforces on a machine — that is why both exist.

This axis did actually disappear once and was restored. When v3 introduced the reversibility axis it **erased the
Phase axis along with it**, but the two axes are orthogonal — the reversibility class decides *how much* to verify,
the Phase decides *what to produce in what order*. In the same commit "reference freshness" was also demoted to
`paths: src/**`, so **it did not appear at the very moment it was needed (when quoting a document or a review report).**

### Trap ② — an inverted trigger

The `paths:` of `lessons.md` has to fire not "when the lessons file is edited" but **"when work likely to draw a criticism is done"**.
Hook it to `docs/lessons.md` alone and **it loads only after you have already gone to record something** —
the trigger is inverted, and a rule in that state might as well not exist.

### The 2 project-owned cards

`/orangekit-init` **generates** `project-structure.md` and `code-conventions.md`. They have no version stamp,
so plugin updates do not reach them. What protects them is not a stamp but **name non-collision** —
`install-rules.sh` iterates only the plugin's `rules/*.md`, so as long as no card of the same name is created
on the plugin side, these two are safe.

---

## 02-b — The inner order within one feature (P4)

**Canonical**: `rules/workflow-routing.md`, "Inner Order Within One Feature (P4)"

The Phase axis (P0~P6) settled only "what you have to know to start". **What gets frozen first** while one
feature is actually being built existed nowhere until v3.31.0, and in that gap the shipped guides quietly assumed
backend-first (the old title of §0 in the `nextjs+supabase` frontend example was "Premises"). The consumer
project side was worse — there was **no place at all to write down** the contract that frontend and backend have
to share across a context boundary.

### The order is not layers but the cost of reversal

| # | What you do | Why it is at this position |
| --- | --- | --- |
| 1 | Write down the fields the screen reads and writes | The input to the contract. If the screen is unsettled, go to P0-D |
| 2 | Write the wire contract `dev/docs/api/wire-contract.md`, or add this feature's part to it | The only thing frontend and backend share across a context boundary |
| 3 | Derive a mock from the contract, bring the UI up first and verify it | This is where plan changes come out most — absorb them at the cheapest place |
| 4 | Once the UI is frozen, do the backend (migrations included) in one pass, to the contract | Freeze Irreversible last, in the state that shakes least |
| 5 | Removing the mock = integration | If a mock that stood in for the contract is still there, this feature is not finished |

Work that touches only one axis (a style fix, a query optimization) leaves 1 · 2 · 5 empty and keeps only that axis's row —
not all five rows are needed every time.

### Wiring points

- `rules/workflow-routing.md` — it is an extension of the **always-on** T1 card (§02), so it catches a request
  that skipped P0~P3 just the same. It is on the same sheet as the Phase axis, but the two axes are still orthogonal.
- `skills/service-planner/SKILL.md` 4-4 — the screen data requirements table (fields read/written · lists · empty/loading/error) is
  the artifact of row 1.
- `skills/dev-docs-generator/SKILL.md` — for work that touches both frontend and backend, it is wired to write
  `dev/docs/api/wire-contract.md` before writing the slices.
- `skills/stack-guide-generator/assets/wire-contract.template.md` — the single canonical source of the form.
  Each seam guide only references this template and keeps no copy of it.

`dev/docs/api/**` was already the target of edges 3 and 6 in the 6-edge graph of `doc-dependency.md` (§02-a),
but **there was no artifact that filled it** — `wire-contract.md` is the first canonical document
to close that gap.

### Grounds for intervention

- **(a) The failure being blocked**: author the frontend and the backend independently and the shape of the contract
  diverges. Even inside the shipped guides, a pre-built frontend/backend pair was written against different execution
  units (`/tasks` versus `/notes`) and did not mesh as-is, and another seam (`vue+node-api`) had both sides define the
  auth surface separately. Divergence of the same kind had no device at all to block it in a consumer project.
- **(b) The risk of making it worse**: adding 14 lines to an always-on card costs that much of every session's budget. And this
  section can be misread as reversing "existing code patterns beat the guide" (instruction precedence in
  `workflow-routing.md`), so the boundary — that this is a rule about **timing (when to freeze what first), not about
  shape (what the code looks like)** — is stated explicitly in the body.

### Measured

The T1 resident total in `README.md` grew 1,052 → 1,073 (the "declaration ↔ reality" cross-check in `doctor`
detected it). Introduction was verified with `npm test` (64 · 95 · 21 · 7) · `guide-gate --self-test` 55 ·
`--regress` 81 · `pack-smoke` 18 — all 0 FAIL. Per the principle of §08 this repository is not itself a consumer,
so `install-rules.sh` and `install-guide.sh` were actually run against a scratch project to confirm that the new
section and the contract guidance reach `.claude/`.

---

## 03 — The 6 loops — five are gates, one is a flywheel

**Canonical**: the reverse edges of `workflow.graph.json` · `rules/lessons.md`

### What a loop is in this harness

A loop is not a separate feature. It is **an edge in the graph that goes backward.** A graph that only goes
forward is a pipeline; a gate holds only if there is an edge that comes back — because the definition of a gate is
that it **sends you back to the same place** when the condition is not met.

And an edge that sends you back always needs a **termination predicate**. Without one it repeats forever, and
**repetition with no cap only burns tokens.** That is exactly what the **P3 axis** of `harness-evaluation` does —
it checks whether a repeating node has a cap or a termination predicate.

| Loop | The edge that goes back | What sends you back | Termination predicate | Cap device |
| --- | --- | --- | --- | --- |
| **Session** | `handoff` → the next `session-brief` | context compaction · session end | until the session starts again | file rotation, 10 most recent |
| **Build gate** | `build-gate → build` | source changed but no trace of a build or test | a build/test Bash call detected in the transcript | `stop_hook_active` prevents re-blocking |
| **Review** | `orangekit-reviewer → build` | a Critical found | 0 Criticals | read-only — it does not fix things itself |
| **Cross-check** | `cross-check → build` | fewer than a majority of the 3 lenses pass | a majority find no problem | re-verification **at most twice** → user tie-break |
| **Sonar fix regression** | `receiving-code-review → health-check` | after fixing static analysis issues | 0 new issues | re-analysis **once** → whatever remains goes to the user |
| **Feedback** | `lessons → doctor → rule-promotion` | accumulated user criticism | threshold of 3 in a category · one approval | **physically moved** to the archive |

### The first five are gates, only the sixth is a flywheel

**A gate** sends you back to the same place until the condition is met. One turn leaves the system as it was;
what changes is **only the work product**.

**A flywheel** is different. The last step feeds the first, and the shared state in the middle —
**the harness assets themselves** — thickens on every turn. Only the feedback loop has this property.
That is why this one alone needs a separate explanation.

### The character of each loop

**The session loop** is the only loop with no human intervention. The event of the context vanishing arrives
without warning, and only the runtime knows the moment, so a hook takes it. Its termination predicate is "until the
session starts again" because this loop is not a **decision** but a **preservation**.

**The build gate loop**, when the harness is working properly, **normally never turns at all.**
So the `build-gate→build` edge is marked `conditionalEmit` in the graph —
a declaration that "never executed" is not a defect for this edge.

**The review loop** is run by the `orangekit-reviewer` subagent. That agent has Write and Edit blocked by
`disallowedTools`, so **it cannot fix what it finds.** The findings have to go back to the main session, and
that is the `orangekit-reviewer→build` edge. A case where taking a permission away set the shape of the loop.

**The cross-check loop** sends source to an external model (Codex). So **prior consent is
mandatory**, and as the only path that crosses a boundary it is why the **P7 axis** of `harness-evaluation`
exists. It is also the only loop whose re-verification cap is explicitly 2 — a round trip with an external model
is a cost you can see.

**The Sonar fix regression loop** has the same shape as the cross-check loop with a different counterpart — a
rule engine instead of an external model. So it gets the same two disciplines: **prior consent** (`health-check` Step 5.5 asks) and
**an explicit cap** (one re-analysis). The cap is 1 because the findings of a rule engine do not tangle with one
another — everything fixable in one turn gets fixed, and a second turn reduces almost nothing further.
Issues on paths with a high cost of reversal do not ride this loop; they go to `orangekit-reviewer`.

**Only the feedback loop needs a section of its own next.**

### Loops whose cap is not a number

Guide generation (`stack-guide-generator`) and the review loop end on **a predicate rather than a counter** —
"0 gate FAILs", "0 Criticals". The P3 axis accepts this. With a termination predicate there need be no cap, and
**only having neither a predicate nor a counter** is a defect.

---

## 03-a — The feedback loop: the hardest thing in this harness to keep

**Canonical**: `rules/lessons.md` · `scripts/doctor.sh --lessons`

```
implement → (user criticism) → record → aggregate → promote → contract → implement …
                                    └→ the harness assets change
```

| Step | Who | What |
| --- | --- | --- |
| criticism | the user | fixes the code · the approach · the workflow |
| record | the model | **immediately**, into `docs/lessons.md` in `[category: …]` form |
| aggregate | **`doctor --lessons`** | frequency per category. 3 or more makes it a promotion candidate |
| promote | human approval | into a hook, a skill or a rule |
| contract | the model | **physically moved** into `lessons-archive.md` |

**That the aggregation is done by doctor and not by the model** is the design point of this loop. If a rule
tells the model to "go count", that count cannot be verified. Whatever can be counted deterministically is given to a script.

### The form of a promotion is decided by the nature of the mistake

| Nature of the mistake | Form of promotion |
| --- | --- |
| deterministically detectable by pattern matching | **hook extension** or a lint rule |
| a repeating workflow | **a skill** |
| needs semantic judgement or context | **a rule card** |
| 2 or more `[category: false-positive]` | **contraction** — do not make a rule; narrow the condition or retire the device |
| 3 or more `[request: …]` | a repeated request → consider promoting to a skill |

### Why the evidence was pinned to two things

v2 **declared "✅ promoted" 22 times and changed 0 rules.** Because declaring is free.
So v3 fixes the evidence of a promotion to two things:

1. **The diff of the corresponding asset** — did the hook, skill or rule file actually change
2. **The item that disappeared from the file** — was it physically moved into `lessons-archive.md`

One decision criterion falls out of this — **when the loop turns properly, `lessons.md` shrinks.**
If it only grows, things are being recorded and not promoted. 30 items is the cap, and an item with no
recurrence for 6 months is also an archive candidate.

### Why this loop ends at a person

In the graph, `rule-promotion` goes to `user-report` (terminal). **It does not close automatically.**
Because if the harness changes its own rules by itself, the grounds for reversing that disappear, and approval is limited to one round.
Not taking the person out of the self-improvement loop is deliberate design.

---

## 04 — Graph engineering — what a checklist cannot answer

**Canonical**: `workflow.graph.json` (49 nodes · 90 edges) · `dev/docs/port-to-origin/phase-5-graph.md`

### Why a graph

This structure existed in v2 as well. It was just **scattered across markdown tables and prose, so neither
verification nor instrumentation was possible.** As a result "an asset that is declared but cannot be reached"
(697 lines of rules) went undiscovered by anyone for four months.

A checklist can answer only **"does X exist"**. The 697 lines of rules kept answering "yes" to that question —
the files were there. A graph answers three questions a checklist structurally cannot:

| Question | The defect it detects | What it actually was in v2 |
| --- | --- | --- |
| does every edge's target exist | dangling — a reference to something that is not there | a document claimed a file existed that did not |
| **is there a node with no inbound edge** | **an unreachable asset** | ← the 697 lines of rules were exactly this |
| does every execution node declare an **error edge** | no failure path | failures vanished silently |

The third is especially characteristic of this harness. **If the failure path is not in the graph, the failure vanishes silently.**
So a node that declares `blocks` must have an `on_error`, and `doctor --graph` enforces it.

### Vocabulary — node · edge · path

A **node** is an asset that executes or holds state. There are 7 `kind`s:

| kind | Count | What |
| --- | --- | --- |
| `skill` | 28 | 26 skills + `harness-evaluation` (the `orangekit-harness` plugin) + `install-guide` (a node standing up the assembly-only path separately) |
| `stage` | 6 | `understand` · `plan` · `build` · `verify` · `cross-check` · `rule-promotion` — **the model's behaviour**, so code cannot emit them |
| `hook` | 5 | the only category that code executes |
| `agent` | 2 | `orangekit-planner` · `orangekit-reviewer` |
| `store` | 4 | `lessons` (mistakes) · `decisions` (choices) · `eval-report` (defects) · `design-system` (tokens and direction — jurisdiction is split with the canvas) |
| `tool` | 3 | `doctor` · `skill-creator` · `design-canvas` (the latter two are native — no path, as there is no file in this repository) |
| `terminal` | 1 | `user-report` — the place where a loop ends at a person |

An **edge** is a transition and has a `cond` (condition) and `instrumented`.
A **path** is this harness's unit of evaluation — in the wording of `harness/skills/harness-evaluation/SKILL.md:8`,
not the asset unit ("what exists") but the path unit,
**"which nodes one task steps on, where it stops, and what it leaves behind."**

### `instrumented: true` — where declaration and measurement are joined

Only **7** of the edges are `instrumented: true`. This is not importance but means **an edge a hook actually
emits**.

| Edge | Emitting hook |
| --- | --- |
| `session-start → doctor` | `session-brief` (on a hook liveness shortfall) |
| `session-start → harness-evaluation` | `session-brief` (after 30 days) |
| `build → security-check` | `security-check` |
| `build → build-gate` | `build-gate` |
| `build-gate → build` | `build-gate` (when blocking) |
| `build → handoff` | `handoff` |
| `build → track-skill` | `track-skill` |

This marking is what lets `doctor --usage` count **"the declared edges that were actually stepped on"**.
That is how "this skill is not used" becomes **a measurement, not a claim**.

### The four disciplines that keep the graph honest

1. **Edges between stages are excluded from the "dead edge" decision.** Because they are the model's behaviour and
   code cannot emit them. Report those as "dead" too and it becomes **a warning that never turns off**, and
   a warning that never turns off teaches people to ignore warnings.
2. **`conditionalEmit`** — marks an edge that legitimately does not fire in a healthy harness
   (`build-gate→build` is never emitted if nobody skips verification).
3. **A `store` must have both an inbound and an outbound edge.**
   **A store with no node reading it is pure cost and a source of drift.** This one discipline
   retired two actual assets.
4. **`produces` is attached only to artifacts the harness reads again later.** Something that is delivered to the
   user and ends there (a marketing site, a favicon) is not a store.

### The graph and the routing card use the same vocabulary

A node's `phase` value is cross-checked **in both directions** against the Phase vocabulary of
`rules/workflow-routing.md` (P0-A~E · P1~P6). If the routing card declares an invocation but no graph node has that
phase, or the reverse, `doctor --graph` fails. **Because once the two vocabularies diverge, routing becomes
impossible to check by machine.**

### The graph is not written twice

`workflow.graph.json` is canonical and the documents quote it. That is also why the full graph is not
transcribed into this document.

---

## 05 — A single task walked through — where the four devices are visible at once

The previous four sections each explained one device. In practice the four turn together.
Let us follow one request all the way through.

> **"Add a payment status field to the order API"** — the file to fix is `src/app/api/orders/route.ts`.

| # | What happens | Which device | Why there |
| --- | --- | --- | --- |
| 1 | The session opens. T0 operating contract 37 lines enter the context | **hook** `session-brief` → **T0** | No file has been opened yet, so the reversibility classification table has to go in here |
| 2 | At the same moment `workflow-routing.md` appears | **T1 always on** | Because it has no `paths:`. What to produce in what order is needed before any file is opened |
| 3 | The briefing prints branch · uncommitted · hooks 5/5, and a working tree snapshot (path+mtime+size) is saved | **hook** | This snapshot becomes the baseline for step 9 |
| 4 | It is "extending an existing feature", so per the routing table **P4 → P5**. P0~P3 are skipped | **T1 always on** | When the 4 entry conditions hold, no preparation document is produced. What gets frozen first inside P4 is §02-b |
| 5 | The path is `**/api/**` → **Costly**. It cannot end with a self-review | **T0** | Decided by **path**, not by size — a 5-line migration is more dangerous than a 400-line refactor |
| 6 | The moment the file is read, `code-change.md` · `security.md` · `reversibility.md` load | **T1 conditional** | `paths: src/**` matched. They arrive only at the moment they are needed |
| 7 | Implementation. The payment token is accidentally put in a constant | — | — |
| 8 | **It is blocked before the Edit runs** — the `sk_live_…` pattern, exit 2 | **hook** `security-check` | Find it after the write and it is already on disk. Intervention point ③ |
| 9 | It is fixed to an environment variable and the turn is about to end. **Blocked** — 1 source file changed with no trace of a build or test | **hook** `build-gate` | It compares against the baseline from step 3 and looks only at "what changed this session". It is caught **even if that file has been uncommitted since yesterday** |
| 10 | `pnpm build && pnpm test` runs → passes → the turn ends | **loop** (build gate) | One turn around the `build-gate→build` edge |
| 11 | Being Costly, the review goes to `orangekit-reviewer`. 1 Critical | **agent** + **loop** (review) | Read-only, so it cannot fix it itself → `orangekit-reviewer→build` |
| 12 | Fixed and verified again. 0 Criticals | **loop** termination predicate met | |
| 13 | The session ends. Branch · uncommitted · remaining tasks are saved to `dev/handoff/` | **hook** `handoff` + **loop** (session) | The next session's `session-brief` picks this up |
| 14 | If the user criticized the approach along the way, it is recorded in `docs/lessons.md` | **loop** (feedback) | Once 3 accumulate, `doctor --lessons` raises it as a promotion candidate |

**The graph path stepped on**:
`session-start → build → security-check → build → build-gate → build → verify → orangekit-reviewer → build → handoff`

What is visible here is the harness's actual shape.

- **Hooks** intervened four times (1 · 8 · 9 · 13) and **every one without the model's cooperation**.
- **Rules** arrived at three moments — before the start (T0), before the start (T1 always on), when a file was opened (T1 conditional).
  **Nothing that was not needed was ever resident.**
- **Loops** turned three times (build gate · review · session) and all ended on a termination predicate.
- **The graph** made this path countable after the fact. The edges left in `graph.log` are the evidence.

And if at step 4 this work had touched `**/migrations/**`, it would have become **Irreversible**, gone
to P6, and picked up a 3-lens `cross-check` majority, user confirmation and a rollback procedure.
**The same harness folds to a different depth depending on the nature of the work** — that is the purpose of the reversibility axis.

---

## 06 — Agents · skills · guides

### 2 agents — removing permissions is the design

| Agent | Tools | What becomes structurally impossible |
| --- | --- | --- |
| `orangekit-planner` | Read · Grep · Glob · WebSearch · WebFetch | **Churning out unnecessary documents** — there is no Write |
| `orangekit-reviewer` | Read · Grep · Glob · Bash (`disallowedTools`: Write · Edit · NotebookEdit) | **Editing or moving files without authorization** — read-only |

Write "do not create documents" as an instruction and it may or may not be obeyed. **Take the tool away and
the violation is impossible.** This harness consistently chooses the latter.

There is one side effect — the fact that `orangekit-reviewer` cannot fix things **sets the shape of the review
loop.** A finding has to go back to the main session, and that is the `orangekit-reviewer→build` edge.

An agent does not inherit `.claude/rules/`, so the norms it needs are written **directly into the agent prompt**.
But so that the same norm is not asserted in two places, one side is left as a quotation.

### 26 skills — divided by how they fire

| How it fires | Examples | Character |
| --- | --- | --- |
| the model fires it automatically when a condition holds | `prd-generator` · `completion-review` · `receiving-code-review` · `shortcut-ledger` · `pr-prep` | The routing card's Phase sets the condition. Where there is no Phase, the description sets it |
| **manual invocation only** (`disable-model-invocation`) | `orangekit-init` · `orangekit-migrate` · `execution-dashboard` · `fix-issue` · `health-check` — **5** | Running automatically would be expensive or needs user intent. The descriptions of these five **are not resident** |
| another skill or hook invokes it | `stack-guide-generator` (← `orangekit-init`) · `skill-enhancer` (← native `skill-creator` · evaluation) | They have an inbound edge in the graph |

**The path to making a skill runs through three stages.** Each of the three has a different owner —
this table is the **canonical source** for the procedure and the handoff order (it used to be in a T1 card, but as a
plugin development procedure it had no reason to be resident in a consumer session and was moved here).

| Stage | Owner | Why there |
| --- | --- | --- |
| creation · draft | `skill-creator` (native) | A built-in gets better along with the model. Do not reimplement it |
| enhancement | `/skill-enhancer` | Retention decision + the 6 patterns — the dimension the evaluation loop **cannot score** |
| measured A/B · description optimization | `skill-creator` | The subagent fan-out, the benchmark viewer and `run_loop.py` are there |

**Two tools write to the same description field.** The order is fixed —
**the P1 and P5 injections of enhancement first, `skill-creator`'s optimizer second.** And in the eval set
handed to the optimizer, **include the near-misses created by the P1 boundary as should-not-trigger.**
Leave them out and the optimization can erase the boundary sentence and still look like the score went up.

**`/skill-enhancer` comes first when fixing an existing skill too** — Step 0 decides retention, boundary
splitting, conversion to manual, merging or deletion. Enhancing a skill that is about to disappear is the most
expensive outcome, and a description is resident every session even if you never invoke that skill.

**Do not build what overlaps with native** is the principle, but there is a counter-discipline alongside it —
**"a native equivalent exists" is evidence of overlap, not evidence of inferiority.**
And since native keeps getting better along with the model, this comparison **does not end after one round**:
P6-② of `/harness-evaluation` throws it again (skipped only when the previous decision is within 30 days **and** there are 0 asset commits), and the decision is one of three — **replace · keep · compose**.
A custom that chose the third must be a thin layer wrapping native and must not reimplement it. To propose retiring something you must actually open both
bodies of text and compare the coverage, and what you compare against must be **the best, undamaged version**.
That is how `/security-review` (full audit · dependency CVEs · secrets) and `receiving-code-review`
(it *verifies* findings rather than *producing* them) survived, while `skill-generator` ·
`requesting-code-review` · `persistent-loop` were removed.

**A description is resident even if the skill is never used.** So the number of skills is a context budget, and
once the budget is full no new asset can be made. In v3.21.0 the headroom actually shrank to **7 characters**,
and the answer at that point was not compression but **separation** — the 5 marketing skills (`marketing-workflow` ·
`scroll-stop-builder` · `scroll-stop-prompter` · `seo-strategy` · `web-asset-generator`) were moved
to `orangekit-marketing`, a second plugin in the same repository (`docs/platform-contract.md` §2.5).
**The problem was that skills unrelated to development were eating a development session's budget, not that the skills were bad.**

The same decision was applied once more in the opposite direction — `harness-evaluation` is a tool used only by
people who **build** this plugin, so it was moved to a third plugin, `orangekit-harness` (`harness/`).
**Except that the grounds here are not budget.** This skill is `disable-model-invocation: true`, so its resident
cost is **0** even sitting in `skills/` (the table in §2.4). The reason it moved anyway is **the command list** —
in `skills/` a consumer sees `/harness-evaluation` and presses it, and outside the source repository that skill
exits 2 with "nothing to evaluate". **Not handing over a command that cannot be used** is what the separation bought.
There are two costs (resident tokens · one line in the command list) and `dmi` turns off only the first — miss that
distinction and you reach the wrong conclusion that "`dmi` is attached, so it can stay in `skills/`".

By the same decision, the items a consumer cannot execute (graph registration ·
`orangekit-init` installation steps · preset branching · retiring the plugin repository) were split out of
`rules/harness-change.md` into `harness/rules/harness-authoring.md`.

**The decision is one: does this asset have anything to do in a consumer project.** If not, it goes to `harness/`.

So that the separation does not create a blind spot, `doctor`'s **hygiene checks look at all three roots**, and
only the skill count for the budget and for "declaration ↔ reality" was narrowed to `skills/`. The graph is an
exception and includes `harness/skills` — `harness-evaluation` is a node of the feedback loop, and leaving it out breaks that loop.

**The first case of a compose decision is `shortcut-ledger`.** `/simplify` shrinks code that is *already written*
and `/code-review` produces findings on a diff — both have the **diff** as their target. The gap was **before writing**,
and a norm for before you write has to fire every time, so it went **into a T1 card, not a skill**
(`code-change.md`, "The implementation ladder"). Put an always-on norm in a skill that has to be invoked to appear and
it does not appear at the moment it is needed. What was left as a skill is the one fragment with no place in either native
or a card — **has the ceiling on a deliberate shortcut (the `ORANGEKIT-SHORTCUT:` marker) expired.** The card takes the norm,
native takes the after-the-fact cleanup and the skill takes only the expiry tracking; this three-way split is the actual shape of "a thin layer that does not reimplement native".

### Why guides are a `guides/` axis pack rather than a skill

Frontend 4 × backend 9 = 36 combinations. **Take the combination as the pre-built unit and you have to make 36,
most of which nobody will use.** So the pre-built unit is taken as the **axis** —
4 frontend packs + 9 backend packs + only the 3 frequently used seam pairs are made, and the remaining combinations are
**assembled** by `install-guide.sh` or **generated** by `stack-guide-generator`.

The app axis works on the same principle — there is one `react-native` pack and only the app seam is generated. But the app seam
is a function not only of the combination but of the **shape** (`appShell`·`deliveryModel`), so it is not pre-built; instead the cache
slots are split by shape and reused (`cache_slot` in `install-guide.sh`).

There is a separate reason for not making the name a skill. Plugin skills coexist as `orangekit-product:name` and project
skills as `name`. Keep the guide only as the project's `frontend-guide` and keep the plugin side as a pack rather
than a skill, and **the names do not collide, so there is no precedence fight at all.**

The quality of what is generated is handled on the premise that **generation and verification are one set**:
`guide-gate.sh` (what can be caught by reading, in the 3 grades FAIL/WARN/REVIEW) →
`pack-smoke.sh` (actually restore the files and run syntax and type checks + 12 security vectors).
The reason the latter came into being is concrete — the defects left after passing every item of the gate were
**caught almost entirely by execution**, and **one of them was an open redirect present in four places in the shipped assets.**

---

## 07 — `doctor` — the proving device

**Canonical**: `scripts/doctor.sh`

There is one premise — **a project with no CI.** So doctor is a single command the user can type themselves,
and the session briefing prints the absolute path every time.

| Mode | What it proves | Target |
| --- | --- | --- |
| `--fast` | structure — forbidden idioms · hook output format · **rule reachability** · dangling · agent contract · manifest · **declaration ↔ reality** | the plugin tree |
| `--self-test` | **working** — inject per-event fixtures into the hooks and check that a positive fixture with a planted defect is actually blocked | the plugin tree |
| `--graph` | the graph — dangling edges · unreachable nodes · missing `on_error` · Phase vocabulary cross-check | `workflow.graph.json` |
| `--usage` | instrumentation — hook liveness · edge traversal · the never-invoked skill list · resident context cost | the current project |
| `--lessons` | feedback — category aggregation · promotion candidates · false positive → **contraction** candidates | the current project |
| `--consumer` | **the consumer layout** — copy the plugin into a fake cache and run the real hooks in 3 synthetic projects | a temporary tree |
| `--inventory` | **inventory** — an asset table by area (skill lines · resident/on-invoke bytes · graph in/out · document mentions · cards · hook block points · packs). **It does not judge** — it is the input to `/harness-evaluation` | the plugin tree |

Having two roots is deliberate. Asset checks (`--fast` · `--graph` · `--self-test`) look at the **plugin
root**, and state checks (`--usage` · `--lessons`) look at the **current project**. Merge them into one and asset
checks look at the wrong place in a consumer project.

That `set -uo pipefail` has **no `-e`** is deliberate too — stop at the first failure and the whole report
never comes out. A checking script runs every check to the end.

### Where "alive ≠ working" is implemented

`--self-test` does not just check that a hook exits 0. It puts in a fixture with a planted defect and checks
**whether it is blocked**:

- `PreToolUse-block.json` — a Write containing a secret → **must be exit 2**
- `PreToolUse-bash-block.json` — a secret written via heredoc → **must be exit 2**
- `PreToolUse-bash-ok.json` — a read-only `grep 'AKIA…'` → **must be exit 0** (false positive prevention)

The static checks work the same way. Build a synthetic plugin tree, plant one defect, then check **① that what
you meant to plant actually went in** and **② that the expected message comes out in that state**.
Without ①, you mistake "a tree with nothing planted passed" for success — which has actually happened.
`ORANGEKIT_FX_WHY=1` even shows whether it was caught **for the intended reason**.

There is a baseline check alongside it — **those messages must not appear on a tree with no defect.**
Block only the false negatives and not the false positives and the check is soon ignored.

### `--regress` is not a mode of doctor

It is `guide-gate.sh --regress`. Unlike `--self-test`, which runs only synthetic fixtures, it **actually checks
the entire shipped pack set and every pre-built seam.** The reason is clear —
**synthetic fixtures catch false negatives and the real assets catch false positives.** It is slow, so it runs before shipping.

### The boundary between doctor and `harness-evaluation`

| | `doctor` | `/harness-evaluation` |
| --- | --- | --- |
| What it does | **measures** — deterministic grep · fixture injection · counters | **judges** — is the design appropriate · is it overkill for the current model |
| Output | `pass N · warn N · fail N`, exit 0/1 | a **defect list** by severity (= an improvement backlog) |
| Discipline | does not judge | does not recount — **though it does look at how the counting is done** |

The occasion that produced this separation is striking. In one evaluation, **4 of 5 new defects came out of the
instrument (doctor) itself and the distribution path.** Because while "what do we measure" was being improved,
**nobody was looking at "is the measuring tool right".** One of them was a **false positive** from the previous
evaluation — it looked only at the number of files without opening the code and judged already-working rotation logic to be "no cap".
So a discipline was attached to the evaluation skill: **"Do not inherit the previous decision — always
re-confirm against the current file."**

---

## 07-a — Render proof — a passing build is not evidence that the screen appears

**Canonical**: `skills/ui-ux-design/scripts/ui-probe.sh` · `rules/ui-design.md` §6 ·
`_ui_render_notice` in `scripts/build-gate.sh`

### The failure being blocked

`tsc` **passes a blank screen, and a screen whose console is exploding.** The build gate (§01) looks only as
far as "was a build run", so the path of fixing the UI, passing only the typecheck and then saying "done" was
wide open. The last square of verification — **does the screen actually appear** — was empty.

### Three devices form one axis

| Device | When | What it does | Does it block |
| --- | --- | --- | --- |
| the UI branch of `security-check` | **when a new UI file is written** | summons the direction review (`ui-design.md`) | **No** — a notice |
| `_ui_render_notice` of `build-gate` | at turn end | notifies when the UI changed and the build passed but **there is no trace of a render check** | **No** — once per session |
| `ui-probe.sh` | when a person or the model invokes it | opens it in a real browser and gathers **reconnaissance and evidence in the same pass** | exit 1 |

**All three refrain from blocking for the same reason.** "Was the review actually done" and "is the screen as
intended" cannot be decided by a machine, and **folding undecidable into blocking makes a false positive.** Cry
every time in an environment with no headless browser, or on a component fix that needs no server, and the user
turns the hook off. So this axis **summons rather than blocks** — make the intervention point, but let the user set the cost.

What the `build-gate` notice accepts as "a trace of a render check" is **an actual tool call** —
it looks in the transcript for a `ui-probe` · `playwright` · `puppeteer` · `chromium` Bash call, or an invocation of
the built-in `/run` skill. Not the presence of a string (the symmetric repair of the failure where v2's stop-guard
passed on the single word "test").

### What `ui-probe` actually measures

It does not bring the server up — the built-in `/run` does that. This script **receives that URL.**

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/ui-probe.sh --url http://localhost:3000 --ready "main"
```

| Axis | Item | Reflected in the exit code |
| --- | --- | --- |
| **Defect** | console error · uncaught exception · failed request | **Yes** (exit 1) |
| **Quality** | contrast ratio · touch target · body size · `cursor` · `prefers-reduced-motion` | No — WARN |
| **Reconnaissance** | an inventory of buttons, links and inputs + selectors | No |
| **Evidence** | a screenshot per viewport (`.claude/.orangekit/ui-probe/`, 5 most recent) | No |

Putting quality in WARN is the key judgement. **When a false positive like text over an image spreads into a
block, the device gets turned off.** Only the 3 defect types raise the exit code.

**The waiting discipline was inverted to match measurement** — visibility-based (`--ready <selector>`) is first,
fixed-time waits are not used, and `networkidle` is **the last resort** (with polling, SSE or websockets it never
finishes — Playwright itself discourages it). This is the point where it parts from the Anthropic `webapp-testing`
skill it was based on.

**The exit code is 3-state**: `0` no defect · `1` defect detected · `2` **undecidable**
(no node, no playwright, connection failure). Not folding 2 into 1 is the condition on which this axis survives.

### The plugin does not install Playwright

**This is intended.** The chromium binary is ~94 MB, and half of all projects have no UI (FastAPI, API-only).
A project that needs it installs it explicitly — the command is in Step 6 of the `ui-ux-design` skill.

```bash
npm i -D playwright && npx playwright install chromium
```

Without it, `ui-probe` **guides you to the install command and stops**, with exit 2. It does not pass silently.

### Block proof — the proof of this device only actually ran in v3.27.0

> **This is why this section was written latest in this document.** `ui-probe --self-test` was there from the
> beginning, but this repository had no playwright, so **the block proof was left as SKIP.**
> The script honestly reported that as "unverified — this is not a silent pass",
> so nobody lied, but **nobody proved anything either.**
> "If you built a guard, prove that it blocks" is this repository's norm, and here was one device that had not
> been subjected to that norm.

Bringing playwright in as a devDependency and actually passing the fixtures grew the self-test
**from 3 checks to 7**. The 4 that were added are all demonstrations:

| Check | Fixture | Result |
| --- | --- | --- |
| no false positive | `clean.html` | 0 defects · exit 0 |
| console error detected | `broken.html` | 1 |
| uncaught exception detected | `broken.html` | 1 |
| failed request detected | `broken.html` | 1 · exit 1 |

`npm test` now runs this along with the rest. In an environment without playwright it stays SKIP, but
**that fact stays in the output** — the same discipline as every other 3-state device.

---

## 08 — Operations

### A version bump is not 4 places but 5 steps

The version is bumped simultaneously in `plugin.json` · `package.json` · the README badge ·
`marketplace.json` (2 places). doctor cross-checks them. **But those 4 places are all local files.**

| Step | Without it |
| --- | --- |
| ① commit | the tag has nothing to point at |
| ② `claude plugin validate .` **+ a local install rehearsal** | you discover a load rejection after installing |
| ③ `claude plugin tag --push` | there is no tag — doctor warns "not distributed" |
| ④ merge to main | **the marketplace looks only at main** |

② must not end with `validate` alone. When `.claude-plugin/` holds two manifests,
`validate` checks **only `marketplace.json`** and lets errors in `plugin.json` through.
Measured (evaluation v5 · E-16): `"agents": "./agents/"` was put into `plugin.json` and `validate` returned ✔, while
`install` rejected it with `Validation errors: agents: Invalid input`. Hence the rehearsal:

```bash
claude plugin marketplace add <absolute repository path>   # source: directory — reads the working tree as-is
claude plugin install <plugin>@<marketplace>
claude plugin details <plugin>                 # cross-check that the component inventory matches reality
```

The inventory in `details` is **sensitive to the form of the declaration.** Declare `agents` as an array of file
paths and the runtime loads them fine while `details` reports `Agents (0)` — remove the key and leave it to auto
discovery and it is right (evaluation v5 · E-17). **There are cases where not declaring is more accurate than declaring.**

> Measured: while the repository claimed 3.18.0, `origin/main` was at 2.0.0 and the tag count was 0.
> **17 version bumps had never once reached a consumer.**

### Where the mirror missed the canonical source — v3.31.1

A value that changes externally, such as a model name, is **not transcribed** into this document — the canonical
sources are only `skills/image-generator/SKILL.md` and `scripts/image-gen.sh`. Yet when v3.31.1 changed
`gpt-image-2` to `gpt-image-2.5-flare`, the two canonical sources and the 4 version places were fixed but
**the skill table row in the manual mirror `docs/manual/user.html` was passed over** — being a hand mirror it is
itself neither stamped with `orangekit-rule-version` nor a target of the `doctor --fast` cross-check, so missing it
announces nothing. It is a case where "reference freshness" (`workflow-routing.md`) — "has the canonical source
evolved while the quotation stood still" — reproduced itself exactly, in a **document mirror** rather than in source code.

### Before adding an asset

| # | Question | If YES |
| --- | --- | --- |
| Q1 | Does it overlap in role with an existing hook/rule/skill or with **native** | **Stop** — extend it, or use native |
| Q2 | Is it now unnecessary because the model got better | **Stop** |
| Q3 | Are you changing something that already works well for no good reason | **Stop** |

Priority among remedies: **edit 1~3 lines of an existing document > extend an existing hook > add to an existing
script > a new script.** A new one is the last resort.

The place that **throws the same questions again at assets that already exist** is the P6 axis of
`/harness-evaluation`. With only the 3 questions before adding, **the harness only ever grows.** So every
evaluation **considers at least one contraction proposal**, and if there is none it writes "none + grounds".

### Real-world verification cannot be done in this repository

There is no consumer here. **So whether the rules actually reach a consumer project cannot be confirmed here** —
that one thing is exactly what v2 missed for four months.

What fills that gap is `doctor --consumer`. It copies the plugin into a temporary directory **as if it were the
cache path**, creates 3 synthetic projects (**before the first commit · with a commit · with config**), runs the
real hooks and then checks:

- were the T1 rules auto-installed
- **were they not written into a project with no `orangekit.config.json`** (does the consent gate leak)
- do the always-on cards actually exist
- does build-gate **not** block when there is no transcript

Even so, the final check is done by a person — install the plugin into a new project and look with your own eyes
at whether the cards were **actually** placed in `.claude/rules/`.

### The device that keeps this document from going stale

Numbers written by hand into a document are certain to go stale. While the README said "24 nodes · 41 edges"
reality had become 47/67, and there was a time when three different values for the skill count coexisted.

So the **cross-check-against-reality line** at the head of this document is cross-checked against reality by
`doctor --fast`. When the numbers diverge, **it is not the document that fails but the check.** It is this
document's own discipline applied to this document itself.

---

## Further reading

| What you want to know | File |
| --- | --- |
| installation · use | [`README.md`](../README.md) · [`docs/getting-started.md`](getting-started.md) |
| every option in `orangekit.config.json` | [`docs/configuration.md`](configuration.md) |
| presets · axes · seams | [`docs/presets.md`](presets.md) |
| Claude Code platform behaviour (substitution variables · component auto discovery · per-event output format) | [`docs/platform-contract.md`](platform-contract.md) |
| running render proof · installing Playwright | [`rules/ui-design.md`](../rules/ui-design.md) §6 · Step 6 of the `ui-ux-design` skill |
| the discipline for fixing the harness | [`rules/harness-change.md`](../rules/harness-change.md) |
| the canonical source for reversibility classes | [`templates/operating-contract.md`](../templates/operating-contract.md) |
| the canonical source for the graph | [`workflow.graph.json`](../workflow.graph.json) |
