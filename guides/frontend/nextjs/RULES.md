---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "lib/**"
---
<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (no secrets behind the NEXT_PUBLIC_ prefix · an action is an entry point too, so auth first · no raw HTML injection) belong to security.md, so they are not here. -->

# Next.js 15 App Router core card

The project spec and `.claude/rules/code-conventions.md` take precedence over this card and the `frontend-guide` skill.
Look up wiring and examples in the `frontend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] The return shape of a Server Action and the refresh after a mutation follow existing actions; if there are none, decide once and write it in `code-conventions.md`. Expected failures are returned, not thrown. — why models get it wrong: a throw leaks to the nearest `error.tsx` and the whole screen becomes an error <!-- evidence: ledger ActionState · DeleteTaskButton · model-gap: not-observed -->
- [consistency] Fetch server data in a Server Component and pass it down as props. Never refetch on the client or copy it into a store. — why models get it wrong: the SPA `useEffect` fetching habit <!-- evidence: policies (what humans keep) · model-gap: not-observed -->

## Security — where this stack leaks

- [security] A server-only module (data queries · secret use) starts with `import 'server-only'`. — why models get it wrong: `'use client'` propagates through imports, yet ordinary server code is bundled with no error <!-- evidence: resources/component-patterns.md §2 · model-gap: not-observed -->
- [security] Server → Client props travel to the browser verbatim in the RSC payload. Never pass whole user or row objects; pass only the fields the screen needs. — why models get it wrong: if the screen does not draw it, nobody notices the leak <!-- evidence: ledger AppHeader · policies (what humans keep) · model-gap: not-observed -->
- [security] Never put per-user values in a module top-level `create()` store. On the server every request shares that instance — build per-request state per tree inside a Provider. — why models get it wrong: it is the correct idiom in an SPA <!-- evidence: resources/state-management.md · ledger createUiStore · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] `params`, `searchParams` and `cookies()` are Promises. `await` them before use. — why models get it wrong: the v14 idiom, and without await an undefined flows on silently <!-- evidence: policies await-request-apis · model-gap: not-observed -->
- [performance] Put `'use client'` only on interactive leaves. — why models get it wrong: the shortest fix for a hook error is to add it to a parent file, which drags the whole subtree into the client bundle <!-- evidence: policies (what humans keep) · model-gap: not-observed -->
- [performance] Do not draw a `persist` store value before mount (use a same-size placeholder). — why models get it wrong: the first server render and the restored value differ and hydration mismatches <!-- evidence: ledger CartBadge · model-gap: not-observed -->
