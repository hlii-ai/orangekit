<!-- orangekit-pack-policies: frontend/react-vite v3.12.0 -->

# react-vite pack — cross-file invariants

The gate checks **whether the seam obeys the policies this pack declares**. In the measurement the largest class of
audit findings (26 of 57) was "the place that declares a policy and the place that enforces it are different, and
nothing obliges anyone to reconcile the two". Symbols had a ledger, but policies had no matching device —
this file is that device.

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad
section. Count prose and anti-pattern examples and every hit is a false positive (5 confirmed at extraction time).

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-reader` | forbid | guide | `import\.meta\.env[.\[]` | `types-and-testing.md` | `import.meta.env.VITE_FEATURE_FLAGS` | `import.meta.env['VITE_API_BASE']` | Environment values are read in exactly one place, `src/config.ts`. When another file reads them directly, both the types and the validation are bypassed. **Why the regex also demands an actual key access (`.VITE_X`)**: a bare `import.meta.env` appears in prose·comments explaining the rule and becomes a false positive (2 confirmed on the gate's first run) |
| `http-only-in-api-layer` | forbid | guide | `\bfetch\(` | `data-fetching.md` | `const res = await fetch('/api/tasks')` | `const res = await window.fetch(url)` | A raw `fetch` belongs only in the HTTP client module. When a screen calls it directly, the auth header·error normalization·base URL diverge |
| `no-secret-env-prefix` | forbid | guide | `VITE_[A-Z_]*(SECRET\|PASSWORD\|PRIVATE\|CREDENTIAL)` | — | `VITE_SESSION_SECRET` | `VITE_STRIPE_PRIVATE_KEY` | `VITE_*` is inlined into the bundle at build time. The prefix is not protection |
| `no-server-data-in-store` | forbid | guide | `set\(\{[^}]*\b(tasks\|items\|rows)\b` | — | `set({ tasks: data })` | `set({ list: rows })` | Copying a server response into Zustand gives you two caches. Server state is owned solely by the query cache |
| `return-to-validated` | require | guide | `navigate\(safeReturnTo\(` | — | `navigate(safeReturnTo(params.get('returnTo')))` | `export function safeReturnTo(raw: unknown)` | A return path must always pass through this before it reaches `navigate`. `//host`·`/\host` are not stopped by a prefix check |
| `three-states` | require | guide | `if \(isPending` | — | `if (isPending) return <ListSkeleton />` | `const { data, isPending } = useQuery(opts)` | A data screen renders all three states: loading·empty·error |

When `scope` is `guide`, the verdict is made over the whole assembled guide (pack + seam). When it is `seam`, only
the seam files are examined. `require` is satisfied by at least one occurrence after assembly.

**The `proof example` column is mandatory** (the gate FAILs without it). Write one string the regex actually
catches. The gate asserts two things: ① does the example match its own regex — if it does not, it is a dead regex
that catches nothing ② for `forbid`, is that example absent from the target files — if it is present, the pack has
broken its own policy. Measured (2026-08-23): while authoring the vue pack, building a defect fixture for every
policy and running it dominated the wall clock, and this column replaces that round trip with milliseconds.

**Do not use markdown emphasis in a `scope` value.** The gate does not recognize `**seam**` as a scope, so the
policy silently targets every file — that is exactly what happened in the vue pack, and an audit repair that claimed
to "target the seam" shipped void. The gate now strips emphasis, but write the bare value in the table.

## For humans to uphold (undecidable by machine)

These are the items where deciding by regex makes one false positive breed another. They go to the auditor.

- **A shared component does not call `useNavigate`·`useQuery`.** Calling them blocks reuse —
  it receives what it needs as props
- **Design tokens owned by a shared component (height·typography·spacing) are not overridden at the call site.**
  Override them and the shared component becomes an empty shell
- **Search `src/components/common/`·`layout/` before creating a new shared component.**
  Most duplication is a search failure, not an extraction failure
- **Authorization UI is not a trust boundary.** Hiding is UX and the real verdict is the server's — if you hid
  something, the handling of the matching failure response must be there too
