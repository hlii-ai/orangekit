<!-- orangekit-pack-ledger: frontend/nextjs v3.12.0 -->

# nextjs pack — symbol ledger

This is the table the gate machine-checks. `provides` is what this pack defines, so if the seam defines it again that is a
duplicate; `requires` is what this pack consumes but does not define, so the seam must supply it.
Library APIs are out of scope.

## provides — this pack defines them

**The "shape" column is the full signature.** While this column was missing, the ledger told you **only the owner**, and an
author who cannot read sibling files **guessed** the signature — in the 2026-08-23 parallel-authoring measurement two
critical defects came out of exactly this hole. Both arguments were `string`, so neither TypeScript nor the gate caught a
call that reversed their order (every single-record lookup 404'd), and an example that mistook "the function that drains"
for "the function that wires the drain up" shipped (the server exited after 800ms). So write the argument names and
**order** · type · return · what it throws on failure · what the caller is obliged to wire up.
**This axis has a server/client boundary, so for every symbol also record which side of that boundary it is used on**
— get this wrong and it surfaces not as a build error but at runtime or as a leaked secret. The gate blocks an empty
"shape" and **an argument count that disagrees with the definition** with a FAIL. One row = one symbol.

| symbol | defining file | shape | nature |
| --- | --- | --- | --- |
| `cn` | styling.md | **`lib/utils.ts`** — `cn(...inputs: ClassValue[]): string` — variadic utility (1 parameter = rest) · merges conditionals with `clsx`, then resolves Tailwind conflicts with `twMerge` · a pure function, so **both** server and client | class-merge utility · variant components |
| `Badge` | styling.md | `<Badge variant?={'default'\|'outline'\|'destructive'} className?={string} {...React.HTMLAttributes<HTMLSpanElement>} />` — renders a `<span>` · `variant` defaults to `'default'` · no hooks, so it renders on **both** sides, but to pass a handler prop such as `onClick` it must sit inside a Client Component | class-merge utility · variant components |
| `PageHeader` | component-patterns.md | **`components/layout/page-header.tsx`** — `<PageHeader title={string} backHref?={string} rightSlot?={React.ReactNode} />` — **Server Component** (no hooks) · does not take `children` · when `backHref` is absent it fills the back-button slot with blank space · only this component defines the header height·title font, and pages control it through props alone | shared UI·layout |
| `PageSection` | component-patterns.md | `<PageSection title={string} action?={React.ReactNode}>{children}</PageSection>` — **Server Component** (no hooks) · `children` **required** · `action` is the slot to the right of the title | shared UI·layout |
| `EmptyState` | component-patterns.md | **`components/common/empty-state.tsx`** — `<EmptyState title={string} description?={string} action?={React.ReactNode} />` — **Server Component** (no hooks) · no `children` · for "zero items" only, not for showing errors | shared UI·layout |
| `SearchInput` | component-patterns.md | `<SearchInput onSearch={(query: string) => void} defaultValue?={string} ref?={React.Ref<HTMLInputElement>} />` — `onSearch` is a **required function prop**, so it can be used **only inside a Client Component boundary** (passing a function Server → Client is forbidden) · on React 19 `ref` is an ordinary prop (no `forwardRef`) · the body is omitted from the guide | shared UI·layout |
| `CollapsiblePanel` | component-patterns.md | **`components/common/collapsible-panel.tsx`** — `<CollapsiblePanel title={string}>{children}</CollapsiblePanel>` — `'use client'` · `children` **required**, and it **passes a Server Component straight through** (a tree received as children stays on the server) · initially open (`useState(true)`), with no prop for controlling the open state from outside | shared UI·layout |
| `useUiStore` | state-management.md | **`stores/ui-store-provider.tsx`** — `useUiStore<T>(selector: (state: UiState) => T): T` — a `'use client'`-only hook · one selector argument (no whole-store subscription form is offered) · called outside `UiStoreProvider` it **throws** `Error('useUiStore must be used within UiStoreProvider')` | global client state |
| `UiState` | state-management.md | **`stores/ui-store.ts`** — `interface UiState { sidebarOpen: boolean; toggleSidebar: () => void }` — both fields **required** · state and the action that changes it live in the same type (no external `setState`) | global client state |
| `createUiStore` | state-management.md | **`stores/ui-store.ts`** — `createUiStore(init?: { sidebarOpen?: boolean }): StoreApi<UiState>` — not a hook but a vanilla `createStore` **factory** · one argument (optional; the real type is `Partial<Pick<UiState, 'sidebarOpen'>>`) · caller's obligation: call it **once per tree** (the `useRef` in `UiStoreProvider` is that place) — called at module top level it is shared across server requests | global client state |
| `UiStoreProvider` | state-management.md | **`stores/ui-store-provider.tsx`** — `<UiStoreProvider>{children}</UiStoreProvider>` — `'use client'` · the only prop is `children: React.ReactNode` (no initial-value prop) · caller's obligation: wrap in the root `layout.tsx` (or that segment's layout) — without the wrapper `useUiStore` throws · even though the Provider is a client component, a Server Component received as `children` stays on the server | global client state |
| `useCartStore` | state-management.md | **`stores/cart-store.ts`** — `useCartStore<T>(selector: (s: CartState) => T): T` — a `'use client'`-only hook · `CartState = { items: CartItem[]; add(item: CartItem): void; remove(id: string): void; clear(): void }` · created by `create()` at module top level, so **on the server it is shared across requests** (allowed for purely client state only) · §5 shows the same hook again, wrapped in `persist({ name: 'cart-storage' })` | store example |
| `CartItem` | state-management.md | **`stores/cart-store.ts`** — `interface CartItem { id: string; name: string; qty: number }` — all three fields **required** · `id` is both the key for `remove(id)` and the list key, so it must be stable | store example |
| `CartBadge` | state-management.md | **`components/cart/cart-badge.tsx`** — `<CartBadge />` — `'use client'` · no props · before mount it renders `<Skeleton className="h-6 w-10" />` (prevents a hydration mismatch between the persisted value and the server's first render) — change the placeholder size and the layout jumps | store example |
| `CartSummary` | state-management.md | **`components/cart/cart-summary.tsx`** — `<CartSummary />` — `'use client'` · no props · subscribes to `useCartStore` with a selector and bundles several slices with `useShallow` (a new object every time → prevents infinite re-renders) | store example |
| `useQueryParams` | state-management.md | **`hooks/use-query-params.ts`** — `useQueryParams(): { searchParams: ReadonlyURLSearchParams; setQueryParam: (key: string, value: string \| null) => void }` — `'use client'` · **no arguments** · **`setQueryParam`'s order is (key, value) and both are string-like, so reversing them still type-checks** · an empty or `null` value deletes the key, and when `key` is not `'page'` it deletes `page` as well · it uses `router.replace(…, { scroll: false })`, so it does not pile up history · caller's obligation: it uses `useSearchParams()`, so it must sit inside a `<Suspense>` boundary | URL state · forms |
| `ProfileForm` | state-management.md | `<ProfileForm defaultValues?={ProfileFormData} />` — `'use client'` · the only prop is `defaultValues` (optional) · `ProfileFormData = z.infer<typeof profileSchema>` = `{ name: string; email: string }` · submission is delegated to the Server Action `updateProfile(data)` (RHF does client-side validation only) · does not use `.default()` in the schema | URL state · forms |
| `DeleteTaskButton` | state-management.md | `<DeleteTaskButton taskId={string} />` — `'use client'` · the only prop is `taskId` (required) · calls `deleteTask(taskId)` inside `startTransition` and **receives failure as the return value `result.error`** (a throw leaks out to `error.tsx`) · locks the button while `isPending` | URL state · forms |
| `useDebounce` | performance.md | **`hooks/use-debounce.ts`** — `useDebounce<T>(value: T, delay = 300): T` — a `'use client'`-only hook · two arguments, the second optional (default 300ms) · resets the timer whenever the value·delay changes and clears it in the cleanup | performance patterns |
| `SearchBar` | performance.md | `<SearchBar />` — `'use client'` · no props · combines `useQueryParams` + `useDebounce(query, 300)` so `q` is updated only after a 300ms pause (the URL change is what triggers the server re-query) · caller's obligation: it goes through `useSearchParams()`, so place it inside `<Suspense>` | performance patterns |
| `TaskStats` | performance.md | `<TaskStats tasks={Task[]} />` — `'use client'` · the only prop is `tasks` (required) · receives the `Task[]` queried on the server as props (no copying into a store) · the inner `TaskRow` belongs to the same file and is not exported | performance patterns |
| `LiveStatus` | performance.md | **`components/common/live-status.tsx`** — `<LiveStatus statusUrl={string} />` — `'use client'` · the only prop is `statusUrl` (required) · calls `router.refresh()` every 5 seconds and on unmount releases the interval·`AbortController`·listeners in full · `statusUrl` is used only for external APIs **outside** the data layer | performance patterns |
| `EditToggle` | performance.md | `<EditToggle content={string} />` — `'use client'` · the only prop is `content` (required) · it uses `dynamic(…, { ssr: false })`, so **the component file itself must be `'use client'`** (`ssr: false` in a Server Component is a runtime error on Next.js 15) | performance patterns |
| `Task` | file-organization.md | `interface Task { id: string; title: string; done: boolean; created_at: string }` — all four fields **required** · `created_at` is a snake_case ISO string (not a Date) · reuse what `lib/queries/` exports and do not redefine it in components or `types/` | domain type·component placement example |
| `TaskCard` | file-organization.md | `<TaskCard task={Task} className?={string} />` — **Server Component** (no hooks) · `task` required·`className` optional · no `children` · the body is omitted from the guide | domain type·component placement example |
| `AppHeader` | routing.md | **`components/layout/app-header.tsx`** — `<AppHeader />` — **async Server Component** · no props · it calls `await getCurrentUser()` internally, so it cannot be imported from a `'use client'` file · it passes down only the fields it needs (`user.email`) to the client leaf, not the whole user object | layout · metadata |
| `metadata` | routing.md | `const metadata: Metadata` — a **static** module export (not a function) of a routing file (`page.tsx`·`layout.tsx`) · server only · cannot be used together with `generateMetadata` in the same file · when the root layout has `title.template`, fill in `title` only | layout · metadata |
| `generateMetadata` | routing.md | `generateMetadata({ params }: PageProps): Promise<Metadata>` — one argument (route props) · `async` required, and `params` is **a Promise, so it must be `await`ed** · a module export of a routing file, executed on the server only | layout · metadata |

`Component`·`metadata`·`generateMetadata`·`middleware` are exports whose names the framework
dictates — a different body per file is normal, so they are excluded from duplicate detection.

## requires — the seam must supply them

**Distinguish the kind.** `project` must be `export`ed by the seam; `library` is judged by whether the name appears in an
import statement. `cross-axis` is defined by the **opposite axis pack**, so look for it in the guide on the other side, not
in this one — having no definition inside this guide even after assembly is normal.

| symbol | kind | shape the pack assumes | why it is a seam concern |
| --- | --- | --- | --- |
| `getCurrentUser` | project | `getCurrentUser(): Promise<AuthUser \| null>` — **no arguments** and `async`, so `await` is required · unauthenticated returns `null` rather than throwing (the call site branches with `user ? … : …`) · **server boundary only**, so a component that calls it becomes an async Server Component (cannot be imported from a `'use client'` file) · `Promise<AuthUser \| null>` — the user as verified on the server | how the authenticated principal is determined is a function of the backend axis |
| `AuthUser` | project | `{ id, email }` | same as above |
| `getTasks` | project | `getTasks(filter?: { id?: string }): Promise<Task[]>` — **call sites disagree**: `PACK.md` uses the argument-less `getTasks()` (2 places, "RLS returns only the caller's own rows — no userId argument"), `typescript-standards.md` uses `getTasks({ id })` in 1 place. **The argument-less form is canonical** and the argument is treated as an **optional filter** (with one optional argument both call sites compile) · **the argument is not a userId** — the principal is decided by RLS, so the seam must not implement the first argument as an owner id · an empty result is `[]`, not `null` (call sites use `.length`·`.map` directly) · list query function | the data access layer is owned by the seam |
| `TaskList` | project | list-rendering component | depends on the fetching method |
| `ActionState` | project | the return contract of a Server Action | the action boundary is a function of the combination |
| `Database` | cross-axis | a type generated from the DB schema | the **backend axis pack** owns the generation procedure (`database-patterns.md` in `backend/supabase`). Having no definition inside the frontend guide is normal |
| `createClient` | cross-axis | the server version `@/lib/supabase/server` and the client version `@/lib/supabase/client` are **different functions**. The server one is bound to cookies, is per-request and needs `await` — calling two files by one name is the idiom of this axis, so **the import path decides the boundary** | the **backend axis pack** owns the creation convention (the same symbol is also in the `requires` of `backend/supabase`) |
| `Button` | library | shadcn/ui **generates** it at `@/components/ui/button`. The pack neither defines nor modifies it — the project brings it in with `npx shadcn add button` | a scaffolding artifact, so not owned by the pack. The hub's Common Imports hands the name over, so the source of supply is stated |
| `Input` | library | shadcn/ui **generates** it at `@/components/ui/input`. The pack neither defines nor modifies it — the project brings it in with `npx shadcn add input` | a scaffolding artifact, so not owned by the pack. The hub's Common Imports hands the name over, so the source of supply is stated |
| `Skeleton` | library | shadcn/ui **generates** it at `@/components/ui/skeleton`. The pack neither defines nor modifies it — the project brings it in with `npx shadcn add skeleton` | a scaffolding artifact, so not owned by the pack. The hub's Common Imports hands the name over, so the source of supply is stated |

## Removed from this pack during extraction

Judged not axis-local and moved to the seam. This table is the evidence if it has to be undone.

| what moved | original location | where it went |
| --- | --- | --- |
| §6 protected routes (including middleware session refresh) | `routing.md` L133-213 | seam `auth-and-session.md` |
| §7 generated types (`supabase gen types`) | `typescript-standards.md` L115-134 | **backend axis pack** `backend/supabase/database-patterns.md` |
| 4 direct backend client calls | `routing.md` · `typescript-standards.md` | replaced by delegation to `getCurrentUser`·`getTasks` (declared in requires) |

## Known gaps (inherited at extraction time, not repaired)

| item | status |
| --- | --- |
| `Task` defined in three places | pack `file-organization.md`, seam `data-fetching.md`·`complete-example.md`. **The fields are completely identical** and only the form differs, so this is not a signature conflict. Inherited from the original `nextjs-frontend-guide` |
