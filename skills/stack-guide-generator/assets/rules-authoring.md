<!-- stack-guide-generator only. The rules mode in SKILL.md's "Mode" section calls it.
     It is not read in full mode (the detailed guide). -->

# Rules generation mode — the stack rule file for a stack with no pack

An axis with no pack (rust-axum · flutter · ios-swift · android-kotlin · native-dual · custom and the like) receives only the universal rules (L1 `security.md` and the rest)
and `code-conventions.md`. This mode makes that axis a **project-owned stack rule file** `.claude/rules/stack-<axis>-<stack>.md`.

> **Evidence comes only from outside the model.** A "best practice" the model wrote from its own knowledge writes down only what the model already knows —
> circular, and worth nothing. An item that cannot be backed is not left as "needs checking"; it **is not written.** Three items is normal, and if not even one can be backed, no file is created.

## Input and output

| | |
| --- | --- |
| Input | the axis (`frontend` · `backend` · `app`) · the stack name (`techStack.presets.<axis>`, or the framework the user typed if `custom`) · that axis's source directory |
| Output | `.claude/rules/stack-<axis>-<stack>.md` — the stack name is lowercase-hyphenated. **No stamp** (project-owned — the same as `code-conventions.md`) |
| `paths:` | **only that axis's source directory** out of the `paths:` in the `project-structure.md` that init Step 7.5 made. If it is wrong, the card is never loaded |

## Evidence — there are only two

| Evidence | Content |
| --- | --- |
| ① Installed version vs the model's knowledge | read the version the project actually uses, then pick out of the **official** changelog and migration docs only the changes the model might write in the old form. **URL · check date · installed version are required** |
| ② Run check (optional) | a pitfall confirmed by running a small reproduction on that stack's toolchain. Only when the toolchain is **already installed** and the reproduction fits in one file — if it needs an install or a build, do not. Run it only in `.orangekit/scratch/rules-<axis>/` |

**Do not write**: "best practices" from model knowledge · universal security (L1's territory) · values at a decision point (path prefix · id type · envelope · status codes belong to `code-conventions.md`) ·
changes that compilation, tests or lint catch (a broken build gets fixed without a rule — a rule is worth something only for what **passes silently**).

## Procedure

**R0 Can it be judged at all.** First see whether web lookup (WebSearch · WebFetch) is available. If it is not, or you are offline, **create no file** and
report "evidence could not be confirmed, so nothing was created — only the universal rules apply". Do not fold "cannot judge" into a file with no evidence (the same principle as `rules/harness-change.md`, "A Guard Has Three States").

**R1 Target packages and versions.** 3~6 core dependencies of that axis — framework · runtime / data access · DB driver / auth / toolchain.
Read the version in this order: lockfile → manifest → (a new project with no manifest yet) the registry's latest stable release.

| Ecosystem | Files to read |
| --- | --- |
| Rust | `Cargo.lock` · `Cargo.toml` |
| Dart · Flutter | `pubspec.lock` · `pubspec.yaml` |
| Swift | `Package.resolved` · `Package.swift` |
| Kotlin · Android | `gradle/libs.versions.toml` · `build.gradle(.kts)` |
| Go | `go.mod` |
| JS · TS | `package-lock.json` · `pnpm-lock.yaml` · `package.json` |
| Python | `uv.lock` · `poetry.lock` · `pyproject.toml` · `requirements*.txt` |

**R2 Collect the changes.** For each package, open the official doc site's changelog and migration guide and the official repository's CHANGELOG and release notes.
An item becomes a candidate only when it satisfies **all** of these:

1. The docs state the change **holds at the installed version** (the version is written in the doc)
2. It differs from the earlier form — the model may write the earlier idiom
3. Compilation, tests and lint do not catch it
4. Its class is one of `[consistency]` (a decision point) · `[security]` (where this stack leaks) · `[performance]` (integrity that breaks silently)
5. It does not overlap L1 or `code-conventions.md` — write only **how** it goes wrong on that stack

A package whose docs cannot be opened is **skipped** and noted in the report. Do not fill it in from memory.

**R3 Write.** The format and budget are canonical in `guide-skeleton.md` "Stack core card" (body 3,000 characters · at most 12 items · a precedence sentence at the top). Only the evidence comment differs:

```markdown
---
paths:
  - "<that axis's source directory>/**"
---

# <stack> rules

The project spec and `code-conventions.md` take precedence over this card.

- [performance] <what to do / not to do>. — why models get it wrong: <one line> <!-- evidence: <official URL> · installed: <package>@<version> · checked: <YYYY-MM-DD> -->
```

An item with no evidence recorded in R2 is not written. If you confirmed it by ②, append ` · run: <reproduction file path>` to the evidence comment.

**R4 Gate.** The main session runs it itself (the generator's self-report is not evidence):

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/guide-gate.sh --rules-card .claude/rules/stack-<axis>-<stack>.md
```

Fix until FAIL is 0. This gate looks only at form (that the URL · date · installed version exist) — **whether the URL really supports the item is R5's job.**

**R5 Independent verification (once).** Without giving the generation context, hand only the card file to `Agent` (`model: "haiku"`). Have it open each item's URL and judge
① does the doc contain that claim ② does it hold at the installed version, and return a TSV (`item number · true|false|unverifiable · reason`).
Items that are `false` or `unverifiable` are **removed, not repaired** — an item that cannot be backed is not written. Run R4 again after removing. Do not launch a re-verification.
The only working directory is `.orangekit/scratch/` and it is wiped with `rm -rf .orangekit/scratch` when done (the same as "Audit and repair budget" ③).

**R6 If zero items remain,** delete the file. The report is "no item with evidence — only the universal rules (L1) and `code-conventions.md` apply". This is a normal outcome, not a failure.

**R7 Report.** The file path · item count · the count and reason for excluded items (lookup failed · R5 false/unverifiable) · skipped packages · **the version basis** (for a new project,
"based on the registry's latest — if the project pins another version, re-check those items").

## Updating and retiring

- When an item's `installed:` differs from the version the project actually uses, re-check that item or delete it — a card that only grows becomes a general guide again.
- When the model changes, the items that pass again without them should be dropped first. The measuring tool exists only on the maintainer's side (no consumer-side means — a separate decision).
