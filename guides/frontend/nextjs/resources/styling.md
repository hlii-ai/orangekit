<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# Styling

The Tailwind CSS v4 + shadcn/ui styling system and its forbidden patterns.

## 1. Tailwind v4 — CSS-first configuration

v4 is configured in CSS, with no JS config file. There is exactly one entry point: `app/globals.css`.

```css
/* app/globals.css — the structure shadcn/ui init generates */
@import "tailwindcss";
@import "tw-animate-css";

@custom-variant dark (&:is(.dark *));

:root {
  --background: oklch(1 0 0);
  --foreground: oklch(0.145 0 0);
  --primary: oklch(0.205 0 0);
  --primary-foreground: oklch(0.985 0 0);
  --muted-foreground: oklch(0.556 0 0);
  --destructive: oklch(0.577 0.245 27.325);
  --border: oklch(0.922 0 0);
  --radius: 0.625rem;
  /* …the remaining tokens shadcn init generates */
}

.dark {
  --background: oklch(0.145 0 0);
  --foreground: oklch(0.985 0 0);
  /* …dark value overrides */
}

@theme inline {
  --color-background: var(--background);
  --color-foreground: var(--foreground);
  --color-primary: var(--primary);
  --color-primary-foreground: var(--primary-foreground);
  --color-muted-foreground: var(--muted-foreground);
  --color-destructive: var(--destructive);
  --color-border: var(--border);
  --radius-lg: var(--radius);
  /* …the @theme mapping is what generates utilities such as bg-background */
}
```

- Do not create a new `tailwind.config.js` — tokens are added in `@theme`
- Example of adding a custom token: `@theme inline { --color-brand: var(--brand); }`
  → the `bg-brand`, `text-brand` utilities are generated automatically

## 2. Semantic tokens first

Use meaning-based tokens instead of raw colors — dark mode then comes for free.

```tsx
// Good: semantic tokens — inverted automatically under .dark
<div className="bg-background text-foreground border-border" />
<p className="text-muted-foreground">Secondary description</p>
<p className="text-destructive">Error message</p>

// Bad: raw colors — they break in dark mode
<div className="bg-white text-black border-gray-200" />
```

## 3. The shadcn/ui workflow

```bash
npx shadcn@latest init            # once, at the start — sets up globals.css·lib/utils.ts
npx shadcn@latest add button input dialog skeleton
```

- Components are **copied in as code** under `components/ui/` — we own them, so editing them
  directly is fine. But edit only for a project-wide requirement (a single screen's need goes in `className`)
- Extend styling from the call site with `className` → the internal `cn()` merges Tailwind conflicts
- When a new primitive UI element is needed, check the shadcn/ui catalog before building one yourself

<!-- file: lib/utils.ts -->
```ts
// lib/utils.ts — the standard for every conditional class combination
import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}
```

## 4. Variants through CVA

Control variation along `variant`/`size` axes instead of multiplying boolean props — the same way shadcn/ui does.

```tsx
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '@/lib/utils'

const badgeVariants = cva(
  'inline-flex items-center rounded-md px-2 py-0.5 text-xs font-medium',
  {
    variants: {
      variant: {
        default: 'bg-primary text-primary-foreground',
        outline: 'border border-border text-foreground',
        destructive: 'bg-destructive text-white',
      },
    },
    defaultVariants: { variant: 'default' },
  }
)

interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

export function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />
}
```

## 5. Responsive·dark mode

```tsx
// Mobile first: the base value is mobile, breakpoints expand it
<div className="grid grid-cols-1 gap-4 md:grid-cols-2 lg:grid-cols-3" />

// Dark mode: toggle the .dark class (per the @custom-variant setting)
// With semantic tokens the dark: prefix is almost never needed.
// Use dark: only in exceptional cases outside the tokens
<div className="shadow-sm dark:shadow-none" />
```

Implement the dark mode toggle as a client component that adds and removes the `.dark` class on `<html>`, and
to prevent a first-paint flash (FOUC), apply the class up front with an inline script in the root layout.

## 6. Class-writing conventions

- Order: layout (flex/grid) → size/spacing → typography → color → border/shadow → state (hover etc.)
  — `prettier-plugin-tailwindcss` sorts this automatically
- Conditional classes always go through `cn()` — no string template concatenation (conflicts do not get merged)
- Do not abstract a repeated bundle of classes in CSS; **extract a component** instead
  (the review-at-two · mandatory-at-three rule in resources/component-patterns.md)

## 7. Forbidden patterns

- **The inline `style` attribute** — the only exception is a runtime-computed value (a progress `width`, dynamic coordinates)
- **Adding a runtime CSS-in-JS library** — it conflicts with Server Components and is not in this stack
- **Adding a separate CSS file per component** — there is exactly one global style file, `app/globals.css`
- **Using a raw color when a semantic token exists** — `bg-background` instead of `bg-white`
- **Overusing arbitrary values** (`w-[137px]`) — first check whether a scale value can express it
- **Overusing `@apply`** — solve repetition by extracting a component; `@apply` is for global base styles at most
- **Creating a new `tailwind.config.js`** — v4 is configured through `@theme` (the JS config is for legacy compatibility)
