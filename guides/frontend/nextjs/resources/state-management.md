<!-- orangekit-pack: frontend/nextjs v3.12.0 -->
# State Management

How to tell local from global, Zustand subscription patterns, the form state boundary (useActionState vs RHF).

## 1. Classifying state — where to put it

| Kind of state | Tool |
| --- | --- |
| UI state of a single component (open/closed, input value) | `useState` |
| Narrow state shared by a few siblings | lift it into the parent component (lifting) |
| State that must be shareable·bookmarkable via the URL (filter·tab·pagination) | `searchParams` |
| Global client state used across several trees (sidebar·theme·cart) | Zustand |
| Server data (the contents of the DB) | fetched by a Server Component — **never copied into a store** |
| Form submission progress/result/optimistic value | `useActionState` / `useOptimistic` |

Principle: **the further down the list, the higher the cost.** Do not lift state that `useState` handles into Zustand. Introducing a global store is justified only when "three or more unrelated trees subscribe to the same state".

## 2. Zustand base form

<!-- file: stores/cart-store.ts -->
```ts
// stores/cart-store.ts
import { create } from 'zustand'

export interface CartItem {
  id: string
  name: string
  qty: number
}

interface CartState {
  items: CartItem[]
  add: (item: CartItem) => void
  remove: (id: string) => void
  clear: () => void
}

export const useCartStore = create<CartState>()((set) => ({
  items: [],
  add: (item) => set((s) => ({ items: [...s.items, item] })),
  remove: (id) => set((s) => ({ items: s.items.filter((i) => i.id !== id) })),
  clear: () => set({ items: [] }),
}))
```

- Define the state and the actions that change it **inside the same store** — never call `setState` directly from outside
- Use the curried `create<State>()(…)` form (for TypeScript inference)

## 3. Subscribe with a selector — never the whole store

<!-- file: components/cart/cart-summary.tsx -->
```tsx
// components/cart/cart-summary.tsx
'use client'

import { useShallow } from 'zustand/react/shallow'
import { useCartStore } from '@/stores/cart-store'
import { Button } from '@/components/ui/button'

export function CartSummary() {
  // Good: only the slice you need — re-renders only when that slice changes
  const items = useCartStore((s) => s.items)
  // Good: when pulling several slices into an object, use useShallow (a new object every time → prevents infinite re-renders)
  const { remove, clear } = useCartStore(useShallow((s) => ({ remove: s.remove, clear: s.clear })))
  // Bad: subscribing to the whole store — re-renders on every change
  // const store = useCartStore((s) => s)

  return (
    <div className="flex items-center gap-2">
      {items.map((i) => (
        <Button key={i.id} size="sm" variant="ghost" onClick={() => remove(i.id)}>{i.name} ✕</Button>
      ))}
      <Button size="sm" variant="ghost" onClick={clear}>Clear</Button>
    </div>
  )
}
```

- Do not store derived values; compute them in the selector:
  `useCartStore((s) => s.items.length)`

## 4. App Router caution — where the store is created

A store created by `create()` at module top level is **shared by every request** on the server.

- **A global `create()` is allowed**: purely client UI state that does not affect the server-rendered result
  (sidebar open, a client-only toggle). Only when the initial value is independent of user·request
- **The Provider pattern is mandatory**: a store that starts from a per-request initial value (user data and the like)

<!-- file: stores/ui-store.ts -->
```ts
// stores/ui-store.ts — vanilla store factory
import { createStore } from 'zustand/vanilla'

export interface UiState {
  sidebarOpen: boolean
  toggleSidebar: () => void
}

export const createUiStore = (init?: Partial<Pick<UiState, 'sidebarOpen'>>) =>
  createStore<UiState>()((set) => ({
    sidebarOpen: init?.sidebarOpen ?? false,
    toggleSidebar: () => set((s) => ({ sidebarOpen: !s.sidebarOpen })),
  }))
```

<!-- file: stores/ui-store-provider.tsx -->
```tsx
// stores/ui-store-provider.tsx — one store created per request (per tree)
'use client'

import { createContext, useContext, useRef } from 'react'
import { useStore } from 'zustand'
import { createUiStore, type UiState } from './ui-store'

type UiStoreApi = ReturnType<typeof createUiStore>

const UiStoreContext = createContext<UiStoreApi | undefined>(undefined)

export function UiStoreProvider({ children }: { children: React.ReactNode }) {
  const storeRef = useRef<UiStoreApi | null>(null)
  if (!storeRef.current) storeRef.current = createUiStore()
  return <UiStoreContext.Provider value={storeRef.current}>{children}</UiStoreContext.Provider>
}

export function useUiStore<T>(selector: (state: UiState) => T): T {
  const store = useContext(UiStoreContext)
  if (!store) throw new Error('useUiStore must be used within UiStoreProvider')
  return useStore(store, selector)
}
```

Wrap with the Provider in the root `layout.tsx` (or the layout of the segment that needs it).
Even though the Provider itself is a client component, server components received as `children` stay on the server.

## 5. persist — when localStorage retention is needed

```ts
import { create } from 'zustand'
import { persist } from 'zustand/middleware'

export const useCartStore = create<CartState>()(
  persist(
    (set) => ({ /* the same items·add·remove·clear as §2 */ }),
    { name: 'cart-storage' }              // localStorage key
  )
)
```

**Hydration caution**: the server's first render uses the initial value, the browser uses the restored one — they disagree.
UI that depends on a persisted value renders only after mount has been confirmed.

<!-- file: components/cart/cart-badge.tsx -->
```tsx
// components/cart/cart-badge.tsx
'use client'

import { useEffect, useState } from 'react'
import { useCartStore } from '@/stores/cart-store'
import { Skeleton } from '@/components/ui/skeleton'

export function CartBadge() {
  const [mounted, setMounted] = useState(false)
  const count = useCartStore((s) => s.items.length)
  useEffect(() => setMounted(true), [])

  if (!mounted) return <Skeleton className="h-6 w-10" />   // the same placeholder as the server
  return <span className="rounded-full bg-primary px-2 text-xs text-primary-foreground">{count}</span>
}
```

## 6. Form state — useActionState by default, RHF+Zod only as the exception

Forms are **`useActionState` + a Server Action by default** (the mutation section of resources/data-fetching.md).
React Hook Form + `zodResolver` is introduced only when **complex client-side live validation** is
needed — cross-field validation, feedback as the user types, dynamic field arrays and the like.

```tsx
'use client'

import { useForm } from 'react-hook-form'
import { zodResolver } from '@hookform/resolvers/zod'
import { z } from 'zod'
import { updateProfile } from '../actions'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'

const profileSchema = z.object({
  name: z.string().min(1, 'Name is required'),
  email: z.email('Enter a valid email address'),      // Zod v4: z.email()
})

type ProfileFormData = z.infer<typeof profileSchema>

export function ProfileForm({ defaultValues }: { defaultValues?: ProfileFormData }) {
  const { register, handleSubmit, formState: { errors, isSubmitting } } =
    useForm<ProfileFormData>({ resolver: zodResolver(profileSchema), defaultValues })

  return (
    <form onSubmit={handleSubmit((data) => updateProfile(data))} className="space-y-4">
      <Input {...register('name')} placeholder="Name" />
      {errors.name && <p className="text-sm text-destructive">{errors.name.message}</p>}
      <Input type="email" {...register('email')} placeholder="Email" />
      {errors.email && <p className="text-sm text-destructive">{errors.email.message}</p>}
      <Button type="submit" disabled={isSubmitting}>Save</Button>
    </form>
  )
}
```

- The submission itself still goes through a Server Action — RHF only handles client validation·field state (server-side re-validation is owned by backend-guide)
- **Do not use `.default()` in a form schema** — zodResolver's input/output types diverge and rub against the `useForm` generic. Supply defaults through `defaultValues`

## 7. URL state — reading·writing `searchParams`

For filters·tabs·search terms·page numbers, **the URL is the store**. Sharing·bookmarking·the back button come for free, and
the Server Component re-runs with the new `searchParams`, so no client-side refetching code is needed. Reading is
`useSearchParams()`; writing is unified behind the single hook below.

<!-- file: hooks/use-query-params.ts -->
```ts
// hooks/use-query-params.ts
'use client'

import { useCallback } from 'react'
import { usePathname, useRouter, useSearchParams } from 'next/navigation'

export function useQueryParams() {
  const router = useRouter()
  const pathname = usePathname()
  const searchParams = useSearchParams()

  const setQueryParam = useCallback(
    (key: string, value: string | null) => {
      const params = new URLSearchParams(searchParams)
      if (value) params.set(key, value)
      else params.delete(key)                      // an empty value deletes the key (prevents a leftover ?q=)
      if (key !== 'page') params.delete('page')    // when a filter changes, the page goes back to 1
      router.replace(`${pathname}?${params}`, { scroll: false })
    },
    [router, pathname, searchParams]
  )

  return { searchParams, setQueryParam }
}
```

- `router.replace` does not pile up history — it stops every keystroke from creating a back-button entry. When the user must be able to go back, as with tab switching, use `router.push`
- A component that uses `useSearchParams()` must sit inside a `<Suspense>` boundary
- For a usage example (debounced search) see resources/performance.md; for the server-side translation see resources/data-fetching.md

## 8. Button-style mutations — `useTransition`

A mutation that is not a form (a delete·toggle-done button) cannot use `useActionState`. Call the Server Action directly, but **wrap it in `startTransition`** to get a pending state and disable the button.

```tsx
// app/(main)/tasks/_components/delete-task-button.tsx
'use client'

import { useState, useTransition } from 'react'
import { deleteTask } from '../actions'
import { Button } from '@/components/ui/button'

export function DeleteTaskButton({ taskId }: { taskId: string }) {
  const [isPending, startTransition] = useTransition()
  const [error, setError] = useState<string | null>(null)

  const handleDelete = () => {
    startTransition(async () => {
      const result = await deleteTask(taskId)      // the action also performs revalidatePath
      setError(result.error)
    })
  }

  return (
    <>
      <Button variant="ghost" size="sm" onClick={handleDelete} disabled={isPending}>
        {isPending ? 'Deleting…' : 'Delete'}
      </Button>
      {error && <p className="text-sm text-destructive">{error}</p>}
    </>
  )
}
```

- `isPending` stays `true` until the action plus the server re-render it causes are finished — the button stays
  locked until the list is actually updated
- Failures arrive as the action's **return value** (a throw goes straight to `error.tsx`) — the return contract of
  `deleteTask` is `ActionState` in resources/complete-example.md, and immediate reflection is `useOptimistic`
  (resources/data-fetching.md)

## 9. Anti-patterns

- **Copying server data**: putting a query result into a store creates a stale copy.
  Server data flows down as props, and refreshing is the job of `revalidatePath`/`router.refresh()`
- **Fetching inside a store**: never fetch data in a store action and hold it in state —
  querying is the Server Component's job (resources/data-fetching.md)
- **Whole-store subscription**: `useCartStore((s) => s)` — a subscription without a selector re-renders on every change
- **Storing derived values**: do not keep a computed value such as `totalCount` in state — compute it in a selector
- **Store sprawl**: split stores per domain, but never create a store for a single screen
