<!-- orangekit-pack: frontend/react-vite v3.12.0 -->
# Styling (Tailwind CSS v3)

Tailwind utilities are the **only** styling system in this project. Do not mix in CSS Modules, styled-components,
or inline `style` objects — the moment they mix, "where does this value come from" has two places to look.

## 1. Configuration

```js
// tailwind.config.js
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],   // leave one out and the classes vanish entirely
  darkMode: 'class',
  theme: {
    extend: {
      colors: {
        // Colors get meaning names — so screens never pick a raw value such as slate-700 directly
        surface: { DEFAULT: '#ffffff', muted: '#f8fafc', border: '#e2e8f0' },
        brand: { 50: '#eef2ff', 500: '#6366f1', 600: '#4f46e5', 700: '#4338ca' },
        danger: { 50: '#fef2f2', 500: '#ef4444', 600: '#dc2626' },
      },
      borderRadius: { card: '0.625rem' },
    },
  },
  plugins: [],
};
```

```css
/* src/index.css — these three directives are v3's entry point */
@tailwind base;
@tailwind components;
@tailwind utilities;
```

Check that the `content` globs actually cover the real files. Tailwind scans sources **as strings**, so
a class used in a file outside the scan range does not exist in the build output.

## 2. The `cn()` helper

<!-- file: src/lib/cn.ts -->
```ts
// src/lib/cn.ts
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

export const cn = (...inputs: ClassValue[]) => twMerge(clsx(inputs));
```

Among conflicting utilities `twMerge` keeps **the later one** (`px-4 px-6` → `px-6`).
Without it the call site cannot override a shared component's default classes.

## 3. Defining variants

```tsx
const base = 'inline-flex items-center justify-center rounded-md font-medium ' +
  'transition-colors focus-visible:outline-none focus-visible:ring-2 ' +
  'focus-visible:ring-brand-500 disabled:pointer-events-none disabled:opacity-50';

const variants = {
  primary: 'bg-brand-600 text-white hover:bg-brand-700',
  secondary: 'border border-surface-border bg-white text-slate-700 hover:bg-surface-muted',
  danger: 'bg-danger-600 text-white hover:bg-danger-500',
  ghost: 'text-slate-600 hover:bg-surface-muted',
} as const;

const sizes = { sm: 'h-8 px-3 text-xs', md: 'h-10 px-4 text-sm', lg: 'h-12 px-6 text-base' } as const;

export type ButtonProps = ComponentPropsWithoutRef<'button'> & {
  variant?: keyof typeof variants;
  size?: keyof typeof sizes;
};
```

- With `as const` + `keyof typeof` the props type follows automatically — add a variant and the type widens
- Write class strings in their **complete form** (see item 4 below)

## 4. No dynamic class strings

```tsx
// ❌ The scanner cannot see this string — the class is absent from the built CSS
<span className={`text-${color}-500 bg-${tone}-50`} />

// ✅ Pick a complete class from a map
const toneClass = {
  info: 'text-sky-600 bg-sky-50',
  warn: 'text-amber-600 bg-amber-50',
  error: 'text-danger-600 bg-danger-50',
} as const;
<span className={toneClass[tone]} />
```

Use `safelist` only in the genuinely rare case where a class has to be built from a value in a server response.
A growing `safelist` is not a data problem but a design problem.

## 5. `@apply` only as an exception

```css
/* ✅ When the third-party markup is not ours to change */
.ProseMirror p { @apply my-2 leading-relaxed text-slate-700; }

/* ❌ Reinventing our component as a class — the component already does that job */
.btn-primary { @apply inline-flex h-10 items-center rounded-md bg-brand-600 px-4 text-white; }
```

The unit of reuse is a **React component**, not a CSS class. A class built with `@apply` has neither
props nor types, and it is hard to trace where it is used.

## 6. Layout and responsiveness

```tsx
// Mobile first — the unprefixed value is the small screen, prefixes are the larger ones
<div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">

// Spacing goes through gap. space-x/y is a margin between children, so it breaks on wrap·reordering
<div className="flex flex-wrap items-center gap-2">
```

- An arbitrary value (`w-[137px]`) is for one-off fine-tuning only. Appearing twice means promoting it to `theme.extend`
- Try flex/grid before absolute positioning
- Text truncation is `truncate` (one line) / `line-clamp-2` (several lines)

## 7. The accessibility baseline

```tsx
// Do not remove the focus ring. To hide it for mouse users only, use focus-visible
className="focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2"

// Give an icon-only button an accessible name
<button aria-label="Delete task"><TrashIcon className="h-4 w-4" aria-hidden /></button>

// Hidden visually only (display:none disappears from the screen reader too)
<span className="sr-only">Current page</span>
```

- Body text contrast is `text-slate-700` or stronger (`text-slate-400` is for placeholders only)
- Never express state with color alone — put an icon or text alongside it
- The minimum touch target for anything interactive is `h-10 w-10` (40px) or larger

## Misuse list ① — do not use v4 idioms in v3

This project's baseline is **tailwindcss@3**. Bring in v4 syntax you saw in docs·blogs and the build
breaks silently or the styles disappear entirely.

| v4 idiom (an error here) | The v3 form |
| --- | --- |
| `@import "tailwindcss";` | `@tailwind base; @tailwind components; @tailwind utilities;` |
| `@theme { --color-brand-500: … }` inside CSS | `theme.extend.colors` in `tailwind.config.js` |
| The PostCSS plugin `@tailwindcss/postcss` | `tailwindcss` (+ `autoprefixer`) |
| The Vite plugin `@tailwindcss/vite` | Through PostCSS — registered in `postcss.config.js` |
| Automatic source detection with no configuration | The `content: [...]` globs must be written out |
| `bg-linear-to-r` · `shadow-xs` · `outline-hidden` | `bg-gradient-to-r` · `shadow-sm` · `outline-none` — utilities renamed in v4 |
| A default `border` color of `currentColor` | The v3 default is `gray-200` — port v4-based code and the border color changes |

`size-4` is **not** v4-only. It is a utility added in v3.4, so use it as is on this baseline (`tailwindcss@3.4`) —
there is no reason to revert it to `h-4 w-4`. When you cannot tell whether something is v4 syntax, do not guess;
check the documentation for the installed version.

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `gap` vs `space-x-*` | A flex/grid container uses `gap`. `space-*` is a child margin, so it breaks on wrapping·reordering·conditional rendering |
| `w-full` vs `flex-1` | To fill the parent's full width, `w-full`. To share the remaining space with siblings, `flex-1 min-w-0` |
| `hidden` vs `sr-only` | To remove it completely, `hidden`. To keep it invisible but readable by a screen reader, `sr-only` |
| `focus:` vs `focus-visible:` | To show the ring to keyboard users only, `focus-visible`. Giving nothing but `outline-none` is an accessibility violation |
| An arbitrary value `[#4f46e5]` vs a theme token | Colors are always tokens. Arbitrary values are for one-off corrections of size·position |
| `overflow-hidden` vs `min-w-0` | Text overflow in a flex child: without `min-w-0`, `truncate` does not work |
| `dark:` vs a separate theme stylesheet | With `darkMode: 'class'` it is controlled by one class toggle on the root `<html>`. Do not define the colors twice |
