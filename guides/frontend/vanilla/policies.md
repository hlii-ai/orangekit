<!-- orangekit-pack-policies: frontend/vanilla v3.14.0 -->

# vanilla pack — cross-file invariants (L0 draft)

The gate checks **whether the pack itself and the seam obey the policies this pack declares**. When the place that
declares a policy and the place that enforces it differ and nothing obliges anyone to reconcile the two, a policy survives only as documentation — this file is that obligation.

## Machine checks (gate `check_policies` · `check_pack_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad section.
Count prose and anti-pattern examples and every hit is a false positive.

**The `proof example` column is mandatory** (the gate FAILs without it). The gate asserts ① does the example match its own regex
② for `forbid`, is that example absent from the target files.

**Narrow a `require` down to its owning file.** Besides `guide`·`seam`, `scope` also takes **`file:<filename>`**.
Leave it at `guide` and it degenerates into "one occurrence anywhere in the pack passes", and it grows **more
powerless the more files there are** — in the fastapi measurement audit C confirmed by running it that deleting the
owning file's check outright still let the policy pass, because a sibling file carried the same string.

**Do not use markdown emphasis in a `scope` value.** `**seam**` is not recognized as a scope, so the policy
silently targets every file — that is exactly what happened in the vue pack.

**A `require` regex targets the "enforcement point", not the definition.** File-level degeneration ("one occurrence anywhere in the pack passes") was already blocked by narrowing with `file:`, but **the same degeneration reappeared at line level** (audit C, run confirmed): the name `safeReturnTo` appears 13 times in its owning file and **only one of those lines is the enforcing call**, so deleting that one line still produced **0 FAILs** because the definition·tests·prose satisfied the regex. A regex that asks "does the name exist" is a dead policy — it has to ask for the **call form**.

**Do not use an alternation group in a regex.** The broader branch alone satisfies it and the narrow path you meant to
verify is never measured at all. Check the regex against a string it **must not pass** as well.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-entry` | forbid | guide | `import\.meta\.env` | `types-and-testing.md` | `const base = import.meta.env.VITE_API_BASE` | `import.meta.env['VITE_API_BASE']` | Environment values are read in exactly one place, `config`. When another file reads them directly, both the validation and the boot-time failure are bypassed. **Vite inlines this expression as a string at build time**, so a secret put there is baked into the bundle — one reading site is what keeps that review in one place |
| `no-inner-html` | forbid | guide | `\.innerHTML[[:space:]]*[+]?=` | — | `row.innerHTML = task.title` | `row.innerHTML += task.title` | **There is no framework auto-escaping.** One line becomes an XSS, and this axis has no layer that stops it. `textContent` and `<template>` are the default |
| `no-framework` | forbid | guide | `from ['\"](react\|vue\|svelte)` | — | `import { useState } from 'react'` | `import { useState } from "react"` | This axis has no framework. Pull one in and the pack's premises (the cleanup-function contract · direct DOM manipulation) become meaningless, and that combination is owned by another axis pack |
| `typecheck-on` | require | file:types-and-testing.md | `"checkJs"[[:space:]]*:[[:space:]]*true` | — | `"checkJs": true` | `"checkJs": false` | **This is the only device that actually enforces JSDoc.** With it off, `@param`·`@returns` are assertions that check nothing. `allowJs` alone only parses and raises not a single type error (measured) |
| `typecheck-strict` | require | file:types-and-testing.md | `"strict"[[:space:]]*:[[:space:]]*true` | — | `"strict": true` | `"strict": false` | With `strict: false` the same file comes out error-free (pilot comparison run: TS7006 under `strict: true`, 0 under false). **It pairs with the policy above** — turn the check on but leave it loose and it only pretends to run |
| `boundary-parse` | require | file:types-and-testing.md | `safeParse\(` | — | `const r = TaskSchema.safeParse(raw)` | `TaskSchema.parse(raw)` | **JSDoc does nothing at runtime.** Putting `@type` on a value that came from the network·`localStorage`·a URL is an assertion, not validation |
| `store-unsubscribe` | require | file:state-management.md | `return\s+\(\)\s*=>` | — | `return () => listeners.delete(fn)` | `return (fn) => fn` | If `subscribe` does not return an unsubscribe function, on this axis — which has no unmount hook — **the subscription stays forever** |
| `delegate-not-per-row` | require | file:component-patterns.md | `=[[:space:]]*delegate\(` | — | `const off = delegate(root, 'click', '[data-task-id]', onRow)` | `export function delegate(root, type, selector, handler)` | Attach a listener to every list item and listeners pile up on every re-render, and there are N of them to unsubscribe. Delegate to a single root |
| `abort-on-reload` | require | file:loading-error-states.md | `new AbortController\(` | — | `const ctl = new AbortController()` | `/** @type {AbortController} */` | Without cancellation **an earlier response arriving late overwrites the later one**. In an SPA with frequent route changes this class of defect is hard to reproduce |
| `intercept-modifier-keys` | require | file:routing.md | `e\.metaKey` | — | `if (e.metaKey \|\| e.ctrlKey) return` | `const metaKeyLabel = "cmd"` | **The list of things not to intercept cannot be shortened** — drop the modifier keys and "open in a new tab" breaks silently. C3 confirmed it with a mutation test: delete this one check and everything else is still green. The whole list cannot be enforced by regex, so **the one item that goes missing first** serves as the marker |
| `safe-return-to` | require | file:routing.md | `requireSession\([^,]+,[[:space:]]*safeReturnTo\(` | — | `requireSession(navigate, safeReturnTo(here))` | `export function safeReturnTo(raw)` | This is the spot where **an open redirect recurred three times** in this repository. The return-path validation function has to exist for the 12 vectors in `pack-smoke.sh` to actually run |
| `seam-parse-response` | require | seam | `=>[[:space:]]*parseTask\(` | — | `const tasks = raw.map((r) => parseTask(r))` | `export function parseTask(raw)` | A response is not trusted input. If the seam skips parsing, the schema is left as a declaration and **every `@type` assertion in the pack becomes false**. Writing the proof example as `raw.map(parseTask)` got caught by the gate as a **dead regex** — passing a function reference does not match `parseTask(` |
| `seam-signal-passed` | require | seam | `\{[[:space:]]*signal[[:space:]]*\}` | — | `await fetch(url, { signal })` | `const signal = null` | `createResource` hands over a signal, and if the seam does not pass it to `fetch` the cancellation is void and the race comes back |
| `vocab-task` | forbid | guide | `\bnotes?\b` | — | `const notes = []` | `creates a note` | The vocabulary is Task/task (issued by L0). Splitting authorship across clusters splits the vocabulary — measured, it drifted to `task` 217 times against `note` 166 times, and the complete examples could not run against each other |

## For humans to uphold (undecidable by machine)

- **A function with no `@returns` leaks silently even under `strict`.** Wrap a function whose return is `any` (the `JSON.parse` family) and omit the comment and that `any` flows straight through — it is not "there is no type" but **"it is not checked"**. The gate cannot see this: every line of a JSDoc block starts with `*` so `codelines()` throws the whole block away, which makes a policy that counts `@returns` by regex **come out at 0 hits on healthy code** (the pilot confirmed it by running a fixture)
- **The side that creates the unsubscribe function returns it, and the side that receives it keeps it.** The machine can see the return but
  it cannot see **the caller throwing it away**. A leak does not show up in tests
- **`@type` is an assertion and `safeParse` is validation.** The moment the two are used as the same thing, this axis's
  type standard collapses — a human decides where the boundary is (network·storage·URL)
- **Do not carry user input into `el`'s `props` as an attribute.** A value that goes into `href`·`src`
  has to have its scheme checked, and `javascript:` is not stopped by `textContent`
- **Do not give a derived value a `set`.** Make a derivation writable and the truth exists in two places
- **The list of things `interceptLinks` does not intercept cannot be shortened.** Modifier keys · middle click ·
  `target` · an external origin · `download` — drop any one of them and "open in a new tab" breaks silently
