<!-- orangekit-pack: frontend/react-vite v3.35.0 -->
# Routing (React Router v7 · library mode)

In a Vite SPA, React Router is used **as a library only** — no framework mode, no file-based
routing; the route object tree is declared directly in code.

## 1. The route tree (`src/routes/routes.tsx`)

```tsx
import { createBrowserRouter } from 'react-router';
import { authRoutes } from '@/auth/routes';
import { RootLayout } from './RootLayout';
import { RequireAuth } from './RequireAuth';

export const router = createBrowserRouter([
  {
    path: '/',
    element: <RootLayout />,
    errorElement: <RouteErrorBoundary />,
    children: [
      { index: true, element: <Navigate to="/tasks" replace /> },
      // The login (and OIDC callback) routes are owned by the auth adapter (auth-and-session.md).
      // The number of screens differs per method, so the paths are spread here rather than written — they must be outside RequireAuth
      ...authRoutes,
      {
        element: <RequireAuth />,               // a layout route with no path = the auth gate
        children: [
          {
            path: 'tasks',
            children: [
              { index: true, lazy: () => import('@/features/tasks/pages/TaskListPage') },
              { path: ':taskId', lazy: () => import('@/features/tasks/pages/TaskDetailPage') },
            ],
          },
          { path: 'settings', lazy: () => import('@/features/settings/pages/SettingsPage') },
        ],
      },
      { path: '*', element: <NotFoundPage /> },
    ],
  },
]);
```

```tsx
// src/main.tsx — there is no auth Provider. The module owns the adapter's state and useAuth() subscribes to it
void startSession();                          // session restore — useAuth().status stays 'loading' until it finishes

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>   {/* the single instance from src/api/queryClient.ts */}
      <RouterProvider router={router} />
    </QueryClientProvider>
  </StrictMode>,
);
```

The module a `lazy` points at exports route properties — the screen component is exported under the
name `Component`.

```tsx
// features/tasks/pages/TaskListPage.tsx
export function Component() { /* ... */ }
Component.displayName = 'TaskListPage';
```

- Keep the route tree in **one file**. Scatter it and you cannot see which paths are protected
- Base the nesting on the **shared layout**, not on the URL structure
- A route with no `element` (a layout route) is used for gates·context injection

## 2. Layouts and `<Outlet />`

```tsx
export function RootLayout() {
  return (
    <div className="min-h-screen bg-slate-50">
      <AppHeader />
      <main className="mx-auto max-w-5xl px-6 py-8">
        <Outlet />   {/* the child route renders here */}
      </main>
    </div>
  );
}
```

When a parent layout has to pass a value down to a child, use `<Outlet context={value} />` +
`useOutletContext<T>()`. The coupling is shallower than a global store.

## 3. Protected routes

```tsx
export function RequireAuth() {
  const { status } = useAuth();
  const location = useLocation();

  if (status === 'loading') return <FullPageSpinner />;   // restoring the session — do not bounce before the verdict
  if (status === 'signedOut') {
    const returnTo = location.pathname + location.search;
    return <Navigate to={`/login?returnTo=${encodeURIComponent(returnTo)}`} replace />;
  }
  return <Outlet />;
}
```

- Redirect while `'loading'` and the login screen flashes on every refresh
- Use `replace` — otherwise the back button returns to the protected route and you get a loop
- **Always validate that the return path is an internal path.** `//evil.com`, `/\evil.com`, and values with
  control characters mixed in are parsed by the browser as external URLs. A string prefix check
  (`startsWith('/')`) alone does not stop them

<!-- file: src/lib/safeReturnTo.ts -->
```ts
// src/lib/safeReturnTo.ts
export function safeReturnTo(raw: string | null, fallback = '/'): string {
  if (!raw) return fallback;
  try {
    const url = new URL(raw, window.location.origin);
    if (url.origin !== window.location.origin) return fallback;  // blocks //host, https://host
    // The origin check alone is not enough: when a dot segment swallows the leading `/`, as in
    // `/..//evil.example`, the normalized result becomes a protocol-relative path (`//host`) again.
    // Validate the **output**, not the input.
    const p = url.pathname;
    if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return fallback;
    return p + url.search + url.hash;
  } catch {
    return fallback;
  }
}
```

`safeReturnTo` **only means something if a screen consumes it.** The only places that read the return path are the login
screen (and, for OIDC, the callback screen), and those screens are owned by the auth adapter
(`auth-and-session.md`). The rule is the same for every method — pass only a value that has been through this function to `navigate`.

```tsx
// Navigation after login finishes — a shape independent of the method (the full screens are in auth-and-session.md)
const [params] = useSearchParams();
navigate(safeReturnTo(params.get('returnTo')), { replace: true });
```

- **Do not use `window.location.assign`/`href` for the return navigation.** It becomes a channel that bypasses
  the validation, and the full reload throws away the cache and the auth state. Internal navigation is always `navigate`
- `returnTo` is **a value that came back from outside**, whether from a URL query or the OIDC `state`. Even when the
  source looks like our own code, do not trust it as is

This gate is **a UX device, not a security device.** Even someone who cannot get past the route can still call the
API, and the actual blocking is done by the server (see `auth-and-session.md`).

## 4. Handling route errors

```tsx
export function RouteErrorBoundary() {
  const error = useRouteError();

  if (isRouteErrorResponse(error)) {
    return <ErrorState title={`${error.status}`} message={error.statusText} />;
  }
  if (error instanceof ApiError) {
    // Branch on code. NOT_FOUND means both "a missing resource" and "someone else's resource"
    return <ErrorState title="We could not process your request" message={toUserMessage(error)} />;
  }
  return <ErrorState title="Something went wrong" onRetry={() => window.location.reload()} />;
}
```

`errorElement` catches **exceptions raised during render**. To raise a query error this far,
turn on `throwOnError: true` for that query — by default it is handled inside the screen with `isError`.

## 5. Use the URL as state

A list's filter·sort live in the URL, not in component state. Sharing·refresh·the back button work
for free, and the value doubles as the query key.

```tsx
const [searchParams, setSearchParams] = useSearchParams();
// The URL is a value from outside — narrow it with an allow-list instead of casting (the same shape as STATUS_VALUES in complete-example.md)
const STATUS_VALUES: TaskFilter['status'][] = ['all', 'open', 'done'];
const raw = searchParams.get('status');
const filter: TaskFilter = { status: STATUS_VALUES.find((s) => s === raw) ?? 'all' };

// Changing the filter — replace, so as not to dirty the history
const setStatus = (status: TaskFilter['status']) =>
  setSearchParams({ status }, { replace: true });

const { data } = useTasksQuery(filter);   // URL → query key
```

**Do not put the cursor in the URL.** The backend's pagination uses opaque cursors, so carrying one in the URL
means nothing for sharing·restoration, and there are no page numbers either. The next-page state is owned by
`useInfiniteQuery` inside the cache (`data-fetching.md` §5).

## 6. Deep links on static hosting (history fallback)

`createBrowserRouter` uses real paths (`/tasks/42`). Static hosting has no file at that path, so
**unless every unmatched path is sent back to `index.html`, refreshes and deep links
return 404.** The OIDC variant's `/auth/callback` is no exception, and without this setting the login itself
never completes.

| Hosting | Setting |
| --- | --- |
| S3 + CloudFront | In the distribution's custom error responses, 403·404 → `/index.html` with response code **200**. Or rewrite extension-less paths to `/index.html` with a viewer-request CloudFront Function |
| nginx | `location / { try_files $uri $uri/ /index.html; }` |
| Local preview | `vite preview` falls back by default — always confirm the deployment environment does the same |

- If the API is served from `/api/*` on the same host, check that the fallback rule does not swallow `/api/*`
- Serve `index.html` with `Cache-Control: no-cache` and hashed assets with a long cache.
  Cache the index and it points at the old bundle even after a deploy, breaking the whole screen

## 7. What this stack does not do

- **Do not read or write data with `loader` / `action`.** The single owner of server state is
  TanStack Query. Mix the two and the same data gets two caches and two invalidation paths.
  The router is responsible only for "which screen to show"
- When prefetching is needed, call `queryClient.prefetchQuery` on link hover, not in a loader
- Do not use `<a href="/tasks">` — it becomes a full page reload and the app state and cache are lost

## Misuse list ① — version idiom conversion table

| Old habit (v5/v6) | The v7 form |
| --- | --- |
| `import { Link } from 'react-router-dom'` | `import { Link } from 'react-router'` — the packages were merged in v7 <!-- verified: React Router v7 upgrade notes — react-router-dom only re-exports react-router --> |
| `<Switch>` / `<Route component={X}>` (v5) | `<Routes>` / `element={<X />}`, or the route object's `Component` |
| `useHistory().push(...)` (v5) | `useNavigate()('/path')` |
| `<Redirect to="/x" />` (v5) | `<Navigate to="/x" replace />` |
| `useRouteMatch()` (v5) | `useMatch(pattern)` |
| `<NavLink activeClassName="on">` (v5) | `<NavLink className={({ isActive }) => cn(base, isActive && 'on')}>` |
| Using only a JSX `<Route>` tree | The `createBrowserRouter([...])` object tree — data APIs such as `errorElement`·`lazy` work only here |
| Splitting screens with `React.lazy` + `<Suspense>` | The route's `lazy` property — the router handles split loading during the transition |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `<Link>` vs `useNavigate` | Navigation the user clicks is always `<Link>` (new tab·right click·accessibility come with it). `useNavigate` is for programmatic navigation **after an event** (to the detail page after a successful save) |
| `navigate(path)` vs `navigate(path, { replace: true })` | Navigation the user must not come back to — a login redirect, after a form submit — uses `replace` |
| `useParams` vs `useSearchParams` | A resource identifier is a path parameter (`/tasks/:taskId`); screen options (filter·sort·page) are the query string |
| A layout route vs a wrapper component | A tier that **has no URL**, such as an auth gate·shared shell, is a route with no `path` + `<Outlet />`. Something that wraps only part of a screen is just a component |
| `errorElement` vs `isError` inside a component | `errorElement` only when the whole screen cannot come up. When one list widget fails, branch on `isError` right there |
| `index: true` vs `path: ''` | The child to show on an exact match of the parent path is `index: true`. `path: ''` muddies the intent and misbehaves under nesting |
| The position of `path: '*'` | Put it **last** among the top-level children. Put it deeper in the nesting and it catches only the misses of that subtree |
