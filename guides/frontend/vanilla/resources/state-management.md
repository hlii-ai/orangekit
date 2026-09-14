<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# State management — a module-scope store, and a disposer that leaks unless it is returned

Owns: `createStore`·`derive` in `src/store/create.js` and `tasksStore` in `src/store/tasks.js`.
What it does not own — the `Task` type the store handles belongs to `resources/types-and-testing.md`,
the component that consumes the subscription (`mountTaskList`) to `resources/component-patterns.md`,
and the three states of an async load (`createResource`) to `resources/loading-error-states.md`.
Fetching the value from the server at all is the seam's `data-fetching` slot.

## 1. Decision tree — where does this state go

**The default is not a store.** There is no framework, so every store you create adds one more
subscription that has to be disposed of. Read from the top and stop at the first row that fits.

| this state… | where it goes | why |
| --- | --- | --- |
| has to survive a refresh·a share·the back button | the URL (`resources/routing.md`) | the link is the state |
| is born and dies inside one function | a local variable | no subscription means no disposal |
| one component's open/closed·focus | that component's closure | nobody outside reads it |
| one request's progress·failure | `createResource` | the three states and cancellation are already bound together |
| **two or more places read the same value and one writes it** | a module-scope store | this is where a store begins |
| whether the user is logged in | the seam's `session` | the axis does not decide it |

"into a store, in case we need it later" is especially expensive on this axis — a subscription whose disposal was
forgotten does not show up in tests and piles up on every route change.

## 2. The store factory (`src/store/create.js`)

`@template T` is the whole of this file. **Miss it and every value held in the store becomes `any`**,
and even with `checkJs` on it will not catch a single typo.

<!-- file: src/store/create.js -->
```js
// src/store/create.js
/**
 * @template T
 * @param {T} initial
 * @returns {{ get(): T, set(next: T | ((prev: T) => T)): void, subscribe(fn: (value: T) => void): () => void }}
 */
export function createStore(initial) {
  let value = initial;
  /** @type {Set<(value: T) => void>} */
  const listeners = new Set();

  return {
    get: () => value,
    set(next) {
      const resolved = typeof next === 'function'
        ? /** @type {(prev: T) => T} */ (next)(value)
        : next;
      if (Object.is(resolved, value)) return;
      value = resolved;
      for (const fn of listeners) fn(value);
    },
    subscribe(fn) {
      listeners.add(fn);
      fn(value);
      return () => listeners.delete(fn);
    },
  };
}

/**
 * @template T, U
 * @param {{ get(): T, subscribe(fn: (value: T) => void): () => void }} store
 * @param {(value: T) => U} selector
 * @returns {{ get(): U, subscribe(fn: (value: U) => void): () => void }}
 */
export function derive(store, selector) {
  return {
    get: () => selector(store.get()),
    subscribe(fn) {
      let prev = /** @type {U | undefined} */ (undefined);
      let primed = false;
      return store.subscribe((value) => {
        const next = selector(value);
        if (primed && Object.is(next, prev)) return;
        prev = next;
        primed = true;
        fn(next);
      });
    },
  };
}
```

Three things are the contract.

- **`subscribe` calls once with the current value the instant it registers.** That is why the mount code never grows two
  paths, "the first render" and "updates afterwards" — subscribing is the render
- **The return value of `subscribe` is the disposer.** This axis has no unmount hook. Do not return it and
  the very means of disposal is gone
- **The identity comparison is `Object.is`, that is, by reference.** A new object literal notifies even when the contents are equal.
  That is what makes "one single `set`" in §5 matter

Put the same factory beside a version that fudges it with `@param {*}` and the difference shows — the typo
`store.get().items[0].titel` is caught as `TS2551` in the generic version, while in the `*` version **not a single
error appears.** <!-- verified: both versions run and compared in the same file with typescript@7.0.2 checkJs+strict -->

## 3. Subscribe and dispose — the creating side returns it, the receiving side keeps it

The machine can see **the return**, but it cannot see **the caller throwing it away**.
Taking the disposer and never using it is the representative leak of this axis.

```js
// ❌ the disposer was thrown away — this subscription lives until the page closes
tasksStore.subscribe((s) => { root.textContent = String(s.items.length); });

// ✅ keep it, and the cleanup function calls it
function mountCounter(root) {
  const offTasks = tasksStore.subscribe((s) => { root.textContent = String(s.items.length); });
  return () => offTasks();
}
```

With two or more subscriptions, collect them in an array and release them at once. A cleanup function **has to be safe to call repeatedly** —
`Set.delete` quietly returns `false` for an element that is not there, so this implementation satisfies that condition.
A component like `mountTaskList`, which returns the delegation disposer as well, uses the same form.

```js
// bundle several subscriptions into one cleanup function
const offs = [
  tasksStore.subscribe((s) => { list.textContent = String(s.items.length); }),
  openCount.subscribe((n) => { badge.textContent = String(n); }),
];
return () => offs.forEach((off) => off());
```

## 4. Derived values (`src/store/create.js`)

§2 carries the full text. A derivation is **read-only** — not giving it a `set` is the design. Give it one and the same
truth exists in two places, and the moment the two diverge there is no ground on which to decide which is right.

The disposer of `derive` **hands back the source store's disposer as it is.** Dispose of the derivation and
the source subscription is released with it — there is no separate lifetime to manage per derivation.

**A selector returns a primitive by default.** The comparison is `Object.is`, so a selector that builds a new array
every time filters nothing out.

```js
// ❌ a new array on every call, so a notification goes out whenever the source changes
const openTasks = derive(tasksStore, (s) => s.items.filter((t) => t.status === 'open'));

// ✅ narrow to a comparable value — a count·a flag·the length of an id array
const openCount = derive(tasksStore, (s) => s.items.filter((t) => t.status === 'open').length);
```

When the list itself is needed, do not derive it; compute it inside the subscription each time. The render function redraws
the whole thing anyway.

## 5. The domain store (`src/store/tasks.js`)

Keep `items` (order) and `byId` (lookup) **together**. The point is to keep a single-record update from requiring a walk over
the list, and the price is that **both fields must always change inside the same `set`.** Split it into two calls and
in between a subscriber renders half a state.

<!-- file: src/store/tasks.js -->
```js
// src/store/tasks.js
import { createStore } from './create.js';
/** @typedef {import('../schemas/task.js').Task} Task */
/** @typedef {{ items: Task[], byId: Record<string, Task> }} TasksState */

export const tasksStore = createStore(/** @type {TasksState} */ ({ items: [], byId: {} }));

/** @param {Task[]} tasks @returns {void} */
export const replaceTasks = (tasks) => tasksStore.set({
  items: tasks,
  byId: Object.fromEntries(tasks.map((t) => [t.id, t])),
});

/** @param {Task} task @returns {void} */
export const upsertTask = (task) => tasksStore.set((prev) => {
  const exists = task.id in prev.byId;
  return {
    items: exists ? prev.items.map((t) => (t.id === task.id ? task : t)) : [...prev.items, task],
    byId: { ...prev.byId, [task.id]: task },
  };
});
```

Wrap updates in named functions inside the same module — rewrite the shape of `set` at every call site and
one place will certainly miss the `byId` update. **These two are the store's public write surface**:
components, and the results of the seam's `fetchTasks`·`createTask`, all come in here. The moment a place appears
that calls `tasksStore.set` directly from outside the module, that place is the next defect.

- **What goes into the store is an already-parsed `Task`.** Put in a value that did not pass the boundary parser
  (`parseTask`) and the type assertion of `TasksState` becomes false at that instant
- **Use the updater form (`set((prev) => …)`).** Call `get()` and then `set()` separately and you overwrite
  whatever else was updated in between
- `status` is the lowercase `'open'`·`'done'` — use the **value** `TaskStatus` fixed, verbatim

## 6. Where not to use a store

| situation | instead |
| --- | --- |
| the loading·error of a response just received from the server | `createResource` — the three states and cancellation come with it |
| the current route·query parameters | the URL is the original. Copy it into a store and it diverges from the back button |
| a value that can be read from the DOM (`input.value`·scroll position) | read it when you need it. Mirroring creates sync bugs |
| a derivable value (a count·a filter result·a sort) | `derive`. Store it as a separate field and you will forget to update it |
| the logged-in user | the seam's `session` |
| a form draft used once and discarded | a local variable. Put it in a store and it is still there on the next visit |

## 7. Tests that prove disposal (`test/store.test.js`)

**An assertion that "it returns a disposer" is not a block proof.** The return value being a function and that function
actually cutting off notification are different things. Pair the positive path (before disposal it receives) with it **inside the same `it`**.

<!-- file: test/store.test.js -->
```js
// test/store.test.js
import { describe, it, expect, vi } from 'vitest';
import { createStore, derive } from '../src/store/create.js';

describe('createStore', () => {
  it('a subscription receives once immediately and receives nothing after disposal', () => {
    const store = createStore(0);
    /** @type {number[]} */
    const seen = [];
    const off = store.subscribe((v) => seen.push(v));
    expect(seen).toEqual([0]);
    store.set(1);
    expect(seen).toEqual([0, 1]);
    off();
    store.set(2);
    expect(seen).toEqual([0, 1]);
    expect(store.get()).toBe(2);
  });

  it('assigning the same value does not notify', () => {
    const store = createStore('open');
    const fn = vi.fn();
    store.subscribe(fn);
    store.set('open');
    expect(fn).toHaveBeenCalledTimes(1);
    store.set('done');
    expect(fn).toHaveBeenCalledTimes(2);
  });
});

describe('derive', () => {
  it('notifies only when the selected value changes, and disposal cuts the source too', () => {
    const store = createStore({ items: [1], other: 'a' });
    const len = derive(store, (s) => s.items.length);
    const fn = vi.fn();
    const off = len.subscribe(fn);
    store.set({ items: [1], other: 'b' });
    expect(fn).toHaveBeenCalledTimes(1);
    store.set({ items: [1, 2], other: 'b' });
    expect(fn).toHaveBeenCalledTimes(2);
    off();
    store.set({ items: [], other: 'b' });
    expect(fn).toHaveBeenCalledTimes(2);
  });
});
```

The reason `store.get()` being `2` after `off()` is asserted alongside is to pin down that disposal **cuts only this
subscription rather than stopping the store**. Delete the `Object.is` comparison in the second `it`
and the first assertion goes red immediately. <!-- verified: both forms run and compared with vitest@4.1.11 + happy-dom@20.11.6 -->

## Misuse list ① — Redux · Zustand habits → module-scope store idiom conversion table

| Old habit | The current form |
| --- | --- |
| `dispatch({ type: 'ADD' })` + a reducer | `upsertTask(task)` — a named function is the action |
| `useSelector(s => s.x)` | `derive(store, (s) => s.x)` + `subscribe` |
| subscribing through a `useStore()` hook | put the disposer `subscribe` returned into the cleanup function |
| the hook disposes on unmount by itself | **nobody disposes.** Keeping the return value is the contract |
| everything in one store via `createSlice` | one module per domain. `src/store/tasks.js` |
| mutating a draft with `immer` | build a new object — the `Object.is` comparison presumes it |
| injecting with `<Provider>` | a module import. An SPA has one tree, so there is nothing to inject into |
| the `subscribeWithSelector` middleware | `derive` is that place |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `store.set(v)` vs `store.set((prev) => …)` | always the latter when the previous value has to be read |
| `derive` vs computing inside the subscription | the former when it narrows to a primitive, the latter when it builds an array·object |
| `subscribe` vs `get` | the former to react when a value changes, the latter to read once, now |
| a module-scope store vs a component closure | the former when there are two or more readers |
| a store vs the URL | the URL when it has to survive a refresh·a share |
| `items` vs `byId` | the former for order·render, the latter for a single lookup·an existence check. **When writing, always both** |
| calling `off()` vs only keeping the reference | keeping it is half of it. The contract runs through the cleanup function actually calling it |
