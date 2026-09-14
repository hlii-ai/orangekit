<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
# Styling — layers take over the specificity fight, and a component owns its own tokens

Owns: `src/styles/tokens.css` (`@layer tokens`) · `src/styles/base.css` (`@layer base`) ·
`src/components/task-list.css`. The ledger registers the last file as `taskListStyles` — which does not mean
that identifier exists in the code, but that **one CSS file is the unit of a symbol**. What it does not own —
the DOM code that actually adds and removes classes belongs to `resources/component-patterns.md`, and the structure
of the loading·empty·error screens to `resources/loading-error-states.md`.

## 1. Decision tree — where does this value go

The build tool does not create a scope for you. **The file and the name prefix are the only scope.**

| this value… | where it goes | why |
| --- | --- | --- |
| a color·spacing·typography that two or more components read | `src/styles/tokens.css` (`@layer tokens`) | a global token. Its name must not carry a component |
| an element's default look (`body` · `:focus-visible`) | `src/styles/base.css` (`@layer base`) | the layer is lower, so a component always wins |
| one component's height·spacing·typography | that component's CSS (`@layer components`) | as with `--task-row-height`, the prefix states the ownership |
| a look that changes with state | a modifier class (`.task-list__row--done`) | JS only toggles the class and CSS decides the value |
| a different density of the same component | a modifier inside the owning file (`.task-list--compact`) | the definition stays in one file |
| a value JS **measured** | `style.setProperty('--task-row-height', …)` | it hands over one value, not a rule |

## 2. `index.html` pins down the layer order

The order of `@layer` is fixed by **the order of first appearance**, and an order declaration that arrives later cannot
move a layer that has already taken its place. So putting the order declaration inside a CSS file **leaves it hanging
on the module import order.**

```html
<!-- the <head> of index.html — the only place parsed before the bundled stylesheet -->
<style>@layer tokens, base, components;</style>
```

If `main.js` writes `import './components/…'` before the style import, the first line of the bundled CSS becomes
`@layer components {` and the `@layer tokens, base, components;` that arrives late is ignored —
the result is the exact opposite order, in which **`base` beats the component rules**.
<!-- verified: compared the two import orders with a vite@8.2.2 build and observed the layer appearance order in the output CSS flip -->
Move it to the one line in `<head>` and it becomes independent of the import order.
<!-- verified: in the same run, confirmed from the build artifact that <style> stays before <link> even when the component is imported first -->

## 3. Global tokens (`src/styles/tokens.css`)

A global token is **only a value two or more components read**. Let a value only one reads up here and, when it comes time to delete it,
there is no telling who uses it, so it stays forever.

```css
/* src/styles/tokens.css */
@layer tokens {
  :root {
    --color-surface: #ffffff;
    --color-text: #16181d;
    --color-muted: #6b7280;
    --color-accent: #2f6fed;
    --space-2: 0.5rem;
    --space-3: 1rem;
    --font-body: system-ui, sans-serif;
    --size-body: 1rem;
  }

  @media (prefers-color-scheme: dark) {
    :root {
      --color-surface: #14161a;
      --color-text: #e8eaed;
      --color-muted: #9aa1ab;
    }
  }
}
```

- **Dark mode changes token values only.** Start rewriting component rules and you have two copies, and
  a day comes when only one of them gets fixed
- **Do not put a component into the name.** With `--task-row-height` here, the name cannot tell you whether it is global
  or component-owned
- Custom properties are **inherited.** Put one on `:root` and every component reads it; put it in a component block
  and only that subtree reads it — §5 uses this property as it is

## 4. Element defaults (`src/styles/base.css`)

The reset and element defaults go in `@layer base`. The layer is **lower** than `components`, so
component rules win regardless of specificity — no `!important`, no selector nesting needed.

```css
/* src/styles/base.css */
@layer base {
  *, *::before, *::after { box-sizing: border-box; }

  body {
    margin: 0;
    font-family: var(--font-body);
    font-size: var(--size-body);
    color: var(--color-text);
    background: var(--color-surface);
  }

  :focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; }
}
```

Define `:focus-visible` once here and do not erase it in a component. There is no framework, so
there is no separate layer that gives the focus ring back — erase it and a keyboard user loses their place.

## 5. Tokens a component owns (`src/components/task-list.css`)

**A component token is defined inside the component block.** Not on `:root` — it is inherited only by
the subtree, so it can be written short with no collision worries, and deleting the file takes the token with it.
`src/components/task-list.js` pulls this file in on its first line with `import './task-list.css';` —
delete the component and the styles drop out of the bundle too. That import is what creates the ordering trap in §2.

```css
/* src/components/task-list.css */
@layer components {
  .task-list {
    --task-row-height: 2.75rem;
    --task-row-gap: var(--space-2);
    --task-row-title-size: var(--size-body);

    margin: 0;
    padding: 0;
    list-style: none;
  }

  .task-list--compact { --task-row-height: 2rem; }

  .task-list__row {
    display: flex;
    align-items: center;
    gap: var(--task-row-gap);
    block-size: var(--task-row-height);
    padding-inline: var(--space-3);
  }

  .task-list__title {
    font-size: var(--task-row-title-size);
    overflow: hidden;
    white-space: nowrap;
    text-overflow: ellipsis;
  }

  .task-list__row--done .task-list__title {
    color: var(--color-muted);
    text-decoration: line-through;
  }
}
```

Height·gap·font size are **defined in this file and nowhere else.** When a different density is needed, do not rewrite
the rule; reassign the value alone.

```css
/* ❌ the call site rewrites the rule — the truth of the row height now lives in two places */
.task-list__row { block-size: 2rem; }
/* ✅ change only the value through a modifier inside the owning file. The caller merely adds one more class */
.task-list--compact { --task-row-height: 2rem; }
```

A component token **references a global token as its default** (`var(--space-2)`). That is what makes the component follow when the
global spacing scale changes, and if you still want this one component to be the exception,
one line is all you edit.

## 6. The class-name convention

**The prefix is the only scope.** There are no scoped styles and no CSS Modules hash.

| form | meaning | example |
| --- | --- | --- |
| `.<component file name>` | the block. One root element | `.task-list` |
| `.<block>__<element>` | a part inside that block | `.task-list__row` · `.task-list__title` |
| `.<block>--<modifier>` · `.<block>__<element>--<modifier>` | a variant·state | `.task-list--compact` · `.task-list__row--done` |

- **Prefix = file name = mount function name.** `mountTaskList` in `src/components/task-list.js`
  owns `.task-list*`. Let the three diverge and you will not know what dies when you delete CSS
- **Do not write it out of element selectors and descendant depth.** `.task-list li span` dies quietly the moment the `<template>`
  markup changes once, and when it dies no tool tells you
- **A class string lives in two places, JS and CSS.** Neither checks the other, so
  `rg "task-list__" src/` is the means of reconciliation. Rename and both places change in the same commit
- **State through classes, values through CSS.** JS goes only as far as `classList.toggle('task-list__row--done', …)`
  and this file decides what that state looks like

## 7. The boundary where inline styles are banned

The inline `style` attribute sits **outside every layer**, so `@layer` cannot beat it. Once someone starts
using it, the next person answers with `!important`, and at that point the layer design is meaningless.

```js
// ❌ builds the rule as a string and carries it — outside the layers, and if the value is user input the surface grows by one
row.setAttribute('style', `block-size:${h}px;color:red`);
// ✅ hand over one value as a custom property and leave the rule in CSS
list.style.setProperty('--task-row-height', `${h}px`);
```

The one allowed place is **handing over a single measured value only JS can know** — a container's measured height,
a virtual-scroll offset, values CSS cannot know. Even then what is handed over is a **value**, not a rule.
The rule against carrying `style` in `el`'s `props` has the same reason, and once user input is mixed in
the `style` attribute opens one more surface, such as a background-image URL.

## Misuse list ① — Tailwind · CSS-in-JS habits → plain CSS + `@layer` conversion table

| Old habit | The current form |
| --- | --- |
| `className="flex items-center h-11"` | one class (`.task-list__row`) + a rule in the owning file |
| a `styled.li` template literal · a `css={{ … }}` prop | `src/components/task-list.css` — the file is the scope |
| `styles.row` from CSS Modules | the prefix convention is that place. There is no hash, so the name is the contract |
| a specificity fight through `!important` | win by `@layer` order. Move the layer if you have to |
| re-declaring component rules for dark mode | change **only token values** inside `prefers-color-scheme` |
| a dynamic value through inline `style` | `style.setProperty('--task-row-height', …)` |
| a component token on `:root` | put it in the component block (`.task-list`) — it disappears along with it |
| writing your own utility classes | global tokens + component rules. A utility has no owner |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| a global token vs a component token | the former when two or more components read it, the latter when one component owns it |
| `@layer base` vs `@layer components` | element defaults the former, class rules the latter |
| a modifier class vs a new component | the former when only the value differs, the latter when the structure differs |
| re-declaring `block-size` vs reassigning a custom property | **always the latter.** The rule lives only in the owning file |
| `style.setProperty(…)` vs `setAttribute('style', …)` | the former for a single value. The latter is building a rule as a string |
| declaring a token on `:root` vs in a component block | the former when the whole screen reads it, the latter when only a subtree does |
| `.task-list__row--done` vs `.done` | **always the former.** A name without a prefix has no owner |
