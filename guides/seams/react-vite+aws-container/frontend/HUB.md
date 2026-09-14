---
name: frontend-guide
description: "[Preset: react-vite × aws-container] React 18 + Vite 5 SPA frontend guide covering common-layout extraction, TanStack Query v5 server state, Zustand client state, React Router v7 protected routes, Tailwind styling, and OIDC/Cognito tokens and 401 handling. Use when creating or modifying components, pages, layouts, styling, routing, REST API clients, data fetching, caching, state, or auth/session code. Use ONLY when the active preset matches."
---
<!-- orangekit-guide-baseline: verified 2026-08-22 react@18 vite@5 typescript@5 react-router@7 @tanstack/react-query@5 zustand@5 tailwindcss@3.4 react-oidc-context@3 oidc-client-ts@3 react-error-boundary@6 sonner@2 msw@2 vitest@3 clsx@2 tailwind-merge@2 eslint-plugin-import@2 -->

# React + Vite SPA Frontend Guide

This guide covers an **SPA that runs only in the browser**. There is no server runtime, so all data comes
over HTTP from a REST API you operate yourself, and everything that goes into the bundle is assumed to be public.

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

### Adding a new screen (route)

- [ ] **Search first** in `src/components/common/` and `src/components/layout/` for a shell · form · table to reuse
- [ ] Add the path to the route-object tree in `src/routes/routes.tsx` — nest it under `RequireAuth` if it needs auth
- [ ] Put the screen component in `src/features/<feature>/pages/` and code-split it with the route's `lazy`
- [ ] Fetch data only through the query hooks in `src/features/<feature>/api/` (no `fetch` inside a component)
- [ ] Render all three states — loading · empty · error (`isPending` / zero items / `isError`)
- [ ] If you hid UI by permission, implement handling for the server's **403 · 404** responses as well (hiding is only UX)
- [ ] Write styles as Tailwind utilities, and promote a combination to a shared component on its third repetition
- [ ] Confirm `npm run typecheck && npm run lint && npm run test` passes

### Adding a new API integration (query/mutation)

- [ ] Check the backend's request/response contract and declare the types + narrowing function in `src/features/<f>/api/tasks.types.ts`
- [ ] Request functions use only the shared client in `src/api/http.ts` (never assemble the URL or auth header by hand)
- [ ] Add the query key to the `<feature>Keys` factory (do not scatter string literals across screens)
- [ ] Lists use cursor pagination — `useInfiniteQuery` (`initialPageParam` · `getNextPageParam`).
      `page`/`total` do not exist on the backend
- [ ] Writes use `useMutation` — hook names are `use<Thing>Query` / `use<Thing>Mutation`
- [ ] In the mutation's `onSuccess`, invalidate the affected keys with `invalidateQueries({ queryKey })`
- [ ] Branch errors on `error.code` (`UNAUTHORIZED` is the session, `FORBIDDEN`/`NOT_FOUND` is authorization,
      `VALIDATION_FAILED` is the per-field message in `details`)
- [ ] Set `staleTime` to match the nature of the data (the default of 0 refetches every time you return to the screen)
- [ ] Confirm no secret or signing logic ended up in the frontend (every `VITE_*` is a public value)

## Architecture Overview

```
[Browser SPA]  React 18 · Vite 5 bundle · static hosting    ← an untrusted execution environment
      │ HTTPS + Authorization: Bearer <access_token>
      ▼
[REST API]     Hono on ECS/Fargate · behind an ALB          ← the only trust boundary
      ├── authentication check (JWT signature · issuer · audience · expiry)
      ├── authorization enforcement (ownership · role) — unauthorized answers 404   ← the frontend only mimics this
      └── Drizzle ORM → RDS PostgreSQL
      ▲
[OIDC Issuer]  Cognito (standard OIDC) — Authorization Code + PKCE
```

Static hosting **must return `index.html` for every unmatched path**. Without that setting,
refresh · deep links · `/auth/callback` all become 404s (`resources/routing.md` §6).

| Concern | Owner | The frontend's role |
| --- | --- | --- |
| Business rules · validation | API server | It only previews the same rules for UX; the final ruling is the server response |
| Authorization (who may do what) | API server | Hiding a button · gating a route = convenience. Always handle 403 · 404 |
| Session · token issuance | OIDC Issuer | Storing · attaching · refreshing · discarding the token |
| Server data cache | TanStack Query | A single cache. Never duplicated elsewhere |
| Screen state | Zustand / URL / `useState` | Only state the server does not know about |

The premise of this stack is that **there is no server code**. There is no escape hatch called "a module that runs only on
the server", so secrets · signing · policy decisions have no option but to be pushed out to the API server.

## Directory Structure

```
src/
├── main.tsx                 # createRoot + Provider assembly (Auth · AuthWiring · Query · Router)
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── routes/
│   ├── routes.tsx           # the route-object tree (single source, includes /auth/callback)
│   ├── RootLayout.tsx       # the global shell: header · nav · <Outlet />
│   └── RequireAuth.tsx      # the auth-gate layout route
├── api/
│   ├── http.ts              # fetch wrapper · envelope parsing · auth header · ApiError normalization
│   └── tokenProvider.ts     # access-token provider (injected by the auth module)
├── auth/                    # oidcConfig · AuthWiring · session · endSession · groups · pages/
├── features/
│   └── tasks/
│       ├── api/             # endpoint functions + query keys + query/mutation hooks
│       ├── components/      # components used only by this feature
│       └── pages/           # the screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · Sidebar · SectionHeader
├── stores/                  # Zustand stores (no server data brought in)
├── lib/                     # cn() · formatters · pure utilities
└── types/                   # types shared by several features
```

## Core Principles (6 Key Rules)

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

```tsx
// ✅ request function → query hook → component
export const useTasksQuery = (f: TaskFilter) =>
  useQuery({ queryKey: taskKeys.list(f), queryFn: () => listTasks(f) });

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

Anyone can download and read the bundle, and a route gate is bypassed from the console. A UI gate is a device
for "not clicking it by mistake"; the real permission is decided by the API on every request.

```tsx
// ✅ hide it, but trust the server's ruling and handle the failure response
{canDelete && <Button onClick={remove}>Delete</Button>}
// mutation.onError: toast.error(toUserMessage(e));
// this backend returns **someone else's resource as 404** (so existence does not leak). 403 arrives only for an insufficient role

// ❌ treating a token claim as "the permission check is done" — defenseless unless the server checks again
if (jwtDecode(token).role === 'admin') await http.delete(`/tasks/${id}`);
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

## Common Imports

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

// auth (standard OIDC — not a specific IdP SDK)
import { AuthProvider, useAuth } from 'react-oidc-context';
import { UserManager, WebStorageStateStore, InMemoryWebStorage } from 'oidc-client-ts';

// error boundary · toast (the packages are pinned — do not use a different one per screen)
import { ErrorBoundary } from 'react-error-boundary';
import { toast } from 'sonner';

// project-internal
import { http, ApiError, type Page } from '@/api/http';
import { config } from '@/config';
import { cn } from '@/lib/cn';
```

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

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Create a component · extract repeated UI into a shared one · design-token ownership rules | `resources/component-patterns.md` |
| Fetch list/detail data · query keys · cache invalidation · API client | `resources/data-fetching.md` |
| Enforce the HTTP call boundary with lint | `resources/data-fetching.md` |
| Add a route · nested layouts · protected routes · login/callback screens · deep links (history fallback) | `resources/routing.md` |
| Decide whether to introduce global state · write a Zustand store · optimize subscriptions | `resources/state-management.md` |
| Write Tailwind classes · define variants · forbidden patterns | `resources/styling.md` |
| Loading skeletons · empty states · error boundaries · error classification | `resources/loading-error-states.md` |
| Login/logout · token storage · 401 handling · cache cleanup · swapping the issuer | `resources/auth-and-session.md` |
| TypeScript configuration · narrowing API types · env variable types | `resources/types-and-testing.md` |
| Testing components/hooks · HTTP mocking · resetting stores | `resources/types-and-testing.md` |
| One feature end to end, from list query to create | `resources/complete-example.md` |
