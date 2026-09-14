<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# File Organization

A full map of the directory structure, how to decide where a file goes, file naming rules, import order.

## 1. Directory Structure

```
app/                          # Routing (folder structure = URL)
├── layout.tsx                # Root layout (globals.css·fonts·Provider)
├── globals.css               # Tailwind v4 entry point
├── error.tsx / not-found.tsx # Global state UI
├── (auth)/                   # Route group — not in the URL
│   ├── layout.tsx            # Layout for auth screens only (no app chrome)
│   ├── login/page.tsx        # URL: /login
│   └── signup/page.tsx       # URL: /signup
├── (main)/                   # Main app group
│   ├── layout.tsx            # Layout shared by the group (header·sidebar)
│   ├── page.tsx              # URL: /
│   ├── tasks/
│   │   ├── page.tsx          # List — URL: /tasks
│   │   ├── loading.tsx
│   │   ├── actions.ts        # Server Actions for this route (colocated)
│   │   ├── _components/      # Components for this route only (excluded from routing)
│   │   └── [id]/
│   │       ├── page.tsx      # Detail — URL: /tasks/<id>
│   │       └── not-found.tsx
│   └── search/page.tsx
└── api/                      # Route Handlers — owned by backend-guide
    └── webhooks/route.ts

components/
├── ui/                       # shadcn/ui generated components (added through the CLI only)
├── layout/                   # Shared page skeleton (page-header.tsx, app-sidebar.tsx)
├── common/                   # Domain-agnostic reusables (empty-state.tsx, page-section.tsx)
├── task/                     # Per-domain shared components (when several routes use them)
│   ├── task-card.tsx
│   └── task-card-skeleton.tsx
├── user/
│   └── user-avatar.tsx
└── comment/
    └── comment-form.tsx

lib/
├── <data client>/            # client.ts · server.ts · middleware.ts (the backend axis decides)
├── queries/                  # Data query functions (server only, the single read entry point)
│   ├── tasks.ts
│   └── profiles.ts
├── analytics/                # Wrappers for external service SDKs (when needed)
└── utils.ts                  # Shared utilities such as cn()

hooks/                        # Custom hooks (use-debounce.ts, use-media-query.ts)
stores/                       # Zustand (ui-store.ts, ui-store-provider.tsx)
types/                        # Shared types (database.ts = types generated from the DB schema — by the backend axis)
constants/                    # Constants (config.ts)
middleware.ts                 # Session refresh + protected routes
```

- The route groups `(auth)`/`(main)` are this guide's standard — the login screen does not share the app chrome
  (header·sidebar), so the layout boundary is split by group. Parenthesized folders do not appear in the URL
  (`app/(main)/tasks/page.tsx` → `/tasks`) — every example in this guide uses the same structure
- In a project that uses `src/`, put the same structure under `src/`
- If the project already has an established structure, that one takes precedence

## 2. How to decide placement

| Question | Yes → | No → |
| --- | --- | --- |
| A Next.js routing file (page/layout/loading/error/actions)? | `app/` | next |
| A component used by only one route? | `app/<route>/_components/` | next |
| Page skeleton (header·container·action bar)? | `components/layout/` | next |
| Domain-agnostic reusable UI? | `components/common/` (primitive UI goes to shadcn `components/ui/`) | next |
| A shared component of one domain? | `components/<domain>/` | next |
| A server data query function? | `lib/queries/` | next |
| Global client state? | `stores/` | next |
| A React hook? | `hooks/` | `types/` or `constants/` |

Before creating a new shared component, grep `components/layout/`·`components/common/` —
reuse what is already there (resources/component-patterns.md).

## 3. File naming rules

| File type | Rule | Example |
| --- | --- | --- |
| Component | kebab-case.tsx (the export is PascalCase) | `task-card.tsx` → `TaskCard` |
| Routing file | Next.js reserved name | `page.tsx`, `layout.tsx`, `actions.ts` |
| Custom hook | use-xxx.ts | `use-debounce.ts` |
| Zustand store | xxx-store.ts | `cart-store.ts`, `ui-store-provider.tsx` |
| Query/utility | kebab-case.ts | `tasks.ts`, `format-date.ts` |
| Type/constant | kebab-case.ts | `database.ts`, `config.ts` |

## 4. Export style

- **A default export only in routing files** — `page.tsx`·`layout.tsx`·`loading.tsx`·`error.tsx`·
  `not-found.tsx`·`template.tsx`. Because Next.js looks for the default, not for a name
- **Everything else is a named export** — components·hooks·utilities·query functions·Server Actions·types.
  The name is fixed, so grep·auto-import·rename tracking stay accurate (no `export default`)

## 5. Import order

```tsx
// 1. React / Next.js
import { Suspense } from 'react'
import Link from 'next/link'
import Image from 'next/image'

// 2. Third-party libraries
import { z } from 'zod'

// 3. Project-internal — UI components
import { Button } from '@/components/ui/button'
import { Card } from '@/components/ui/card'

// 4. Project-internal — layout·domain components
import { PageHeader } from '@/components/layout/page-header'
import { TaskCard } from '@/components/task/task-card'

// 5. Project-internal — utilities·hooks·stores·queries
import { cn } from '@/lib/utils'
import { useDebounce } from '@/hooks/use-debounce'
import { useUiStore } from '@/stores/ui-store-provider'

// 6. Types (import type)
import type { Task } from '@/lib/queries/tasks'
```

## 6. Ordering inside a component file

Fix the order inside a file as well — open any file and the same thing is in the same place.

1. The `'use client'` directive (only when needed, **at the very top of the file**)
2. imports (the §5 order above)
3. Types·constants — `interface XxxProps`, module constants (`const initialState = …`)
4. The component function — its inside keeps an order too:
   state (`useState`/`useActionState`) → derived values (`useMemo`) → effects (`useEffect`) →
   handlers (`handleXxx`) → early returns (loading·empty·error) → returning JSX
5. Helper subcomponents used only in the same file (not exported)

In a routing file slot 4 holds the `export default`; in every other file slot 4 is a named export (§4).

## 7. Props vs shared types

```ts
// Good: props are defined at the top of the component file
// components/task/task-card.tsx
interface TaskCardProps {
  task: Task
  className?: string
}

export function TaskCard({ task, className }: TaskCardProps) {/* … */}

// Good: the type of server-queried data is exported by lib/queries/ — components reuse it
// lib/queries/tasks.ts
export interface Task {
  id: string
  title: string
  done: boolean
  created_at: string
}
```

`types/` is used only for domain-wide types and generated types (`database.ts`) —
do not define a query result type twice, in `types/` and in `lib/queries/`.

## 8. Anti-Patterns

```ts
// Bad: relative-path import
import { Button } from '../../components/ui/button'
// Good: @/ alias
import { Button } from '@/components/ui/button'

// Bad: dropping a component bare into the route folder (mixed in with routing files)
// app/(main)/tasks/task-card.tsx
// Good: if it is route-only, app/(main)/tasks/_components/task-card.tsx,
//       if several routes share it, components/task/task-card.tsx

// Bad: one giant component file (300+ lines)
// → split it into units that can be tested·reused independently

// Bad: index.ts barrel export (hurts tree-shaking, invites circular imports)
// components/task/index.ts ← do not create it. Import from each file directly

// Bad: a default export in a non-routing file (the name differs at every import site)
// export default function TaskCard() {…}
// Good: named export — components/task/task-card.tsx
// export function TaskCard() {…}
```
