---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
  - "supabase/**"
---
<!-- orangekit-pack: backend/supabase v3.12.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (secret placement · ownership in the query condition · a 0-row mutation is 404 · 404 instead of 403) belong to security.md, so they are not here.
     This axis has RLS — boundary items are written as "policy + application check, both". -->

# Supabase (PostgreSQL + RLS) core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Verified versions — `@supabase/supabase-js@2` · `@supabase/ssr@0.12`. Install the latest stable release (`code-change.md` "Before Adding a Dependency") — where an item conflicts with a newer major, the official upgrade docs take precedence.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Id type · owner column name · response envelope · error status codes follow existing migrations, code or the spec; if there is none, decide once and write it in `code-conventions.md`. Do not carry over the guide example values. — why models get it wrong: it anchors on example values <!-- evidence: guide-ab T-B·T-D (fastify measured) · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Check auth on the server with `getUser()`. — why models get it wrong: `getSession()` trusts the cookie without verifying it <!-- evidence: policies getUser-not-getSession · PACK.md principle 2 · model-gap: not-observed -->
- [security] Create the server client per request. — why models get it wrong: a module singleton mixes auth cookies across requests <!-- evidence: policies no-module-singleton-client · model-gap: not-observed -->
- [security] The boundary is policy + application check, both. A new table turns RLS on in the same migration with `using`/`with check` policies, and the handler also filters by `user.id` and fills the owner column. — why models get it wrong: a table with no policy is fully open to the anon key and spreads through realtime too <!-- evidence: policies (what humans keep), database-patterns.md Realtime · model-gap: not-observed -->
- [security] Use the service role (admin) client only on webhook, cron and admin paths; `security definer` functions likewise. Every function gets `set search_path = ''`. — why models get it wrong: server code or not, once on an ordinary request path RLS is off <!-- evidence: policies (what humans keep), database-patterns.md RPC · model-gap: not-observed -->
- [security] Add `.select()` to mutations to receive the affected rows. `PGRST116` from `.single()` (absent, or hidden by RLS) is 404. — why models get it wrong: `delete()` reports success even when it deleted nothing <!-- evidence: database-patterns.md Write patterns, policies (what humans keep) · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Check `error` on every query and storage call. — why models get it wrong: it returns rather than throws, so a failure poses as an empty result <!-- evidence: policies error-is-checked · model-gap: not-observed -->
- [performance] To change several statements atomically, wrap them in a Postgres function (`.rpc()`). — why models get it wrong: supabase-js has no transactions, so chained calls leave half the change behind on a mid-way failure <!-- evidence: database-patterns.md Multi-step mutations · model-gap: not-observed -->
- [performance] Name columns; never `select('*')`. — why models get it wrong: as columns grow, the response silently grows and secret columns come along <!-- evidence: policies no-select-star · model-gap: not-observed -->
