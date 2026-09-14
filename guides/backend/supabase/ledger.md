<!-- orangekit-pack-ledger: backend/supabase v3.12.0 -->

# supabase pack — symbol ledger

## provides — none

**This pack has no symbol surface.** What the two resources carry are query and policy patterns
as inline snippets, with not one top-level `export` (measured at extraction time: a single
`export default`, and that inside an example file). This is not a defect but the pack's **shape**.

| pack shape | example | trait |
| --- | --- | --- |
| symbol-surface | `backend/aws-container` (25 exports) · `frontend/*` | Defines project modules. The seam imports them |
| **pattern-knowledge** | `backend/supabase` | Teaches **how to use** the vendor SDK. It defines no project module |

A BaaS axis naturally lands on pattern-knowledge — the vendor supplies the data access module
itself, so what the project defines is the **layer wrapping** it, and the shape of that layer is
set by the host runtime (the frontend axis). Hence the seam owns it.

This distinction has a concrete implication for the gate: **running the reverse ledger check
(find exports missing from the ledger) on a pack with an empty `provides` flags everything as a
violation.** It must read `symbolSurface: false` in `pack.json` and skip that check.

## requires — the seam must provide these

| symbol | kind | shape the pack assumes | why it belongs to the seam |
| --- | --- | --- | --- |
| `createClient` | project | `Promise<SupabaseClient<Database>>` — per request, cookie-bound | How you reach cookies is a function of the host runtime. In this combination, `next/headers` |
| `fromSupabaseError` | project | PostgREST/SQLSTATE error → HTTP response | Status code and envelope are a function of the wire contract |
| `Database` | generated | The type `supabase gen types` produces | **This pack owns the generation procedure** (`database-patterns.md`), but the output file itself belongs to the project |

## Removed from this pack at extraction

| moved | original location | destination | reason |
| --- | --- | --- | --- |
| §Server client (per request · cookie-bound) | `database-patterns.md` L18-58 | seam `server-client.md` | Cookie access is a function of the host runtime |
| Layer 2·3 (Route Handler · Server Action tests) | `testing.md` L51-160 | seam `handler-testing.md` | A test that calls the handler directly depends on the handler's shape |
| all of `validation-and-errors.md` | — | seam | Zod wiring, the error envelope and env validation are tangled with Next.js **paragraph by paragraph**, so no section boundary split them. The seam absorbs it whole |
| all of `edge-and-operations.md` | — | seam | middleware, the Edge runtime, CORS and security headers are the host's concern, not Supabase's |

## Gained by this pack

| received | original location | reason |
| --- | --- | --- |
| §Generated types (`supabase gen types`) | `nextjs-frontend-guide/typescript-standards.md` §7 | Making types from a DB schema is this axis's knowledge, not the frontend's |
