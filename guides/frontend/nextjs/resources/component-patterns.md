<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# Component Patterns

Component design standards: the Server/Client boundary, extracting repeated UI, props conventions,
and handling the three loading·empty·error states (merged into this file).

## 1. How to decide Server / Client

| What you need | Kind |
| --- | --- |
| Data queries, session checks, static markup | Server Component (default) |
| Event handlers such as `onClick` | Client Component |
| Hooks such as `useState` / `useActionState` | Client Component |
| Browser APIs (localStorage, IntersectionObserver…) | Client Component |
| Subscribing to a Zustand store | Client Component |

Principle: **the server is the default.** Declare `'use client'` only on the smallest unit where interaction
actually happens (the leaf component). As a rule it does not go on page·layout files.

## 2. Boundary design patterns

### `'use client'` is transitive

Every module a `'use client'` file imports ends up in the client bundle.
Server code that uses `next/headers` (a data client module and the like) raises a build error when it is
imported from a client component, but **ordinary server code can be bundled silently, with no error** —
so a server-only module (`lib/queries/` and the like) declares `import 'server-only'` at the top of the file,
promoting the mistake into a build error. Server data is always passed **as props**.

### Passing a Server Component through as children

Even when a client wrapper is needed, the inner content can stay on the server.

```tsx
// app/(main)/tasks/page.tsx (Server Component)
<CollapsiblePanel title="Tasks">
  <TaskList tasks={tasks} />   {/* passes through, still a Server Component */}
</CollapsiblePanel>
```

<!-- file: components/common/collapsible-panel.tsx -->
```tsx
// components/common/collapsible-panel.tsx (Client Component)
'use client'

import { useState } from 'react'

interface CollapsiblePanelProps {
  title: string
  children: React.ReactNode
}

export function CollapsiblePanel({ title, children }: CollapsiblePanelProps) {
  const [open, setOpen] = useState(true)
  return (
    <section className="rounded-xl border">
      <button onClick={() => setOpen((o) => !o)} className="w-full p-4 text-left font-semibold">
        {title}
      </button>
      {open && <div className="border-t p-4">{children}</div>}
    </section>
  )
}
```

### Props that cross the boundary must be serializable

From Server → Client, pass only JSON-serializable values and Server Action references.
Ordinary functions·class instances·data client objects must not be passed.

## 3. Extracting repeated UI (review at two · mandatory at three) — the mandatory rule in depth

When the same markup pattern **appears twice, consider extraction; at three times, extraction is mandatory**.
The destination is decided by the scope of the repetition.

| Scope of repetition | Destination |
| --- | --- |
| Inside a single route | `app/<route>/_components/` |
| Shared page skeleton (header·container·bottom action bar) | `components/layout/` — `PageHeader`, `PageContainer`, `BottomActionBar` |
| Domain-agnostic body UI (section skeleton, empty state, card) | `components/common/` — `PageSection`, `EmptyState` |
| A shared component of one domain (used by several routes) | `components/<domain>/` |
| A frame shared by an entire route segment (nav·sidebar placement) | that segment's `layout.tsx` |
| Primitive UI elements (button·input·dialog) | reuse shadcn/ui (`components/ui/`) |

```tsx
// Bad: a section skeleton repeated on every page (third copy-paste)
<div className="rounded-xl border bg-card p-6">
  <div className="mb-4 flex items-center justify-between">
    <h2 className="text-lg font-semibold">Tasks</h2>
    <Button size="sm">Add</Button>
  </div>
  …
</div>
```

```tsx
// Good: the skeleton in one place, the differences as props
// components/common/page-section.tsx (Server Component — no hooks needed)
interface PageSectionProps {
  title: string
  action?: React.ReactNode
  children: React.ReactNode
}

export function PageSection({ title, action, children }: PageSectionProps) {
  return (
    <section className="rounded-xl border bg-card p-6">
      <div className="mb-4 flex items-center justify-between">
        <h2 className="text-lg font-semibold">{title}</h2>
        {action}
      </div>
      {children}
    </section>
  )
}
```

Rules when extracting:

- When a variation is needed, control it with one `variant` prop instead of multiplying boolean props
  (`isSmall`, `isDanger`…) (the CVA pattern — resources/styling.md)
- A shared layout (`layout.tsx`) does not re-render between navigations —
  UI that depends on page state goes on the page side, not in the layout
- Do not abstract fewer than two repetitions in advance (no speculative generalization)

### The shared layout system — PageHeader

The top header (back button + title) of sub pages such as detail/settings/profile is the archetypal repeated UI.
**Before creating a new shared component, grep `components/layout/`·`components/common/`** —
reuse what is already there, and add one only when there is none.

<!-- file: components/layout/page-header.tsx -->
```tsx
// components/layout/page-header.tsx
import { ChevronLeft } from 'lucide-react'
import Link from 'next/link'

interface PageHeaderProps {
  title: string
  backHref?: string
  rightSlot?: React.ReactNode
}

export function PageHeader({ title, backHref, rightSlot }: PageHeaderProps) {
  return (
    <header className="sticky top-0 z-10 flex h-14 items-center justify-between border-b bg-background px-4">
      {backHref ? (
        <Link href={backHref} aria-label="Back">
          <ChevronLeft className="h-6 w-6" />
        </Link>
      ) : (
        <span className="w-6" />
      )}
      <h1 className="text-base font-semibold">{title}</h1>
      <div className="w-6">{rightSlot}</div>
    </header>
  )
}
```

```tsx
// Usage: every sub page shares the same interface
<PageHeader title="Tasks" backHref="/tasks" />
<PageHeader title="Settings" backHref="/" rightSlot={<SaveButton />} />
```

```tsx
// Bad: inlining a copy of the same header on every page —
// heights·fonts start to drift from page to page (h-12/h-14/h-16, text-lg/text-base mixed)
<header className="sticky top-0 …">
  <Link href="/tasks"><ChevronLeft /></Link>
  <h1 className="text-lg font-semibold">Tasks</h1>
</header>
```

Design token consistency:

- The header height·title font·spacing (`h-14`, `text-base font-semibold` and so on) are defined
  **in PageHeader alone** — pages control them through props only
- If an extra token is needed (a mobile-only header height, say) it must agree with the design system
  artifact (`dev/docs/design/`, produced by the ui-ux-design skill)

## 4. Props·type conventions

- Declare the props type as `interface XxxProps` at the top of the component file — export it only when it is reused
- `children` is `React.ReactNode`
- For server data, import and reuse the type `lib/queries/` exports (no duplicate definitions)
- Event handler props are `onXxx`, internal handlers are `handleXxx`
- React 19: `ref` is an ordinary prop — no `forwardRef` wrapper needed

```tsx
interface SearchInputProps {
  defaultValue?: string
  ref?: React.Ref<HTMLInputElement>   // React 19: ref as prop
  onSearch: (query: string) => void
}

export function SearchInput({ defaultValue, ref, onSearch }: SearchInputProps) {
  // …
}
```

## 5. The three states: loading·empty·error

Any screen that displays data is finished only once it handles all three states: **loading·empty·error**.

### Loading — `loading.tsx` for a whole route, `<Suspense>` for a part

```tsx
// app/(main)/tasks/loading.tsx — shown automatically on a route transition (an implicit Suspense boundary)
import { Skeleton } from '@/components/ui/skeleton'

export default function TasksLoading() {
  return (
    <div className="space-y-3 p-6">
      <Skeleton className="h-8 w-40" />
      <Skeleton className="h-24 w-full" />
      <Skeleton className="h-24 w-full" />
    </div>
  )
}
```

- Make the skeleton resemble the shape of the real content (avoid using a bare spinner)
- If only part of the page is slow, split that part into its own server component and
  wrap it in `<Suspense fallback={…}>` — see the streaming section of resources/data-fetching.md

### Empty state — "zero items" is not an error

The empty state is the archetypal UI repeated on every screen — extract it to `components/common/` per the rule in §3.

<!-- file: components/common/empty-state.tsx -->
```tsx
// components/common/empty-state.tsx (Server Component — no hooks needed)
interface EmptyStateProps {
  title: string
  description?: string
  action?: React.ReactNode        // button·link prompting the next action
}

export function EmptyState({ title, description, action }: EmptyStateProps) {
  return (
    <div className="rounded-lg border border-dashed p-8 text-center">
      <p className="text-sm text-muted-foreground">{title}</p>
      {description && <p className="mt-1 text-xs text-muted-foreground">{description}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  )
}
```

```tsx
// Usage: handle the empty state first with an early return
if (tasks.length === 0) {
  return <EmptyState title="No items registered yet." description="Add your first item with the form above." />
}
```

Show guidance for the next action with the empty state (prompting the first item, for instance) — `description` or `action` is where it goes.

### Error — the `error.tsx` boundary

```tsx
// app/(main)/tasks/error.tsx — catches errors thrown inside this segment
'use client'

import { Button } from '@/components/ui/button'

interface TasksErrorProps {
  error: Error & { digest?: string }
  reset: () => void
}

export default function TasksError({ error, reset }: TasksErrorProps) {
  return (
    <div className="p-8 text-center">
      <p className="text-sm text-destructive">Could not load the list.</p>
      <Button variant="outline" onClick={reset} className="mt-4">
        Try again
      </Button>
    </div>
  )
}
```

- `error.tsx` must be `'use client'`
- Query functions throw errors → the nearest `error.tsx` catches them (avoid try/catch inside components)
- **Form submission errors are not sent to the boundary** — show them inline from the return value of
  `useActionState` (see the mutation section of resources/data-fetching.md)
