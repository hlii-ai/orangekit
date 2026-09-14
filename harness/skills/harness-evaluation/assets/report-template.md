# Harness (graph) evaluation v{N}

- date: {YYYY-MM-DD} · HEAD: {short-hash} · plugin: {version} · asset commits since the last report: {N} · uncommitted assets: {N} files
- point-in-time stamp: Claude Code {version} · model {name} · {date} — the basis for the P6 judgement (re-survey {performed or skipped — reason})
- doctor `--all`: passed {N} · warnings {N} · failures {N} · resident cost {N} bytes · fixtures {N}

## Verdict per axis

| axis | measurement (state what was not measured) | verdict |
| --- | --- | --- |
| P1 routing and canonical-source consistency | {summary of machine output} | {met or partially met or unmet or unmeasured — basis} |
| P2 firing accuracy | | |
| P3 loop termination | | |
| P4 feedback closure | | |
| P5 path cost | | |
| P6 structural restraint | | |
| P7 boundaries | | |
| P8 consumer journey | | |

## Per-area summary (1 row per `doctor --inventory` area — "no defects" is also a verdict)

| area | inventory figure | this round's defect IDs | one-line verdict |
| --- | --- | --- | --- |
| skills | {N · resident desc N B · largest SKILL.md N lines} | | |
| rule cards | {N cards, N lines · always-on N} | | |
| hooks | {N scripts · N blocking points · N fixtures} | | |
| agents | | | |
| guide packs and seams | | | |
| references, templates, presets | | | |
| documents (README · docs) | | | |
| check scripts (doctor, etc.) | | | |
| graph | {N nodes · N edges · N instrumented edges} | | |

## Defect list (by severity)

| ID | severity | file:line | failure scenario | intervention point | fix direction | disposition |
| --- | --- | --- | --- | --- | --- | --- |
| E-{NN} | {Critical or Important or Suggestion} | | {what breaks on which input} | {① briefing or ② decision point or ③ checkpoint or ④ after-the-fact recovery} | | {fix or defer (reason) or accept} |

With 0 defects, leave the table empty and write "none — 8 axes met". That is a legitimate result.

## Reviewed but not intervened in

| target | why no intervention |
| --- | --- |
| {the asset or structure reviewed} | {the reason — cost · a designed choice · undecidable, etc.} |

※ A Critical counts only when backed by isolated reproduction (fixture or `ORANGEKIT_STATE_DIR` injection) — write the reproduction command and the exit code. Grounds from reading documents top out at Important.

## Narrowing proposals (at least 1 **review** — not a duty to propose · if none, "none + reason")

| target | reason (excess or duplication or vagueness) | replacement path | regression risk |
| --- | --- | --- | --- |

## Compared with the previous round (when v{N-1} exists)

- defects: Critical {N}→{N} · Important {N}→{N} · Suggestion {N}→{N}
- new: {list of IDs} · resolved: {list of IDs} · remaining: {list of IDs}
- resident cost: {N}→{N} bytes · false-positive history: {N}→{N} (archive {N})

## Uncertainty map

| item | state | why | closing condition | where |
| --- | --- | --- | --- | --- |
| {what could not be measured} | {measured or unmeasured or impossible here} | {the reason — do not fill it with guesses} | {what would close it} | {here or consumer or platform} |

## Feedback (what this round left in lessons)

- {retraction · false positive · an error in the evaluation's own verdict → the `docs/lessons.md` entry title · whether it moved to the archive} — if none, "none"
