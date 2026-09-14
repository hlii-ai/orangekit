<!-- orangekit-pack: frontend/vanilla v3.14.0 verified 2026-08-24 vite@8 zod@4 vitest@4 happy-dom@20 typescript@7 -->

# vanilla axis pack — hub fragment

These are the fragments moved into `SKILL.md` at assembly time. Each fragment sits between
`<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, closed inside the axis, so it is used as-is however the combination changes.
Only the slots in the "What the seam fills in" table at the end of the file are rewritten by the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
index.html                   # single entry point. The <template> markup and the **@layer order declaration** live here
vite.config.js               # import defineConfig from **vitest/config** (the vite one gives TS2769 on the test key)
jsconfig.json                # **checkJs: true** — checks JSDoc comments as types
src/
├── main.js                  # boot only — load config → router start() → keep the cleanup function
├── config.js                # the **only file** that parses build-time environment values with zod
├── schemas/
│   └── task.js              # TaskSchema · TaskStatus · parseTask (the values are lowercase 'open'·'done')
├── store/
│   ├── create.js            # createStore · derive — without @template every value is any
│   └── tasks.js             # tasksStore — changes items and byId inside the same set
├── dom/
│   ├── el.js                # el · fromTemplate — a string child goes in through textContent
│   └── delegate.js          # delegate(root, type, selector, handler) → unsubscribe function
├── components/
│   ├── task-list.js         # mountTaskList — **the return is the cleanup function** (there is no unmount hook)
│   └── task-list.css        # the tokens this component owns are defined here and nowhere else
├── routes/
│   └── tasks.js             # route screen module — render(params) **returns a cleanup function**
├── router/
│   ├── index.js             # createRouter — each route render returns a cleanup function
│   ├── links.js             # interceptLinks — does not intercept modifier keys·middle click·target
│   └── return-to.js         # safeReturnTo — a security primitive. Passes all 12 vectors
├── state/
│   ├── resource.js          # createResource — the contract is that fetcher takes an AbortSignal
│   └── render.js            # renderState — does not carry the server message into the error view verbatim
├── api/
│   └── tasks.js             # fetchTasks · createTask — **owned by the seam**
├── auth/
│   └── session.js           # session · requireSession — **owned by the seam**
└── styles/
    ├── tokens.css           # global custom properties (@layer tokens)
    └── base.css             # reset and element defaults (@layer base)

test/
├── setup.js                 # prepares the happy-dom environment
├── schemas.test.js          # schema unit — partial update · unknown key · empty object
├── return-to.test.js        # return path — **asserts the block and the normal pass in the same file**
└── task-list.test.js        # component — asserts even that the cleanup function really unsubscribes
```

**There is no framework, so cleanup is the contract.** There is no unmount hook — a function that created a
subscription·listener·`AbortController` **has to return the disposer**, and the caller has to keep
it. A function that does not return one creates a leak, and that leak does not show up in tests.

**`src/api/` and `src/auth/` are owned by the seam.** The pack only calls into them. Before assembly it is
normal for them to have no definition, and the gate checks that they are satisfied together with `--assembly`.

**The types live only in the comments.** `checkJs` in `jsconfig.json` has to be on for those comments to be checked —
with it off, `@param`·`@returns` are **assertions that enforce nothing.**
<!-- /pack-slot -->

<!-- pack-slot: quick-start-axis -->
## Quick Start

**A new component**

- [ ] Search `src/components/` before building one — if something with the same role is there, reuse it
- [ ] Write it in the form `mount<Name>(root, store)` and **return a cleanup function** (there is no unmount hook)
- [ ] Build DOM with `el`·`fromTemplate` — a string child goes in through `textContent`
- [ ] Delegate list events to the root with `delegate(root, type, selector, handler)` and call the disposer it returns from the cleanup function
- [ ] Put `@param`·`@returns` on every exported function — without them it becomes an implicit `any` and escapes checking
- [ ] In a test, call the cleanup function and then fire the event once more to assert the handler is not called
- [ ] `npx tsc -p jsconfig.json --noEmit` — with `checkJs` off, the comments above are decoration

**A new route**

- [ ] Add `{ path, render }` to `createRouter`'s routes and make `render(params)` **return a cleanup function**
- [ ] `params` came from the URL — it is not trusted input, so validate it at the boundary with `safeParse`
- [ ] Take data through `createResource(fetcher)` and pass the `AbortSignal` that `fetcher` received straight to `fetch`
- [ ] Assert in a test that `abort()` is called when the route is left
- [ ] Split loading·empty·error with `renderState` — empty is not an error, and the error view does not carry the server message verbatim
- [ ] For a protected route, `requireSession(navigate, safeReturnTo(raw))` — skip the return-path validation and it becomes an open redirect
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

**There is no server runtime.** The deployable is static files and every render happens in the browser — there is no SSR
and no route handler, and any value sent down can be read and altered by the user.

| component | what it owns |
| --- | --- |
| `index.html` + `src/router/` | **Single entry point.** Every path enters the same document and the History API splits the screens. Each route's `render` returns a cleanup function |
| `src/store/` | **Module-scope store.** There is no reactivity — `subscribe` hands back an unsubscribe function and the DOM is edited directly inside that callback |
| `src/dom/` | **DOM helpers.** `el`·`fromTemplate` are the only path for creating an element and `delegate` the only one for wiring an event — escaping and disposal come along with them |
| `src/schemas/` · `src/config.js` | **The zod boundary.** This is the one door through which values from the network·`localStorage`·a URL enter the app |
| `src/state/` | **State machine.** `createResource` gives the `AbortSignal` to the fetcher and `renderState` draws loading·empty·error·ready apart |
| `jsconfig.json` + `tsc` | **The `checkJs` checker.** The type declarations live only in JSDoc comments, so this is the only device that enforces them |

**`src/api/` and `src/auth/` are owned by the seam** — the pack only calls `fetchTasks`·`createTask`·`session`·
`requireSession`, and the requires table in `ledger.md` pins down their shape. Two things the pack does not
concede: **a response is parsed with `parseTask`** · **the `AbortSignal` is passed to `fetch`**.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles (5 Key Rules)

### 1. Look for repeated UI before building it — then extract

Most duplication is not an extraction failure but a **search failure**. Before building a new shared component
search `src/components/`, and define the tokens that component owns **in that one CSS file only**.
```js
// ❌ writing the list mount again for every new screen — nobody searched
function mountArchivedList(root, store) { /* 90% the same as mountTaskList */ }
// ✅ search first:  rg "export function mount" src/components/
const stopList = mountTaskList(root, tasksStore); // change values only through --task-row-height
```
### 2. Whatever mounts returns a cleanup function

There is no unmount hook. The contract runs to the end: the side that created it returns the disposer and the side that received it keeps it.
```js
// ❌ subscribes and stops there — this subscription survives leaving the route
export function mountTaskList(root, store) { store.subscribe(onChange); }
// ✅ hand back a function that undoes everything created — /** @returns {() => void} */
const off = [store.subscribe(onChange), delegate(root, 'click', '[data-task-id]', onRow)];
const cleanup = () => off.forEach((fn) => fn());  // the caller keeps this and calls it
```
### 3. Do not use `innerHTML`

There is no auto-escaping — one line of a task title becomes an XSS and there is no layer behind it to stop it.
```js
// ❌ a tag that arrived in the title is parsed as-is
row.innerHTML = `<span class="title">${task.title}</span>`;
// ✅ strings only through textContent, repeated markup by cloning <template>
const frag = fromTemplate('task-row');
frag.querySelector('.task-list__title').textContent = task.title;
```
### 4. JSDoc is an assertion and `safeParse` is validation

`@type` is a compile-time comment and does nothing at runtime — `tsc` believes it and lets it pass.
```js
// ❌ only an assertion — a wrong shape first surfaces on the screen
/** @type {Task} */
const task = await res.json();
// ✅ parse at the boundary (response · localStorage · URL)
const task = parseTask(await res.json());
```
### 5. The environment is read in one place, `config`

`src/config.js` parses at module top level, so a wrong value makes **the boot fail, not the first request**.
```js
// ❌ writing the base URL at every call site — neither the validation nor the place to change it is single
const res = await fetch('https://api.example.com/tasks', { signal });
// ✅ read one validated value (import { config } from '../config.js')
const res = await fetch(`${config.VITE_API_BASE}/tasks`, { signal });
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

**Do not use a path alias (`@/`).** When the bundler config and `paths` in `jsconfig.json` diverge, Vite
resolves it but the checker cannot find it. Write relative paths and **always add the `.js` extension**.
```js
// relative to src/components/. Pick only what you need
import { config } from '../config.js';
import { TaskSchema, TaskCreateSchema, parseTask } from '../schemas/task.js';
import { tasksStore } from '../store/tasks.js';
import { el, fromTemplate } from '../dom/el.js';
import { delegate } from '../dom/delegate.js';
import { createResource } from '../state/resource.js';
import { renderState } from '../state/render.js';
import { createRouter } from '../router/index.js';
import { interceptLinks } from '../router/links.js';
import { safeReturnTo } from '../router/return-to.js';
// owned by the seam — having no definition before assembly is normal
import { fetchTasks, createTask } from '../api/tasks.js';
import { session, requireSession } from '../auth/session.js';
```
<!-- /pack-slot -->

<!-- pack-slot: anti-patterns-axis -->
## Anti-Patterns — what is actually observed on this axis

| class | observed form | the fact on this axis |
| --- | --- | --- |
| framework habit | expecting the screen to follow when a value is changed | there is no reactivity — after `set`, the DOM is edited directly inside the `subscribe` callback |
| framework habit | redrawing the whole container every time the state changes | there is no diffing — a full replacement throws away scroll·focus·typed input. Fix only the changed row through `byId` |
| framework habit | assuming a `key` on the list is enough to line things up | nothing lines them up — find the row directly by `data-task-id` |
| framework habit | assuming the framework calls cleanup by itself | the caller is what calls it — fail to hold the return value of `mount*` and it leaks |
| lost disposer | `mountTaskList(root, tasksStore);` — the return is not taken | every entry and exit leaves one more set of subscription and delegation listeners running |
| lost disposer | a route's `render` returns nothing | the router has no cleanup to call — the return is `createRouter`'s contract |
| lost disposer | not calling `abort()` when leaving a route | an earlier response arriving late overwrites the next screen's container |
| lost disposer | a test that only mounts and never calls the cleanup function | the leak stays behind the green — assert it by firing the event once more after cleanup |
| assertion instead of validation | putting `@type` on a response·`localStorage` value and stopping there | tsc believes it and passes — `parseTask`·`safeParse` are what belong there |
| assertion instead of validation | taking a URL parameter as `@type {string}` and using it as-is | if it is a return path it becomes an open redirect — put it through `safeReturnTo` |
| assertion instead of validation | an export whose JSDoc is missing | it is not "there is no type" but **it is not checked** — an implicit `any` |
| argument order | swapping `delegate`'s `type`·`selector` | both are strings so the checker cannot catch it — nothing happens, silently |
<!-- /pack-slot -->

> **The slots below are written by L2** (L0 freezes only the directory tree):
> `core-principles-axis` · `common-imports-axis` · `architecture-overview` ·
> `quick-start-axis` · `anti-patterns-axis`.

## What the seam fills in

| slot | what |
| --- | --- |
| `data-fetching` | the actual API call · envelope parsing · cache. **Parse the response with `parseTask` and pass the `AbortSignal` to `fetch`** |
| `auth-and-session` | keeping and refreshing the token·session · the login/logout flow · the protected route's verdict. **A return path must always be put through `safeReturnTo`** |
| `complete-example` | schema → store → component → route → test, end to end |
