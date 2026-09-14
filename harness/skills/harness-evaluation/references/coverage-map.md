# Coverage map — the ledger for reorganizing the axes

**When to read it**: only when reorganizing the axes. It does not need reading every evaluation round — if the report table
has all 8 axis rows, this map has already been honored.

**One discipline**: after a reorganization, **if any item in the two tables below ends up with no destination, the reorganization is unfinished.**
A place that does not count does not get counted — when v3 demoted axes 8 and 10 to "judgement inputs", the v1 report
lost every single line on native duplication and model excess. It was not a problem with the items' worth but with their placement.

## 1. Destinations of the construction axes (v2 10 axes → v3 5 axes → 7 axes → 8 axes)

| construction (v2) | v3 destination | 7-axis destination | 8 axes (current) |
| --- | --- | --- | --- |
| 1 entry discipline | P5 + P2-① | same | same |
| 2 token efficiency | P5 | P5 — measured resident cost via `--usage` | P5 — `--inventory` also supplies **on-invocation and conditional card costs** |
| 3 confirmation-bias prevention | P2-①② | same | same + **the Step 2 reproduction procedure** |
| 4 context continuity | P4 + P2-③ | same | same |
| 5 incremental governance | P1 + P5 | same | same |
| 6 self-improvement | P4 | P4 — promotion + narrowing | same + the `eval-report → lessons` edge |
| 7 security | P2-③ | P2-③ (blocking power) + P7 (crossing boundaries) | same + P2-⑤ **bypass-attempt fixtures** |
| 8 native duplication | judgement input to P2 and P5 | reduced to a P6-② item | same |
| 9 SW foundation | a precondition of P2-③ | same | same |
| 10 model excess | judgement input to P5 | reduced to a P6-① item | same |

## 2. The 10 request perspectives → 8 axes (2026-09-09 · introduced in evaluation v6)

These are the ten perspectives the user asked for as a "multi-angle exhaustive inspection". Three of them (①⑦⑧) had no place in the 7 axes.

| # | request perspective | destination | source of the machine verdict |
| --- | --- | --- | --- |
| ① | per-area review (skills · rules · hooks · agents · guides · refs) | the report's "per-area summary" section — 1 row per area | `doctor --inventory` |
| ② | the whole workflow | P1 (routing card ↔ graph ↔ hbs ↔ T0, all four compared) | `--fast` "rule reachability" · `--graph` G6·G9 |
| ③ | graph engineering | P1 measurement column + P4 | `--graph` G1–G10 |
| ④ | is it invoked as the process says | P2-①② | comparison against the graph declaration · agent frontmatter |
| ⑤ | invoked, referenced, and generated as intended | P2 + P1 reference existence + P4 | `--fast` "skill-internal references" · G7 |
| ⑥ | false positives · errors · duplication · over-engineering | P2-④ + P6 + **Step 2 reproduction** | `--self-test` benign fixtures · `--lessons` per guard |
| ⑦ | the user's (consumer's) point of view | **P8 consumer journey** | `--consumer` · "declaration ↔ reality" skill names and tool lists |
| ⑧ | uncertainty map | the report's "uncertainty map" section (a table) | the explicit unmeasured items in each axis's measurement column |
| ⑨ | token cost | P5 (resident + on-invocation + conditional `paths:` width) | `--usage` · `--inventory` |
| ⑩ | overall optimization | P5 + P6 → "narrowing proposals" | — (judgement) |

## 3. Where the new items came from (nothing is invented out of thin air)

| new item | origin |
| --- | --- |
| P2-④ false positives | the three-state discipline existed in `rules/harness-change.md`, but no axis instrumented it |
| P2-⑤ bypass | v6 E-21 — one exemption string opened the destruction gate wholesale and no fixture ever attempted a bypass |
| P6-③ vagueness | a generalization of evaluation v1's E-02, "a warning that will not turn off teaches people to ignore it" |
| P7 boundaries | no axis looked at leakage through the external model loop (codex) or the unbounded residue in `dev/handoff/` |
| **P8 consumer journey** | v6 E-32 (7 skills missing from the consumer docs) · E-33 (redefinition semantics contradicting across two documents) · E-24 (T0 pointing at a location that does not exist) — all three are the one class of "a consumer following the docs diverges from reality", and none of the 7 axes had a place for it |
| the Step 2 reproduction procedure | both false positives, v2 E-06 and v5 E-18, **concluded absence from a single observation**, and v6 E-21 could not have been a Critical without reproduction |
| the "per-area summary" and "uncertainty map" sections | request perspectives ① and ⑧ — a prose list is not a place that counts |
