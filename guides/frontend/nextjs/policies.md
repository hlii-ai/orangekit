<!-- orangekit-pack-policies: frontend/nextjs v3.12.0 -->

# nextjs pack — cross-file invariants

The gate checks **whether the seam obeys the policies this pack declares**. In the measurement the largest class of audit
findings (26 of 57) was "the place that declares a policy and the place that enforces it are different, and nothing obliges
anyone to reconcile the two" — this file is that obligation.

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad
section. Every rule below was **tested against the pre-built seam at extraction time and confirmed at zero violations**.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `no-inline-style` | forbid | guide | `style=\{[[:space:]]*\{` | — | `style={{ marginTop: 8 }}` | `style={ { marginTop: 8 } }` | Style with Tailwind utilities + `cn()`. An inline `style` is a channel that leaks outside the design tokens |
| `cn-for-classnames` | require | guide | `className=\{cn\(` | — | `className={cn('px-4 py-2', className)}` | `export function cn(...inputs: ClassValue[])` | Conditional classes are merged with `cn()`, not by string concatenation |
| `await-request-apis` | require | guide | `await (params\|searchParams\|cookies\(\))` | — | `const { id } = await params` | `const h = headers()` | On Next 15, `params`·`searchParams`·`cookies()` are Promises. Used without await, undefined flows silently at runtime |
| `no-data-client-in-pack` | forbid | pack | `create[A-Za-z]*Client\(` | — | `const db = createClient(url, key)` | `const db = createBrowserClient(url, key)` | **This checks the pack itself.** A frontend axis pack does not create a data client directly — the moment it does it is tied to a backend axis and becomes wrong guidance in every other combination (4 places were pulled out by this rule at extraction) |

`scope`: `guide`=the whole assembled guide · `seam`=seam files only · `pack`=this pack's resources only ·
`file:<name>`=that file only. `require` is satisfied by at least one occurrence.

**The `proof example` column is mandatory** (the gate FAILs without it). Write one string the regex actually
catches. The gate asserts two things: ① does the example match its own regex — if it does not, it is a dead regex
that catches nothing ② for `forbid`, is that example absent from the target files — if it is present, the pack has
broken its own policy. Measured (2026-08-23): while authoring the vue pack, building a defect fixture for every
policy and running it dominated the wall clock, and this column replaces that round trip with milliseconds.

**Do not use markdown emphasis in a `scope` value.** The gate does not recognize `**seam**` as a scope, so the
policy silently targets every file — that is exactly what happened in the vue pack, and an audit repair that claimed
to "target the seam" shipped void. The gate now strips emphasis, but write the bare value in the table.

## For humans to uphold (undecidable by machine)

- **Server Components are the default and `'use client'` goes only on interactive leaves.** Put it higher in the
  tree and the entire subtree is dragged into the client bundle — which depth counts as a "leaf" is something a
  regex cannot decide
- **Fetch server data on the server and pass it down as props.** A component does not call the data layer
  directly (what must not be called directly is decided by the backend axis)
- **Review repeated UI at the second occurrence and extract without exception at the third.** Search the shared
  directories before building — most duplication is a search failure, not an extraction failure
- **Do not pass functions·class instances·data client objects from a server component to a client
  component** (the serialization boundary)
- **Split state into layers.** Server state as props, what belongs in the URL in the URL, and only the remaining
  global client state in the store
