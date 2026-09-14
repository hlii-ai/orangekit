<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# Routing — a single entry point, and what dies when you leave a screen

Owns: `createRouter` (`src/router/index.js`) · `interceptLinks` (`src/router/links.js`) ·
`safeReturnTo` (`src/router/return-to.js`). What it does not own — the loading·empty·error render belongs to
`resources/loading-error-states.md`, the DOM helpers to `resources/component-patterns.md`, and global state to
`resources/state-management.md`. The login screen·token storage·session refresh are the seam's `auth-and-session`
slot, and this file **only calls** `session`·`requireSession`.

## 1. Decision tree — does this value belong in the URL

On this axis the URL is **the only store that survives a refresh**. Read from the top and stop at the first row that fits.

| this value… | where it goes | why |
| --- | --- | --- |
| has to be shareable by link | a path segment (`/tasks/:id`) | the address bar is the state |
| has to survive a refresh·the back button | the query (`?filter=open`) | the history entry remembers it |
| where to go back to after login | the query — **but only a value that passed `safeReturnTo`** (§5) | carry it unvalidated and it is an open redirect |
| the scroll position | `history.state` (§7) | it differs per entry, so it is not global |

**A value read from the URL is not trusted input.** Both `params` and the query can be edited by the user — validate at the boundary with `safeParse` (`resources/types-and-testing.md`), and send the return path to §5.

## 2. The router (`src/router/index.js`)

**Each route's `render(params)` returns a cleanup function.** There is no framework, so that return value is the only thing the
router can call before it draws the next screen. `start()` hands back its own disposer as well.

<!-- file: src/router/index.js -->
```js
// src/router/index.js — matching and lifetime
/**
 * @typedef {(params: Record<string, string>) => (() => void)} RouteRender
 * @typedef {{ path: string, render: RouteRender }} Route
 */

/** Matches the segments of `/tasks/:id`. `'*'` matches anything.
 * @param {string} pattern @param {string} pathname @returns {Record<string, string> | null} */
function matchPath(pattern, pathname) {
  if (pattern === '*') return {};
  const pat = pattern.split('/').filter(Boolean);
  const seg = pathname.split('/').filter(Boolean);
  if (pat.length !== seg.length) return null;
  /** @type {Record<string, string>} */
  const params = {};
  for (let i = 0; i < pat.length; i += 1) {
    if (pat[i].startsWith(':')) params[pat[i].slice(1)] = decodeURIComponent(seg[i]);
    else if (pat[i] !== seg[i]) return null;
  }
  return params;
}

/** @param {Route[]} routes @returns {{ start(): () => void, navigate(path: string): void }} */
export function createRouter(routes) {
  /** @type {(() => void) | null} */
  let dispose = null;
  let running = false;

  /** @returns {void} */
  function renderCurrent() {
    if (dispose) dispose();          // the previous screen's cleanup comes before the next screen's render
    dispose = null;
    for (const route of routes) {
      const params = matchPath(route.path, window.location.pathname);
      if (params === null) continue;
      dispose = route.render(params);
      return;
    }
  }

  return {
    start() {
      window.history.scrollRestoration = 'manual';   // do not fight the browser's own restoration
      /** @param {PopStateEvent} e @returns {void} */
      const onPop = (e) => {
        renderCurrent();
        const state = /** @type {{ scrollY?: number } | null} */ (e.state);
        window.scrollTo(0, state?.scrollY ?? 0);     // the back button goes to where it was
      };
      window.addEventListener('popstate', onPop);
      running = true;
      renderCurrent();
      return () => { running = false; window.removeEventListener('popstate', onPop); if (dispose) dispose(); };
    },
    /** @param {string} to @returns {void} */
    navigate(to) {
      if (!running) return;
      // stamp the position on the entry being left and push the new entry
      window.history.replaceState({ scrollY: window.scrollY }, '', window.location.pathname + window.location.search);
      window.history.pushState({ scrollY: 0 }, '', to);
      renderCurrent();
      window.scrollTo(0, 0);                         // a new screen starts at the top
    },
  };
}
```

- **Call cleanup first, then draw.** Reverse it and the previous screen's subscription writes into the new container once more
- Put the `'*'` route **last in the array** — put it earlier and the 404 swallows the other paths
- Without the `running` flag, a `navigate()` after `stop()` **redraws into a detached container**. The contract of a cleanup function runs all the way to stopping the router <!-- verified: observed in happy-dom@20.11.6 that navigate() after stop() performs a render, then blocked it with the flag -->

## 3. Link interception (`src/router/links.js`) — the list cannot be shortened

Intercept `<a href>` wholesale and "open in a new tab" breaks silently — and **missing a single item** does it.

<!-- file: src/router/links.js -->
```js
// src/router/links.js
/** @param {Element} root @param {(path: string) => void} navigate @returns {() => void} */
export function interceptLinks(root, navigate) {
  /** @param {Event} event @returns {void} */
  const onClick = (event) => {
    const e = /** @type {MouseEvent} */ (event);
    if (e.defaultPrevented || e.button !== 0) return;                 // middle·right click
    if (e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) return;     // ⌘·Ctrl·Shift·Alt
    const from = /** @type {Element | null} */ (e.target);
    const anchor = from?.closest('a[href]');
    if (!(anchor instanceof HTMLAnchorElement)) return;
    if (anchor.hasAttribute('target') || anchor.hasAttribute('download')) return;
    const url = new URL(anchor.href, window.location.origin);
    if (url.origin !== window.location.origin) return;                // an external origin·mailto:
    e.preventDefault();
    navigate(url.pathname + url.search + url.hash);
  };
  root.addEventListener('click', onClick);
  return () => root.removeEventListener('click', onClick);
}
```

| what is not intercepted | what breaks |
| --- | --- |
| ⌘·Ctrl·Shift·Alt · `e.button !== 0` | open in a new tab·new window, middle click |
| `target` · `download` | `_blank` opens in the same tab, and the file is not saved |
| a different origin | an external link turns into a 404 inside the app. `mailto:`·`tel:` are caught here too |

Checking `e.defaultPrevented` first keeps a click another handler already dealt with from being handled twice. `anchor.href` is
a value the DOM has already made absolute, so even a relative path is caught by the origin comparison. This verdict cannot be
replaced by `safeReturnTo` — that one looks at a **string**, this one at an **element**.

## 4. Protected routes — the enforcement point lives inside the pack

In `requireSession(navigate, returnTo)`, **`returnTo` is already a validated value.** Leave the validation to the seam and the `safe-return-to` policy cannot see it — the **caller** that puts it through is here.

```js
// src/main.js — a protected route (the route screen sits inline in the routes array)
/** @param {Record<string, string>} _params @returns {() => void} */
function renderTasks(_params) {
  const here = window.location.pathname + window.location.search;
  // ❌ carries the current address unvalidated — the seam puts it into the login URL query
  // if (!requireSession(router.navigate, here)) return () => {};
  // ✅ the enforcement point is inside the pack
  if (!requireSession(router.navigate, safeReturnTo(here))) return () => {};

  const resource = createResource(fetchTasks);
  const off = resource.subscribe((state) => renderState(outlet, state, views));
  resource.load();
  return () => { off(); resource.abort(); };   // leaving the route kills the request in flight
}
```

- **When unauthenticated, return an empty cleanup function.** Even with nothing to undo, hand back `undefined` and the router
  blows up on the next transition
- The cleanup function it returns calls **both the unsubscribe and `abort()`** — it is this cluster's joint, and
  the details are in `resources/loading-error-states.md` §8
- The side where the login screen **reads** `?returnTo=` is owned by the seam, and the seam has to put it through the same
  function too (the `auth-and-session` slot in `pack.json` writes it down as an obligation)

## 5. Return-path validation (`src/router/return-to.js`)

**This is the spot where an open redirect recurred three times in this repository.** `startsWith('/')` alone is
**not enough**, and neither is the origin comparison of `new URL()` alone. The four layers below each block something different.

<!-- file: src/router/return-to.js -->
```js
// src/router/return-to.js
/**
 * Validates the path to return to after login. Returns an internal path only, otherwise '/'.
 * **It does not throw** — so that the caller has no way to catch the failure and route around it.
 *
 * @param {unknown} raw
 * @returns {string}
 */
export function safeReturnTo(raw) {
  const fallback = '/';
  if (typeof raw !== 'string' || raw === '') return fallback;
  if (/[\u0000-\u001f\u007f]/.test(raw)) return fallback;
  if (!raw.startsWith('/')) return fallback;
  try {
    const url = new URL(raw, window.location.origin);
    if (url.origin !== window.location.origin) return fallback;
    const path = url.pathname;
    if (!path.startsWith('/') || path.startsWith('//') || path.startsWith('/\\')) return fallback;
    return path + url.search + url.hash;
  } catch {
    return fallback;
  }
}
```

| layer | what it blocks | what happens if you delete it |
| --- | --- | --- |
| rejecting control characters | `/tasks\n\rSet-Cookie: x=1` | the URL parser **silently strips** the control characters and hands back `/tasksSet-Cookie:%20x=1`. That path does not exist in the SPA router, but if the seam carries the same string into a server `Location` it becomes response splitting |
| `startsWith('/')` | `javascript:` · `https://` · a relative path | the scheme·host reaches the parser (the next layer catches it, but the layers overlap) |
| the `url.origin` comparison | `/\evil.example` | `new URL()` normalizes the backslash into a slash, so **the host becomes `evil.example`** |
| the `'//'` check on `pathname` | `/..//evil.example` | the parser lets the origin through and **then** normalizes the dot segments, so the result is `//evil.example` again |

**Both the third and the fourth are needed.** Keep only the origin comparison and `/..//evil.example` passes; keep only the `pathname` check and `/\evil.example` passes. The gate's `check_security_shapes` enforces the fourth.

## 6. Vector verdicts — confirmed by deleting layers

The 12 items in section A of `assets/security-vectors.md` were confirmed by **actually feeding them in**. The criterion is not
"it falls to the fallback" but **"the result never leaves its own origin"**.

| vector | input | output | verdict |
| --- | --- | --- | --- |
| A1·A2·A3·A4 | `//evil.example` · `/\evil.example` · `https://evil.example` · `javascript:alert(1)` | `'/'` | blocked |
| A5·A6 | `/..//evil.example` · `/../..//evil.example` | `'/'` | blocked |
| A7·A8·A9 | `%2f%2fevil.example` · `/tasks\n\rSet-Cookie: x=1` · `\tjavascript:alert(1)` | `'/'` | blocked |
| A10 | `''` · `null` · `42` (a non-string input) | `'/'` | blocked |
| A11·A12 | `/tasks?filter=open#top` · `/tasks/123` | the input verbatim | **passes — block it here and the feature dies** |

<!-- verified: ran the 12 items + 2 more (null·number) under node 22. Used the unsafe() predicate from pack-smoke.sh verbatim -->

A **positive control** was run alongside — because a broken implementation that blocks everything is green on the first four rows
too. The version keeping only the prefix check **returns A1·A2·A8 verbatim**, and the one keeping only the origin comparison
**returns A5·A6 as `//evil.example`**. A11·A12 passed in all four versions — the last row is the proof of "it does not block".
<!-- verified: ran 4 mutated versions through the same vector runner and observed FAILs of 3 / 2 / 0 / 0 -->

## 7. 404 and scroll restoration

**A 404 is a route.** Special-case a match failure with an `if` and you create a screen that leaks outside the cleanup contract — the `'*'` at the end of the array is that place, and it returns a cleanup function exactly like any other route.

§2 carries the code in full. **The `replaceState` right before leaving is the key** — stamp the position on a module variable instead of on the history **entry** and several steps of the back button all give the same value. Without `'manual'` turned on, the browser's own restoration and `scrollTo` overlap and the screen jumps. The real scroll position·restoration timing **could not be verified in a real browser.**
<!-- unverified: the authoring environment has no browser. In happy-dom scrollY is always 0, so only the round trip of the value is confirmed by proxy -->

## 8. Tests that prove the block (`test/return-to.test.js`)

**Asserting only that every attack input becomes `'/'` is not a guard.** Replace the function body with
the single line `return '/'` and it is still green. Pair the normal path with it **in the same file, the same `it`**.

<!-- file: test/return-to.test.js -->
```js
// test/return-to.test.js
import { describe, it, expect } from 'vitest';
import { safeReturnTo } from '../src/router/return-to.js';

describe('safeReturnTo', () => {
  it('lets an internal path through and blocks every form that goes outside', () => {
    expect(safeReturnTo('/tasks?filter=open#top')).toBe('/tasks?filter=open#top');
    expect(safeReturnTo('/tasks/123')).toBe('/tasks/123');

    for (const attack of [
      '//evil.example', '/\\evil.example', 'https://evil.example', 'javascript:alert(1)',
      '/..//evil.example', '/../..//evil.example', '%2f%2fevil.example',
      '/tasks\n\rSet-Cookie: x=1', '\tjavascript:alert(1)', '', null, 42,
    ]) {
      expect(safeReturnTo(attack)).toBe('/');
    }
  });

  it('looks at the output after the dot segments are normalized', () => {
    const url = new URL('/..//evil.example', window.location.origin);
    expect(url.origin).toBe(window.location.origin);   // the origin comparison lets this through
    expect(url.pathname).toBe('//evil.example');       // after normalization the output points outward
    expect(safeReturnTo('/..//evil.example')).toBe('/');
    expect(safeReturnTo('/tasks/../done')).toBe('/done');
  });
});
```

The second `it` is the most expensive assertion in this file. It reads **a value the browser's `URL` parser produced itself**,
so it is not circular verification reading back a value we put in, and deleting the layer that looks at `//` turns the last two
assertions red immediately. `/tasks/../done` is the control showing that normalization happens **on a normal path too**.
<!-- verified: passes under vitest@4.1.11 + happy-dom@20.11.6, and the failure was observed in the mutated version with the layer deleted -->

`test/router.test.js` likewise asserts **an intercepted link and a non-intercepted link in the same `it`**.
In happy-dom a link that is not intercepted really does try to follow the page, so a listener that swallows the default
behavior is put at the document level and `e.defaultPrevented` is read.
<!-- verified: observed that this it goes red in the mutated version with the modifier-key check deleted -->

## Misuse list ① — React Router · Vue Router habits → History API idiom conversion table

| Old habit | The current form |
| --- | --- |
| `<Link to="/tasks">` | a plain `<a href="/tasks">` + `interceptLinks` catching it by delegation |
| `useParams()` | the argument `render(params)` receives. **It came from the URL, so it is not trusted input** |
| `useNavigate()` | `router.navigate(path)` — take the router instance from the module |
| `<Route element={…}>` handling the unmount | `render` **returns a cleanup function** and the router calls it |
| protecting with `<Navigate to="/login" />` | `requireSession(navigate, safeReturnTo(raw))`, then return an empty cleanup function |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `pushState` vs `replaceState` | the former for a new screen, the latter **when stamping the scroll onto the entry being left** |
| `safeReturnTo` vs the origin comparison in `interceptLinks` | the former judges a string, the latter an `<a>` element. Neither stands in for the other |
| `url.origin` vs `url.pathname` | **look at both.** Look at only one and the other row of the §5 table is open |
| a `'*'` route vs an `if` on match failure | always the former — it does not create a screen that leaks outside the cleanup contract |
| `render` returning `undefined` vs `() => {}` | the latter, even when nothing was created. The router calls it |
