---
name: frontend-guide
description: "[Preset: nextjs-supabase] Next.js App Router frontend development guide. Covers Server/Client Component patterns, Tailwind CSS v4 + shadcn/ui styling, App Router routing, Zustand state management, performance optimization, and TypeScript standards. Use when creating or modifying components, pages, layouts, styling, data fetching, routing, state management, or any frontend code. Use ONLY when the active preset matches."
---
<!-- orangekit-guide-baseline: verified 2026-08-21 next@15 react@19 typescript@5 tailwindcss@4 zod@4 @supabase/ssr@0.12 @supabase/supabase-js@2 zustand@5 react-hook-form@7 @hookform/resolvers@5 class-variance-authority@0.7 clsx@2 tailwind-merge@3 lucide-react@1 -->

Standards guide for a Next.js 15 (App Router) + React 19 + TypeScript strict + Tailwind CSS v4 + shadcn/ui
+ Zustand + Supabase (@supabase/ssr) frontend.

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

### New Component

- [ ] Start with a Server Component — `'use client'` only when interaction (events · hooks · browser APIs) is needed
- [ ] Decide placement: `app/<route>/_components/` if it belongs to one route, `components/` if shared
- [ ] Before creating a new shared component, grep `components/layout/` · `components/common/` — reuse one if it exists
- [ ] When the same UI repeats twice, consider extracting it; at three times, extract it into a shared component (Core Principle 3)
- [ ] Define props as `interface XxxProps` at the top of the file (TypeScript strict, no `any`)
- [ ] Reuse an existing shadcn/ui component (`components/ui/`) first — add one with the CLI if there is none
- [ ] Style with Tailwind utilities combined through `cn()`, preferring semantic tokens (`bg-background` and so on)
- [ ] For a data-displaying component, confirm all three states are handled: loading · empty · error

### New Page (Route)

- [ ] Create `app/(main)/<route>/page.tsx` — the folder structure is the URL (parenthesized groups are not in the URL)
- [ ] Query data from a Server Component by calling a `lib/queries/` function (no inline data queries in components)
- [ ] The auth check (`auth.getUser()`) is the exception — call it directly in the page or layout (not through the query layer)
- [ ] `params` · `searchParams` are Promises — always `await` them (Next.js 15)
- [ ] Define the loading UI with `loading.tsx` or `<Suspense>`
- [ ] Define the error boundary with `error.tsx` (`'use client'` required)
- [ ] For a protected route, confirm the `middleware.ts` matcher covers it, and re-check `getUser()` in the page
- [ ] Define `metadata` or `generateMetadata`
- [ ] Extract UI shared with sibling routes into the parent `layout.tsx`

## Architecture Overview

```
Browser
  │ request
  ▼
middleware.ts ── @supabase/ssr session refresh + first gate for protected routes
  ▼
Next.js 15 App Router (React 19)
  ├─ Server Component (default) ──→ lib/queries/* ──→ Supabase (PostgreSQL)
  │      └─ lib/supabase/server.ts (cookie-based session, getUser)
  ├─ Client Component ('use client') ── events · forms · Zustand subscription
  │      └─ mutations call a Server Action → revalidatePath → server re-render
  └─ layout.tsx hierarchy ── UI shared across routes
```

Responsibility boundaries:

- **Server Component**: data queries, re-checking access control, static markup — the default form of rendering
- **Client Component**: event handling, form state, browser APIs, Zustand subscription — the smallest leaf unit
- **Zustand**: client-side global UI state only (never a copy of server data)
- **Supabase**: auth + data (PostgreSQL). Access only through the `@supabase/ssr` client
- **The internal logic of a Server Action / Route Handler (validation · permissions · error design)**: owned by backend-guide

## Directory Structure

```
app/
├── layout.tsx              # root layout (globals.css · fonts · Providers)
├── globals.css             # Tailwind v4 entry point (@import "tailwindcss")
├── (auth)/                 # route group — not in the URL
│   ├── layout.tsx          # layout for auth screens only (no app chrome)
│   └── login/page.tsx      # URL: /login
└── (main)/                 # the main app group
    ├── layout.tsx          # app-wide chrome such as header and sidebar
    ├── page.tsx            # URL: /
    └── tasks/
        ├── page.tsx        # Server Component (data fetching) — URL: /tasks
        ├── loading.tsx     # route loading UI
        ├── error.tsx       # route error boundary
        ├── actions.ts      # Server Actions (mutations)
        └── _components/    # components for this route only (excluded from routing)
components/
├── ui/                     # shadcn/ui generated components (added via CLI)
├── layout/                 # shared page skeleton (PageHeader, sidebar, …)
├── common/                 # domain-agnostic reuse (PageSection, EmptyState, …)
└── <domain>/               # per-domain shared components (when several routes use them)
lib/
├── supabase/               # client.ts · server.ts · middleware.ts
├── queries/                # data query functions (server only, the single query entry point)
└── utils.ts                # cn() and friends
stores/                     # Zustand stores + Provider
hooks/ · types/ · constants/  # details in resources/file-organization.md
middleware.ts               # session refresh + protected route matcher
```

If the project already has a real structure, that takes precedence.

## Core Principles (6 Key Rules)

### 1. Server Component is the default — `'use client'` only on interactive leaves

```tsx
// Good: the page fetches on the server, only the interactive part is a client component
// app/(main)/tasks/page.tsx
export default async function TasksPage() {
  const tasks = await getTasks()
  return <TaskList tasks={tasks} />        // data is injected through props
}

// Bad: making the whole page 'use client' and giving up server fetching
'use client'
export default function TasksPage() { /* fetching in useEffect… */ }
```

### 2. Server data comes from the server — no direct Supabase query in a component

```tsx
// Good: Server Component → lib/queries → props
const tasks = await getTasks()             // goes through lib/queries/tasks.ts

// Bad: querying directly from a client component
useEffect(() => {
  createClient().from('tasks').select()... // boundary violation
}, [])
```

There are only two exceptions. ① The auth check — `auth.getUser()` is called directly in a page, layout or action
(it is not a target for the query layer). ② Client-side realtime subscription and auth-state UI.
See resources/data-fetching.md.

### 3. Extract repeated UI into a shared component or layout (consider at 2 · required at 3)

```tsx
// Bad: copying the same section skeleton into every page (third duplicate)
<div className="rounded-xl border bg-card p-6">
  <h2 className="mb-4 text-lg font-semibold">Tasks</h2>…</div>

// Good: differences as props, the skeleton in one place
<PageSection title="Tasks">{children}</PageSection>
```

A frame shared by a whole route (header, nav) goes in `layout.tsx` — see resources/component-patterns.md.

### 4. Request APIs are Promises — await `params` · `searchParams` · `cookies()`

```tsx
// Good (Next.js 15)
export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params
}

// Bad: synchronous access (the old style — a type error)
export default function Page({ params }: { params: { id: string } }) {
  const id = params.id
}
```

### 5. State in layers — server state through props, only global client state in Zustand

```tsx
// Good: subscribe with a selector to just the slice you need
const open = useUiStore((s) => s.sidebarOpen)

// Bad: subscribing to the whole store (re-render on every change) + copying server data into the store
const store = useUiStore((s) => s)
```

Local state uses `useState`, URL-shared state uses `searchParams` — see resources/state-management.md.

### 6. Style with Tailwind utilities + `cn()` — no inline style, no per-component CSS file

```tsx
// Good: compose conditional classes with cn()
<div className={cn('rounded-lg border p-4', isActive && 'border-primary')} />

// Bad: inline style + adding a custom class to the global CSS
<div style={{ borderRadius: 8, padding: 16 }} className="custom-card" />
```

## Common Imports

```tsx
// ── server code (Server Component · Server Action)
import { createClient } from '@/lib/supabase/server'
import { cookies, headers } from 'next/headers'
import { revalidatePath } from 'next/cache'
import { redirect, notFound } from 'next/navigation'
import { cache } from 'react'

// ── client components ('use client' files)
import { useState, useActionState, useOptimistic, useTransition } from 'react'
import { useRouter, usePathname, useSearchParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { useUiStore } from '@/stores/ui-store-provider'

// ── shared UI
import Link from 'next/link'
import Image from 'next/image'
import { cn } from '@/lib/utils'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
```

## Component Templates

### Server Component (default form)

```tsx
import { getTasks } from '@/lib/queries/tasks'

export async function TasksPanel() {
  const tasks = await getTasks()             // RLS returns only the caller's rows — no userId argument needed
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

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Create a component, decide the Server/Client boundary, design props | resources/component-patterns.md |
| Extract repeated UI, shared layout (PageHeader) and section components | resources/component-patterns.md |
| Handle the three states — loading · empty · error (skeletons · error boundaries) | resources/component-patterns.md |
| Data fetching, the query layer (lib/queries), caching and revalidation, refreshing after a mutation | resources/data-fetching.md |
| Server-side search · filter · pagination (count · range), optimistic UI (useOptimistic) | resources/data-fetching.md |
| Add a page or layout, dynamic routes, protected routes, auth-conditional headers, metadata | resources/routing.md |
| Design client state, Zustand store · Provider · persist, the RHF+Zod form boundary | resources/state-management.md |
| URL state (reading and writing searchParams), pending handling for button mutations (useTransition) | resources/state-management.md |
| Styling, Tailwind v4 tokens, adding and varying shadcn/ui (CVA), dark mode | resources/styling.md |
| Performance optimization such as images · dynamic import · memoization · debounce | resources/performance.md |
| Type design, removing any, utility types, null handling, naming | resources/typescript-standards.md |
| Protected routes, middleware session refresh, reading the current user on the server | resources/auth-and-session.md |
| File placement and naming rules, directory structure, import order, export style, the order of contents within a file | resources/file-organization.md |
| One feature from start to finish (a list + create example all the way through) | resources/complete-example.md |
