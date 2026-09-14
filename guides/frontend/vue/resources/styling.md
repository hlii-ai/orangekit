<!-- orangekit-pack: frontend/vue v3.12.0 -->
# Styling (Tailwind CSS v3)

Tailwind utilities are the **only** styling system in this project. Do not mix in `<style scoped>`, CSS Modules,
or inline `style` objects — the moment they mix, "where does this value come from" has two places to look.

## 1. Configuration

```js
// tailwind.config.js
export default {
  // Leave out .vue and the classes vanish entirely — the number one trap in a Vue project
  content: ['./index.html', './src/**/*.{vue,ts,tsx}'],
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
/* src/assets/main.css — these three directives are v3's entry point. main.ts imports this file */
@tailwind base;
@tailwind components;
@tailwind utilities;
```

Tailwind scans sources **as strings**. A class used in a file outside the scan range does not exist in the
build output. An SFC's `<template>` is subject to that same string scan, so the rule is identical.

## 2. The `cn()` helper

<!-- file: src/lib/cn.ts -->
```ts
// src/lib/cn.ts
import { clsx, type ClassValue } from 'clsx';
import { twMerge } from 'tailwind-merge';

export const cn = (...inputs: ClassValue[]) => twMerge(clsx(inputs));
```

Among conflicting utilities `twMerge` keeps **the later one** (`px-4 px-6` → `px-6`).
A template's `:class` array·object syntax does no merging and only concatenates, so when combining
classes that can conflict, use a `computed` that has been through `cn()`.

```vue
<script setup lang="ts">
import { computed } from 'vue';
import { cn } from '@/lib/cn';

const props = defineProps<{ active: boolean; dense?: boolean }>();

// ✅ A combination that can conflict goes through cn() — p-3 and p-6 do not both survive
const rowClass = computed(() => cn('flex items-center p-6', props.dense && 'p-3',
  props.active && 'bg-brand-50 text-brand-700'));
</script>

<template>
  <!-- ✅ A state toggle with no conflict is fine with the object syntax -->
  <li :class="rowClass" />
  <li class="flex items-center" :class="{ 'font-semibold': active, 'opacity-50': !active }" />
</template>
```

## 3. Keep the variant table outside the SFC

`<script setup>` cannot export **values**. Several components and tests need to read the same variant table,
so the table is owned by a `.ts` file beside the SFC.

<!-- file: src/components/common/button-variants.ts -->
```ts
// src/components/common/button-variants.ts
import { cn } from '@/lib/cn';

export type ButtonVariant = 'primary' | 'secondary' | 'danger' | 'ghost';
export type ButtonSize = 'sm' | 'md' | 'lg';

const base = 'inline-flex items-center justify-center rounded-md font-medium transition-colors ' +
  'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 ' +
  'disabled:pointer-events-none disabled:opacity-50';

const variants: Record<ButtonVariant, string> = {
  primary: 'bg-brand-600 text-white hover:bg-brand-700',
  secondary: 'border border-surface-border bg-white text-slate-700 hover:bg-surface-muted',
  danger: 'bg-danger-600 text-white hover:bg-danger-500',
  ghost: 'text-slate-600 hover:bg-surface-muted',
};

const sizes: Record<ButtonSize, string> = {
  sm: 'h-8 px-3 text-xs',
  md: 'h-10 px-4 text-sm',
  lg: 'h-12 px-6 text-base',
};

export function buttonClass(variant: ButtonVariant, size: ButtonSize): string {
  return cn(base, variants[variant], sizes[size]);
}
```

`Record<ButtonVariant, string>` makes it impossible to add a variant and forget the table — a missing key
is a type error. Write class strings in their **complete form** (§4).

## 4. No dynamic class strings

The scanner reads sources as strings, so it cannot see a name assembled at runtime.

❌ The class below does not exist in the built CSS:

```vue
<template>
  <span :class="`text-${color}-500 bg-${tone}-50`" />
</template>
```

```vue
<script setup lang="ts">
// ✅ Pick a complete class from a map
const toneClass = {
  info: 'text-sky-600 bg-sky-50',
  warn: 'text-amber-600 bg-amber-50',
  error: 'text-danger-600 bg-danger-50',
} as const;
const props = defineProps<{ tone: keyof typeof toneClass }>();
</script>

<template>
  <span :class="toneClass[props.tone]" />
</template>
```

Use `safelist` only in the rare case where a class has to be built from a value in a server response.
A growing `safelist` is not a data problem but a design problem.

## 5. Do not use scoped CSS or inline style

Neither of the two forms below exists in this stack. The first splits the style source in two (the same
spacing ends up both in a class and in CSS), and the second turns the value into a runtime object rather
than a bundle string, making design token reconciliation impossible.

❌ Do not do this:

```vue
<template>
  <div class="card" :style="{ padding: dense ? '12px' : '24px' }">…</div>
</template>

<style scoped>
.card { border-radius: 10px; padding: 24px; }
</style>
```

The one permitted exception is **a number that can only come from a computation**: drag coordinates, a
measured height, a progress width. Even then, narrow it to a single CSS variable.

```vue
<template>
  <div class="h-2 rounded-full bg-brand-600" :style="{ width: percent + '%' }" />
</template>
```

Use `@apply` only when the third-party markup is not ours to change. The unit of reuse in our UI is a
**component**, not a CSS class — a class built with `@apply` has neither props nor types.

```css
/* ✅ An area whose markup we do not own */
.ProseMirror p { @apply my-2 leading-relaxed text-slate-700; }
```

## 6. Layout and responsiveness

```vue
<template>
  <!-- Mobile first — the unprefixed value is the small screen, prefixes are the larger ones -->
  <div class="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3" />

  <!-- Spacing goes through gap. space-x/y is a margin between children, so it breaks on wrap·conditional rendering -->
  <div class="flex flex-wrap items-center gap-2" />
</template>
```

- An arbitrary value (`w-[137px]`) is for one-off fine-tuning only. Appearing twice means promoting it to `theme.extend`
- Try flex/grid before absolute positioning
- Text truncation is `truncate` (one line) / `line-clamp-2` (several lines)
- Give the classes of `<Transition>`·`<TransitionGroup>` as Tailwind utilities
  (`enter-active-class="transition duration-150"`) — do not create a CSS block for transitions

## 7. The accessibility baseline

```vue
<template>
  <!-- Do not remove the focus ring. To hide it for mouse users only, use focus-visible -->
  <button class="focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2" />

  <!-- Give an icon-only button an accessible name -->
  <button aria-label="Delete task"><TrashIcon class="size-4" aria-hidden="true" /></button>

  <!-- Hidden visually only (hidden disappears from the screen reader too) -->
  <span class="sr-only">Current page</span>
</template>
```

- Body text contrast is `text-slate-700` or stronger (`text-slate-400` is for placeholders only)
- Never express state with color alone — put an icon or text alongside it
- The minimum touch target for anything interactive is `size-10` (40px) or larger
- Never draw a string that came from user input with `v-html`. Vue's interpolation (`{{ }}`) escapes
  automatically, but `v-html` turns that defence off entirely

## Misuse list ① — do not use v4 idioms in v3

This project's baseline is **tailwindcss@3.4**. Bring in v4 syntax you saw in docs·blogs and the build
breaks silently or the styles disappear entirely.

| v4 idiom (an error here) | The v3 form |
| --- | --- |
| `@import "tailwindcss";` | `@tailwind base; @tailwind components; @tailwind utilities;` |
| `@theme { --color-brand-500: … }` inside CSS | `theme.extend.colors` in `tailwind.config.js` |
| The PostCSS plugin `@tailwindcss/postcss` | `tailwindcss` (+ `autoprefixer`) |
| The Vite plugin `@tailwindcss/vite` | Through PostCSS — registered in `postcss.config.js` |
| Automatic source detection with no configuration | The `content: [...]` globs must be written out (including `.vue`) |
| `bg-linear-to-r` · `shadow-xs` · `outline-hidden` | `bg-gradient-to-r` · `shadow-sm` · `outline-none` |
| A default `border` color of `currentColor` | The v3 default is `gray-200` — port v4-based code and the border color changes |

`size-4` is **not** v4-only. It is a utility added in v3.4, so use it as is on this baseline.
When you cannot tell whether something is v4 syntax, do not guess; check the documentation for the installed version.

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `class` vs `:class` | A fixed string goes in `class`. Both may sit on the same element and Vue joins them — do not drag the fixed part into `:class` |
| `:class` object·array vs `cn()` | A toggle with no conflict uses the object syntax. `cn()` only when conditionally choosing **utilities that can conflict** (spacing·size·color) — the object syntax has no tailwind-merge |
| A call site's `class` fallthrough vs a prop | A fallthrough `class` is **merely concatenated** onto the root class. If the intent is to change a token the component owns, add a `variant`/`size` prop instead |
| `:style` vs a utility class | If the value is a design token, a class. `:style` only for **a number computed at runtime** (progress width, measured height) |
| `<style scoped>` vs utilities | scoped is not used. Global CSS + `@apply` only when the markup is third-party and no class can be attached |
| `gap` vs `space-x-*` | A flex/grid container uses `gap`. `space-*` is a child margin, so it breaks on wrapping·conditional rendering |
| `w-full` vs `flex-1` | The parent's full width is `w-full`. Sharing the remaining space with siblings is `flex-1 min-w-0` |
| `hidden` vs `sr-only` | To remove it completely, `hidden`. To keep it invisible but read aloud, `sr-only` |
| `v-show` vs the `hidden` class | For a toggle, `v-show` is better — the `display` control stays in one place |
| `focus:` vs `focus-visible:` | To show the ring to the keyboard only, `focus-visible`. Giving nothing but `outline-none` is an accessibility violation |
| An arbitrary value `[#4f46e5]` vs a theme token | Colors are always tokens. Arbitrary values are for one-off corrections of size·position |
| `overflow-hidden` vs `min-w-0` | Text overflow in a flex child: without `min-w-0`, `truncate` does not work |
| `dark:` vs a separate theme stylesheet | With `darkMode: 'class'` it is controlled by one class toggle on the root `<html>` |
