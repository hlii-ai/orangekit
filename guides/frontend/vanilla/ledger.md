<!-- orangekit-pack-ledger: frontend/vanilla v3.14.0 -->

# vanilla pack — symbol ledger (L0 declaration)

This is the contract the main session declared before authoring began. It is the only device that keeps duplicate
definitions and **signature guessing** from appearing when the clusters are split and written in parallel.

**The "shape" column is mandatory.** Assign only the owning file and leave the shape empty and a sibling cluster
guesses the signature — measured (node-api), both arguments had the same type so neither the checker nor the gate
caught it and every single-record lookup 404'd. Write down the argument **order** · the return · what it does on failure ·
**what the caller has to wire up**, all together.

**"defining file" is ownership in the documents, not the path of the code.** That is why the shape column **pins down
the source path** — measured in firebase, each cluster assumed a different root and the relative imports of the
assembled guide did not resolve. **The gate passes a symbol as long as it is defined somewhere in the pack.**

## The four spots that are especially dangerous in this pack

1. **Type checking hangs off the comments.** The language is JavaScript, so `@param`·`@returns`·`@typedef` are
   **the only type declarations**, and tsc with `checkJs` on reads them. A function whose comment is missing
   **becomes an implicit `any` and silently escapes checking** — it is not "there is no type" but "it is not checked"
2. **Parse again at the runtime boundary.** JSDoc is **a compile-time comment and does nothing at
   runtime.** Putting `@type` on a value that came from the network·`localStorage`·a URL is an assertion, not
   validation — zod's `safeParse` is what fills that spot
3. **Fail to return a cleanup and it leaks.** There is no framework, so there is no unmount hook.
   **The contract is that the function which created the subscription·event listener·`AbortController` returns the disposer**
4. **`innerHTML` becomes an XSS in one line.** There is no framework auto-escaping —
   `textContent` and `<template>` are the default, and policy forbids `innerHTML`

## provides — this pack defines them

| symbol | defining file | shape | nature |
| --- | --- | --- | --- |
| `config` | types-and-testing.md | **`src/config.js`** **this is the only definition** — the result of parsing `import.meta.env` with zod. `VITE_API_BASE` (a URL) · `VITE_ENV` (`'development'|'staging'|'production'`). **The field names of the result object are the environment keys verbatim** — `config.VITE_API_BASE`, not `config.apiBase`. Leave this cell empty and the hub and the resources use different names, which the gate cannot catch because it only looks at the symbol `config`. **Parse at module top level** — a failure has to be a boot failure (blow up at the first request instead and half the screen is alive). **It is the only file that reads the environment** | validated environment values |
| `TaskStatus` | types-and-testing.md | **`src/schemas/task.js`** — `z.enum(['open', 'done'])`. **The values are the lowercase `'open'`·`'done'`.** What goes on the wire·into a DOM attribute·into a test assertion is the **value**, not the name — leaving this cell empty once had a sibling cluster guess uppercase and the block-proof test was red every time (measured in fastapi) | status enum |
| `TaskSchema` | types-and-testing.md | **`src/schemas/task.js`** — `z.object({ id, ownerId, title, status, createdAt })`. `createdAt` is **taken as a string (ISO) and not turned into a `Date`** — keep the serialization boundary in one place. `.strict()` | domain schema |
| `Task` | types-and-testing.md | **`src/schemas/task.js`** — `/** @typedef {import('zod').z.infer<typeof TaskSchema>} Task */`. **Do not put a hand-written `@typedef` alongside the schema** — two copies always diverge. Derive it from the schema | domain type |
| `TaskCreateSchema` | types-and-testing.md | **`src/schemas/task.js`** — `title` (1–200) · `status` (defaults to `'open'`). `.strict()` | creation input |
| `TaskCreate` | types-and-testing.md | **`src/schemas/task.js`** — `/** @typedef {import('zod').infer<typeof TaskCreateSchema>} TaskCreate */`. **`createTask` in `requires` references this name, so it has to be in `provides`** — without it the seam has nothing in the contract to point at | creation input type |
| `TaskUpdateSchema` | types-and-testing.md | **`src/schemas/task.js`** — **Do not build it with `TaskCreateSchema.partial()`.** In zod 4 `.partial()` does not strip `.default()`, so a partial update that does not send `status` becomes `{ status: 'open' }` — a task that was marked done quietly comes back to life (run confirmed by the pilot, zod@4.4.3). **Derive Create and Update separately from a bundle of fields with no defaults (`taskInputFields`).** `.strict()` | update input |
| `parseTask` | types-and-testing.md | **`src/schemas/task.js`** — `(raw: unknown) => Task` — uses `TaskSchema.safeParse` and **throws** on failure. **The contract is that it is called at the boundary** (a response·`localStorage`·a URL). Attaching only an `@type` comment on the success path is not validation | boundary parser |
| `createStore` | state-management.md | **`src/store/create.js`** — `/** @template T */ (initial: T) => { get(): T, set(next: T \| ((prev: T) => T)): void, subscribe(fn: (value: T) => void): () => void }` — **`subscribe` returns an unsubscribe function, and on registration it emits once immediately with the current value** (subscribing is the first render — assume the opposite and the first render is either missed or drawn twice). The caller has to keep and call the unsubscribe function. `set` compares by **reference identity (`Object.is`)** and does not notify when they are equal — it is not a shallow per-field comparison (read it that way and you get the exact opposite implementation, in which replacing `{items, byId}` is never notified). **Without `@template` every store value becomes `any`** | store factory |
| `tasksStore` | state-management.md | **`src/store/tasks.js`** — an instance made with `createStore`. The state is `{ items: Task[], byId: Record<string, Task> }`. **The reason `byId` is kept separately is to keep an update from requiring a walk over the list**, and both fields have to change together **inside the same `set`** — split them and a subscriber sees half a state | domain store |
| `replaceTasks` | state-management.md | **`src/store/tasks.js`** — `(tasks: Task[]) => void` — replaces the whole list. Changes `items` and `byId` together **inside the same `set`**. The result of the seam's `fetchTasks` comes in here | update |
| `upsertTask` | state-management.md | **`src/store/tasks.js`** — `(task: Task) => void` — inserts·updates a single record. Use the updater form (`set((prev) => …)`) — call `get()` and then `set()` separately and you overwrite whatever was updated in between. The result of the seam's `createTask` comes in here | update |
| `derive` | state-management.md | **`src/store/create.js`** — `/** @template T,U */ (store, selector: (value: T) => U) => { get(): U, subscribe(fn: (value: U) => void): () => void }` — a derived value. There is **no** `set` (a derivation is not a write target) | derivation |
| `el` | component-patterns.md | **`src/dom/el.js`** — `(tag: string, props?: Record<string, unknown>, children?: (Node \| string)[]) => HTMLElement` — a string child goes in **through `textContent`** (never `innerHTML`). `on*` keys in `props` are wired as listeners, `class`·`data-*` as attributes | element creation |
| `fromTemplate` | component-patterns.md | **`src/dom/el.js`** — `(id: string) => DocumentFragment` — clones a `<template id>`. It is the default means of repeated rendering, and it leaves the markup in the HTML where it can be searched·reviewed | template cloning |
| `delegate` | component-patterns.md | **`src/dom/delegate.js`** — `(root: Element, type: string, selector: string, handler: (event: Event, target: Element) => void) => () => void` — **argument order: root → event type → selector → handler.** `type` and `selector` are **both strings, so the order is everything.** The return is **the unsubscribe function**. Instead of a listener on every list item, one on a single root | event delegation |
| `mountTaskList` | component-patterns.md | **`src/components/task-list.js`** — `(root: Element, store: typeof tasksStore) => () => void` — the representative component. **The return is the cleanup function** and it calls both the store unsubscribe and the delegation unsubscribe. There is no framework, so this return value is the only unmount path | representative component |
| `createRouter` | routing.md | **`src/router/index.js`** — `(routes: { path: string, render: (params: Record<string, string>) => (() => void) }[]) => { start(): () => void, navigate(path: string): void }` — each route's `render` **returns a cleanup function**. `start()` attaches `popstate`, performs the first render and **returns its own disposer**. **`navigate` does nothing after that disposal** — a call after the stop redrawing into a detached container was reproduced (C3, happy-dom). In route notation **array order is priority** and the catch-all is `path: '*'` — if the 404 is not in the contract, the seam's complete example assumes a different notation | router |
| `interceptLinks` | routing.md | **`src/router/links.js`** — `(root: Element, navigate: (path: string) => void) => () => void` — intercepts clicks on internal links. **Spell out what it does not intercept**: modifier keys (⌘·Ctrl·Shift·Alt) · middle click · a `target` attribute · an external origin · `download`. Drop any one of them and open-in-a-new-tab breaks | link interception |
| `safeReturnTo` | routing.md | **`src/router/return-to.js`** — `(raw: unknown) => string` — validates the post-login return path and returns **an internal path only**, otherwise `'/'` (it does not throw). **This is the spot where an open redirect recurred three times in this repository**: `//host` · `/\host` · a control-character injection · a backslash · an encoded scheme all parse as an external URL in the browser. `startsWith('/')` or an origin comparison alone is **not enough**. Pass all 12 vectors in `assets/security-vectors.md` and put the result in the report | security primitive |
| `createResource` | loading-error-states.md | **`src/state/resource.js`** — `/** @template T */ (fetcher: (signal: AbortSignal) => Promise<T>) => { subscribe(fn: (state: { status: 'idle' } \| { status: 'loading' } \| { status: 'empty' } \| { status: 'error', error: Error } \| { status: 'ready', data: T }) => void): () => void, load(): void, abort(): void }` — **the contract is that `fetcher` takes an `AbortSignal`.** A new `load()` first cancels the one in flight — without cancelling, an earlier response arriving late overwrites the later one. `'empty'` is the state where the call succeeded and the result holds 0 records, and it renders **differently** from `'error'` | three-state machine |
| `renderState` | loading-error-states.md | **`src/state/render.js`** — `(container: Element, state: ResourceState<T>, views: { idle?: () => Node, loading: () => Node, empty: () => Node, error: (e: Error) => Node, ready: (d: unknown) => Node }) => void` — empties the container and puts in the view that matches the state. **`idle` is optional and when it is absent the container is left empty** — `createResource` has five states, and taking only four views leaves what to draw in the first state out of the contract. **Do not carry `error.message` into the error view verbatim** — a server message has internal paths in it | three-state render |

> **Do not list a CSS file in `provides`.** `provides` is the device that stops a sibling cluster from **guessing a
> signature**, but CSS has no signature and no way to pass the gate's definition check (the `function|const|@typedef`
> family) — that is why `taskListStyles` was a FAIL (C2's report). Planting a fake constant to satisfy the
> regex is a workaround, not a contract.
>
> **Instead the real contract is owned by the "Symbols appearing in examples" table below**: `src/components/task-list.css` is
> owned by `styling.md`, and the convention is **file name = mount function name = class prefix**
> (`.task-list` · `.task-list__row` · `.task-list__title` …). There are no scoped styles, so
> **the prefix is the only scope**. The tokens a component owns (height·spacing·typography) are defined in that one CSS
> file alone, and call sites control them only through custom properties.

## requires — the seam must provide them

`project` has to be defined by the seam; `library` is judged by whether the name appears in an
import statement. **For a symbol the pack calls, write down the call signature** — without it the seam
guesses the argument order (the gate blocks that with a FAIL).

| symbol | kind | shape the pack assumes | why it is a seam concern |
| --- | --- | --- | --- |
| `fetchTasks` | project | `(signal: AbortSignal) => Promise<Task[]>` — **the contract is to take the `signal` and pass it to `fetch`** (`createResource` supplies it). A response is not trusted input, so **parse every item with `parseTask` (provided by the pack)**. A failure throws an `Error`. Put it in `src/api/tasks.js` | the envelope·endpoint·auth header are a function of the combination |
| `createTask` | project | `(input: import('../schemas/task.js').TaskCreate, signal?: AbortSignal) => Promise<Task>` — **parse the input with `TaskCreateSchema` before sending it.** Success returns **the created `Task`** (not a 204 — the store puts it in) | the same as above |
| `session` | project | `{ get(): { userId: string } \| null, subscribe(fn): () => void }` — the protected route decides with `get()`. **`subscribe` returns an unsubscribe function** (the same as the pack's cleanup contract). Put it in `src/auth/session.js` | where the token is kept and how it is refreshed are a function of the backend axis |
| `requireSession` | project | `(navigate: (path: string) => void, returnTo: string) => boolean` — when unauthenticated it sends the user to login carrying `returnTo` and returns `false`. **Putting it through `safeReturnTo` (provided by the pack) is the caller's job** — the pack's protected route calls it as `requireSession(navigate, safeReturnTo(raw))`. That is a decision to keep the enforcement point inside the pack (leave it to the seam and the `safe-return-to` policy cannot see it). **Carry a return path without validating it and it becomes an open redirect** | the login path and flow are a function of the combination |

## Known gaps

None. Every axis-local mandatory slot is filled, and what looks empty (data fetching · auth/session ·
the complete example) is the seam's share, declared by `seamSlots` in `pack.json`.

## Symbols appearing in examples — app symbols (the project builds them)

Neither `provides` nor `requires`. Only the name appears in the examples, so having no definition even after assembly is
normal. **Register not only functions·classes but also CSS custom properties·data attributes** — when a name an
example introduces is declared nowhere, the reader takes it for something the pack provides.

| name | appears in | nature |
| --- | --- | --- |
| `--task-row-height` | styling.md · component-patterns.md | an example of a token a component owns |
| `data-task-id` | component-patterns.md (identifying the target of event delegation) | a data attribute the delegation handler reads |
| `.task-list__*` | styling.md · component-patterns.md | **The class-prefix convention.** file name = mount function name = prefix, and both files use the same name |
