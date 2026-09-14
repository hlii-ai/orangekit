<!-- orangekit-pack-policies: frontend/vue v3.12.0 -->

# vue pack — cross-file invariants

The gate checks **whether the seam obeys the policies this pack declares**. When the place that declares a policy
and the place that enforces it differ and nothing obliges anyone to reconcile them, the policy survives only as
documentation — this file is that obligation.

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌/Bad
section. Count prose and anti-pattern examples and every hit is a false positive.

**A Vue-specific caution**: an anti-pattern in a `.vue` fence is not excluded even when marked with `<!-- ❌ -->`.
The comment prefixes `codelines()` recognizes are only `//` · `#` · `*` · `--`, so an HTML comment is counted as a
code line. That is why the SFC anti-patterns in this pack **put the ❌ on the prose line immediately before the
fence**, which excludes the whole fence. Break this convention and the forbid rules below start catching their own
bad examples (all 8 confirmed by measurement at declaration time).

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `env-single-reader` | forbid | guide | `import\.meta\.env[.\[]` | `types-and-testing.md` | `import.meta.env.VITE_FEATURE_FLAGS` | `import.meta.env['VITE_API_BASE']` | Environment values are read in exactly one place, `src/config.ts`. When another file reads them directly, both the types and the validation are bypassed. **Why the regex demands an actual key access**: a bare `import.meta.env` appears in prose·comments explaining the rule and becomes a false positive |
| `http-in-api-layer` | forbid | pack | `\bfetch\(` | — | `const res = await fetch('/api/tasks')` | `const res = await window.fetch(url)` | A raw `fetch` belongs only in the seam's HTTP client module. When a screen calls it directly, the auth header·error normalization·base URL diverge. **Why the scope is `pack`**: the seam's client file legitimately uses `fetch(` — apply it to the whole `guide` and it becomes a false positive on the seam |
| `no-secret-env-prefix` | forbid | guide | `VITE_[A-Z_]*(SECRET\|PASSWORD\|PRIVATE\|CREDENTIAL)` | — | `VITE_SESSION_SECRET` | `VITE_DB_PASSWORD_HASH` | `VITE_*` is inlined into the bundle at build time. The prefix is not protection |
| `no-server-data-in-store` | forbid | guide | `state:[[:space:]]*\(\)[[:space:]]*=>[[:space:]]*\(\{[^}]*\b(tasks\|items\|rows)\b` | — | `state: () => ({ tasks: [] as Task[] })` | `state: () => ({ items: [] as Task[] })` | Put a server collection in Pinia state and you have two caches. Server state is owned solely by the query cache. A setup store's `ref<Task[]>([])` cannot be distinguished by regex from the identical expression in a component, so it was not put in the machine checks — it is in the human checks below |
| `no-scoped-style` | forbid | guide | `<style[^>]*(scoped\|module)` | — | `<style scoped>` | `<style module lang="postcss">` | Tailwind is the only styling system. Allow scoped CSS and the same spacing exists both in a class and in CSS, making design token reconciliation impossible |
| `no-dynamic-class-string` | forbid | guide | `:class=.{0,80}(\$\{\|['\"][a-z-]+['\"][[:space:]]*\+)` | — | `:class="'text-' + tone"` | `:class="`text-${tone}`"` | Tailwind scans sources as strings. An assembled class name is absent from the built CSS, so the style silently disappears. **It looks for both template literals and string concatenation** — the audit found by measurement that the concatenation form (`'text-' + tone`) was not being caught |
| `no-options-api` | forbid | guide | `export default[[:space:]]+defineComponent` | — | `export default defineComponent({` | `export default  defineComponent({` | Every component in this stack is `<script setup lang="ts">`. Mix the two styles and prop declarations·reactivity rules·testing approaches differ from file to file. **The `export default { setup() {} }` form is not caught here** — widen it to `export default {` and `tailwind.config.js` gets caught (confirmed by measurement). A config file and a component cannot be told apart line by line, so it was moved to the human checks |
| `no-v-html` | forbid | guide | `v-html` | — | `<div v-html="task.description" />` | `<span v-html="html" />` | Vue's interpolation (`{{ }}`) escapes automatically, but `v-html` turns that defence off entirely. One untrusted string getting in is an XSS |
| `return-to-validated` | require | seam | `router\.replace\(safeReturnTo\(` | — | `router.replace(safeReturnTo(route.query.returnTo))` | `export function safeReturnTo(raw: unknown)` | A return path must always pass through this before it reaches `router.replace`. **Why the scope is `seam`**: the pack defines this function, so scoping it to `guide` means it can never fail as long as the pack ships — and the seam's login screen, the thing that actually needs checking, goes unchecked (an audit finding) |
| `three-states` | require | seam | `\{[^}]*isPending[^}]*\}[[:space:]]*=` | — | `const { data, isPending, isError } = useTasksQuery()` | `const isPending = false` | A data screen renders all three states: loading·empty·error. It targets the seam for the same reason as above |
| `storetorefs-required` | require | guide | `=[[:space:]]*storeToRefs\(` | — | `const { density } = storeToRefs(useUiStore())` | `import { storeToRefs } from "pinia"` | This is the canonical way to take state out of a store. If the name disappeared from the assembled guide, someone replaced the example with one that simply destructures the store |
| `no-react-query` | forbid | guide | `@tanstack/react-query` | — | `import { useQuery } from '@tanstack/react-query'` | `import { useQuery } from '@tanstack/react-query/build/modern'` | **The biggest risk on this axis**: when the React pack is consulted as a format reference, this import is the first thing to leak in. Vue uses `@tanstack/vue-query`. This was a place that had a prose warning and no machine defence |
| `no-fullpath-key` | forbid | guide | `:key="\$?route\.fullPath"` | — | `<RouterView :key="route.fullPath" />` | `:key="$route.fullPath"` | `fullPath` includes the query·hash, so the page remounts on every filter change·anchor jump and a form being typed into is lost. Use `route.path` (a defect the audit confirmed by running it) |
| `no-hash-history` | forbid | guide | `createWebHashHistory` | — | `history: createWebHashHistory()` | `history: createWebHashHistory(import.meta.env.BASE_URL)` | Adds a machine defence to the prose prohibition (§routing) |
| `no-vue-shim` | forbid | guide | `declare module ['\"]\*\.vue['\"]` | — | `declare module '*.vue' {` | `declare module "*.vue" {` | Depending on the tooling it blankets every component type as `any`. Adds a machine defence to the prose prohibition |

When `scope` is `guide`, the verdict is made over the whole assembled guide (pack + seam). `pack` looks only at
pack files, `seam` only at seam files. `require` is satisfied by at least one occurrence after assembly.

**The `proof example` column is mandatory** (the gate FAILs without it). Write one string the regex actually
catches. The gate asserts two things: ① does the example match its own regex — if it does not, it is a dead regex
that catches nothing ② for `forbid`, is that example absent from the target files — if it is present, the pack has
broken its own policy. Measured (2026-08-23): while authoring the vue pack, building a defect fixture for every
policy and running it dominated the wall clock, and this column replaces that round trip with milliseconds.

**Do not use markdown emphasis in a `scope` value.** The gate does not recognize `**seam**` as a scope, so the
policy silently targets every file — that is exactly what happened in the vue pack, and an audit repair that claimed
to "target the seam" shipped void. The gate now strips emphasis, but write the bare value in the table.

## For humans to uphold (undecidable by machine)

- **Do not use the `export default { setup() {} }` form either.** Only `defineComponent` is caught by a regex,
  and this form cannot be told apart from a config file's `export default {`

These are the items where deciding by regex makes one false positive breed another. They go to the auditor.

- **Do not simply destructure a Pinia store.** State·getters come out with `storeToRefs`, and only actions are
  taken directly. Destructuring actions is legitimate, so `const { x } = useXStore()` itself cannot be
  forbidden — only a human knows whether the extracted name is state or an action
- **Do not destructure props.** Read them as `props.x`. Depending on the Vue version the compiler sometimes
  compensates for destructuring, but do not let screen updates depend on whether it compensates
- **Do not put a server collection in a setup store.** `const tasks = ref<Task[]>([])` is legitimate in a
  component and a defect in a store — the verdict depends on where it sits
- **A shared component does not call `useRouter`·`useQuery`.** Calling them blocks reuse —
  it receives what it needs through props and slots
- **Design tokens owned by a shared component (height·typography·spacing) are not overridden at the call site.**
  In Vue a fallthrough `class` is simply concatenated without passing through `cn()`'s tailwind-merge, so an
  override leaves the winner to CSS file order — the override does not even work as an override
- **Search `src/components/common/`·`layout/` before creating a new shared component.**
  Most duplication is a search failure, not an extraction failure
- **Do not use `<Suspense>` and top-level `await` for screen data loading.** The owner of the loading state
  moves outside the component and diverges from the three-state rule
- **Authorization UI is not a trust boundary.** Hiding is UX and the real verdict is the server's — if you hid
  something, the handling of the matching failure response must be there too
