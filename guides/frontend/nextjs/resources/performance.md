<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# Performance

Frontend performance optimization: images·code splitting·memoization·resource cleanup.

## 1. The top optimization — stay a Server Component

A Server Component is itself a performance optimization: zero client bundle, rendered on the server.
**Keeping the `'use client'` boundary as small as possible is the most effective optimization**,
and the techniques below come after it — do not apply them pre-emptively without measuring.

## 2. Next.js Image

```tsx
import Image from 'next/image'

// Fixed size — use priority for the LCP (largest element on the first screen) image
<Image src="/hero.jpg" alt="Hero" width={800} height={400} priority />

// Responsive (fill) — parent needs relative + an aspect ratio, sizes shrinks the download
<div className="relative aspect-video">
  <Image
    src={imageUrl}
    alt={title}
    fill
    className="rounded-lg object-cover"
    sizes="(max-width: 768px) 100vw, (max-width: 1200px) 50vw, 33vw"
  />
</div>
```

```ts
// next.config.ts — allow external image hosts (object storage and the like)
const config = {
  images: {
    remotePatterns: [{ hostname: 'assets.example.com' }],   // replace with the backend axis's storage host
  },
}
```

- Never use a bare `<img>` tag — always `next/image`
- A `fill` image must always specify `sizes` (the 100vw default over-downloads)

## 3. Dynamic Import (Code Splitting)

Load heavy client UI (editor·chart·map) only when it is needed.

```tsx
// Caution: `ssr: false` is allowed only inside a 'use client' file.
// Used in a Server Component, Next.js 15 throws a runtime error.
'use client'

import { useState } from 'react'
import dynamic from 'next/dynamic'

const HeavyEditor = dynamic(() => import('@/components/common/rich-editor'), {
  loading: () => <div className="h-64 animate-pulse rounded-lg bg-muted" />,
  ssr: false,               // only for a browser-only library
})

export function EditToggle({ content }: { content: string }) {
  const [editing, setEditing] = useState(false)
  return editing
    ? <HeavyEditor content={content} />
    : <button onClick={() => setEditing(true)}>{content}</button>
}
```

- When a Server Component needs lazy loading, use `dynamic(() => import(…))` alone,
  **without** `ssr: false` — SSR is kept and only the client chunk is split out
- Conditional UI that is not visible on the first screen (inside a modal, content behind a tab) is the candidate

## 4. useMemo · useCallback — only where they are needed

```tsx
// app/(main)/tasks/_components/task-stats.tsx
'use client'

import { memo, useCallback, useMemo, useState } from 'react'
import { cn } from '@/lib/utils'
import type { Task } from '@/lib/queries/tasks'

export function TaskStats({ tasks }: { tasks: Task[] }) {
  const [selectedId, setSelectedId] = useState<string | null>(null)

  // Good: useMemo only for an expensive computation
  const stats = useMemo(
    () => ({ total: tasks.length, doneCount: tasks.filter((t) => t.done).length }),
    [tasks]
  )

  // Good: useCallback only for a handler passed to a memo'd child
  //       (if the handler reference changes every render, the child's memo is defeated)
  const handleSelect = useCallback((id: string) => setSelectedId(id), [])

  return (
    <div className="space-y-1">
      <p className="text-sm text-muted-foreground">{stats.doneCount} / {stats.total} done</p>
      {tasks.map((task) => (
        <TaskRow key={task.id} task={task} selected={task.id === selectedId} onSelect={handleSelect} />
      ))}
    </div>
  )
}

interface TaskRowProps {
  task: Task
  selected: boolean
  onSelect: (id: string) => void
}

const TaskRow = memo(function TaskRow({ task, selected, onSelect }: TaskRowProps) {
  return (
    <button onClick={() => onSelect(task.id)} className={cn('block w-full text-left text-sm', selected && 'font-semibold')}>
      {task.title}
    </button>
  )
})
```

```tsx
// Bad: useMemo for a trivial computation
const fullName = useMemo(() => `${firstName} ${lastName}`, [firstName, lastName])
// Good: compute it directly
const fullName = `${firstName} ${lastName}`

// Bad: useCallback for a handler that is not passed to a child
const handleClick = useCallback(() => setOpen(true), [])
// Good: define it directly
const handleClick = () => setOpen(true)
```

## 5. React.memo — only for components whose re-render is measurably expensive

```tsx
import { memo } from 'react'

const ExpensiveChart = memo(function ExpensiveChart({ data }: { data: ChartPoint[] }) {
  // complex rendering logic
  return <canvas /* … */ />
})
```

The default is no memo — wrap only when profiling has confirmed the cost of re-rendering.

## 6. Debounce — frequent input events

<!-- file: hooks/use-debounce.ts -->
```ts
// hooks/use-debounce.ts
import { useEffect, useState } from 'react'

export function useDebounce<T>(value: T, delay = 300): T {
  const [debouncedValue, setDebouncedValue] = useState(value)

  useEffect(() => {
    const timer = setTimeout(() => setDebouncedValue(value), delay)
    return () => clearTimeout(timer)
  }, [value, delay])

  return debouncedValue
}
```

```tsx
// app/(main)/tasks/_components/search-bar.tsx
'use client'

import { useEffect, useState } from 'react'
import { useDebounce } from '@/hooks/use-debounce'
import { useQueryParams } from '@/hooks/use-query-params'   // defined in: resources/state-management.md §7
import { Input } from '@/components/ui/input'

export function SearchBar() {
  const { searchParams, setQueryParam } = useQueryParams()
  const initial = searchParams.get('q') ?? ''
  const [query, setQuery] = useState(initial)
  const debouncedQuery = useDebounce(query, 300)            // update the URL only after a 300ms pause

  useEffect(() => {
    if (debouncedQuery !== initial) setQueryParam('q', debouncedQuery)  // searchParams changes → server re-queries
  }, [debouncedQuery, initial, setQueryParam])

  return <Input value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search" />
}
```

When the URL changes, the Server Component runs again with the new `searchParams` — no client-side refetching code
is needed. For writing the server-side search query, see the search·pagination section of resources/data-fetching.md.

## 7. Resource cleanup — preventing memory leaks

Every subscription·timer·listener created in a `useEffect` must be released in the cleanup.

<!-- file: components/common/live-status.tsx -->
```tsx
// components/common/live-status.tsx
'use client'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'

export function LiveStatus({ statusUrl }: { statusUrl: string }) {
  const router = useRouter()
  const [narrow, setNarrow] = useState(false)

  useEffect(() => {
    const interval = setInterval(() => router.refresh(), 5000)   // interval
    return () => clearInterval(interval)
  }, [router])

  // The fetch below is a "cleanup technique demo" — in this stack a Server Component does the data query.
  // Client fetch is used only for external APIs outside the data layer (status badges·third-party widgets).
  useEffect(() => {
    const controller = new AbortController()                     // request cancellation
    fetch(statusUrl, { signal: controller.signal }).catch(() => {})
    return () => controller.abort()
  }, [statusUrl])

  useEffect(() => {
    const handler = () => setNarrow(window.innerWidth < 768)     // event listener
    window.addEventListener('resize', handler)
    return () => window.removeEventListener('resize', handler)
  }, [])

  return <span className="text-xs text-muted-foreground">{narrow ? 'Mobile' : 'Desktop'}</span>
}
```

A realtime subscription channel is the same — clean it up with the release API the backend axis provides (`resources/data-fetching.md`).

## 8. List keys

```tsx
// Good: a stable, unique key
{tasks.map((task) => <TaskCard key={task.id} task={task} />)}

// Bad: index key — state drifts when items are added/removed/sorted
{tasks.map((task, index) => <TaskCard key={index} task={task} />)}
```

## 9. Performance checklist

- [ ] Is the Server Component the default, with a minimal `'use client'` boundary?
- [ ] Are images on `next/image` with appropriate `sizes`·`priority`?
- [ ] Is heavy client UI split out with `dynamic()`? (`ssr: false` only in a client file)
- [ ] Does every `useEffect` have a cleanup?
- [ ] Is debounce applied to search/filter input?
- [ ] Have you avoided unnecessary `useMemo`/`useCallback`/`memo`?
