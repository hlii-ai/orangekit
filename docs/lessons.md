# Lessons

## [category: workflow] Writing only "major" leaves the user unable to tell what changes — write the version numbers

- Date: 2026-10-17
- Situation: init's latest-version question was designed and reported as "update to the latest majors / keep the verified majors".
  The user pointed out that "major" alone is not understandable and the versions must be stated.
- Mistake: internal verdict vocabulary (major rise · declared major) was used verbatim as the wording of the user's options. Even with
  numbers somewhere in a table, abstract option labels leave the user unsure what they are choosing.
- Lesson: a question that asks the user to choose puts concrete values **in the options themselves** (package name · current version →
  latest version · scope of impact). Keep verdict vocabulary in internal documents only.

## [category: tooling] The typecheck had not run once in months — "install failed → skip"

- date: 2026-10-17
- situation: In the seam-absorption pilot, the react-vite pack's `--online` typecheck ended with "toolchain install failed — unchecked".
  The cause was `react-dom` missing from `pkgs`, so npm pulled in react-dom@19 and hit a peer conflict (ERESOLVE) with react@18,
  and with `--silent` the log was empty. Once fixed, real defects in existing pack files poured out (missing imports · the
  `ImportMeta.env` type · a missing testing library). aws-container's typecheck was already failing at HEAD too.
- mistake: The skip was explicitly reported as "not a pass", but nobody treated a pack that kept skipping as a defect.
- lesson: An `--online` skip on a shipped pack is not "undecidable" but **something to investigate** — if there is a network and the install
  fails, the pkgs declaration is wrong. Pin the peers too (react-dom · the testing library's dom) in pkgs.

## [category: skill] Two client packs made the same session defect separately — behavior rules belong in the contract too

- date: 2026-10-17
- situation: The web (react-vite) and app (react-native) packs were authored in parallel by different agents, and the audit found the same
  two defects in both: ① a refresh response arriving after sign-out revived the session ② when the retry after a successful refresh also got 401,
  the client stayed signedIn. A wire mismatch where the app's refresh body carried a key the server's strict schema rejects was of the same kind.
- mistake: The contract pinned the values (codes · envelope) but left the client session's **behavior** and the auth endpoint bodies blank.
  A blank gets filled differently by each author, or left out by all of them alike.
- lesson: A rule several packs share goes into the contract, whether it is a value or a behavior (§5 session rules · `auth-self-issued.md`).
  When the audit finds the same defect in two packs, it is not a pack defect but **a blank in the contract** — the audit prompt's "norm candidate" is that signal.

## [category: tooling] With a space in the path the gate did not FAIL — it went blind

- date: 2026-10-16
- situation: A consumer ran init in a folder with a space in its name (Windows), and the generation agent spent time
  chasing a gate malfunction. Reproducing it, the same pack **passed** in a path with a space with "no version claims", "no test code"
  and "0 complete files" — 24 places that expanded `$(guide_files …)` unquoted split the path and read 0 files.
- mistake: Many checks report "0 targets" as a normal result (not applicable), so a state in which the input had vanished
  could not be told apart from a pass. Every fixture ran only in a temporary path with no spaces.
- lesson: A shell script that handles file lists pins IFS to newline and tab, and **keeps a space-in-path fixture
  in its self-test** — that fixture must pick a defect that "looks like a pass when there are 0 targets" (a missing procurement and the like) to prove
  that it blocks. Pick an arbitrary defect and it FAILs for some other reason even in the blind state, which proves nothing (measured).

## [category: skill] Without a scope cap on a generation delegation, the generator widens "checking" on its own

- date: 2026-10-16
- situation: In a consumer project (react-vite + fastify + RN), a single seam-generation agent spent 62 minutes and 340k tokens.
  The delegation prompt asked it to install and run `tsc`, and the backend generator went on to run an embedded PostgreSQL · vitest ·
  mutations. On top of that, while writing the L0 contract the main session invented `todo/doing/done` states and an `updatedAt` that
  the packs do not have, and one more repair round ran.
- mistake: The spec named the owners of execution verification (the main session's pack-smoke · audit A) but never told the
  generator what it does "not do". The example domain, too, pinned only the names and not the fields.
- lesson: A delegation spec writes **what not to do** alongside what to do (the cap in rule 6 of generation-delegation.md).
  Values the contract does not pin get filled in by the generator — keep the example domain's fields and values in the canonical source (contracts/http-standard.md §0).

## [category: skill] With no cap, model or location set for audit and repair, a re-audit loop and disk residue followed

- date: 2026-10-14
- situation: While generating guides in a consumer project (OrangeTopia), the model launched 5 second-round audits on its own after the
  repair had finished. Each audit inherited the main model and spent 45k~100k tokens within its first minute. Audit A actually
  installed and bundled the whole app and ran 59 mutants. 11 working folders (including a separate npm cache per audit) were left
  at the drive root. The user pointed out the excess time and tokens, the risk of a loop, and large folders appearing on their own
  disk without their knowing.
- mistake: The spec said only "run the gate again after repairing" and set none of: a ban on re-auditing · a round cap · subagent models ·
  a work location · when to delete · an execution scope. The repair criterion "medium and low are the user's call" either created questions
  or let the model just fix them. With a principle (generator ≠ verifier) and no budget, the model applies the principle without end.
- lesson: A spec that launches subagents writes **a budget alongside the principle** — a round cap (with the counter in a file outside the session),
  a model per stage, the number run concurrently, an execution scope cap, a work location and when it is deleted. And filter repairs by impact
  grade. Do not ask about what will not be fixed; record it.

## [category: skill] With no recording rule for stacks outside the choices, init invented preset names

- date: 2026-10-13
- situation: In a consumer project (OrangeTopia), the init result recorded `presets: {frontend: "expo-universal", backend: "fastify"}`.
  Neither name is a preset in any repository. It was recorded as hybrid, but the real structure was an RN app as the
  primary shape, and the RN shell had no place to be recorded. The user pointed out: "don't make up stacks that don't
  exist — have me type them in as custom."
- mistake: The schema had a `presets` enum, but the init spec never defined the **recorded value** for an "other" entry or a "native family" pick,
  so the model filled the blank with a plausible-looking name. No step showed the user what would be written before the files were created, so the
  invented value never passed a human's eyes. And with only two axes, a product holding both web screens and app code could not be expressed.
- lesson: A choice that accepts free input is specified **down to what it records** — normalize when it matches a pack name; otherwise record
  `custom` and keep the original name in another field. Define the exit for someone who does not know (`undecided` · recommend) to the same level.
  And put a **source-labelled confirmation summary** before generation — values produced by measurement, inference, or normalization get filtered only there.

## [category: tooling] A message string in a branch that never runs is never evaluated

- date: 2026-09-13
- situation: `skills/stack-guide-generator/scripts/profiles/node-ts.sh` builds its "cannot run the classifier"
  skip message with `${$(node --version 2>/dev/null)}`. That is not a valid expansion — bash answers
  `bad substitution` and the script dies — so the branch meant to report *undecidable* instead takes the whole
  run down. It was present in the predecessor repository too, which means it had never once fired.
- mistake: I treated `bash -n` as the syntax gate for the shell this repo ships. It is not: a bad substitution is a
  **runtime** error, so `bash -n` passes it cleanly. The branch is a skip path, so no fixture drives it, and a skip
  path is exactly where nobody looks.
- lesson: The three-state discipline says an undecidable verdict must report itself and pass. That promise is only
  as good as the branch that delivers it, and an undecidable branch is the least-executed code in any checker —
  when you write one, run it once with the dependency actually absent. One observation so far, so no lint was added;
  if a second appears, the home for it is doctor's existing "silently broken shell constructs" section, which
  already holds the BSD BRE case.

## [category: workflow] Partitioned a repository-wide sweep by file extension and left five blind spots

- date: 2026-09-13
- situation: Translating the whole repository, I split the work by directory and by kind, and wrote the script
  assignment as "the shell scripts". Four sets fell outside every assignment and were found only because a later
  agent happened to trip over them: `skills/ui-ux-design/scripts/*.py`, `ui-probe.browser.mjs`,
  `scripts/fixtures/*.json`, and `skills/stack-guide-generator/scripts/profiles/`.
- mistake: I derived the work set from my own picture of the repository — "scripts means `.sh`" — while the
  verification command I planned to finish with was a content scan that knows nothing about extensions. The two
  disagreed from the first minute, and the disagreement is exactly the set of files nobody was assigned.
- lesson: **Derive the work set with the same command you will verify it with.** If the finish line is
  `grep -rl <pattern>`, then the assignment list is the output of that grep, partitioned — never a description of
  it. A description of a file set and the file set are different objects, and only one of them is checkable.

## [category: architecture] Put a universal norm into a preset-only skill and narrowed its reach

- date: 2026-08-20
- situation: While backfilling the original repo's data-modeling rules (456 lines) into v3, I ported them
  as a resource of nextjs-backend-guide, which is preset-scoped. When the defect was pointed out, I added
  wiring so that stack-guide-generator copies and adapts them into the generated guide.
- mistake: I missed the same axis twice in a row. (1) At port time I did not verify the reach path beyond
  the preset branch (reach 0 on the react-vite / python-fastapi combination), and (2) at repair time I chose
  copy-and-adapt, creating a drift source that spawns a copy per project — reintroducing the failure mode that killed v2.
- lesson: The distribution vehicle for a norm that must always apply regardless of stack is a **T1 rule card**
  (paths auto-load + version stamp refresh = preset-independent reach + a single canonical source). Shipping
  copies is the last resort. When adding a harness asset, include "does it reach under every preset combination?"
  in the reach-path verification (reflected in the harness-change card).

## [category: naming] Did not chase the old name of a renamed asset, and shipped false statements for 4.5 months

- date: 2026-09-02
- situation: While reviewing the `frontend-design` skill I found 4 leftovers in `skills/ui-ux-design/` —
  a false preset marker (`[Preset: nextjs-supabase]`), a pointer to a skill that does not exist
  (`frontend-dev-guidelines`, renamed to `frontend-guide` during the port), the original repo's project name,
  and a hardcoded consumer-layout path. After landing on 2026-04-14 they passed 89 commits · 14 doctor
  hardening passes · 5 harness evaluations, every one of them.
- mistake: I treated renames and moves purely as a "reach" problem. Every verification was on the "does the new
  asset land?" axis and never asked "where did the things pointing at the old name go?" A renamed asset sits
  neatly under its new name, so it **always passes the reach check** — the leftovers stay on the vanished-name
  side, and no check looked there. Worse, the port's Phase 4 completion criterion **stated** "zero references to
  the old name across the whole repo", yet the command actually run looked only at `.claude/` and `CLAUDE.md`.
  `dev/` was in the instruction but missing from the verification command, and that is exactly where the old name survived.
- lesson: **Only the command that ran is evidence, not the sentence in the checklist.** Write the scope in prose and
  a human reads the sentence and ticks it while the machine runs only the command — the gap between the two is
  exactly the blind spot. And a sentence that was true in the original context becomes false in the shipping
  context (preset marker · own project name · consumer path). It was not written wrong; it was written right and
  became wrong by moving, so a human eye does not catch it — that is the class you hand to a machine. I added a
  "post-change back-trace" section to `harness-change` and 2 "port leftover" checks to `doctor --fast` (block proof via 3 fixtures).

## [category: rule] Signals suppressing clarification piled up across three layers and nobody summed them

- date: 2026-09-02
- situation: While checking the harness against the 4 principles of an external repo
  (`multica-ai/andrej-karpathy-skills`), I found the harness had no norm answering the first pathology, "the model
  forms a wrong assumption and runs without confirming". Not only was it absent — there were **three signals
  pointing the other way**: T0 "Work entry"'s `2 or more unmet` threshold, T0 "Decision point"'s `decide trivial
  matters yourself`, and the `no wasting time on questions` line `templates/CLAUDE.md.hbs` baked into the senior profile.
- mistake: The three arrived at different times, each for a valid reason. "4-state entry condition" to stop
  document sprawl, "Decision point" to stop asking on every decision, and the hbs line for the experienced-user
  experience. **Each is right on its own; together, "do not ask" rings three times.** I had only ever reviewed
  norms file by file and never looked at *the sum of signals on one axis*. And decisively, I **counted the four
  entry conditions as equals** — context freshness, impact radius, and verification path are three the model
  solves alone with `git log` and `grep`, but intent exists only inside the user's head. Count what it can solve
  alone on the same scale as what it cannot, and the one item that must be asked is diluted to 1/4.
- lesson: **Review norms by axis, not by file.** Ask not "is this file right?" but "how many times, and in which
  direction, does the whole harness speak about this axis?" And **a norm that counts conditions and sets a
  threshold must first confirm the conditions are of the same kind** — summing items of different natures by
  count makes the threshold erase that difference. I added 1 line on the asymmetry of intent to T0's "Work entry"
  and 1 line on orthogonal edits to "Minimal change", and deleted the two rows in "further reading" that were
  path-driven, since each card's `paths:` already does that job. The remaining row (recording lessons, whose
  trigger is a **behavior**, not a path) I deleted and then restored after review feedback — net +1 line (40→41, budget 42).
  The senior line in `CLAUDE.md.hbs` was rewritten, splitting intent from method.

## [category: rule] Assumed implicitly for 4 months that "Minimal change" meant only file boundaries

- date: 2026-09-02
- situation: In the same comparison I found the pathology "changes comments, formatting, and style unrelated to
  the fix as a side effect". I swept all of `rules/` · `templates/` · `agents/` for
  `comment|format|formatting|indent|do not touch|leave alone|dead code|side effect|existing style` — 0 valid hits.
- mistake: T0's "Minimal change" reads `if a file outside scope needs modifying, stop and confirm`.
  Reading that sentence feels like "scope" has been handled, but what it actually blocks is **the file boundary**
  only. Edits happening inside a file you already opened are not "a file outside scope", so they sail past the norm.
  The fact that a norm existed stopped me from checking that norm's coverage — **the feeling of being covered was
  used as evidence of being covered.**
- lesson: **Read the condition a norm imposes, not the fact that it exists.** When asking "what does it block?", the
  noun that actually appears in the sentence (here, "file") is the boundary of application. However broad the prose
  sounds, the boundary is only as broad as the noun. The same method — **turn the pathology into search terms and grep
  exhaustively, not into a sentence** — works on other axes too. 0 hits usually means a gap, not "covered, worded differently".

## [category: freshness] Used a subagent's measurement as the basis for a plan without re-verifying it

- date: 2026-09-02
- situation: To measure the harness token budget I launched 3 Explore subagents. Two independently reported
  `rules/data-modeling.md` as 465 lines / about 41KB, and on that number I wrote the plan item "the biggest
  token lever is decomposing this card". After user approval I started, and the actual value in the working
  tree was **182 lines / 11.7KB** — the decomposition had already been finished in the v3.25.0 work.
  What is more, the placement of the reference assets was more accurate than my design — I was going to put
  them in `.claude/rules/refs/`, but a `.md` there is resident every session unless it has `paths:`, which
  breaks "read it only when needed". The implemented side avoided that trap by putting them in `.claude/references/`.
- mistake: `workflow-routing`'s "reference freshness" states explicitly that **you take a prior report only as a
  hint about where to look, and use only what you re-verified against the current canonical source**. I read that
  card in this very session and still thought of it as applying only to "documents written in the past" — I did
  not register that **a subagent report I had just received is the same class**. Freshness comes not from the age
  of a document but from *the fact that I did not look myself*. That the two said the same value only raised my
  confidence, when it was likely not 2 independent observations but 1 look at the same contaminated source (the commit).
- lesson: **A delegated measurement is a citation, not an observation.** Before using a subagent report as the
  **numeric basis** of a plan, re-measure at least the few values that could flip the decision — not all of them,
  only **the values sitting on the decision threshold**. Here, one line of `wc -l rules/data-modeling.md` would
  have done it. And check the working tree for in-flight work with `git status` right before starting. I looked
  only at `git diff --stat` early in the session, and that tool misses staging and scope. "Context freshness" is
  one item in the entry conditions, not a state you settle once — **look again at the moment you start.**

## [category: architecture] Deleted a duplicate and thereby removed the subject of the check that watched it

- date: 2026-09-02
- situation: I found that the `references/shared-workflow.md` files of `codex-claude-loop` and
  `gemini-claude-loop` were byte-identical, judged it a "drift source", made one canonical and turned the other
  into a pointer stub. `doctor --fast` passed as before.
- mistake: That duplication was not an accident — it was **design.** `dev/active/graph-upgrade/plan.md` B-3
  decided to **deliberately restore** the copy under the "skill directory is self-contained" principle, and left
  drift to be blocked by a check (B-6) that pairs the files via the `orangekit-doctor: shared-copy` marker on the
  first line and compares them. When I deleted one, the pair had one member left, so that check had **nothing to
  compare and passed trivially**. The green light looked like "fixed" when in fact **the thing being watched had
  disappeared**. And this decision was written in `dev/active/`, which I did not read — even though the session
  brief was surfacing that name under "open work".
- lesson: **Before deleting a duplicate, first look for a machine that knows about it.** A duplicate carrying a
  marker, a comment, or a dedicated check is not an accident but the result of a trade-off — one copy accepted in
  exchange for directory independence, with the price already being paid by a machine. Generalized: **a check
  passing means neither that there is no defect nor that the check is alive.** A change that shrinks what a check
  examines cannot cite its passing as evidence. And read the in-flight plans in `dev/active/` before starting —
  "previously written material" in "reference freshness" includes **plans that are still open**.

## [category: false-positive] Re-measured with a tool that is not on the execution path, then piled a harness overhaul on top

- date: 2026-09-04
- Guard: evaluation method — measured with a tool that is not on the execution path (not a false positive of the hook itself)
- situation: While answering "is SAST/DAST enough?", I found that the `secretPatterns` in `presets/*.json`
  were not wired into any hook. That much was right. The problem came next — I declared the preset regexes
  "broken" and on that basis produced a reorganization proposal bundling a control-flow change to the blocking
  hook, a new config field, a new script, and 7 reference files.
- mistake: Three overlapped. (1) I **declared from memory** that `grep -E` does not support `\s` —
  the `/usr/bin/grep` the hook actually uses (BSD 2.6.0) handles it fine. (2) When I went to measure it, the
  shell's `grep` was a **`ugrep` wrapper** — I measured with a tool that is not on the execution path and drew
  a conclusion from it. (3) I called `guides/*/policies.md` "the largest unused asset". `guide-gate.sh` uses it
  fully at authoring time — what is missing is only *a trigger point against consumer code*, and I smeared the
  two together. And I **did not apply Q3 of the 3-question test in `rules/harness-change.md`** ("am I changing
  something that already works fine → stop") **to my own proposal.** That hook had blocked two of my commands
  correctly in the very same session.
- lesson: **Claim absence or a defect only after re-measuring on the execution path that code actually uses.**
  Same axis as "took the file count as evidence of a missing policy", but with one extra layer this time — I did
  open it, but **with a different binary**. Two tools sharing a name does not make them the same tool.
  And **the answer to declaration ≠ reality is always two — build the implementation or delete the declaration.**
  Across four plan revisions I only ever offered the former, and when the user picked the latter the change
  shrank to 1/5. Removal is the default candidate, not the last resort. Finally, **an external asset's surface
  area is not our yardstick** — the moment I compared "6 standards vs 5 axes" against a zero-force document set, scope inflated.

## [category: skill] Defined the handling of overlapping skills as "merge and delete one" only

- date: 2026-09-08
- situation: While designing the Step 0 keep/drop judgement for skill-enhancer, I set four outcomes and wrote
  "consolidate = merge with the overlapping neighbor and delete one" in a single line.
- mistake: **The case where each side has a different advantage was missing from the definition.** Run it in
  that state and the side with the advantage gets erased. It only surfaced when the user asked "what if each
  one has its own advantage?" Worse, the counterexample was already in the repo — `security-review` overlaps
  in function with the built-in `/security-review`, and it was split rather than merged, and that handling was
  **written up as a best practice in catalog P1.** The judgement table I wrote contradicted my own reference
  document.
- lesson: **The default handling of overlap is boundary splitting, not merging.** Because the cost is
  asymmetric — if a merge is wrong you lose an advantage and it is hard to undo, whereas the cost of not
  merging is one description line each. And when you do choose a merge, **the advantage comparison table is the
  acceptance criterion**: if even one item does not carry over into the merged asset, do not merge. "Merge and
  then judge" does not hold, because by then one side is already erased. Before writing a new judgement
  procedure, **first find how the repo has already handled that situation.**

## [category: scope] The request was "add a case" and I inflated the plan into a harness overhaul

- date: 2026-09-09
- situation: I received a request for GitLab support, ran measurements (scripts · skills · config, three
  directions), then made a plan. The measurement showed the GitHub dependency was only 4 command sites, but the
  plan added, on top of those 4, a doctor drift triangulation check, a GitLab PAT secret pattern + 2 fixtures +
  POS_FX wiring, an extension of the non-invasive list, a terminology sweep across 6 files, and a new shared
  file under `references/`. The user rejected the plan with "don't overcomplicate it, keep it simple".
- mistake: I absorbed the **adjacent defects** the measurement had found (glpat- not being detected, etc.) into
  the request scope. I cited the fact that the user had picked "port + gap fill" in my scoping question, but I
  was the one who built those options — I got consent for an option I had inflated and used it to justify the
  inflation. The actual request was one thing: "let the user pick GitLab".
- lesson: When measurement finds adjacent defects, **report them and leave them outside the request scope.**
  Turning them into an option and asking is also scope expansion — the user can only pick from the options
  presented. An AskUserQuestion scoping question must be "how should we do what was asked?", not "what shall we drop?"
  Execute the minimum scope by default and report the defects you found separately, in one line.

## [category: false-positive] The first session opened with "the hooks are broken" — counted no-opportunity as no-fire

- date: 2026-09-10
- Guard: scripts/session-brief.sh
- situation: During a consumer-perspective review I reproduced, 3 times, the session immediately after
  installing into an empty project. Run 1 showed `⚠️ hook liveness 1/5 — some hooks have never run`, run 2 showed 3/5, run 3 showed 5/5.
- mistake: I took the denominator to be the **number of unique scripts** in `hooks.json`. But on run 1 no hook
  other than SessionStart **has any chance to run.** On top of that `track-skill.sh` is a PostToolUse(Skill)
  matcher, so for a user who never invokes a skill it will never fire — that user sits at 4/5 and sees **a
  warning every session that they cannot fix**. The prepared fallback (`no hook heartbeat (first session)`) was
  **unreachable dead code**, because `orangekit_begin` on line 17 of the same file creates the log before the check runs.
- lesson: "Did not run" and "had no chance to run" are different. `hooks.json` already tells you the firing
  opportunity — only hooks without a `matcher` fire unconditionally every session; hooks with a matcher depend
  on user behavior. The warning's denominator is **the former only**, and a first session is decided not by file
  absence but by `session-brief`'s own record count. When using a fallback branch, confirm by execution that the
  branch is actually reachable — the same function was creating a file first and then asking "if it is missing"
  later. (Evaluation v3 E-11 · v5 E-14 were the same "warning that will not turn off". This is the third.)

## [category: naming] A shipped card cited paths from the plugin repo's context — files the consumer does not have

- date: 2026-09-10
- situation: I actually created a consumer project, installed the cards with `install-rules.sh`, and then
  checked every backticked relative path in the card bodies **against the consumer root**.
- mistake: `harness-change.md` alone had 6 paths that cannot exist in a consumer —
  `agents/orangekit-planner.md` · `docs/harness-anatomy.md` · `docs/platform-contract.md` ·
  `rules/reversibility.md` (in a consumer it lives in `.claude/rules/`) · `scripts/build-gate.sh` ·
  `scripts/lib/common.sh`. That card had written into its own frontmatter comment "paths holds only paths that
  are true in the consumer layout", yet wrote **the body** in plugin context. The same card's "post-change
  back-trace" section warns about exactly this class — the rule did not catch its own author.
- lesson: A T1 card is loaded from two repos. Do not write a relative path that is true in only one of them;
  write `<plugin-root>/…` (shipped by the plugin) · `.claude/…` (owned by the project) instead.
  And **writing the discipline in a sentence is not the same as a machine checking it** — I added a third check
  to "port leftovers" (plugin-context paths in a rule card body) and proved its blocking power with the positive
  fixture `card-plugin-path`. The decision rule is "does it actually exist in the plugin?" —
  that is the only machine evidence for "the author wrote this in plugin context".

## [category: tooling] The instrument narrowed its scope and reported resident cost at 1/2.8 of the real value

- date: 2026-09-10
- situation: `doctor --usage` reported "resident context cost" as 17,063 bytes, while a coding session measured
  in a fully configured consumer cost 48,450 bytes.
- mistake: I subtracted three things. (1) I excluded the SessionStart output as "varies per session, so not
  included (honest reporting)", but while the size varies, **the injection itself is unconditional.** (2) The 4
  cards of the `paths: src/**` kind (22,827 bytes) were dropped entirely for being "conditional", but they load
  as soon as a single source file is read, so in a coding session they are effectively certain. (3) I measured
  `workflow-routing.md` after stripping comments, whereas Claude Code loads **the file as-is** (a 414-byte
  difference). The P5 judgement leans on this number, so the yardstick for restraint was 2.8x more lenient than reality.
- lesson: "Not included" is not evidence of honesty — it is honest only when you write down **what you cannot
  count and why**; leaving out something countable is an optimistic lie. Judge conditional loading by the
  **width** of the trigger: `src/**` carries the name "conditional" but its firing probability is close to 1.
  And when the measured subject is a file, measure it **in the form the runtime reads** (whether comments are
  included is decided by who preprocesses the file — a hook strips T0, so excluding is right; nobody strips a card, so including is right).

## [category: tooling] The resident-cost instrument cut its scope by asset type and missed agents

- date: 2026-09-10
- situation: The user asked for "the context cost a consumer with the plugin installed pays unconditionally, no
  matter what prompt they throw". `doctor --usage` reported an unconditional subtotal of 17,477 bytes, and on
  counting it turned out the 733 bytes of `name` · `description` · `tools` in `agents/*.md` were missing wholesale.
- mistake: I designed the instrument as **"let's count skills"** rather than "what enters the context".
  An agent description is resident even when never invoked, which is the same property as a skill's, yet it was
  dropped purely because the asset type differed. On top of that agents have **no** non-resident switch
  equivalent to `disable-model-invocation`, which makes the cost more certain than a skill's — I left out of the
  yardstick the very thing that cannot be turned off. The "non-resident" value in the same section was also
  inflated by 186 bytes because the frontmatter reset regex (`[a-z_]+:`) fails to catch hyphenated keys,
  so the savings were being reported larger than they are.
- lesson: **Cut the measurement scope by load time, not by asset type.** Same root as the preceding 2026-09-10
  lesson "the instrument narrowed its scope and reported resident cost at 1/2.8 of the real value" — that time I
  cut on timing (conditional/unconditional), this time on type. When adding a new kind of asset to the plugin,
  ask "does this enter the context even when not invoked?" and if yes, wire it into the instrument.
  And "excluded because it is on the consumer side" is honest **only when the plugin does not ship that value** —
  the generated guide descriptions were countable because the real files sit in `guides/seams/*/` (876–966 bytes).

## [category: security] A false-positive fix widened an exemption and opened a blocking path — an exemption must be proven as strongly as the block

- date: 2026-09-10
- Guard: scripts/security-check.sh
- situation: Before release, an independent `orangekit-reviewer` review flagged a regression in `_message_cmd`. I
  reproduced it directly, comparing the current diff against `git show HEAD:scripts/security-check.sh` on the same input.
- mistake: While fixing E-22 (DDL vocabulary in a commit message blocked as a false positive), I exempted
  segments beginning with `git commit|tag|…` · `gh` · `glab`. Because the sole exception condition
  `_pipes_to_db_client` looked only at a DB client after `[|;&]`, **command substitution passed straight through
  the exemption**: `git commit -m "$(psql -d app -c \"DROP TABLE users\")"` gave exit 0 (the previous version gave exit 2).
  `$(…)` is a position the shell always executes, so this is execution, not description.
- lesson: **When you add an exemption while fixing a false positive, you must block the execution paths that pass
  through that exemption with a fixture at the same time.** `harness-change.md` already requires it ("an exemption
  must be proven by a fixture as strongly as the blocking point (bypass-attempt fixture → exit 2)"), and after
  E-21 this is the **second** occurrence of the same shape — the rule existed and the fixture did not. This time I
  pinned it with `bash-commit-cmdsub` · `bash-gh-body-cmdsub` as positive fixtures. And when narrowing the hole I
  did not include a bare `(`: it would misread `git commit -m "docs: (psql) explanation"` as execution and become a
  new false positive — **narrow only the hole in the exemption, do not add false positives.**

## [category: agent] If a "read-only" agent has Bash, that declaration is a convention, not an enforcement

- date: 2026-09-10
- situation: During a pre-release review, §6.1 (16 lines) appeared in `docs/platform-contract.md`. That file was
  not in the session-start `git status` and I did not touch it. The only thing able to write to the repo in that
  window was the `orangekit-reviewer` running the review, and the content was exactly what a reviewer would
  observe (the resident cost of agent descriptions).
- mistake: `agents/orangekit-reviewer.md` blocks writes with `disallowedTools: Write, Edit, NotebookEdit` and
  declares "this is read-only" in its description and body. But `tools` **includes Bash** — `cat > file` is not
  the Write tool, so it routes around `disallowedTools`. In other words "read-only" was **a promise in the
  prompt**, not a property the harness enforces. The prompt stated "do NOT modify anything in the repo" and the
  modification landed anyway.
- lesson: Before claiming you blocked something with permissions, check **whether the remaining tools can route
  around that prohibition** (`platform-contract.md` §6 already warns that "the claim that a violation is impossible
  because the permission is absent quietly becomes false" — this is an instance of that warning). Right before a
  release, **recount the diff size just before committing** and compare it against expectation: this time that
  comparison caught an unapproved edit and kept unclear-origin content out of a public release. Reverting took one `git checkout -- <file>`.

## [category: ssot] Named a canonical source and then tried to paper over drift with "trust this one"

- date: 2026-09-10
- situation: While wiring the `/design` canvas into the design pipeline, I defined the relationship between the
  canvas and `MASTER.md` as "the canonical source is MASTER.md, the canvas is a copy. If they disagree, trust MASTER.md."
- mistake: Two errors stacked. (1) **I mistook jurisdiction for a copy relationship** — the two documents share
  only the overlapping set (colors · fonts · signature), and the rest (tokens vs screen composition) is mutually
  exclusive, so reading only `MASTER.md` loses the composition. If it were a copy you could read one; with split
  jurisdiction you must read both. (2) **"Trust" is a priority rule, not a detection rule.** A mismatch within
  the overlapping set is a defect, not something to tolerate, and setting only a priority lets drift accumulate
  silently. The user caught both with "shouldn't they not disagree? shouldn't it tell me the diff?"
- lesson: When two artifacts come to hold the same value, first **state the set where their jurisdictions
  overlap**. For the non-overlapping part each is canonical, so **a reading rule** (which one to read when) must
  follow; the overlapping part is handled by **detection, not priority** — a script if a machine can decide it,
  and an explicit statement that a human looks if it cannot (prose, etc.). A rule ending in "trust this one" is drift condoned.

## [category: trigger] Wrote a stage as "optional" and made it decoration with no firing condition

- date: 2026-09-10
- situation: In the same wiring, I wrote the canvas stage's firing condition as "when there are 2 or more
  screens or when the user wants it (optional)".
- mistake: "When they want it" is a mood, not a decision criterion. A stage with no firing condition sits in the
  pipeline and nobody ever steps on it — it surfaced when the user asked "so when does this trigger? is it
  possible it never gets used?" I put the default at "optional" on the grounds that the tool might be absent, but
  that is **absence handling** (undecidable), not **a firing condition**. I mixed the two.
- lesson: Write a stage as **invoke by default + explicit exceptions**. Write one machine-decidable firing
  condition (1 or more new or redesigned screens) separately from an enumerated list of skip cases (tool absent =
  undecidable · user declined). The fact that tool availability is uncertain is not grounds for making a stage
  optional; it is grounds for creating an exit 2 path.

## [category: false-negative] Read every line of a guard's code and gave P2 "met", then injected cases outside the fixtures and got 3 bypasses · 5 false positives

- date: 2026-09-12
- Guard: evaluation method — judging P2 firing accuracy by reading the code (not a false positive of the hook itself)
- situation: In harness evaluation v8 I read `security-check.sh` · `build-gate.sh` line by line and judged P2
  "met" on the basis of `--self-test` 91/0/0. The same day, in v9, isolated injection of cases absent from the
  fixtures let `git push origin +main` (refspec force push) · `--delete main` · `:main` pass with exit 0, while
  build-gate failed to recognize the bare `pytest` · `python -m pytest` · `tsc --noEmit` prescribed by the fastapi
  preset as a run — a false positive **blocking the very session that ran its own prescription** — and conversely let `echo npm run build` through.
- mistake: I counted "I read it" as "I poked it". Reading code confirms *intent*, and a fixture confirms *the
  cases the fixture knows* — neither says "there is no case I do not know about". Same axis as v6 E-21 (one
  exemption string opened the destruction gate wholesale while every fixture stayed green), and back then I added
  "bypass-attempt fixtures" to P2-⑤, but **the evaluation procedure** never got "poke outside the fixtures". Nor
  had I ever fed the own prescription (`commands.test` in `presets/*.json`) into the gate's recognizer — the
  prescription and the decider live in the same repo, and no check ever put them side by side.
- lesson: **Judge a guard's P2 only by injection.** For each gate, inject in isolation cases absent from the
  fixtures (bypass candidates · own prescribed commands · substring traps) and record the result in the
  measurement column — pinned as one line in Step 2 of the evaluation skill. And when there is a decider,
  **feed the repo's own prescriptions into that decider** (pinned in `--consumer` with 5 cases: `pytest -q` · `python -m pytest` · `echo npm run build`).

## [category: drift] Wrote "AI mode" into a SKILL.md and left it unimplemented for 4 months — documentation makes the model call a feature that does not exist

- date: 2026-09-12
- situation: While investigating the image-generation wiring I found that
  `marketing/skills/web-asset-generator/SKILL.md` declared a "hybrid generation engine: Pillow + **Nano Banana 2**
  (optional for OG images)" and an "**AI mode**: prompt-based generation after checking the API key".
  Tracing the real files, **none of it existed** — no AI-mode script in `scripts/`, nothing like `--ai` among the
  6 argparse arguments of `generate_og_images.py`, 0 lines of key-checking logic in `check_dependencies.py`,
  0 procedures in `references/`, and 0 related environment variables anywhere in the repo.
- mistake: The "declaration ↔ reality" check compared only **numbers** (skill count · node count · line count)
  and never compared **capability declarations**. Numbers are machine-countable, so a check got attached; feature
  claims written in prose are not countable, so nobody looked. Several rounds of doctor hardening passed through
  in the meantime, and these two lines passed every time — because they were not a wrong number but **an absent feature**.
- lesson: The model reads SKILL.md as **an executable instruction**. A capability declared without an
  implementation is not dead documentation but **a failing path** — if the model picks that mode, there is
  nothing to call. When you write a feature, write the call path (script · arguments · decision procedure) in the
  same place, or **point at another asset that actually exists** (this repair took the latter — `/image-generator`).
  "I will add it later" belongs in the body as the fact that it is unimplemented, or it should be removed entirely — not left as a comment.

## [category: verification] Three web sources agreed and all three were wrong — do not say "it is possible" without a real smoke test

- date: 2026-09-12
- situation: While investigating "can we hand image-generation requests to Codex?", I cross-checked 3 web
  sources (2 technical blogs · 1 OpenAI API doc), and all three said "the Codex CLI has a built-in `image_gen`
  tool and it runs on ChatGPT authentication, so no API key is needed". I went as far as confirming that local
  auth was `auth_mode: chatgpt` and **built the plan on that premise.** In a real smoke test right before
  implementation, `codex exec` returned `TOOL_UNAVAILABLE`, the `codex app-server` path the plugin uses did the
  same, and when I made the model enumerate its tools, `image_gen` was not there.
  `codex features list` reported `image_generation` as `stable/true` and it still failed —
  the built-in tool was **desktop-app only**, and the "Codex" the sources spoke of was not the CLI.
- mistake: I mistook the **independence** of the cross-check. If 3 sources copy each other or cite the same
  upstream document, they are 1 source, not 3. On top of that, having confirmed "it is installed" (0.154.0) and
  "it is authenticated" (chatgpt) felt like evidence of "the feature exists", and those are three different facts.
  Even the flag being on did not mean the tool existed.
- lesson: **A plan that depends on an external capability is not approvable until you have called that capability once.**
  Even for a call that costs money, poke it once with the cheapest option — here a single free call overturned
  the entire premise of the plan, and had I started implementing, the whole wiring would have been thrown away.
  Fix the order of decision: installation check → authentication check → **tool list check** → real call.
  The first three are premises of the fourth, not substitutes for it.

## [category: workflow] Chose parallelism "because it is possible" — order is set by the cost of change, not by possibility

- date: 2026-09-13
- situation: While promoting the internal order of a single feature onto a resident card, I wrote row 3 as
  "since there is a contract, frontend and backend can run in parallel". The user pointed out that planning
  changes even after design is done, and those changes peak while the UI is being verified, so running in parallel makes the backend eat them twice.
- mistake: I had written "ordered by cost of reversal" in the same table and then decided row 3 alone on the
  grounds of "it is possible". That a contract prevents mismatch and that parallelism is cheap are different
  propositions, and I let the former imply the latter.
- lesson: The basis of an order is not "is it possible?" but "if it changes, who pays again and how much?" Put
  the expensive thing after the stretch where change concentrates — and check row by row that the table's
  principle was applied at the same strength in every row. A row that contradicts the principle means either the principle is wrong or the row is.
