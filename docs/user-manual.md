# User manual — what to use, when, and how

Installation is covered by [Getting Started](getting-started.md) and the configuration options by
[Configuration](configuration.md). **This document answers "so how do I actually do the work"** once installation is done.

If you want to know **why** each device looks the way it does, go to [Harness anatomy](harness-anatomy.md);
to fix or operate the harness, go to the [Operations manual](operations-manual.md).

---

## 1. The 30-second concept — the three things this harness does

Install this plugin into Claude Code and three things appear. **The three are orthogonal** —
they work separately, and none of them stands in for another.

| # | What it does | What decides it | What the user feels |
| --- | --- | --- | --- |
| ① | Routing **what to build in what order** | the kind of task (new/change/bug/refactor) | Claude works out the planning → PRD → implementation order itself |
| ② | Deciding **how much to verify** | the reversibility class (the **path** you touch) | touch a migration and a review is attached; test code goes straight ahead |
| ③ | **Blocking the dangerous** | the 5 hooks (in real time) | hardcoded secrets and `DROP TABLE` are blocked before they run |

**① and ② multiply.** "A new feature" that also "touches a migration" walks the whole of P0~P5 and gets a
review on top. "A bug fix" that "only edits a test file" goes straight to implementation.

> **In one sentence** — the procedure is set by **the path and the kind of task**, not by size (lines, files).
> A 300-line CSS fix is light; a 3-line migration is heavy.

---

## 2. First: which kind is my task

Claude decides automatically, but **knowing it makes the conversation much faster.**

| My situation | Kind | Phase order |
| --- | --- | --- |
| Building a feature that did not exist, with no PRD either | new feature | P0 → P1 → P2 → P3 → P4 → P5 |
| A feature that did not exist, but the PRD already exists | new feature (PRD present) | P3 → P4 → P5 |
| Changing, extending or deleting an existing feature | change | **P4 → P5** |
| Fixing a bug | bug fix | **P4 → P5** |
| Leaving behaviour alone and changing only structure | refactor | P3 → P4 → P5 |
| Writing a document, touching the environment, just looking around | not applicable | no procedure |

**A Phase number marks order, not obligation.** If the four below already hold, Claude skips
P0~P3 entirely and goes straight to implementation.

> ① intent clear · ② context current · ③ impact radius known · ④ verification path exists

**Only ① is yours.** Claude can fill in the other three itself, but "what do you want" can only be asked.
So **when the intent is vague, questions come regardless of how many of the others are met.**

> 💡 **How to get fewer questions** — put ⓐ what ⓑ why ⓒ roughly where into your request, one line each.
> "The bug where the redirect after social login does not go home, somewhere around `app/auth/`" is much
> faster than "fix the login".

---

## 3. The reversibility class — how risky is my change

**It is decided by path. It is not judged by size.**

| Class | Which paths | What happens |
| --- | --- | --- |
| 🔴 **Irreversible** | `migrations/` · auth/RLS · payments and settlement · production data | independent multi-perspective verification + **a user confirmation request** + writing a rollback procedure |
| 🟡 **Costly** | shared packages · public API · type contracts · `api/` · `actions.ts` · `middleware.ts` · generated files | `orangekit-reviewer` reviews the diff independently — **a self-review is no substitute** |
| 🟢 **Reversible** | everything else (test code included, the default) | Go straight ahead. Finish with `/completion-review` |

**Why it works this way** — a reversible mistake is cheap and an irreversible one is expensive. The point is to
pile the verification cost onto the latter. Attach a review to every change and nobody reads the reviews.

> ⚠️ In 🔴, **when a user confirmation arrives it is not a formality.** That moment is the last point at which
> reversing is cheapest.

---

## 4. Journeys by kind of task (use cases)

### 🅰 A new feature — a product feature with UI

*Example: "Build three new patient booking screens"*

This is the longest path. **Each stage has to satisfy a "termination predicate" before moving on** — the test is
not that a document was produced but what has been settled.

#### The planning phase

| Stage | What | When it fires | The signal that it is done |
| --- | --- | --- | --- |
| **P0-A** `/brainstorming` | idea into design | when the requirement will not come out in one sentence | you can say it in one sentence |
| **P0-B** `/research` | web-based investigation | when an external fact needs confirming | a document in `dev/docs/research/` |
| **P0-C** `/business-planner` | revenue model · market entry | when a business judgement is needed | `dev/docs/business/` |
| **P0-D** `/service-planner` | **screen list · user flows** | when screens and flows are unsettled | `dev/docs/service/service-plan-<name>.md` |
| **P0-E** `/council-review` | the 3 perspectives: technical · business · UX | a **planning** decision that is hard to reverse | a combined recommendation + the user's choice |
| **P2** `/prd-generator` | writing the PRD | when there is none in `dev/docs/prd/` | the PRD takes in the screen list |
| **P3** `/dev-docs-generator` | plan · context · tasks | **only when the work crosses sessions** | the 3 files in `dev/active/` |

> 💡 **The artifact of P0-D becomes the input to design.** Settle the screen list here and the next phase reads it
> as-is. Skip it and you get asked again at the design stage.

#### The design phase — `/ui-ux-design`

| Stage | What | The signal that it is done |
| --- | --- | --- |
| **Step 2** generate the design system | colour, font and spacing picked from the data | `dev/docs/design/<project>/MASTER.md` |
| **Step 2.5** direction review | "is this the choice this brief calls for, or my default" | `## Signature` and `## Direction review` are filled in |
| **Step 2.6** draft canvas | publish artboards with `/design` | a canvas URL |
| **👤 user editing** | **fix it directly on the canvas and Save** | the **only stage in the journey a person runs** |
| **Step 2.7** write back + cross-check | the fixes into `MASTER.md` | `design-sync.sh` exit 0 |
| **Step 4** stack guidelines | apply Next.js and shadcn practices | (skipped for stacks outside the 4) |

**Why Step 2.5 matters** — AI-made design converges on three clusters (cream + serif + terracotta / near-black +
acid accent / ruled multi-column). If the brief **specified that direction, it goes as-is.** If it did not specify it
and you landed there anyway, that is a default rather than a choice, so pick again.

**What Steps 2.6~2.7 do** — without them the first time the user sees a screen is **after the code is written**.
By then the components are built and changing direction is at its most expensive. The canvas pulls that
argument earlier than the code.

> 📌 **You do not have to have the canvas.** If `/design` is missing or you decline, it is skipped — **then it is
> exactly the old way** and nothing is lost. But do write at least one line of layout per screen before moving on.

> 📌 **The two documents are not copies; their jurisdictions differ.**
> `MASTER.md` = tokens (colour · font · spacing) · signature; the canvas = screen composition (layout · hierarchy · copy · states).
> When implementing, **read both.** The entry point is the `## Canvas` section of `MASTER.md`, and if that section
> is absent there is no canvas.

#### The implementation and verification phase

| Stage | What | What happens automatically |
| --- | --- | --- |
| **P4** implementation | Claude writes the code | touch a UI file and the `ui-design` card loads automatically · write a secret and the hook blocks · try to finish without running the build and the Stop hook blocks |
| **Step 6** render proof | bring it up with `/run` and run `ui-probe` | screenshots (mobile · desktop) · **0 console errors** · empty/loading/error states rendered |
| **P5** finishing | the class decides the intensity | 🟢 `/completion-review` · 🟡 `orangekit-reviewer` |
| **P6** | 🔴 only | multi-perspective fan-out + user confirmation |
| shipping | `/pr-prep` | a PR body containing the sections the class requires (rollback procedure and so on) |

> ⚠️ **"The build passed" is not "the screen appears".** A typecheck passes a blank screen, and a screen whose
> console is exploding. That is why Step 6 exists separately. When there is no browser and **it cannot be decided,
> Claude does not write "confirmed" — it writes "undecidable".**

---

### 🅱 Changing an existing feature · fixing a bug

**This is the shortest path.** P4 → P5. No planning documents are produced.

```
request → (a question if the intent is vague) → implement → build/test → finish
```

- In a repository with a test runner, **changing behaviour** attaches `/test-driven-development`
  (failing test first → minimal implementation)
- If the bug needs reproducing first, `/fix-issue`
- A review is attached only when the path you touched is 🟡 or 🔴

> 💡 **Do not ask for documents on this path.** The harness holds the rule "do not produce a
> document for a condition already met". `dev/active/` appears only for larger work that crosses
> sessions.

---

### 🅲 The harness was installed later, into a repository that already existed

The code has already grown while the rule cards are empty.

| Order | Command | What |
| --- | --- | --- |
| 1 | `/orangekit-init` | pick the tech stack (frontend · backend · DB · auth) and generate matching guides |
| 2 | `/codebase-survey` | **measure the actual code** and update the `project-structure` and `code-conventions` cards |
| 3 | `doctor` | self-test that the installation actually happened |

**The three have different roles** — the built-in `/init` creates `CLAUDE.md` for the first time, `/orangekit-init`
picks the stack, and `/codebase-survey` **updates cards that already exist to match reality.**

> ⚠️ The harness is **non-invasive**. The `AGENTS.md` · `.github/` · `docs/` and pre-existing `CLAUDE.md` you
> already had are not touched unless you ask explicitly.

---

### 🅳 Changing the stack, or regenerating the guides

Invoke `/stack-guide-generator`. Combinations not in the presets (AWS, MongoDB, SvelteKit and so on) work too.

The guides are pre-built **by axis, not by combination** — 4 frontend axes × 8 backend axes. Instead of making
32 combinations in advance, the axes are assembled. That is why a new combination comes out immediately.

---

### 🅴 My code got reviewed / I got an external AI cross-check

Use `/receiving-code-review`. **It does not accept feedback blindly** — it confirms against the actual code
before adopting it, and rebuts wrong findings with grounds.

| Source of the review | How |
| --- | --- |
| output of the built-in `/code-review` | hand it to `/receiving-code-review` |
| a report from `orangekit-reviewer` | ditto |
| review comments from a person | ditto |
| an external AI cross-check is needed | `/codex-claude-loop` — **source is sent to an external model, so it does not run without consent**. Authentication is `codex login` (ChatGPT account or API key) — the key is not kept in an environment variable or a config file |

---

## 5. Skill catalogue — an index by situation

**26 skills — no need to memorize them.** Claude invokes what fits the situation. This table is for "when you want to invoke one yourself".

### Planning and design

| Situation | Skill |
| --- | --- |
| I want to work an idea up into a design | `/brainstorming` |
| my request is one sentence and I want context attached | `/prompt-enhancer` |
| I want to look at viability and the revenue model | `/business-planner` |
| I want to settle the screens and flows | `/service-planner` |
| I need to investigate external facts | `/research` |
| this is a planning decision that is hard to reverse | `/council-review` |
| I want to make a PRD / verify a PRD I changed | `/prd-generator` · `/prd-reviewer` |
| this work crosses sessions | `/dev-docs-generator` |

### Design and implementation

| Situation | Skill |
| --- | --- |
| building a design system or screens | `/ui-ux-design` |
| I need an image, icon or mockup | `/image-generator` — with an API key it generates (**billed separately from a subscription**); without one it gives you a prompt to paste into ChatGPT. Diagrams are `diagram-design` |
| changing behaviour where there is a test runner | `/test-driven-development` |
| fixing a bug | `/fix-issue` |
| creating or changing a stack guide | `/stack-guide-generator` |
| measuring an existing repository to update the cards | `/codebase-survey` |

### Verification and finishing

| Situation | Skill |
| --- | --- |
| implementation is done and the documents need updating | `/completion-review` |
| a full security audit (dependencies · secrets · payments) | `/security-review` |
| handling review feedback | `/receiving-code-review` |
| cross-checking with an external AI | `/codex-claude-loop` |
| opening a PR/MR | `/pr-prep` |
| reclaiming the shortcuts (`ORANGEKIT-SHORTCUT:`) you left behind | `/shortcut-ledger` |

### The harness itself

| Situation | Skill |
| --- | --- |
| setting a project up for the first time | `/orangekit-init` |
| migrating from an older version | `/orangekit-migrate` |
| I want to see the progress | `/execution-dashboard` |
| enhancing a skill | `/skill-enhancer` |

> 📌 **These do not overlap with the built-in tools.** `/code-review` · `/simplify` · `/security-review` (branch
> diff) · `/init` · `/run` are provided by Claude Code. The `/security-review` in the list above covers **the full
> audit, dependencies, secrets and payments** — the area the built-in does not handle.

---

## 6. When the harness blocks me

The 5 hooks intervene in real time. **A block usually has a reason, but there are false positives too.**

| Hook | When | What |
| --- | --- | --- |
| `session-brief` | session start | injects the operating contract · branch · number of uncommitted changes · hook liveness status |
| `security-check` | **just before** a file write or a Bash run | **blocks (exit 2)** hardcoded secrets and destructive commands |
| `build-gate` | when you try to end the conversation | **stops** you if you edited source and did not run a build or test |
| `handoff` | compaction · session end | saves a handoff note for the next session |
| `track-skill` | after a skill is invoked | records the use (for instrumentation) |

> **On 2026-09-12 the blocking range widened.** The patterns `security-check` inspects went from 23 to
> 24, and **four forms of rewriting the remote history of a shared branch are now treated as one question** —
> not only `git push --force` but `git push origin +main` (a refspec force push) and
> `--delete main` / `:main` (deleting a remote branch). Three of them used to pass straight through.
> If the target is not a shared branch, or cannot be decided, **it does not block.**
>
> On the same day **`build-gate`'s false positives also went down.** It used not to recognize `pytest`,
> `python -m pytest`, `tsc --noEmit` or `jest` as verification runs, so **it blocked sessions that had run
> the very command the harness prescribed.** Now it recognizes them. Conversely, cases like `echo npm run build` that
> **only talk and do not run** no longer pass.

### What to do when you are blocked

**① It is genuinely dangerous (most of the time)** — the message says why. Move secrets out into environment
variables, and narrow the scope of destructive SQL.

**② It is a false positive** — for instance an investigative command that **contains a secret string but writes no
file** gets blocked. In that case:

- write the command into a file and run that, or split it into separate segments
- and **tell Claude it was a false positive** — it is recorded in `docs/lessons.md`, and once 2 or more
  accumulate on the same device it becomes a candidate for **narrowing the condition rather than adding a rule**

> ⚠️ **Do not turn the hooks off.** Turn a hook off because of a false positive and that hook blocks nothing.
> That is exactly why the harness aggregates false positives.

**③ It said "undecidable"** — this is not a block. It means a tool is missing (jq, playwright) or you are
offline so it cannot judge, and it lets you through. **It just does not count as "confirmed".**

---

## 7. When a session gets long — the context boundary

Decide **when a phase (design · implementation · QA) ends. Do not cut in the middle of a phase.**
The first "yes" from the top is the answer.

| # | Question | If yes |
| --- | --- | --- |
| ① | Does the next phase use **this conversation as its primary source**? Is there room in the window? | **keep going** |
| ② | Is the current context unrelated to the next phase? | `/clear` |
| ③ | Are you handing over to another tool, directory or person? | **handoff** |
| ④ | Can it finish without supervision? | **subagent** |
| ⑤ | Anything else | `/compact` + say what to do next along with it |

**Why ① is ruled out first** — the other four all turn the primary source into a summary.
And **that loss cannot be reversed.** There is no way to recover the original from a summary.

---

## 8. Situations you will run into

**Q. Claude just keeps asking questions.**
If "intent clear" is unmet it asks even when everything else is filled in. Give it what, why and roughly where, one line each.

**Q. It is a simple fix but it wants to produce documents.**
The kind of task was picked wrongly. Say "this is a change to an existing feature, just fix it" and it goes to P4.

**Q. No review gets attached.**
If the path is 🟢 that is correct. The class is set by the path, not by the size. If you really want one,
ask directly: "review this with `orangekit-reviewer`".

**Q. The harness is overwriting my project's rules.**
It must not. The precedence is **user request → project `CLAUDE.md` → project `.claude/rules/`
→ the existing code patterns in the repository → plugin guides**. **Existing code patterns beat the plugin
guide.** If it behaves the other way round that is a defect, so tell us.

**Q. It installed but I do not see the rules.**
Check whether the cards are actually in `.claude/rules/`. A successful install and an asset arriving are
different things. `doctor` cross-checks it for you.

**Q. What happens if I ask for an image?**
`/image-generator` fires. **Just once**, it asks "generate via API" or "I will make it myself and drop it in",
writes the answer into `orangekit.config.json` and never asks again. If you choose the API it is
**billed separately from your ChatGPT subscription** — the subscription fee covers no API usage at all.
At 1024×1024 the estimate is roughly $0.006 for low · $0.053 for medium · $0.211 for high, and it tells you the
expected unit price before the call and the actual usage after it. Draw drafts at `low` —
`high` is 35 times `low`.

**Q. I do not have an OpenAI key.**
You are not blocked. Instead it makes you **a prompt that produces the same result if you paste it straight into
ChatGPT**, at `dev/docs/assets/<name>.prompt.md` — it contains the spec (dimensions · format · background), the path to
save to, and even the sentence to send as a follow-up when you do not like the result ("change one thing at a time
and keep the rest"). Put the image you get at the given path and the harness verifies the spec.

**Q. Do I make diagrams with this too?**
No. Diagrams and charts are `diagram-design`, and design systems are `/ui-ux-design`.
`/image-generator` takes only **what cannot be made in code** (photos · textures · illustrations · mockups).
Send simple shapes or badges to a generative model and it costs money, comes out different every time, and cannot be edited.

**Q. The skill is not being invoked.**
Skills fire on their description. If it does not catch, invoke it directly with `/skillname`.

---

## Antipatterns — use it like this and the harness is powerless

| Do not | Why |
| --- | --- |
| Turn a hook off because of a false positive | a hook that is off blocks nothing |
| Wave a 🔴 confirmation request through as a formality | it is the last point at which reversing is cheapest |
| "The build passed, so we are done" | a blank screen passes too — render proof is a separate thing |
| `/compact` in the middle of a phase | it turns the primary source into a summary and cannot be reversed |
| Mention a criticism and move on | it has to land in `docs/lessons.md` for the device to improve |

---

## Further reading

- [Getting Started](getting-started.md) — installation and first run
- [Configuration](configuration.md) — every option in `orangekit.config.json`
- [Presets Guide](presets.md) — stack preset details
- [Windows install](windows-setup.md) — the Git for Windows and `jq` prerequisites
- [Harness anatomy](harness-anatomy.md) — **why** each device has the form it has
- [Operations manual](operations-manual.md) — for the people who fix and maintain the harness
