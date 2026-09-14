<!-- orangekit-pack: frontend/nextjs v3.12.0 verified 2026-08-21 next@15 react@19 typescript@5 tailwindcss@4 zod@4 zustand@5 react-hook-form@7 @hookform/resolvers@5 class-variance-authority@0.7 clsx@2 tailwind-merge@3 lucide-react@1 -->

# nextjs axis pack — hub fragment

This is the **axis-local fragment to be inserted verbatim** when building a combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — in that case the seam's `HUB.md` holds the full hub text.

> **What is distinctive about this axis**: Next.js **has a server runtime built in**. Even when the backend axis is a BaaS, server code
> lives here (Route Handlers·Server Actions). When building a seam, always pass this fact to the backend
> side — where the handlers live is the premise of the entire backend guide.

<!-- pack-slot: quick-start-axis -->
### New Component

- [ ] Start with a Server Component — `'use client'` only when interaction (events·hooks·browser APIs) is needed
- [ ] Placement decision: `app/<route>/_components/` if it belongs to one route, `components/` if shared
- [ ] Before creating a new shared component, grep `components/layout/`·`components/common/` — reuse what is already there
- [ ] When the same UI repeats twice, consider extraction; at three times, extraction into a shared component is mandatory (Core Principle 3)
- [ ] Define props as `interface XxxProps` at the top of the file (TypeScript strict, no `any`)
- [ ] Reuse an existing shadcn/ui component (`components/ui/`) first — add it through the CLI if there is none
- [ ] Style with Tailwind utilities + `cn()`, preferring semantic tokens (`bg-background` and the like)
- [ ] If the component displays data, confirm all three states are handled: loading·empty·error

<!-- /pack-slot -->

<!-- pack-slot: directory-structure -->
## Directory Structure

```
app/
├── layout.tsx              # Root layout (globals.css·fonts·Provider)
├── globals.css             # Tailwind v4 entry point (@import "tailwindcss")
├── (auth)/                 # Route group — not part of the URL
│   ├── layout.tsx          # Layout for auth screens only (no app chrome)
│   └── login/page.tsx      # URL: /login
└── (main)/                 # Main app group
    ├── layout.tsx          # Shared app chrome — header·sidebar
    ├── page.tsx            # URL: /
    └── tasks/
        ├── page.tsx        # Server Component (data fetching) — URL: /tasks
        ├── loading.tsx     # Route loading UI
        ├── error.tsx       # Route error boundary
        ├── actions.ts      # Server Actions (mutations)
        └── _components/    # Components for this route only (excluded from routing)
components/
├── ui/                     # shadcn/ui generated components (added through the CLI)
├── layout/                 # Shared page skeleton (PageHeader·sidebar etc.)
├── common/                 # Domain-agnostic reusables (PageSection·EmptyState etc.)
└── <domain>/               # Per-domain shared components (when several routes use them)
lib/
├── supabase/               # client.ts · server.ts · middleware.ts
├── queries/                # Data query functions (server only, the single read entry point)
└── utils.ts                # cn() and the like
stores/                     # Zustand stores + Provider
hooks/ · types/ · constants/  # details in resources/file-organization.md
middleware.ts               # Session refresh + protected-route matcher
```

If the project already has a real structure, that one takes precedence.

<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
### 1. Server Components are the default — `'use client'` only on interactive leaves

```tsx
// Good: the page fetches on the server, only the interactive part is client
// app/(main)/tasks/page.tsx
export default async function TasksPage() {
  const tasks = await getTasks()
  return <TaskList tasks={tasks} />        // data is injected as props
}

// Bad: making the whole page 'use client' and giving up server fetching
'use client'
export default function TasksPage() { /* fetching with useEffect… */ }
```

### 3. Extract repeated UI into shared components·layouts (review at two · mandatory at three)

```tsx
// Bad: copying the same section skeleton into every page (third duplicate)
<div className="rounded-xl border bg-card p-6">
  <h2 className="mb-4 text-lg font-semibold">Tasks</h2>…</div>

// Good: differences as props, the skeleton in one place
<PageSection title="Tasks">{children}</PageSection>
```

A frame shared by an entire route (header·nav) goes in `layout.tsx` — see resources/component-patterns.md.

### 4. Request APIs are Promises — await `params`·`searchParams`·`cookies()`

```tsx
// Good (Next.js 15)
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
}

// Bad: synchronous access (the old way — type error)
export default function Page({ params }: { params: { id: string } }) {
  const id = params.id
}
```

### 5. Layer the state — server state as props, only global client state in Zustand

```tsx
// Good: subscribe to just the slice you need with a selector
const open = useUiStore((s) => s.sidebarOpen)

// Bad: subscribing to the whole store (re-renders on every change) + copying server data into the store
const store = useUiStore((s) => s)
```

Local state goes in `useState`, URL-shared state in `searchParams` — see resources/state-management.md.

### 6. Style with Tailwind utilities + `cn()` — no inline style·per-component CSS files

```tsx
// Good: compose conditional classes with cn()
<div className={cn('rounded-lg border p-4', isActive && 'border-primary')} />

// Bad: inline style + adding a custom class to the global CSS
<div style={{ borderRadius: 8, padding: 16 }} className="custom-card" />
```

<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
```tsx
// ── Server code (Server Component · Server Action)
import { createClient } from '@/lib/supabase/server'
import { cookies, headers } from 'next/headers'
import { revalidatePath } from 'next/cache'
import { redirect, notFound } from 'next/navigation'
import { cache } from 'react'

// ── Client components ('use client' files)
import { useState, useActionState, useOptimistic, useTransition } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useUiStore } from '@/stores/ui-store-provider'

// ── Shared UI
import Link from 'next/link'
import Image from 'next/image'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
```

<!-- /pack-slot -->

<!-- pack-slot: component-templates -->
## Component Templates

### Server Component (base form)

```tsx
import { getTasks } from '@/lib/queries/tasks'

export async function TasksPanel() {
  const tasks = await getTasks()             // RLS returns only the caller's own rows — no userId argument
  if (tasks.length === 0) return <p className="text-sm text-muted-foreground">No items yet.</p>
  return <ul className="space-y-2">{tasks.map((t) => <li key={t.id}>{t.title}</li>)}</ul>
}
```

### Client Component (interactive form)

```tsx
'use client'

import { useState } from 'react'
import { cn } from '@/lib/utils'

interface ToggleChipProps { label: string; onToggle?: (on: boolean) => void }

export function ToggleChip({ label, onToggle }: ToggleChipProps) {
  const [on, setOn] = useState(false)
  const handleClick = () => { setOn(!on); onToggle?.(!on) }
  return (
    <button onClick={handleClick} className={cn('rounded-full border px-3 py-1 text-sm', on && 'bg-primary text-primary-foreground')}>
      {label}
    </button>
  )
}
```

<!-- /pack-slot -->

## What the seam fills in — what this pack does not have

| Hub slot | Why it is a function of the combination |
| --- | --- |
| Architecture Overview | The data source and the trust boundary depend on the backend axis |
| Quick Start "New Page (Route)" | How a page fetches its data depends on the backend axis |
| Core Principle "server data on the server" | The principle is universal, but **what must not be queried directly** (BaaS SDK·REST client) depends on the backend axis. This rule is mandatory |
| The data access·auth rows of Common Imports | How the client is created depends on the backend axis |
| Navigation Guide | `pack.json` supplies the pack resource rows |
