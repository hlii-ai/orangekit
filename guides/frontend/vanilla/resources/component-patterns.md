<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# Component patterns — nothing is a component until its mount hands back a cleanup function

Owns: `el`·`fromTemplate` in `src/dom/el.js` · `delegate` in `src/dom/delegate.js` ·
`mountTaskList` in `src/components/task-list.js`. What it does not own — the class-name convention and
component tokens such as `--task-row-height` belong to `resources/styling.md`, the store and `upsertTask` to
`resources/state-management.md`, route changes to `resources/routing.md`, the loading·empty·error
screens to `resources/loading-error-states.md`, and procuring the data to the seam's `data-fetching`.

## 1. Decision tree — what do I build this DOM with

Read from the top and stop at the first row that fits. **The default is "do not build one"** — finding an existing
node with `querySelector` and fixing it is always cheaper, and it preserves focus·scroll.

| what to build | what to use | why |
| --- | --- | --- |
| a repeated row·card | `fromTemplate('task-row')` | the markup stays in `index.html` where it can be searched·reviewed·translated |
| text that carries user input | `textContent` · a string child of `el` | there is no auto-escaping |
| an `href`·`src` that carries user input | **check the scheme first** | `el` does not check it — `javascript:` is not stopped by `textContent` |
| a click·input on a list item | `delegate(root, …)` **once** | attach it per item and there are N things to dispose of |

## 2. Element creation and template cloning (`src/dom/el.js`)

`el` puts a string child in **only as a text node**. It is the only place escaping lives on this
axis, and there is no layer behind it to stop anything.

<!-- file: src/dom/el.js -->
```js
// src/dom/el.js
/**
 * @param {string} tag
 * @param {Record<string, unknown>} [props]
 * @param {(Node | string)[]} [children]
 * @returns {HTMLElement}
 */
export function el(tag, props = {}, children = []) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key.startsWith('on') && typeof value === 'function') {
      node.addEventListener(key.slice(2).toLowerCase(), /** @type {EventListener} */ (value));
    } else if (value != null && value !== false) {
      node.setAttribute(key, String(value));
    }
  }
  for (const child of children) {
    node.append(typeof child === 'string' ? document.createTextNode(child) : child);
  }
  return node;
}

/**
 * @param {string} id
 * @returns {DocumentFragment}
 */
export function fromTemplate(id) {
  const tpl = document.getElementById(id);
  if (!(tpl instanceof HTMLTemplateElement)) {
    throw new Error(`<template id="${id}"> is not in the document`);
  }
  return /** @type {DocumentFragment} */ (tpl.content.cloneNode(true));
}
```

`el('span', {}, ['<img src=x onerror="alert(1)">'])` has **zero child elements**. `props`, on the other hand,
becomes an attribute untouched — the `href` of `el('a', { href: 'javascript:…' })` stays as it is — so
**the rule is not to carry user input in `props`** (path validation is in `resources/routing.md`).
<!-- verified: observed by assertion in happy-dom@20.11.6 that childElementCount===0 and getAttribute('href') -->

Repeated markup is cloned from a `<template>`. `fromTemplate` in the file above gives back **a clone**, so the original stays, and
with the markup in `index.html` it can be searched·reviewed·translated, and string assembly disappears.

```html
<!-- index.html — the row markup. The class-name convention is owned by resources/styling.md -->
<template id="task-row">
  <li class="task-list__row">
    <button class="task-list__toggle" type="button" aria-pressed="false">Toggle done</button>
    <span class="task-list__title"></span>
  </li>
</template>
```

## 3. Event delegation (`src/dom/delegate.js`)

**The argument order is the most dangerous spot in this pack.** `type` and `selector` are **both strings**, so
swapping them still passes `tsc` and raises no runtime error — nothing simply happens.

<!-- file: src/dom/delegate.js -->
```js
// src/dom/delegate.js
/**
 * @param {Element} root
 * @param {string} type
 * @param {string} selector
 * @param {(event: Event, target: Element) => void} handler
 * @returns {() => void}
 */
export function delegate(root, type, selector, handler) {
  /** @param {Event} event */
  const onEvent = (event) => {
    const from = event.target;
    if (!(from instanceof Element)) return;
    const target = from.closest(selector);
    if (target && root.contains(target)) handler(event, target);
  };
  root.addEventListener(type, onEvent);
  return () => root.removeEventListener(type, onEvent);
}
```

```js
// ❌ the order is swapped — 'click' goes in as the selector and the selector as the event type. It dies silently
delegate(root, '[data-task-id]', 'click', onRow);
// ✅ root → event type → selector → handler
const offRow = delegate(root, 'click', '[data-task-id]', onRow);
```

The `target` the handler receives is not `event.target` (the `<button>` that was pressed) but the **row** `closest` found, and
`root.contains(target)` blocks the case where `closest` climbed out past the root.

## 4. Fix a row instead of swapping it out (`src/components/task-list.js`)

There is no diffing. So "redraw the whole container when the state changes" is, on this axis,
**a defect that throws away scroll·focus·typed input** — fix the rows that exist, delete only the rows that are gone.

<!-- file: src/components/task-list.js -->
```js
// src/components/task-list.js
import { el, fromTemplate } from '../dom/el.js';
import { delegate } from '../dom/delegate.js';
import { upsertTask } from '../store/tasks.js';
/** @typedef {import('../schemas/task.js').Task} Task */

/** @param {Task} task @returns {HTMLElement} */
function createRow(task) {
  const row = fromTemplate('task-row').querySelector('.task-list__row');
  if (!(row instanceof HTMLElement)) throw new Error('the task-row template has no .task-list__row');
  row.dataset.taskId = task.id;
  return row;
}

/** @param {HTMLElement} row @param {Task} task @returns {void} */
function patchRow(row, task) {
  const title = row.querySelector('.task-list__title');
  if (title) title.textContent = task.title;
  row.classList.toggle('task-list__row--done', task.status === 'done');
  row.querySelector('.task-list__toggle')?.setAttribute('aria-pressed', String(task.status === 'done'));
}

/** @param {HTMLElement} list @param {Task[]} tasks @returns {void} */
function syncRows(list, tasks) {
  /** @type {Map<string, HTMLElement>} */
  const stale = new Map();
  for (const node of list.children) {
    if (node instanceof HTMLElement && node.dataset.taskId) stale.set(node.dataset.taskId, node);
  }
  for (const task of tasks) {
    const row = stale.get(task.id) ?? createRow(task);
    stale.delete(task.id);
    patchRow(row, task);
    list.append(row);   // for a node already in the document, append 'moves' it — the order lines up
  }
  for (const gone of stale.values()) gone.remove();
}

/**
 * @param {Element} root
 * @param {typeof import('../store/tasks.js').tasksStore} store
 * @returns {() => void}
 */
export function mountTaskList(root, store) {
  const list = el('ul', { class: 'task-list' });
  root.replaceChildren(list);

  const offStore = store.subscribe((state) => syncRows(list, state.items));

  const offClick = delegate(root, 'click', '[data-task-id]', (_event, target) => {
    const id = /** @type {HTMLElement} */ (target).dataset.taskId;
    const task = id ? store.get().byId[id] : undefined;
    if (task) upsertTask({ ...task, status: task.status === 'open' ? 'done' : 'open' });
  });

  return () => {
    offStore();
    offClick();
  };
}
```

## 5. The mount and cleanup contract (`src/components/task-list.js`)

§4 carries the full text. `subscribe` **emits once with the current value the instant it registers**, so `mountTaskList` has
no separate "first render" — call the initial render once more by hand and it **draws twice.**
The return value is the **cleanup function**. Throw it away and the store subscription and the delegation listener stay behind as a leak.

- **The return value is the only unmount path.** A route's `render` can hand this value straight back
- **A cleanup function undoes everything it created.** Call only one and the other half stays behind, and that half
  does not show up in tests — §7 is the device that catches it
- **Write through `upsertTask`** (calling `store.set` directly misses the `byId` update)

## 6. Shared components — search before you build

**Most duplication is not an extraction failure but a search failure.** This axis has no registry that
finds a component for you. Before creating a new component file, run the following **without exception**.

```bash
rg -n "mount" src/components/                # see every mount function that already exists
rg "class=\"task-" index.html src/           # does the markup for this component already exist
```

If what you find is 90% the same, add one parameter. If the only differences are spacing·height·font size, it is not a new
component but **a difference in token values**, changed only through `--task-row-height` (`resources/styling.md`).

- **One file = one mount function = one class prefix.** `src/components/task-list.js` owns
  `.task-list*`. Let them diverge and you will not know what dies when you delete CSS
- **Do not import the store; take it as `(root, store)`.** There is no exception to returning a cleanup function

## 7. Tests that prove cleanup (`test/task-list.test.js`)

**An assertion that "it returns a disposer" is not a block proof.** Pair "**it reacts before** cleanup" with
"**it does not react after** cleanup" inside the same `it`.

<!-- file: test/task-list.test.js -->
```js
// test/task-list.test.js
import { it, expect } from 'vitest';
import { el } from '../src/dom/el.js';
import { mountTaskList } from '../src/components/task-list.js';
import { tasksStore, replaceTasks } from '../src/store/tasks.js';

/** @type {import('../src/schemas/task.js').Task} */
const base = { id: 't1', ownerId: 'u1', title: 'Report draft', status: 'open', createdAt: '2026-08-24T03:00:00Z' };

/** @returns {HTMLElement} */
function fixture() {
  const tpl = /** @type {HTMLTemplateElement} */ (el('template', { id: 'task-row' }));
  tpl.content.append(el('li', { class: 'task-list__row' }, [
    el('button', { class: 'task-list__toggle', type: 'button' }),
    el('span', { class: 'task-list__title' }),
  ]));
  const root = el('div');
  document.body.append(tpl, root);
  replaceTasks([]);
  return root;
}

it('the cleanup function of mountTaskList cuts both the subscription and the delegation', () => {
  const root = fixture();
  const stop = mountTaskList(root, tasksStore);

  replaceTasks([base]);
  const row = /** @type {HTMLElement} */ (root.querySelector('[data-task-id="t1"]'));
  expect(row.querySelector('.task-list__title')?.textContent).toBe('Report draft');
  row.click();
  expect(tasksStore.get().byId.t1.status).toBe('done');

  replaceTasks([{ ...base, status: 'done' }]);
  expect(root.querySelectorAll('[data-task-id]')).toHaveLength(1);
  expect(root.querySelector('[data-task-id="t1"]')).toBe(row);

  stop();

  replaceTasks([{ ...base, title: 'Changed title' }]);
  expect(row.querySelector('.task-list__title')?.textContent).toBe('Report draft');
  row.click();
  expect(tasksStore.get().byId.t1.status).toBe('open');
});
```

Without the assertions before `stop()`, the two that follow are indistinguishable from "everything is broken". **All five
mutations go red**: deleting `offStore()` · deleting `offClick()` · replacing `delegate`'s return with `() => {}` ·
removing row reuse from `syncRows` · replacing `syncRows` with `list.replaceChildren(...)`.
<!-- verified: 5 comparison runs with vitest@4.1.11 + happy-dom@20.11.6 · typescript@7.0.2(checkJs+strict) -->
The fixture uses `tpl.content.append(...)` because whether a child simply `append`ed to the element made by
`createElement('template')` lands in `content` differs from environment to environment. <!-- unverified: not run in a real browser · only observed in happy-dom@20.11.6 that template.append is absorbed into content -->

## Misuse list ① — React·Vue habits → direct-DOM idiom conversion table

| Old habit | The current form |
| --- | --- |
| `useEffect(… return cleanup)` · `onUnmounted` | there is none. The caller calls what `mountTaskList` returned |
| `dangerouslySetInnerHTML` · `v-html` | there is no counterpart. Repeated markup is `fromTemplate` + `textContent` |
| leaving reconciliation to `key={task.id}` | pair them yourself with `row.dataset.taskId` + a `Map` |
| re-rendering the container whenever the state changes | `syncRows` — fix the rows that exist and delete only the ones that are gone |
| `onClick={…}` on every item | `delegate(root, 'click', '[data-task-id]', …)` once |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `delegate(root, type, selector, h)` vs `(root, selector, type, h)` | **always the former.** Both are strings, so the checker passes a swap |
| `event.target` vs the handler's `target` | the node actually pressed is the former, the row `closest` found is the latter. What you wire against is the latter |
| `textContent` vs carrying a value in `props` | user input **always through the former**. `href`·`src` do not go to the latter without a scheme check |
| `store.set(...)` vs `upsertTask(...)` | in a component, **always the latter** |
| `querySelector` by id vs collecting into a `Map` | **always the latter.** Put a server string into selector syntax and one quote mark breaks it |
