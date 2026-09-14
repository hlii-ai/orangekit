# Axis pack resource structure template

**This is the only document an L1 authoring agent reads in order to match the format.** It was extracted once from the 5 existing packs
(`nextjs` · `react-vite` · `vue` · `supabase` · `aws-container`).

> **Do not open another pack or guide.** The old spec put up the firewall "reference the format only, never copy content"
> as an instruction, and **it failed under measurement (2026-08-23)** — a broken `safeReturnTo` was copied verbatim
> from the react-vite pack into the vue pack, and the same defect was in all four shipped
> copies. An instruction does not block it. The format comes from this document; the content comes from stack knowledge.
>
> This document is also the common baseline for parallel authoring. Splitting the clusters makes tone, density, and notation
> diverge, and this is what holds them together.

## 1. File header

```
<!-- orangekit-pack: <axis>/<pack> v<version> -->
# <file topic> — <one-line subtitle>

<1~3 lines of introduction. What this file owns and what it does not.>
```

If something is not owned here, write **which path owns it**. A reference without a path
is unreachable. If it is the seam's share, say so — a pack that looks empty and a slot for the seam
to fill are different things.

## 2. Section skeleton

**Use numbered `## N. Title` headings.** If the file owns a code file, attach its path to the heading.

```
## 1. Decision tree
## 2. Writing the store (`src/stores/uiStore.ts`)
## 3. Subscribing — `storeToRefs` is required
...
## Misuse list ① — <old tool/version> → <current> idiom comparison table
## Misuse list ② — confusion pairs
```

- 6~9 body sections. The last two sections are **always misuse lists** (the spec's misuse obligation)
- The first section is a **judgement**: "what to choose when", shaped as a decision tree · a criteria table ·
  a client matrix. The choice comes before the method
- **Write the prose in English.** Technical terms in code, identifiers, and table headers stay in their original form
  (a pack whose prose is in some other language is drift — do not follow it)
  - This is **this repository's pack-authoring convention**, not the consumer output norm. A pack resource is an asset the model
    reads, so it does not follow the project's response language (T0 "Language") — the two are different layers

## 3. The two misuse-list formats

These are the two formats the spec requires, and the table headers are fixed as well.

```markdown
## Misuse list ① — Vuex → Pinia idiom comparison table

| Old habit (Vuex) | Current shape (Pinia) |
| --- | --- |
| Change state only through `mutations` | Assign directly inside an action |

## Misuse list ② — confusion pairs

| Frequently chosen wrongly | The exact condition for applying it |
| --- | --- |
| `storeToRefs` vs destructuring | State and getters take the former, actions the latter |
```

**Write only misuses actually observed on the confirmed stack and version.** Do not write generic "common mistakes".

## 4. Marking good and bad examples — this is a convention the gate reads

The gate's `codelines()` uses these marks to exclude anti-pattern ranges. Break the convention and **the pack gets caught
violating its own policy** (it trips on its own bad example).

| Situation | Mark |
| --- | --- |
| A language with `//` · `#` · `--` comments | `// ❌` / `// ✅` on a comment line **inside** the fence |
| A `.vue` · HTML · JSX markup fence | **❌ on the prose line immediately before the fence** |

The second one matters. The only comment prefixes `codelines()` recognizes are `//` · `#` · `*` · `--`,
so **an HTML comment (`<!-- ❌ -->`) is counted as a code line.** For a bad example in a markup fence,
always put the ❌ in the prose before the fence.

An identifier containing `BAD` or `Good` (`BAD_SHAPE` · `BAD_REQUEST`) is not a mark —
the gate tells them apart by excluding `_` and digits at the word boundary, but using `❌`/`✅` as the mark is safer.

## 5. Marking code files — this is the input to execution verification

There are **two** marks. Mix them and `pack-smoke.sh` mistakes an excerpt for a complete file and produces a false positive.

| Mark | Meaning | How pack-smoke treats it |
| --- | --- | --- |
| `// src/foo.ts` as the fence's first line | **Label** — tells which file this fragment belongs to | Restored, but no syntax or type check is applied |
| `<!-- file: src/foo.ts -->` on the line before the fence | **Complete-file claim** — this fence alone is that file | Subject to the syntax and type checks |

```markdown
<!-- file: src/lib/safeReturnTo.ts -->
```ts
// src/lib/safeReturnTo.ts
export function safeReturnTo(raw: unknown, fallback = '/tasks'): string {
  ...
}
```
```

- **Always attach `<!-- file: -->` to these three classes**: security primitives · configuration files ·
  test harnesses. Every defect measurement caught by running was in these (return path validation ·
  the msw handler · the vite config · the mount harness)
- An idiom that shows only part of a config (`resolve: { alias: ... }`) is a **label**.
  Claim it as a complete file and it is ruled a fragment and warned about
- Even when several fences claim the same path, **they are not concatenated** — each fence is an independent unit
- The security vector test looks for the function under **both** marks. Even with only a label, the vectors run

## 6. Density and budget

| Item | Target |
| --- | --- |
| A file | ≤300 lines (gate FAIL) · WARN from over 290 lines |
| One section | 20~40 lines |
| Code fences | 1~2 per section, 5~25 lines each |
| Prose : code | Roughly 1 : 1.5 — with only code there is no "when to use it"; with only prose it cannot be written |

**Do not run up against the budget ceiling.** In a file that has reached 300 lines, the next change lets the budget,
not the author, pick what gets deleted.

## 7. Tone

- Write only verifiable facts, and write them **declaratively**. If you are not confident, do not write it —
  **an empty slot beats wrong content** (if you left it empty, state it in the report as an "empty slot")
- Attach the "why" in one line. A rule alone is not kept; with a reason behind it, it gets applied
- Write what you confirmed by measurement in those words ("run confirmed" · "measured")
- **Tag version claims** — when you write something of the form `added in vN / removed in vN` · `now requires` · `no longer`,
  attach `<!-- verified: <evidence> -->` or `<!-- unverified -->` on the same line or the line
  immediately before. The gate collects untagged claims as WARNs and hands them to audit B.
  Measured, 5 of this class were false — the model does not know that it is wrong
  - **Attach the tag on the same line.** Attribution to the previous line is recognized only when that line is
    **a standalone comment holding nothing but the tag**. Inside a table, put it in the last cell — a comment line between rows breaks the table.
    If one tag covers every table row that follows, **untagged claims evade the check while appearing to pass it**
  - **A "(run confirmed)" in prose is a claim too.** The gate collects it, but a tag that records the evidence
    with it is better. Measured, **3 of the 4 false claims were clustered in untagged "(run confirmed)" blocks** —
    the defects survived only where the tagging discipline had not reached

## 7-B. No circular verification — when "run confirmed" is not verification

**Reading back a value you put into a fixture you built yourself is not verification.**

Measured (2026-08-23): an author tagged the `meta.cause` wording of Prisma `P2025` as "run confirmed", but
that wording was **a value they had put into an error object they had built by hand themselves**. What the real library produces
was different, and the audit caught it. The author's own report: *"marking that as run-verified was
circular verification."*

| What is verification | What is not |
| --- | --- |
| Read a value the library or runtime **produced itself** | Read back a field of an object I constructed |
| Compared the installed copy's `.d.ts` and source down to the line number | Wrote a plausible-looking API shape from memory |
| Measured output produced by a real request, process, or DB | The stub responded the way I expected |

Needing a stub is normal (seam symbols cannot be resolved by the pack alone). **In the tag, separate what you confirmed with a stub**
**from what you confirmed against the real thing** — write down the scope, as in `<!-- verified: wiring confirmed with a
stub, not verified against the real thing -->`. When a tag **claims properties of an unconfirmed area beyond**
**the scope it actually confirmed**, that is the archetype of a falsehood.

## 7-C. If you carry a test, prove that it blocks

**A test with only negative assertions is not a guard.**

Measured: an ownership regression test presented as "the most expensive test on this axis" asserted only `expect(404)`, so
replacing the whole query function with `return null` still went green — **because then everything is a 404.**

```ts
// ❌ passes even when the implementation is failed wholesale
it("reading someone else's row returns 404", async () => {
  expect((await get(other.id)).status).toBe(404);
});
```

Assert the positive path **as a pair inside the same `it`** — only an assertion that the owner gets a 200 on their own row
separates a 404 that means "blocked" from one that means "everything is broken". The gate's `check_blocking_proof`
raises a test file that has only failure assertions to REVIEW.

## 8. Security primitives are the exception here

Path validation · token comparison · escaping · redirect validation are written fresh **in content, not only in
format.** Actually run the relevant vectors of `assets/security-vectors.md` against your implementation and
carry the results in the returned data. The gate's `check_security_shapes` blocks two known vulnerable
shapes with a FAIL, but **what it blocks is only the shapes it already knows**.
