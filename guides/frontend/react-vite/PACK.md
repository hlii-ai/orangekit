<!-- orangekit-pack: frontend/react-vite v3.36.0 verified 2026-10-17 react@18 react-dom@18 @types/react@18 @types/react-dom@18 vite@5 typescript@5 react-router@7 @tanstack/react-query@5 zustand@5 tailwindcss@3.4 react-error-boundary@6 sonner@2 msw@2 vitest@3 @testing-library/react@16 @testing-library/dom@10 @testing-library/user-event@14 @testing-library/jest-dom@7 clsx@2 tailwind-merge@2 eslint-plugin-import@2 oidc-client-ts@3 -->

# react-vite axis pack — hub fragment

This is the **axis-local fragment to be inserted verbatim** when building a hub (`SKILL.md`). From v3.35.0 this pack assumes the standard <!-- verified: this pack's pack.json packVersion 3.35.0 change -->
contract (`http-standard`) and has its own full hub text in `HUB.md`, and for a combination where the auth variant resolves, the installer
lays that file down as is — these fragments are contained in `HUB.md` **character for character**. This file is used directly
only by a combination whose variant does not resolve so the hub has to be generated (a hybrid app shell), and by pre-built seams.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and is closed
inside the axis, so it holds whatever the backend axis turns out to be. The table at the end of the file states what generation fills in.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.tsx                 # startSession() + createRoot (Query · Router — no auth Provider)
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── routes/
│   ├── routes.tsx           # The route object tree (single source, spreads authRoutes)
│   ├── RootLayout.tsx       # Global shell: header · nav · <Outlet />
│   └── RequireAuth.tsx      # The auth gate layout route
├── api/
│   ├── http.ts              # The only place for raw fetch · envelope parsing · Bearer · 401 refresh
│   └── queryClient.ts       # The single QueryClient instance (retry policy)
├── auth/                    # session.ts (adapter) · routes.tsx · pages/ — owned by the auth variant
├── features/
│   └── tasks/
│       ├── api/             # Endpoint functions + query keys + query/mutation hooks
│       ├── components/      # Components used only by this feature
│       └── pages/           # The screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · Sidebar · SectionHeader
├── stores/                  # Zustand stores (server data must not be brought in)
├── lib/                     # cn() · safeReturnTo · api/errors.ts (ApiError) · pure utilities
└── types/                   # Types shared by several features
```
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
### 1. TanStack Query owns server data — do not copy it into a global store

Move a server response into Zustand and you have two caches, and you end up implementing invalidation·refetching·garbage
collection yourself. Zustand holds only state the server knows nothing about (a modal being open, a collapsed sidebar).

```tsx
// ✅ Server state in a query, client state in the store
const { data: tasks, isPending } = useTasksQuery(filter);
const isSidebarOpen = useUiStore((s) => s.isSidebarOpen);

// ❌ Moving the server response into the store — a duplicated cache
useEffect(() => { fetchTasks().then(setTasksInStore); }, []);
const tasks = useTaskStore((s) => s.tasks);
```

### 2. HTTP lives only in the `src/api/` layer — components do not call it directly

When a component calls `fetch` itself, the auth header·error normalization·base URL diverge screen by screen.
This boundary is **enforced by a lint rule**, not by discipline (see `resources/data-fetching.md`).

The hooks and the client are defined by `resources/data-fetching.md` — a screen knows only what a hook returns.

```tsx
// ✅ Request function → query hook → component. The screen calls only the hook
const { data: tasks, isPending, isError } = useTasksQuery(filter);

// ❌ A raw fetch inside a component — both the token and the error format get reinvented here
const res = await fetch(`${import.meta.env.VITE_API_BASE_URL}/tasks`);
```

### 3. Extract repeated UI into a shared component, but search before you build one

Most duplication comes not from a failure to extract but from a **failure to search**. Before creating a new shared
component, always search `src/components/common/` and `src/components/layout/`.

```bash
rg -l "PageShell|EmptyState|DataTable" src/components   # by name
rg -l "rounded-lg border bg-white p-6" src/components    # by class combination
```

```tsx
// ✅ Tokens (height·typography·spacing) are owned in one shared component, call sites control it through props only
<Button size="sm" variant="danger">Delete</Button>

// ❌ The call site overrides the tokens and the shared component becomes an empty shell
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

`VITE_*` variables are inlined as strings at build time and stay in the bundle as they are. API keys·signing keys·
admin credentials are all kept by the API server, and the frontend calls that server's endpoints.

```ts
// ✅ Expose only values that may be public, and read them in exactly one place, src/config.ts
import { config } from '@/config';
const baseUrl = config.apiBaseUrl;          // a public URL
const authority = config.oidc.authority;    // a public issuer

// ❌ A secret embedded straight into the bundle — the prefix protects nothing
const key = import.meta.env.VITE_DB_PASSWORD;
```

### 6. Every data screen has all three states: loading·empty·error

A screen that implements only the success path goes blank on a slow network and with an expired session. The three
states are not optional; they are the minimum contract of a screen.

```tsx
// ✅ Return all three branches (the list is a cursor infinite query — flatten the pages before use)
if (isPending) return <ListSkeleton rows={5} />;
if (isError) return <ErrorState error={error} onRetry={refetch} />;
const tasks = data.pages.flatMap((p) => p.items);
if (tasks.length === 0) return <EmptyState action={<CreateTaskButton />} />;
return <TaskTable rows={tasks} />;

// ❌ Optional chaining mashes the three states together — error and empty become indistinguishable
return <TaskTable rows={data?.pages.flatMap((p) => p.items) ?? []} />;
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
```tsx
// React 18
import { useState, useMemo, useCallback, forwardRef, type ReactNode } from 'react';

// Routing (React Router v7 — 'react-router', not 'react-router-dom')
import { Link, NavLink, Outlet, Navigate, useNavigate, useParams,
         useSearchParams, useLocation, useRouteError, isRouteErrorResponse } from 'react-router';
import { createBrowserRouter, RouterProvider } from 'react-router';

// Server state (TanStack Query v5)
import { useQuery, useInfiniteQuery, useMutation, useQueryClient, keepPreviousData,
         QueryClient, QueryClientProvider, QueryErrorResetBoundary } from '@tanstack/react-query';

// Global client state (Zustand v5)
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
// A feature component, so it knows the domain type. components/common/ conversely never imports from features/
import { forwardRef, type ComponentPropsWithoutRef, type ReactNode } from 'react';
import { cn } from '@/lib/cn';
import { formatDate } from '@/lib/format';
import type { Task } from '../api/tasks.types';

type TaskCardProps = ComponentPropsWithoutRef<'article'> & {
  task: Task;
  /** The action area is injected — this keeps a shared component from knowing feature logic */
  actions?: ReactNode;
};

/**
 * One item of the list. It neither fetches data nor routes —
 * everything it needs arrives as props.
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
- A shared component never calls `useNavigate`·`useQuery` (that blocks reuse)
- Merge `className` last with `cn()` so the call site can fine-tune spacing and nothing more
<!-- /pack-slot -->

## What generation fills in — only for combinations that cannot use the pack hub

From v3.35.0 the slots below are filled by `HUB.md` (assuming the standard contract): <!-- verified: this pack's pack.json seamSlots [] --> Architecture Overview · the 2 Quick Start
checklists · Core Principle 4 "Authorization is not a trust boundary" (included in the fragment above) · the HTTP · auth rows of
Common Imports (included in the fragment above) · Navigation Guide. Generation remains only when the variant does not resolve.

| Remaining place | When | What must be upheld |
| --- | --- | --- |
| `resources/auth-and-session.md` + hub | Hybrid app shell (`appShell` = `rn-webview` etc.) — `shellOverrides` | The web receives the token from the native bridge. Keep the shape of the adapter rows in the ledger's provides (`getAccessToken` · `refresh` · `endSession` · `useAuth` · `startSession` · `authRoutes`) exactly — `http.ts` calls only the first three |
| The whole hub | When the opposite axis has a different wire contract | Insert this file's fragments as is; the contract difference is carried by a seam that overrides `data-fetching.md` |
