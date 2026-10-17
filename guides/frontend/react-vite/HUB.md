---
name: frontend-guide
description: "React 18 + Vite 5 SPA frontend guide: common-layout extraction, TanStack Query v5 server state with cursor pagination, Zustand client state, React Router v7 protected routes, Tailwind styling, a single HTTP client with Bearer tokens and one-shot 401 refresh, and the auth adapter. Use when creating or modifying components, pages, layouts, styling, routing, API clients, data fetching, caching, state, forms, or login/session code."
---
<!-- orangekit-guide-baseline: verified 2026-10-17 react@18 react-dom@18 vite@5 typescript@5 react-router@7 @tanstack/react-query@5 zustand@5 tailwindcss@3.4 react-error-boundary@6 sonner@2 msw@2 vitest@3 clsx@2 tailwind-merge@2 eslint-plugin-import@2 oidc-client-ts@3 @testing-library/react@16 @testing-library/user-event@14 @testing-library/jest-dom@6 -->

# React + Vite SPA Frontend Guide

This guide covers an **SPA that runs only in the browser**. There is no server runtime, so all data comes
over HTTP from your own API, and everything that goes into the bundle is assumed to be public.

If the project has its own API spec (e.g. `dev/docs/api/`), that is canonical, and the wire values in this guide (paths · codes · statuses) are pattern examples.
The example values follow the standard HTTP contract — success `{ data }` · list `{ data, nextCursor }`, failure
`{ error: { code, message, details? }, requestId }`, cursor pagination, someone else's resource is 404.

## Quick Start

### Adding a new screen (route)

- [ ] **Search first** in `src/components/common/` and `src/components/layout/` for a shell · form · table to reuse
- [ ] Add the path to the route-object tree in `src/routes/routes.tsx` — nest it under `RequireAuth` if it needs auth
- [ ] Put the screen in `src/features/<feature>/pages/`, export it as `Component`, and split it with the route's `lazy`
- [ ] Data only through the query hooks in `src/features/<feature>/api/` — a screen does not call `http` · `fetch`
- [ ] Render all three states — loading · empty · error (`isPending` → `isError` → zero items)
- [ ] If you hid UI by permission, handle the server's **403 · 404** responses too (404 means "missing or not yours")
- [ ] Promote a Tailwind combination to a shared component on its third repetition
- [ ] Confirm `npm run typecheck && npm run lint && npm run test` passes

### Adding a new API integration (query/mutation)

- [ ] Check the wire shape and declare the types + narrowing function (`parseX`) as in `tasks.types.ts` — do not invent fields
- [ ] Endpoint functions use only `http` from `src/api/http.ts` and pass `parse` (the body goes in `{ body }`)
- [ ] Add the query key to the `<feature>Keys` factory — the cursor does not go in the key
- [ ] Lists use `useInfiniteQuery` (`initialPageParam` · `getNextPageParam: (p) => p.nextCursor ?? undefined`) — there is no `page`/`total`
- [ ] Writes use `useMutation` — on success, `setQueryData` for the detail and `invalidateQueries` for the list
- [ ] Branch errors on `error.code` — `VALIDATION_FAILED` puts `details` under the fields, `NOT_FOUND` · `FORBIDDEN` are not retried
- [ ] Do not handle 401 in a screen — the http layer refreshes once and, on failure, sends the user to login
- [ ] MSW handlers follow the envelope contract too, and every failure test is paired with a passing assertion

## Architecture Overview

```
[Browser SPA]  React 18 · Vite 5 bundle · static hosting         ← an untrusted execution environment
      │ HTTPS + Authorization: Bearer <access token>
      ▼
[HTTP API]     /api/tasks (+ /api/auth/* if self-issued)          ← the only trust boundary
      ├── token verification (self-issued signing key or IdP JWKS)
      └── authorization (ownership · role) — someone else's resource is 404, insufficient role is 403
[Auth adapter] src/auth/session.ts — self-issued or OIDC (PKCE). http knows only getAccessToken · refresh · endSession
```

| Concern | Owner | The frontend's role |
| --- | --- | --- |
| Business rules · validation | API server | Only an advance hint for UX; the final ruling is `VALIDATION_FAILED` |
| Authorization | API server | Hiding a button · gating a route is convenience. Always handle 403 · 404 |
| Token issuance · refresh | Server or IdP | Storing (memory/adapter storage) · attaching · one refresh on 401 · discarding |
| Server data cache | TanStack Query | A single cache. Never duplicated into a store |
| Screen state | Zustand / URL / `useState` | Only state the server does not know about |

**Minimum supported browsers** — the http client uses `AbortSignal.any` · `AbortSignal.timeout`, so Chrome 116 · Firefox 124 · Safari 17.4 or later. Supporting older browsers requires a polyfill.

Static hosting must return **`index.html` for every unmatched path** — without it, refresh · deep links (and
the OIDC callback) become 404s (`resources/routing.md` §6). Secrets · signing · policy decisions are all pushed out to the API server.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.tsx                 # startSession() + createRoot (Query · Router — no auth Provider)
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── routes/
│   ├── routes.tsx           # the route-object tree (single source, spreads authRoutes)
│   ├── RootLayout.tsx       # the global shell: header · nav · <Outlet />
│   └── RequireAuth.tsx      # the auth-gate layout route
├── api/
│   ├── http.ts              # the only place for raw fetch · envelope parsing · Bearer · 401 refresh
│   └── queryClient.ts       # the single QueryClient instance (retry policy)
├── auth/                    # session.ts (adapter) · routes.tsx · pages/ — owned by the auth variant
├── features/
│   └── tasks/
│       ├── api/             # endpoint functions + query keys + query/mutation hooks
│       ├── components/      # components used only by this feature
│       └── pages/           # the screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · Sidebar · SectionHeader
├── stores/                  # Zustand stores (no server data brought in)
├── lib/                     # cn() · safeReturnTo · api/errors.ts (ApiError) · pure utilities
└── types/                   # types shared by several features
```
<!-- /pack-slot -->

## Core Principles (6 Key Rules)

<!-- pack-slot: core-principles-axis -->
### 1. TanStack Query owns server data — never duplicate it into a global store

Moving a server response into Zustand gives you two caches and leaves you implementing invalidation · refetching ·
garbage collection by hand. Zustand holds only state the server does not know about (a modal being open, a collapsed sidebar).

```tsx
// ✅ server state in a query, client state in a store
const { data: tasks, isPending } = useTasksQuery(filter);
const isSidebarOpen = useUiStore((s) => s.isSidebarOpen);

// ❌ moving the server response into a store — a duplicated cache
useEffect(() => { fetchTasks().then(setTasksInStore); }, []);
const tasks = useTaskStore((s) => s.tasks);
```

### 2. HTTP only in the `src/api/` layer — a component never calls it directly

If a component `fetch`es directly, the auth header · error normalization · base URL diverge from screen to screen.
This boundary is **enforced by a lint rule**, not by discipline (see `resources/data-fetching.md`).

The hooks and the client are defined by `resources/data-fetching.md` — a screen knows only what a hook returns.

```tsx
// ✅ request function → query hook → component. A screen calls only the hook
const { data: tasks, isPending, isError } = useTasksQuery(filter);

// ❌ a raw fetch inside a component — the token and the error shape get reinvented here
const res = await fetch(`${import.meta.env.VITE_API_BASE_URL}/tasks`);
```

### 3. Extract repeated UI into a shared component, but search before you create one

Most duplication comes not from a failure to extract but from a **failure to search**. Before creating a new shared component,
always search `src/components/common/` and `src/components/layout/`.

```bash
rg -l "PageShell|EmptyState|DataTable" src/components   # by name
rg -l "rounded-lg border bg-white p-6" src/components    # by class combination
```

```tsx
// ✅ tokens (height · type · spacing) are owned in one shared component; call sites steer it through props only
<Button size="sm" variant="danger">Delete</Button>

// ❌ the call site overrides the tokens and the shared component becomes an empty shell
<Button className="h-11 px-6 text-base font-bold">Delete</Button>
```
### 4. Authorization is not a trust boundary — hiding is UX, blocking is the server

Anyone can read the bundle, and a route gate is bypassed from the console. The real permission is decided by the API on
every request. In this contract **someone else's resource is 404** (so existence does not leak), and 403 arrives only for an insufficient role —
a hidden button still needs handling for both of those responses as its pair.

```tsx
// ✅ hide it, but trust the server's ruling — 404 is one message, "missing or not yours" (loading-error-states.md §4)
{canDelete && <Button onClick={remove}>Delete</Button>}
// mutation onError: toast.error(toUserMessage(e))

// ❌ treating a token claim as proof that the permission check is done
if (jwtDecode(token).role === 'admin') await http.delete(`/api/tasks/${id}`);
```

### 5. There are no secrets in a browser bundle

A `VITE_*` variable is inlined as a string at build time and stays in the bundle as it is. API keys · signing keys ·
admin credentials are all held by the API server, and the frontend calls that server's endpoints.

```ts
// ✅ expose only values that may be public; src/config.ts is the one place that reads them
import { config } from '@/config';
const baseUrl = config.apiBaseUrl;          // public URL
const authority = config.oidc.authority;    // public issuer

// ❌ a secret embedded straight into the bundle — the prefix is not protection
const key = import.meta.env.VITE_DB_PASSWORD;
```

### 6. Every data screen has all three states: loading · empty · error

A screen that implements only the happy path goes blank on a slow network or with an expired session. The three states are
not optional; they are the minimum contract of a screen.

```tsx
// ✅ return all three branches (the list is a cursor infinite query — flatten the pages)
if (isPending) return <ListSkeleton rows={5} />;
if (isError) return <ErrorState error={error} onRetry={refetch} />;
const tasks = data.pages.flatMap((p) => p.items);
if (tasks.length === 0) return <EmptyState action={<CreateTaskButton />} />;
return <TaskTable rows={tasks} />;

// ❌ optional chaining mashes the three states together — error and empty stop being distinguishable
return <TaskTable rows={data?.pages.flatMap((p) => p.items) ?? []} />;
```
<!-- /pack-slot -->

## Common Imports

<!-- pack-slot: common-imports-axis -->
```tsx
// React 18
import { useState, useMemo, useCallback, forwardRef, type ReactNode } from 'react';

// routing (React Router v7 — 'react-router', not 'react-router-dom')
import { Link, NavLink, Outlet, Navigate, useNavigate, useParams,
         useSearchParams, useLocation, useRouteError, isRouteErrorResponse } from 'react-router';
import { createBrowserRouter, RouterProvider } from 'react-router';

// server state (TanStack Query v5)
import { useQuery, useInfiniteQuery, useMutation, useQueryClient, keepPreviousData,
         QueryClient, QueryClientProvider, QueryErrorResetBoundary } from '@tanstack/react-query';

// global client state (Zustand v5)
import { create } from 'zustand';
import { useShallow } from 'zustand/react/shallow';

// project-internal — HTTP · errors · the auth adapter keep the same names regardless of the method
import { http, type Page } from '@/api/http';
import { ApiError, type FieldErrors } from '@/lib/api/errors';
import { useAuth } from '@/auth/session';
import { config } from '@/config';
import { cn } from '@/lib/cn';
```
<!-- /pack-slot -->

<!-- pack-slot: component-template -->
## Component Template

```tsx
// src/features/tasks/components/TaskCard.tsx
// a feature component, so it knows the domain type. components/common/ conversely never imports features/
import { forwardRef, type ComponentPropsWithoutRef, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { formatDate } from '@/lib/format';
import type { Task } from '../api/tasks.types';

type TaskCardProps = ComponentPropsWithoutRef<'article'> & {
  task: Task;
  /** the action area is injected — it keeps the shared component ignorant of feature logic */
  actions?: ReactNode;
};

/**
 * One item of the list. It neither fetches data nor routes —
 * everything it needs arrives through props.
 */
export const TaskCard = forwardRef<HTMLElement, TaskCardProps>(
  ({ task, actions, className, ...rest }, ref) => (
    <article
      ref={ref}
      className={cn('rounded-lg border border-slate-200 bg-white p-4', className)}
      {...rest}
    >
      <h3 className="text-sm font-semibold text-slate-900">{task.title}</h3>
      <p className="mt-1 text-xs text-slate-500">{formatDate(task.createdAt)}</p>
      {actions && <div className="mt-3 flex gap-2">{actions}</div>}
    </article>
  ),
);
TaskCard.displayName = 'TaskCard';
```

- React 18 has no automatic ref forwarding — exposing a DOM ref requires `forwardRef`
- A shared component does not call `useNavigate` · `useQuery` (that blocks reuse)
- Merge `className` last with `cn()` so the call site can fine-tune spacing only
<!-- /pack-slot -->

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Create a component · extract repeated UI into a shared one · design-token ownership rules | `resources/component-patterns.md` |
| Write Tailwind classes · define variants · forbidden patterns | `resources/styling.md` |
| Decide whether to introduce global state · write a Zustand store · optimize subscriptions · reset stores on logout | `resources/state-management.md` |
| Add a route · nested layouts · protected routes · validating the return path · URL as state · deep links (history fallback) | `resources/routing.md` |
| Loading skeletons · empty states · error boundaries · user messages per error code | `resources/loading-error-states.md` |
| TypeScript configuration · domain types and narrowing responses · env variable types · testing components/hooks · HTTP mocking | `resources/types-and-testing.md` |
| HTTP client · envelope parsing · 401 refresh · query keys · query/mutation hooks · cache invalidation · HTTP boundary lint | `resources/data-fetching.md` |
| One feature end to end — cursor list · create (field errors) · status transition · detail 404 · tests | `resources/complete-example.md` |
| Login/logout · token storage · session restore · login (and callback) screens · single-flight refresh | `resources/auth-and-session.md` |
