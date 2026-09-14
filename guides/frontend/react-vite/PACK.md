<!-- orangekit-pack: frontend/react-vite v3.12.0 verified 2026-08-22 react@18 vite@5 typescript@5 react-router@7 @tanstack/react-query@5 zustand@5 tailwindcss@3.4 react-error-boundary@6 sonner@2 msw@2 vitest@3 clsx@2 tailwind-merge@2 eslint-plugin-import@2 -->

# react-vite axis pack — hub fragment

This is the **axis-local fragment to be inserted verbatim** when building a combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — in that case the seam's `HUB.md` holds the full hub text.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and is closed
inside the axis, so it holds whatever the backend axis turns out to be. Nothing here is a function of the combination —
the table at the end of the file states what belongs to the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.tsx                 # createRoot + Provider assembly (Auth · AuthWiring · Query · Router)
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── routes/
│   ├── routes.tsx           # The route object tree (single source, includes /auth/callback)
│   ├── RootLayout.tsx       # Global shell: header · nav · <Outlet />
│   └── RequireAuth.tsx      # The auth gate layout route
├── api/
│   ├── http.ts              # fetch wrapper · envelope parsing · auth header · ApiError normalization
│   └── tokenProvider.ts     # Access token provider (injected by the auth module)
├── auth/                    # oidcConfig · AuthWiring · session · endSession · groups · pages/
├── features/
│   └── tasks/
│       ├── api/             # Endpoint functions + query keys + query/mutation hooks
│       ├── components/      # Components used only by this feature
│       └── pages/           # The screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · Sidebar · SectionHeader
├── stores/                  # Zustand stores (server data must not be brought in)
├── lib/                     # cn() · formatters · pure utilities
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

The hooks themselves are **defined by the seam** (`requires` in `ledger.md`) — what this axis owns is how a screen
consumes them. Put the definition here and there would be two of them, one in the seam and one here.

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

// Project-internal (only what this pack owns — the HTTP client is appended by the seam)
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

## What the seam fills in — what this pack does not have

| Hub slot | Why it is a function of the combination |
| --- | --- |
| Architecture Overview | The trust boundary and the data source depend on the backend axis |
| The 2 Quick Start checklists | The pagination model·error code branching depend on the wire contract |
| Core Principle "authorization is not a trust boundary" | The principle is universal, but **whether an unauthorized response is 403 or 404** depends on the backend axis. This rule is mandatory |
| The HTTP client·auth rows of Common Imports | The authentication method and envelope parsing depend on the backend axis |
| Navigation Guide | `pack.json` supplies the pack resource rows, and the seam adds the seam resource rows |
