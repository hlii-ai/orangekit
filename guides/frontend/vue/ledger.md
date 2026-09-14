<!-- orangekit-pack-ledger: frontend/vue v3.12.0 -->

# vue pack — symbol ledger

This is the table the gate machine-checks. `provides` is what this pack defines, so **if the seam defines it again
that is a duplicate definition**; `requires` is what this pack consumes but does not define, so **the seam must
supply it**. Library APIs are out of scope for the ledger — only project-local symbols go in it.

## provides — this pack defines them

Only symbols with an `export` declaration go in this table. An SFC component is the **default export**
of a `.vue` file and has no `export const` declaration, so it goes in a separate section below — mix them
into the same table and the machine check cannot find the defining statement.

The "shape" column records what the owning file alone cannot tell you: **argument names and order** · types ·
return · what it throws on failure · what the caller is obliged to wire up. In the 2026-08-23 parallel-authoring
measurement a sibling cluster, unable to read its sibling files, **guessed** the signature from the ledger's owner
information alone, and a call that reversed the order of two same-typed arguments, plus a confusion between "the
function that wires up / the function that performs", passed both type checking and the gate and became two critical
defects. So the shape is pinned down here — the gate FAILs an empty cell and checks the declared argument count against the real definition.

| symbol | defining file | shape | nature |
| --- | --- | --- | --- |
| `cn` | styling.md | **`src/lib/cn.ts`** — `cn(...inputs: ClassValue[]): string` — variadic. It assembles with `clsx` and then `twMerge` keeps only **the later one** among conflicting utilities (`px-4 px-6` → `px-6`) | class-merge utility |
| `ButtonVariant` | styling.md | **`src/components/common/button-variants.ts`** — `type ButtonVariant = 'primary' \| 'secondary' \| 'danger' \| 'ghost'` — 1:1 with the keys of the `variants` table (`Record<ButtonVariant, string>`), so adding a value requires extending the table for it to compile | variant type |
| `ButtonSize` | styling.md | **`src/components/common/button-variants.ts`** — `type ButtonSize = 'sm' \| 'md' \| 'lg'` — the keys of the `sizes` table (`h-*`·`px-*`·`text-*`). These three values decide the height·spacing·typography wholesale | size type |
| `buttonClass` | styling.md | **`src/components/common/button-variants.ts`** — `buttonClass(variant: ButtonVariant, size: ButtonSize): string` — **the order is variant first, size second.** The two unions do not overlap, so a swap is blocked at compile time. It returns the complete class string, base + variant + size merged with `cn` | variant table → class string |
| `Column` | component-patterns.md | **`src/components/common/table-types.ts`** — `type Column<T> = { key: string; header: string; value: (row: T) => string; class?: string }` — only `class` is optional. `value` is **for string cells only** (a rich cell is covered by the `cell-<key>` slot), and `key` sets both the slot name and the `:key` of the `<th>`/`<td>`. The consumer `DataTable` constrains it with `generic="T extends { id: string }"` | generic table column definition type |
| `toUserMessage` | loading-error-states.md | **`src/lib/toUserMessage.ts`** — `toUserMessage(error: unknown): string` — **never throws.** Only `NETWORK_ERROR`·`TIMEOUT` of `ApiError` have wording in this pack; every other code, and any value that is not an `ApiError`, falls through to the generic fallback message. It never returns the server's raw message as is | error → user-facing message (transport-layer codes + fallback) |
| `routes` | routing.md | **`src/router/routes.ts`** — `const routes: RouteRecordRaw[]` — a single tree with **one** root record (`path: '/'` + `component: DefaultLayout`) carrying children. The same file extends `RouteMeta { requiresAuth?: boolean; title?: string }` with `declare module 'vue-router'`. The catch-all uses the v4 syntax `:pathMatch(.*)*` | route record tree |
| `router` | routing.md | `const router: Router` — the app's **only instance**, made with `createWebHistory(config.basePath)`. This module also wires `beforeEach` (the auth guard) and `onError` (a lost chunk → full reload), so consumers just obtain it with `useRouter()` and do not attach further global guards | router instance (global guards·onError included) |
| `safeReturnTo` | routing.md | **`src/lib/safeReturnTo.ts`** — `safeReturnTo(raw: unknown, fallback = '/tasks'): string` — **blocked (→ returns `fallback`)**: a non-string or empty string · another origin (`https://evil`·`//evil`) · a value whose normalized `pathname` starts with `//` or `/\` (`/..//evil.example`) · a `new URL` parse failure. **Passing**: it returns the same origin's `pathname + search + hash` **as a path string only** (never an absolute URL). Caller's obligation: pass the result only to `router.replace`/`push` — pass it to `window.location` and the validation means nothing. The `fallback` argument is **not validated**, so give it a literal only | return-path validation (blocks external URLs) |
| `STORAGE_KEY` | state-management.md | `const STORAGE_KEY = 'ui-preferences'` (a string literal) — only three places read or write this key: `restore()` in `useUiStore`, the saving `watch`, and `clearClientState`. Never write the literal again | local storage key — `clearClientState` uses the same constant |
| `useUiStore` | state-management.md | `useUiStore(): { isSidebarOpen: Ref<boolean>; density: Ref<Density>; toggleSidebar(): void; setDensity(next: Density): void; reset(): void }` — no arguments. `Density` is `'comfortable' \| 'compact'` (a type local to the store file, not exported). **It is a setup store, so there is no `$reset()`** — resetting is `reset()`. Caller's obligation: call it **inside a function body, after `app.use(createPinia())`**, and take state·getters out with `storeToRefs()` (destructure directly and reactivity is cut) | global client state store |
| `clearClientState` | state-management.md | **`src/stores/clearClientState.ts`** — `clearClientState(): void` — no arguments. It does only `useUiStore().reset()` and `localStorage.removeItem(STORAGE_KEY)`. **It does not touch the server cache (`queryClient.clear()`)** — the discard ordering is owned by the seam's session resource. When a store is added, add that store's `reset()` call to this function too | resets client state on logout |
| `config` | types-and-testing.md | **`src/config.ts`** — `const config: { readonly apiBaseUrl: string; readonly basePath: string }` (`as const`) — when `VITE_API_BASE_URL` is empty, `apiBaseUrl` **throws at module evaluation (boot)** rather than deferring to first use. `basePath` is `import.meta.env.BASE_URL`. It is the only file in which `import.meta.env` appears, and no secrets go in it | the only module that reads environment values |
| `assertTask` | types-and-testing.md | **`src/features/tasks/api/tasks.parse.ts`** — `assertTask(v: unknown): asserts v is Task` — **an assertion function with no return value** (it cannot be used as `if (assertTask(x))`). It checks only that `id`·`title` are `string` and throws `ApiError('BAD_SHAPE', 'The response shape differs from the contract.')` when they are not. It does not check `status`·`createdAt` | narrowing a response — the domain type is `Task` in `requires` |
| `parseTask` | types-and-testing.md | **`src/features/tasks/api/tasks.parse.ts`** — `parseTask(v: unknown): Task` — it returns **the very same object** it put through `assertTask` (no copying·normalization). On failure the `ApiError('BAD_SHAPE')` thrown by `assertTask` propagates unchanged | narrowing a response (single) |
| `parseTaskList` | types-and-testing.md | **`src/features/tasks/api/tasks.parse.ts`** — `parseTaskList(v: unknown): Task[]` — a non-array gets `ApiError('BAD_SHAPE', 'The list response is not an array.')`, and a malformed element makes `parseTask` throw. **It does not strip the envelope** — hand it a page envelope and it fails here, so stripping is the caller's job (the seam's query composable) | narrowing a response (list) |
| `handlers` | types-and-testing.md | **`src/test/msw/handlers.ts`** — `const handlers: RequestHandler[]` (msw v2) — `http.get('*/tasks')` → `HttpResponse.json([])`, `http.post('*/tasks')` → 201 + `{ id: 't1', status: 'open', ...body }`. The paths use a `*` prefix wildcard, so they match regardless of baseUrl. **The response envelope is the seam's contract**, so replace these bodies with that contract at assembly | default msw handlers |
| `server` | types-and-testing.md | **`src/test/setup.ts`** — `const server: SetupServerApi` — the **single test-global instance** from `setupServer(...handlers)`. The same file hangs `listen({ onUnhandledRequest: 'error' })`·`resetHandlers()`·`close()` on `beforeAll`/`afterEach`/`afterAll`. An individual test overrides with `server.use(...)` for that test only and never calls `listen`/`close` itself | msw test server |
| `mountWithProviders` | types-and-testing.md | **`src/test/mountWithProviders.ts`** — `mountWithProviders(component: Component, options: Options = {}): { wrapper: VueWrapper; router: Router; queryClient: QueryClient }` — `Options` is `MountingOptions<Record<string, unknown>>`. It installs pinia · a `createMemoryHistory` router · `VueQueryPlugin` (a **fresh** `QueryClient` per test, `retry: false`·`gcTime: 0`), and merges the caller's `options.global.plugins` by **appending them after** its own. Caller's obligation: a screen that uses the router needs `await router.isReady()` after mounting | test mount harness |

`useUiStore` appears **twice** in state-management.md — the setup notation (the §3 body) and the options
notation (the end of §3). They are different assemblies of the same store, so a project keeps only one.

## Shared components (SFC default exports)

A `.vue` file default-exports its component. The name check is done by **file path**, not by symbol.
If the seam builds a component with the same name, that is a duplicate.

| Component | Defining file | Path |
| --- | --- | --- |
| `Button` | component-patterns.md | `src/components/common/Button.vue` |
| `SearchInput` | component-patterns.md | `src/components/common/SearchInput.vue` |
| `FormField` | component-patterns.md | `src/components/common/FormField.vue` |
| `DataTable` | component-patterns.md | `src/components/common/DataTable.vue` |
| `PageShell` | component-patterns.md | `src/components/layout/PageShell.vue` |
| `ListSkeleton` | loading-error-states.md | `src/components/common/ListSkeleton.vue` |
| `EmptyState` | loading-error-states.md | `src/components/common/EmptyState.vue` |
| `ErrorState` | loading-error-states.md | `src/components/common/ErrorState.vue` |
| `ErrorBoundary` | loading-error-states.md | `src/components/common/ErrorBoundary.vue` |
| `DefaultLayout` | routing.md | `src/layouts/DefaultLayout.vue` |

## requires — the seam must supply them

If the seam fails to fill this list, the pack's examples become unrunnable. The gate checks it after assembly.

**Distinguish the kind.** `project` must be `export`ed by the seam; `library` comes from a package the seam
picked, so it is judged not by an export but by **whether that name appears in an import statement**.
Check both with the same rule and a library binding is reported as undefined forever.

| symbol | kind | shape the pack assumes | why it is a seam concern |
| --- | --- | --- | --- |
| `Task` | project | `{ id: string; title: string; createdAt: string; status: 'open' \| 'done' }` (`@/types/task`). **`status` is not optional** — `component-patterns.md` §10 compares its value, so leaving it out breaks with TS2339 | the domain vocabulary is set by the contract (`exampleDomain` in `pack.json`) |
| `http` | project | `http.get/post/patch/delete(path, init?)` — strips the envelope and returns `unknown`. It is obliged to normalize network failures·timeouts into `ApiError('NETWORK_ERROR')`·`ApiError('TIMEOUT')` (`loading-error-states.md` §5 assumes this) | the shape of the response envelope is a function of the wire contract |
| `ApiError` | project | `new ApiError(code, message)` · fields `code: string` · `details?: Record<string, string[]>`. **The code table must include**: `NETWORK_ERROR`·`TIMEOUT` (made by the HTTP client) · `BAD_SHAPE` (thrown by the pack's `parseTask`) — leave them out and `toUserMessage` silently falls through to the generic fallback | the error code table and the field-error shape are a function of the wire contract |
| `useTasksQuery` | project | `useTasksQuery(filter?: MaybeRefOrGetter<Filter>)` — **the argument is optional** (the pack also calls it with none). The returned `data` must be `Ref<Task[] \| undefined>` — give it a page envelope (`Ref<Page<Task>>`) and the three-state example breaks entirely | the fetching layer is owned by the seam |
| `useCreateTaskMutation` | project | `useCreateTaskMutation(): { mutate: (input: { title: string }, opts?: { onError?: (e: unknown) => void }) => void; isPending: Ref<boolean> }` — the composable itself takes **no arguments** · **`mutate`'s order is (body, options) and both are plain objects, so a swap still type-checks** · `mutate` returns no value (the pack does not `await` it) and reports failure only through the `onError` callback — `loading-error-states.md` §6 lists a failed `mutate()` under "what `onErrorCaptured` does not catch", so **a rejected Promise left to leak is caught by nobody** · the argument of `onError` is `unknown` and the pack narrows with `e instanceof ApiError && e.details`, so a validation failure must be an `ApiError` · `isPending` is not a value but a `Ref<boolean>` (auto-unwrapped in a template `:disabled`) · the create mutation composable. It returns `{ mutate, isPending }` and takes `mutate(input, { onError })` | the request body and what gets invalidated are a function of the wire contract |
| `useAuth` | project | `useAuth(): { isAuthenticated: Ref<boolean>; ensureReady: () => Promise<void> }` — **no arguments** · `ensureReady()` takes no arguments either and is `await`ed on every guard entry, so **repeated calls must be safe** (already restored → resolve immediately) · `isAuthenticated` is a `Ref` rather than a value, so scripts read it with `.value` (omit it and the Ref object is always truthy) · caller's obligation: call it **only inside a guard function body** — call it at module top level and pinia·the app do not exist yet | the authentication method is a function of the backend axis. **Why the pack pins the shape**: a guard is an async function, not a render, so it needs **something it can await** rather than a "loading flag"; the guard must be able to await it, and the seam's screens read the state reactively afterwards, so the state must be a `Ref` |

## Known gaps

None. All six mandatory axis-local slots of this pack are filled, and what looks empty (data fetching·
auth/session·the complete example) is not a gap but **the seam's share**, declared by `seamSlots` in `pack.json`.

## Symbols appearing in examples — app components (the project builds them)

Neither `provides` nor `requires` — the pack does not define them and the seam will not supply them; they are
screens **the consumer project writes for its own domain**. Only their names appear in the examples, so having
no definition inside the guide even after assembly is normal. The gate's symbol check cannot see a `.vue`
default import, so no machine catches them — which is why they are recorded here.

| Name | Appears in | Nature |
| --- | --- | --- |
| `AppHeader` | routing.md (the layout example) | app shell |
| `TaskTable` | loading-error-states.md (the success branch of the three-state example) | domain screen |
| `TaskListPage` | types-and-testing.md (mounted by the §7 test) | domain screen |
