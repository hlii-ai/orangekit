<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# Loading·empty·error — five states, and the earlier response that revives unless you cancel

Owns: `createResource` in `src/state/resource.js` and `renderState` in `src/state/render.js`.
What it does not own — the actual API call (`fetchTasks`·`createTask`) is the seam's `data-fetching` slot, and
the domain store belongs to `resources/state-management.md`, the route lifetime to `resources/routing.md`, and the list
markup to `resources/component-patterns.md`.

## 1. Decision tree — what should be in the container right now

There are **five** states. Cut them to four and "not called yet" and "currently calling" land in the same
cell, and at that moment what to draw on the first paint disappears from the contract.

| state | when | screen |
| --- | --- | --- |
| `idle` | `load()` has not been called yet | **draw nothing** (with no view, leave it empty) |
| `loading` | the request went out and has not come back | a skeleton·spinner. Do not leave the previous data up |
| `empty` | **it succeeded** and the result holds 0 records | "No tasks yet" + a path to creating one |
| `error` | the request failed | "Could not load" + a retry button |
| `ready` | it succeeded and there is a result | the list |

- **Do not put `empty` and `error` in the same cell.** 0 records is normal and the thing to do is create one; a failure is abnormal and
  the thing to do is retry. Draw them as the same screen and an empty list reads as a breakage
- **Cancellation is not a state.** Nobody looks at the result of a screen already left, so `abort()` does not notify

## 2. The resource (`src/state/resource.js`)

**The contract is that `fetcher` takes an `AbortSignal`.** A new `load()` first cancels what is in
flight, and the result of a cancelled request is discarded even when it arrives.

<!-- file: src/state/resource.js -->
```js
// src/state/resource.js
import { createStore } from '../store/create.js';

/**
 * @template T
 * @typedef {{ status: 'idle' | 'loading' | 'empty' | 'error' | 'ready', data?: T, error?: Error }} ResourceState
 */

/**
 * @template T
 * @param {(signal: AbortSignal) => Promise<T>} fetcher
 * @param {{ isEmpty?: (data: T) => boolean }} [options]
 * @returns {{ subscribe(fn: (state: ResourceState<T>) => void): () => void, load(): void, abort(): void }}
 */
export function createResource(fetcher, options = {}) {
  const isEmpty = options.isEmpty ?? ((/** @type {T} */ d) => Array.isArray(d) && d.length === 0);
  const store = createStore(/** @type {ResourceState<T>} */ ({ status: 'idle' }));
  /** @type {AbortController | null} */
  let inflight = null;

  /** @returns {void} */
  function abort() { inflight?.abort(); inflight = null; }

  /** @returns {void} */
  function load() {
    abort();                                  // cancel what is in flight first
    const ctl = new AbortController();
    inflight = ctl;
    store.set({ status: 'loading' });
    fetcher(ctl.signal).then(
      (data) => {
        if (ctl.signal.aborted) return;       // discard an earlier response that arrived late
        inflight = null;
        store.set(isEmpty(data) ? { status: 'empty' } : { status: 'ready', data });
      },
      (cause) => {
        if (ctl.signal.aborted) return;
        inflight = null;
        store.set({ status: 'error', error: cause instanceof Error ? cause : new Error(String(cause)) });
      },
    );
  }

  return { subscribe: (fn) => store.subscribe(fn), load, abort };
}
```

- **Trap `ctl` in the closure.** Read `inflight` again and the next `load()` has already changed it, so
  the verdict is wrong — the code that fixes the race creates one
- **The `ctl.signal.aborted` check is a defense against the seam.** Even when the seam does not pass `signal` to
  `fetch` (the defect the `seam-signal-passed` policy aims at), a late response does not cover the screen
  <!-- verified: ran vitest with a fetcher that ignores signal — observed that only the last response remains -->
- The state object is **replaced whole**, so every transition notifies under the `Object.is` comparison

## 3. The race — without cancellation the earlier response covers the later one

**This defect is hard to reproduce.** It shows up only when the earlier request is slow, and on a dev machine both come back at once —
"it is not observed" is no ground for "it is not there".

```js
// ❌ positive control — call it twice without cancelling and arrival order decides the final state
const load = () => fetcher(new AbortController().signal).then((d) => { latest = d; });
load();              // takes 40ms  (/tasks?filter=all)
load();              // arrives at 0ms  (/tasks?filter=open)
// → latest is resp-1 (the later one), then gets covered by resp-0 (the earlier one)
```

It was run with a 40ms delay on the earlier request and 0ms on the later one. Without cancellation the arrival order is
`resp-1` → `resp-0`, so **what stays on the screen is the earlier request's result.** Run `createResource`
at the same delays and `abort()` cuts the earlier request, leaving only `resp-1`.
<!-- verified: both versions run and compared at the same delays under vitest@4.1.11 + happy-dom@20.11.6 -->

To the user it appears as **pressing a filter and seeing the previous filter's list**, and when moving between routes quickly as **data from the screen you left showing up on the next screen**.

## 4. Rendering the state (`src/state/render.js`)

<!-- file: src/state/render.js -->
```js
// src/state/render.js
/**
 * @template T
 * @param {Element} container
 * @param {import('./resource.js').ResourceState<T>} state
 * @param {{ idle?: () => Node, loading: () => Node, empty: () => Node,
 *           error: (error: Error) => Node, ready: (data: T) => Node }} views
 * @returns {void}
 */
export function renderState(container, state, views) {
  switch (state.status) {
    case 'idle':
      container.replaceChildren(...(views.idle ? [views.idle()] : []));
      return;
    case 'loading': container.replaceChildren(views.loading()); return;
    case 'empty': container.replaceChildren(views.empty()); return;
    case 'error': container.replaceChildren(views.error(state.error ?? new Error('unknown'))); return;
    case 'ready': container.replaceChildren(views.ready(/** @type {T} */ (state.data))); return;
  }
}
```

- **Only `idle` is optional.** With no view, the container is **left empty** — screens that do not put a spinner up
  on the first paint are common. The other four are mandatory, so tsc catches even one of them missing
- **`replaceChildren` is the only point that erases the previous screen.** It is handed a `Node` rather than a string, so
  the escaping contract of `el`·`fromTemplate` carries through (assigning `.innerHTML` is forbidden by policy)
- `state.data` is an optional field, so the `ready` branch needs one assertion — **a consequence of following the shape
  the ledger pinned down**, and it disappears if it is changed to a discriminated union (that is L0's share)

## 5. Do not carry `error.message` into the error view verbatim

**The hub and the ledger write down only this rule and not the reason. The reason is here.**

```js
// src/main.js — the route's views (excerpt)
// ❌ the server message lands on the screen verbatim: "500 at /srv/app/api/tasks.js:42 (db=prod-eu-1)"
error: (cause) => message(`Could not load: ${cause.message}`),
// ✅ an action for the user, diagnostics to the console·remote logging
error: (cause) => { console.error('[tasks]', cause); return message('Could not load the tasks'); },
```

- The reason is **not XSS.** It goes in through `textContent`, so tags are not parsed — the problem is **information
  disclosure**. A server message carries internal paths·stacks·host names·query fragments, and this axis has
  **no server layer to filter them out** (the deployable is static files, so the response reaches the browser as it is)
- Do not use the status code verbatim either. Turn `401` into "you need to log in again" and `5xx` into "try again shortly"
  — the action the user can take has to be on the screen
- **The `error` view receiving an `Error` means branch on it, not draw it**

## 6. Retry — the button comes first

The default is **a retry the user presses**. Call `resource.load()` again and the cancellation from §2 applies as it is,
so no duplicate request is left behind.

```js
// src/main.js — the retry in the error view
error: () => el('div', { class: 'state-error' }, [
  'Could not load the tasks',
  el('button', { onclick: () => resource.load() }, ['Try again']),
]),
```

When automatic retry is needed, **wrap the `fetcher`.** The wrapping layer takes the `signal` too, so cancellation has to
work even while waiting — otherwise the backoff keeps running after the route has been left.

```js
// src/main.js — waiting and backoff that honor cancellation
/** @param {number} ms @param {AbortSignal} signal @returns {Promise<void>} */
function sleep(ms, signal) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener('abort', () => { clearTimeout(timer); reject(signal.reason); }, { once: true });
  });
}

/** @template T @param {(s: AbortSignal) => Promise<T>} fetcher @param {number} attempts @returns {(s: AbortSignal) => Promise<T>} */
function withBackoff(fetcher, attempts = 3) {
  return async (signal) => {
    for (let i = 1; ; i += 1) {
      try { return await fetcher(signal); }
      catch (cause) {
        if (signal.aborted || i >= attempts) throw cause;
        await sleep(200 * 2 ** (i - 1), signal);   // 200 · 400 — there is a ceiling
      }
    }
  };
}
```

Set only a `setTimeout` and never listen to `signal` and cancellation is **deferred until the next attempt starts.**
Confirmed by running it: an `abort()` during the wait takes effect immediately and the `fetcher` calls stop at one.
<!-- verified: observed with vitest, separately, a success after 3 retries and a cancellation during the wait (1 call) -->

**Do not retry every failure.** `400`·`404`·`422` come back with the same answer however often you send them —
which failures are transient is decided by **the seam**, which knows the response envelope.

## 7. Where not to do an optimistic update

An optimistic update holds **only when there is a way back**. This axis has no layer that provides one for you.

| not done | why |
| --- | --- |
| putting a temporary row in the list and waiting for the response | on failure there is no ground on which to delete it. `upsertTask` has no delete, and the temporary id diverges from the server id |
| ticking the checkbox first and sending the request afterwards | restoring the previous value on failure means holding a snapshot, and that covers any other update that arrived in between |
| calling `load()` for the whole list again after an update | the user loses scroll·focus. Put the `Task` the response gave you in through `upsertTask` |

**There is one exception**: disabling a button·a spinner is not state but **an input lock**, so it does not go into the store.

## 8. The route lifetime is the request lifetime (`test/resource.test.js`)

**The lifetime of `AbortController` is tied to the router's.** The route's `render` creates the resource, and
the cleanup function it returns calls **both** the unsubscribe and `abort()` — the same form as §4 of
`resources/routing.md`. Miss either one and the response from the screen you left is drawn into the next screen's container.

<!-- file: test/resource.test.js -->
```js
// test/resource.test.js
import { describe, it, expect, vi } from 'vitest';
import { createResource } from '../src/state/resource.js';

/** @param {number[]} delays @returns {(signal: AbortSignal) => Promise<string[]>} */
function delayedFetcher(delays) {
  let call = 0;
  return (signal) => {
    const i = call; call += 1;
    return new Promise((resolve, reject) => {
      const t = setTimeout(() => resolve([`resp-${i}`]), delays[i]);
      signal.addEventListener('abort', () => { clearTimeout(t); reject(new Error('aborted')); });
    });
  };
}

describe('createResource', () => {
  it('cancels the earlier request, so only the later response remains (the earlier one arrives later)', async () => {
    const res = createResource(delayedFetcher([40, 0]));
    /** @type {string[]} */ const seen = [];
    /** @type {string[]} */ let data = [];
    const off = res.subscribe((s) => { seen.push(s.status); if (s.status === 'ready' && s.data) data = s.data; });
    res.load();
    res.load();
    await new Promise((r) => setTimeout(r, 80));
    expect(data).toEqual(['resp-1']);                              // the earlier response did not cover it
    expect(seen).toEqual(['idle', 'loading', 'loading', 'ready']); // it starts at idle
    off();
  });

  it('no further state comes out after abort()', async () => {
    const res = createResource(delayedFetcher([30]));
    const fn = vi.fn();
    res.subscribe(fn); res.load(); res.abort();
    await new Promise((r) => setTimeout(r, 60));
    expect(fn.mock.calls.map((c) => c[0].status)).toEqual(['idle', 'loading']);
  });
});
```

The first `it` is the most expensive assertion in this file. It looks at **`data` (it was blocked) and `seen` (every normal transition happened)
in the same `it`** — without `seen`, an implementation that deletes `load()` outright is green too. Delete the
`abort()` before `load()` and `data` goes red as `resp-0`; delete the `empty` verdict and the 0-record test goes red.
<!-- verified: ran each of the two mutated versions with vitest run and observed the failures -->

## Misuse list ① — TanStack Query · SWR habits → `createResource` idiom conversion table

| Old habit | The current form |
| --- | --- |
| `useQuery(['tasks'], fn)` | `createResource(fetchTasks)` + `subscribe`. There is no cache |
| a combination of `isLoading` · `isError` booleans | one `status` cell. It cannot express a combination that is impossible |
| judging `data?.length === 0` in the view | the `'empty'` state is that place — judge it in the view and it diverges file by file |
| `refetch()` | `load()` — it cancels what is in flight first |
| the hook cancelling on unmount by itself | **nobody cancels.** The route's cleanup function calls `abort()` |
| the `onMutate` rollback of `useMutation` | optimistic updates are not used (§7) |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `'empty'` vs `'error'` | the former when it succeeded with 0 records. The latter when the request failed |
| `'idle'` vs `'loading'` | the former before `load()`. Screens that do not put a spinner up on the first paint are here |
| `abort()` vs doing nothing | always the former when leaving a route. A late response covers the next screen |
| passing `signal` to `fetch` vs only receiving it | passing it is what makes cancellation actually work — it is the seam's duty |
| automatic backoff vs a retry button | the latter when the user is waiting. The former for a background refresh |
| rendering `error.message` vs a fixed phrase | **always the latter.** Send the message to the console·remote logging (§5) |
