<!-- orangekit-pack-policies: backend/supabase v3.12.0 -->

# supabase pack — cross-file invariants

The gate checks **whether the seam keeps the policies this pack declares**. Measured: the
largest class of audit findings (26 of 57) was "the place that declares a policy and the place
that enforces it differ, and nothing obliges anyone to reconcile them" — this file is that obligation.

> **Premise of this axis**: the data layer **has** a row-level policy engine (RLS). The policies
> below guard one half of a defense in depth. Copying this section into a pack on an axis with no
> policy engine plants the false comfort that "the data layer has your back."

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not
in a ❌/Bad span. Every rule below was **tested against the pre-built seams at extraction time and
confirmed to have 0 violations** (the 8 that look like violations to a raw grep were all prose and comments).

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `getUser-not-getSession` | forbid | guide | `getSession\(` | — | `const { data } = await supabase.auth.getSession()` | `const s = await client.auth.getSession()` | On the server, always verify the user with `getUser()`. `getSession()` trusts the cookie as-is, so it cannot serve as an auth boundary |
| `no-select-star` | forbid | guide | `select\('\*'\)` | — | `await supabase.from('tasks').select('*')` | `.select('*')` | Name the columns in the handler. `select('*')` silently grows the payload on a schema change and drags secret columns along |
| `no-module-singleton-client` | forbid | guide | `^(const\|let\|var) [A-Za-z_$][A-Za-z0-9_$]* = createClient\(` | — | `const supabase = createClient(url, anonKey)` | `const db = createClient(url, anonKey)` | Build the client per request. A module-level singleton mixes auth context between requests |
| `error-is-checked` | require | guide | `if \(error\)` | — | `if (error) throw toAppError(error)` | `if (error !== null)` | A Supabase query does not throw; it returns `error`. Unchecked, a failure disguises itself as an empty result |

`scope`: `guide`=the whole assembled guide · `seam`=the seam only · `pack`=this pack only · `file:<name>`.

**The `proof example` column is mandatory** (the gate FAILs without it). Write one string the
regex actually catches. The gate asserts two things: ① does the example match its own regex — if
not, it is a dead regex that catches nothing ② for `forbid`, is that example absent from the target
files — if present, the pack broke its own policy. Measured (2026-08-23): while authoring the vue
pack, building a defective fixture per policy and running it dominated the wall clock, and this column replaces that round trip with milliseconds.

**Do not use markdown emphasis in a `scope` value.** The gate does not recognize `**seam**` as a
scope, so the policy silently aims at every file — that actually happened in the vue pack, and
the audit repair "aim at the seam" shipped void. The gate now strips emphasis, but write the bare value in the table.

## For humans to keep (machine-undecidable)

- **Turn RLS on for every table.** An application check is UX; enforcement is the policy. Add a
  table and forget the policy and the whole thing is open to the anon key
- **Use the service role key only on isolated server paths** (webhooks, cron, admin jobs). This
  key bypasses RLS, so if it enters the ordinary request path the policy engine is effectively off
- **Return the same response for absent and unauthorized.** A row RLS hid arrives as `PGRST116`;
  answering with a distinct 403 leaks existence
