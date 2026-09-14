# Lessons — Archive

Only entries whose promotion or narrowing is **complete as an asset diff** are physically moved here (`rules/lessons.md`, "why the evidence is pinned to two things").
Disappearing from `docs/lessons.md` is itself the proof that the loop closed.

## [category: tooling] A promotion check that matched a bare word marked every category promoted

- date: 2026-09-13
- promotion complete: 2026-09-13 — the fallback in `doctor --lessons` now requires the card to **name** the category (in a heading, or as a backticked token) instead of containing it anywhere
- situation: `doctor --lessons` decides whether a lesson category has been promoted by looking for a rule card.
  Rule ① is a filename match; rule ② was `grep -rli "$cat"` over the cards. The category names are ordinary
  English words, so once the cards were English the fallback matched everything: `naming` resolved to
  `data-modeling.md`, `drift` to `ui-design.md`, `tooling` to a table cell reading "Docs · tooling/environment".
  Every category came back "promoted" and the candidate warning could no longer fire.
- mistake: The same repository in Korean reported the candidate correctly, because English category names rarely
  appear in Korean prose. The check was never robust — it was **accidentally correct in one language**, and
  translating the corpus took the accident away. I only noticed because the two repositories disagreed about the
  same three lessons, and a verdict that depends on which language the prose is in is not a verdict.
- lesson: When two copies of the same check disagree, the interesting one is not the copy that complains but
  **the one that stays silent**. And a checker keyed on ordinary words of the corpus's own language has no
  defence: give it a stronger signal (a deliberate mention — heading or backticked token) or drop the heuristic.

## [category: tooling] A detector written in the corpus's own language went blind when the corpus changed language, and reported a green tick

- date: 2026-09-13
- promotion complete: 2026-09-13 — self-probe added to `check_claims` in `skills/stack-guide-generator/scripts/guide-gate.sh`: one probe line per claim branch plus two near-misses, asserting the exact set of matched line numbers
- situation: While republishing this harness in English, `check_claims` — which inventories version claims in pack
  prose so audit B has something accurate to work from — turned out to have four of its five branches written as
  phrases in the corpus's own natural language. The moment the packs were English it matched almost nothing and
  printed `no version claims` over a pack that holds 79 of them.
- mistake: I translated the patterns and treated that as the whole job. It was not, in both directions. The
  translated detector first went silent, and then my English rewrite over-fired — it read `cannot be reproduced
  locally` and ordinary uses of `no longer` as version claims. **Neither failure is visible from the output:**
  `ok "no version claims"` and `! untagged version claims: 3` look equally healthy, and the only reason I caught
  either was that I happened to diff the claim inventory against the pre-translation baseline. The gate carries 55
  self-test fixtures and not one of them exercised this detector.
- lesson: A check whose failure mode is **silence** cannot be covered by a fixture that happens to pass; it needs a
  probe it runs against itself on every invocation. And the probe must carry **one line per branch** — the first
  version of this probe used two lines that each tripped several branches, so deleting a whole branch still left it
  green. Assert the exact set of lines that matched, not the count.

## [category: tooling] A grep that recognises a call site by substring counted the same substring inside a comment

- date: 2026-09-13
- promotion complete: 2026-09-13 — the two loose greps in `scripts/doctor.sh` anchored to line start, the form the same file already used for its instrumentation table
- situation: doctor derives the real number of block reasons by grepping `(dblock|block) "…"` out of
  `security-check.sh` and comparing it with what the manual claims. A comment explaining the UI gate contained the
  words `block "what must not happen now"`, so the derived count became 25 against a real 24 — and the manual,
  which correctly said 24, was reported as the thing that had drifted.
- mistake: The right form was already in the same file, 1,600 lines further down: the instrumentation table anchors
  the identical grep at line start, which a comment cannot satisfy. There is also a comment-stripping helper,
  `code_lines`, used by the neighbouring lint and not by these two. I read the loose call sites as "how this repo
  does it" instead of comparing them against their own siblings.
- lesson: When a checker derives a number from source text, **the strict form and the loose form usually both exist
  in the same file.** Find the sibling before trusting either. A checker that cannot tell code from a comment will
  eventually be handed a comment — it is only a question of who writes it.

## [category: freshness] Hand-written file sizes rotted, and three of the four live claims were wrong

- date: 2026-09-13
- promotion complete: 2026-09-13 — file-size claim check added to the numeric-claim section of `scripts/doctor.sh` (resolves the path, compares `wc -l`, tolerates `~` within 15%, skips `lessons.md`/`lessons-archive.md`)
- situation: Skills tell the model how large a reference file is so it reads only the section it needs
  (`references/service-frameworks.md` is N lines). Measuring the four live claims of this shape found three stale:
  1,132 against a real 1,225, 291 against 308, and `~982` against 250 — the last one off by a factor of four, in a
  reading budget the model is meant to act on.
- mistake: doctor already cross-checks a dozen numeric claims — skills, rule cards, graph nodes, hook counts — and
  the document that says so even records the doctrine that *a number written by hand is certain to go stale*. This
  shape of claim simply was not in the list, and being adjacent to a well-guarded class made it look guarded.
- lesson: A drift checker covers **shapes of claim, not documents.** When adding one, enumerate the shapes in which
  the repository states a number, not the files it states them in. The excluded case matters too: an entry in
  `lessons.md` records a number that *was* wrong at the time, and "correcting" it would destroy the evidence.

## [category: false-positive] A heredoc writing documentation was blocked by the destructive-command gate

- date: 2026-09-08
- Guard: scripts/security-check.sh
- narrowing complete: 2026-09-09 — heredoc body stripping + segment-level decision (`_strip_heredoc_bodies` · `_segments`), fixture `PreToolUse-bash-heredoc-authoring-ok.json`
- situation: While explaining "what blocks me" in the harness map (`docs/getting-started.md`), I wrote
  destructive DDL names into the body as examples of what gets blocked. I wrote the file with a
  `python3 - <<'PY'` heredoc, and `destructive_gate` in `security-check.sh` saw that string and blocked with exit 2.
- mistake: Not the gate's fault — **it is a problem of the exemption's scope.** `_authoring_cmd` already holds the
  accurate judgement that "a command writing text into a file is not the execution of destruction", but that
  judgement is narrowed to `cat|tee|printf|echo` only. An interpreter heredoc (`python3 - <<'PY'`) is authoring of
  the same nature but sits outside the list, so it trips. This session was in shell-first mode, so every edit had that shape.
- lesson: I did not slip past it with a workaround (splitting the string); **I made the same edit with a
  different tool and left the gate alone.** Changing a guard's scope is itself a decision point, so ask the user first.
  When `false-positive` for the same device reaches the threshold, the answer is not to add a rule but to
  **narrow the condition** — here the direction is widening, but the principle is the same: grant an exemption **only to a proven shape**.

## [category: false-positive] A commit message, stderr discarding, and a file heredoc body were blocked by the destructive/secret gates, while a self-reference exemption opened a gate wholesale

- date: 2026-09-09
- Guard: scripts/security-check.sh
- narrowing complete: 2026-09-09 — `_self_ref_cmd` · `_message_cmd` · `_writes_file` · heredoc opening-line decision, 8 fixtures (4 positive · 4 benign)
- situation: Harness evaluation v6 reproduced this by injecting directly into `security-check.sh` with an isolated
  state directory (`ORANGEKIT_STATE_DIR`). Three false positives — `git commit -m "fix: drop table legacy_users"` (E-22) · `rg 'AKIA…' . 2>/dev/null`
  (E-23) · `cat > notes.md <<'EOF' … ; psql -c "DROP TABLE t" … EOF` (E-44) — were blocked with exit 2, while
  conversely `bash scripts/doctor.sh --help; psql -c "DROP TABLE users"` passed even the destructive gate
  wholesale via the `*doctor.sh*` substring exemption (E-21, Critical).
- mistake: All four share one root — **the unit of judgement was wrong.** I looked at the whole command as one
  string. Unable to separate the DDL vocabulary in a commit message from the execution chained after it with `&&`,
  exempting leaked and not exempting produced false positives; I read the `>` in `2>/dev/null` as a file write;
  I searched for `; psql` across the whole command instead of the heredoc's opening line, reading a string inside the body as execution; and I keyed the exemption on substring containment, not the first token.
- lesson: **A guard's unit of judgement is the segment (`;` `&&` `||` newline), and exemptions key on the first token.**
  Separate reading, authoring, and message passing per segment and false positives and bypasses vanish in the same
  repair. And **an exemption path is proven by a fixture as strongly as the blocking path** — for the 4 months with
  no bypass-attempt fixture (→ exit 2), this exemption stayed alive. Along with the repair I put a fixture on all
  22 blocking reasons and made doctor check "a fixture exists per reason" (narrowing: the exemption condition was tightened and no rule was added).

## [category: false-positive] Took a file count as evidence of a missing policy and reported a defect that did not exist

- Guard: harness/skills/harness-evaluation (evaluation method — concluding absence from a single observation)
- narrowing complete: 2026-09-09 — built into SKILL.md Step 2 as "a defect claiming absence does three things first" (open the place the policy would live · check the firing condition · the binary on the execution path)
- date: 2026-08-25
- situation: Harness evaluation v2 saw 10 files in `dev/handoff/` and judged it "no rotation, no cap"
  (E-06, Suggestion). The only basis was `ls | wc -l` and `du`.
- mistake: The number 10 was itself **the result of the cap working.** `scripts/handoff.sh:84` keeps only the
  most recent 10 with `ls -1t | tail -n +11 | rm`. That code was already inside the commit v2 evaluated
  (`bacaa9a`) — the evaluation counted files and **never opened the code**.
- lesson: To claim the **absence** of a policy you must actually open the place the policy would live. An observed
  number is not evidence that a policy is missing — **it may be evidence that the policy exists**; two hypotheses
  produce the same observation. The evaluation skill's discipline "do not report if you cannot write the failure
  scenario" did not prevent this case (a scenario could be written — it was simply wrong). What is needed is
  **mandating that the relevant file be opened, for absence claims specifically**.

## [category: false-positive] Read the hook log mid-turn and declared "the hook is dead"

- Guard: harness/skills/harness-evaluation (evaluation method — concluding absence from a single observation)
- narrowing complete: 2026-09-09 — built into SKILL.md Step 2 as "a defect claiming absence does three things first" (open the place the policy would live · check the firing condition · the binary on the execution path)
- date: 2026-08-26
- situation: Harness evaluation v5 read `hookrun.log` at 10:24 and 10:27, saw 0 records for `build-gate`, and
  judged "the Stop hook has never once run in real use" (E-18, Critical). The other 4 hooks had records, and a
  controlled experiment confirmed that a single Write tool call records `security-check` immediately, reaching
  the conclusion "of the 6, only Stop is not delivered".
- mistake: **`Stop` fires per turn completion, not per tool call.** Both observations were made while the first
  turn after a restart **was still in progress** — there was no opportunity for the event to occur at all. When the
  turn ended, `build-gate` was recorded at `10:32:04Z`, the same second as the transcript's Stop summary timestamp
  `10:32:04.965Z`. The controlled experiment was meticulous, but **the premise was wrong, so the rigor reinforced a wrong answer.**
- lesson: **A gap in instrumentation has the same shape as a dead hook.** What separates them is not the log but
  **that event's firing condition**, and that must be confirmed in the platform contract. `docs/platform-contract.md`
  held only the *output format* per event and not *when it arrives* — added as §5.1.
  Generalized, this is the same shape as the preceding false-positive entry: **to claim absence, first confirm the
  conditions under which absence could be observed.** Where the earlier one was "open the place the policy would
  live", this one is "**give the event time to happen**". Both are failures of concluding absence from a single observation.
  (Quoting a category token verbatim in the body makes the `--lessons` tally count a ghost entry — do not quote it.)

## [category: false-positive] Nearly counted a delegated report's defect candidates as defects — second time running

- date: 2026-09-12
- Guard: evaluation method — delegated (Explore) measurement
- narrowing complete: 2026-09-12 — 1 line in `harness/skills/harness-evaluation/SKILL.md` Step 2: "a delegated report's defect candidates go on the list only after opening the file:line yourself and re-confirming". This round applied that discipline first and filtered them out before the report
- situation: In evaluation v7 I handed the codex path and the consumer runtime map to two Explore subagents.
  Two items came back as defect candidates: "`rules/lessons.md` has no version stamp so it is pinned forever"
  and "hook timeout defaults to 60 seconds · silent failure".
- mistake: Both contradicted the current files and the official docs — the stamp is on `:13` (only the first line
  was read), and the default timeout is 600 seconds (declared from memory). In v6 too, 2 Explore reports
  (truncate false positive · a dead check) were wrong. **Once is a hypothesis; twice running is a pattern.** The
  2026-09-02 lesson that a delegated report is a citation, not an observation, existed — but the evaluation skill's procedure had no slot for it.
- lesson: Use delegation to narrow **where to look**, and decide **what is a defect** only from files you opened
  yourself. If that decision hinges on platform behavior, open the official docs unless it is in
  `docs/platform-contract.md` — this round that check changed E-55's severity from Important to Suggestion.
