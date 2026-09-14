<!-- orangekit-pack: frontend/vue v3.12.0 -->
# Routing (Vue Router 4)

In a Vite SPA the route records are **declared directly in code**. No file-based routing plugin is
introduced — which paths are protected must be visible in one file.

## 1. Route records (`src/router/routes.ts`)

<!-- file: src/router/routes.ts -->
```ts
// src/router/routes.ts
import type { RouteRecordRaw } from 'vue-router';
import DefaultLayout from '@/layouts/DefaultLayout.vue';

// Give meta a type. Without it it is any, and a typo such as `requiresAuht` passes straight through
declare module 'vue-router' {
  interface RouteMeta {
    requiresAuth?: boolean;
    title?: string;
  }
}

export const routes: RouteRecordRaw[] = [
  {
    path: '/',
    component: DefaultLayout,          // the layout is owned by the parent route
    children: [
      { path: '', redirect: { name: 'tasks' } },
      // The login screen itself is supplied by the seam — only the path is reserved here
      { path: 'login', name: 'login', component: () => import('@/features/auth/pages/LoginPage.vue') },
      {
        path: 'tasks',
        meta: { requiresAuth: true },   // merged down into the children
        children: [
          { path: '', name: 'tasks', component: () => import('@/features/tasks/pages/TaskListPage.vue') },
          {
            path: ':taskId',
            name: 'task-detail',
            props: true,                // route params as props — the component knows nothing of the router
            component: () => import('@/features/tasks/pages/TaskDetailPage.vue'),
          },
        ],
      },
      // The v4 catch-all syntax. `path: '*'` is v3 syntax and matches nothing in v4
      { path: ':pathMatch(.*)*', name: 'not-found', component: () => import('@/features/errors/pages/NotFoundPage.vue') },
    ],
  },
];
```

- Keep the route tree in **one file**. Scatter it and you cannot see which paths are protected
- Base the nesting on the **shared layout**, not on the URL structure
- Give every route a `name` — once path strings are scattered through the code, changing a path means editing everything
- Passing params with `props: true` makes it possible to test that screen without a router

## 2. Creating the router (`src/router/index.ts`)

```ts
// src/router/index.ts
import { createRouter, createWebHistory } from 'vue-router';
import { config } from '@/config';
import { routes } from './routes';
import { safeReturnTo } from '@/lib/safeReturnTo';
import { useAuth } from '@/auth/useAuth';        // a composable supplied by the seam

export const router = createRouter({
  history: createWebHistory(config.basePath),    // same value as Vite's base when deploying under a sub-path
  routes,
  scrollBehavior: (to, from, saved) => saved ?? (to.hash ? { el: to.hash } : { top: 0 }),
});
```

Do not use `createWebHashHistory()` — hash URLs wreck sharing·SEO·`hash` anchors all at once.
The price of real paths is exactly one thing: the hosting setting in §6.

## 3. Layouts and `<RouterView />`

```vue
<script setup lang="ts">
// src/layouts/DefaultLayout.vue
import { RouterView } from 'vue-router';
import AppHeader from '@/components/layout/AppHeader.vue';
</script>

<template>
  <div class="min-h-screen bg-slate-50">
    <AppHeader />
    <main class="mx-auto max-w-5xl px-6 py-8">
      <!-- The child route renders here. When the route changes the component is mounted anew -->
      <!-- The placement loading-error-states.md §6 prescribes — the layout wraps the RouterView -->
      <ErrorBoundary>
        <RouterView v-slot="{ Component, route }">
          <component :is="Component" :key="route.path" />
        </RouterView>
      </ErrorBoundary>
    </main>
  </div>
</template>
```

The `:key` is what forces a fresh mount on **a parameter change that reuses the same component**
(`/tasks/1` → `/tasks/2`). Without the key, `setup()` does not run again and the previous task's data stays —
the most common "why isn't it changing" accident in Vue Router.

**Use `route.path`. Not `route.fullPath`.** `fullPath` includes the query string and hash, so every filter
change (`?status=open`)·sort change·hash anchor jump destroys and recreates the page.
A form being typed into is then lost, and the background-refresh design (the thin `isFetching` bar in
`resources/loading-error-states.md` §1) is defeated too — a remount has no "existing screen" to keep.
If you want to preserve state, `watch` the parameter instead of removing the key.

## 4. Navigation guards

The authentication **principal** is supplied by the seam. This pack owns only the guard's place and shape.

```ts
// src/router/index.ts — the global guard lives in this one file only
router.beforeEach(async (to) => {
  if (!to.meta.requiresAuth) return true;       // meta has already been merged parent → child

  const auth = useAuth();
  await auth.ensureReady();                     // decide before session restoration finishes and every refresh bounces the user
  if (auth.isAuthenticated.value) return true;

  return { name: 'login', query: { returnTo: to.fullPath }, replace: true };
});
```

- A v4 guard does not call `next()`. It **returns** `true` (pass) · `false` (cancel) · a route location
  (redirect). Mix `next` with a return value and the guard runs twice
- Without `replace: true` the back button returns to the protected route and you get a loop
- Calling a composable inside a guard is safe **only inside the function body**. Call it at module
  top level and pinia·the app do not exist yet
- This gate is **a UX device, not a security device.** Even someone who cannot get past the route can still
  call the API, and the actual blocking is done by the server

## 5. Validating the return path

`returnTo` is **a value that came in from outside**, from the URL query. `//evil.example`, `/\evil.example`, and
values with control characters mixed in are parsed by the browser as external URLs. A `startsWith('/')` check does not stop them.

<!-- file: src/lib/safeReturnTo.ts -->
```ts
// src/lib/safeReturnTo.ts
export function safeReturnTo(raw: unknown, fallback = '/tasks'): string {
  if (typeof raw !== 'string' || raw === '') return fallback;
  try {
    const url = new URL(raw, window.location.origin);
    if (url.origin !== window.location.origin) return fallback;   // blocks //host, https://host
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

`safeReturnTo` **only means something if a screen consumes it.** The only place that reads the return path is the
seam's login screen, and that screen passes only a value that has been through this function to `router.replace`.

```ts
// In the seam's login screen — validated here, exactly once
const target = safeReturnTo(route.query.returnTo);
await router.replace(target);
```

Do not use `window.location.assign`/`href` for internal navigation. It becomes a channel that bypasses the
validation, and the full reload throws away the cache and the auth state.

**There is exactly one exception** — the lost-chunk recovery in §6. A new bundle has to be fetched, so the full
reload is the point. Even then, **always put a one-shot guard on it** (below) — without one, a deployment that
splits the new bundle across the same route loops reload → renavigate → chunk failure forever.

## 6. Route errors

Vue Router has no per-route error component. There are two kinds of failure and they live in different places.

```ts
// src/router/index.ts — ① a failure of the navigation itself (mostly a lost lazy-loading chunk)
router.onError((error, to) => {
  const chunkMissing = /dynamically imported module|Importing a module script failed/i;
  if (chunkMissing.test(String((error as Error).message))) {
    // A deployment removed the old chunk. Only here is a full reload legitimate — internal SPA navigation
    // cannot recover, and left alone the user keeps clicking a link that does nothing
    window.location.assign(to.fullPath);
  }
});
```

② An exception thrown inside a screen is caught by the `onErrorCaptured` boundary
(`loading-error-states.md` §6). A data failure is handled by the query's `isError`, not as an exception.

## 7. Lazy loading

- Every screen is split with `component: () => import(...)`. Layouts and frequently used shared
  components stay static imports — the more you split, the more requests the first screen makes
- If a blank screen shows during a transition, have the screen component draw its own skeleton immediately
  instead of wrapping `<RouterView>` in `<Suspense>` (for the reason in §`loading-error-states.md` §5)
- To prefetch on link hover, call the route's `component` factory directly rather than
  `queryClient.prefetchQuery`

## 8. Deep links on static hosting (history fallback)

`createWebHistory` uses real paths (`/tasks/42`). Static hosting has no file at that path, so
**unless every unmatched path is sent back to `index.html`, refreshes and deep links
return 404.**

| Hosting | Setting |
| --- | --- |
| nginx | `location / { try_files $uri $uri/ /index.html; }` |
| Object storage + CDN | An error-document rule that turns 403·404 responses into `/index.html` (response code **200**) |
| A static host that uses a rewrite rules file | One line: `/* → /index.html 200` |
| Local preview | `npm run preview` falls back by default — always confirm the deployment environment does the same |

- **Whether the API is on the same origin or a different one is decided by the backend axis.** If it is served
  from `/api/*` on the same origin, match that path **before** the fallback rule. If it is on another origin
  this item does not apply — there is no API path for the fallback to swallow in the first place
- Serve `index.html` with `Cache-Control: no-cache` and hashed assets with a long cache.
  Cache the index and it points at the old bundle even after a deploy, making the lost chunks of §6 permanent

## Misuse list ① — Vue Router 3 → 4 idiom conversion table

| Old habit (v3) | The v4 form |
| --- | --- |
| `new VueRouter({ mode: 'history' })` | `createRouter({ history: createWebHistory() })` |
| `mode: 'hash'` | `createWebHashHistory()` |
| The `path: '*'` catch-all | `path: '/:pathMatch(.*)*'` — v4 expresses the wildcard as a parameter |
| `beforeEach((to, from, next) => next())` | **Return** `true`·`false`·a route location, with no `next` |
| `this.$router` / `this.$route` | `useRouter()` / `useRoute()` — they are two different composables |
| A callback argument to `router.push()` | It returns a Promise — `await router.push(...)` |
| `<router-link tag="li">` | `<RouterLink custom v-slot="{ navigate, isActive }">` |
| The `exact` prop of `<router-link>` | The `isExactActive` slot value of `<RouterLink>` |
| Assuming a `route.query` value is a `string` | `string \| null \| (string \| null)[]` — always narrow it |
| Mutating `router.app` / `router.options.routes` | `router.addRoute()` / `router.removeRoute()` |
| A named view with only `component: X` | `components: { default: X, sidebar: Y }` |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `useRoute()` vs `useRouter()` | Reading (the current path·params) is `useRoute`, navigating is `useRouter` |
| `<RouterLink>` vs `router.push` | Navigation the user clicks is always `<RouterLink>` (new tab·right click·accessibility come with it). `router.push` is programmatic navigation **after an event** |
| `push` vs `replace` | Navigation the user must not come back to — a login redirect, a filter change — uses `replace` |
| `route.params` vs `route.query` | A resource identifier is a path parameter (`/tasks/:taskId`); screen options (filter·sort) are the query string |
| `props: true` vs `useRoute().params` | To detach the component from the router, `props`. `useRoute` only when the whole route is needed |
| A global `beforeEach` vs a per-route `beforeEnter` | An app-wide rule (authentication) gets one global guard. A condition specific to one route is `beforeEnter` |
| `to.meta` vs `to.matched` | v4 **merges** the parent records' meta into `to.meta`. Walking `matched` is a v3 habit |
| `:key="route.fullPath"` vs no key | When a parameter change that reuses the same component needs a reset, use a key. When scroll·input must be preserved, use `watch` instead of a key |
| `<KeepAlive>` vs recreating every time | Only screens you are certain to come back to, such as tabs, get `<KeepAlive>`. For list/detail the query cache already does that job |
| `router.onError` vs `onErrorCaptured` | Navigation·chunk loading failures go to `onError`. An exception inside a rendered screen goes to `onErrorCaptured` |
| `redirect` vs `alias` | To change the address, `redirect`. To show the same screen at two addresses, `alias` |
