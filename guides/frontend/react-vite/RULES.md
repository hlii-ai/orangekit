---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "lib/**"
---
<!-- orangekit-pack: frontend/react-vite v3.36.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (no secrets behind the VITE_ prefix · redirect allow-list · no raw HTML injection) belong to security.md, so they are not here. -->

# React + Vite core card

The project spec and `.claude/rules/code-conventions.md` take precedence over this card and the `frontend-guide` skill.
Verified versions — `react@18` · `vite@5`. Install the latest stable release (`code-change.md` "Before Adding a Dependency") — where an item conflicts with a newer major, the official upgrade docs take precedence.
Look up wiring and examples in the `frontend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Call HTTP only through the one API client module; screens never call `fetch` directly. That module's paths and envelope follow the backend spec. — why models get it wrong: auth headers and error normalization split screen by screen <!-- evidence: policies http-only-in-api-layer · model-gap: not-observed -->
- [consistency] The query cache alone owns server data. Never copy it into a global store. — why models get it wrong: with two caches, an update reaches only one <!-- evidence: policies no-server-data-in-store · model-gap: not-observed -->
- [consistency] Before building a new shared component, search the existing shared directory and reuse. — why models get it wrong: duplication comes from a failed search, not a failed extraction <!-- evidence: policies (what humans keep) · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Validate `returnTo` by the **normalized pathname** of `new URL(raw, origin)` (reject a leading `//` or `/\`). An origin comparison alone lets `/..//evil.example` through. — why models get it wrong: normalization happens after the check <!-- evidence: security-vectors A5 (measured in 4 shipped places) · model-gap: not-observed -->
- [security] Never write tokens to `localStorage`/`sessionStorage`. Self-issued tokens stay in memory. — why models get it wrong: it is the shortest implementation <!-- evidence: policies token-not-in-web-storage · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Wrap token refresh in a single flight (`inflight ??= refresh()`). Concurrent 401s each refreshing trip rotating-refresh reuse detection and log a legitimate user out. — why models get it wrong: a single request never reproduces it <!-- evidence: policies refresh-single-flight · model-gap: not-observed -->
- [performance] Fix the 401 retry depth at one refresh + one original request. — why models get it wrong: against a server that keeps answering 401 after a successful refresh, it loops forever <!-- evidence: policies retry-once-on-401 · model-gap: not-observed -->
