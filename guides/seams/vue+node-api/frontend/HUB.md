---
name: frontend-guide
description: Vue 3 + Vite SPA frontend guide for a Node/Express REST API backend. Covers SFC patterns, Tailwind styling, Vue Router, Pinia, TanStack Vue Query over a cursor-paginated response envelope, token auth with one-shot 401 refresh, validated return paths, and loading/empty/error states. Use when creating or modifying components, pages, routing, styling, state, API calls, auth screens, or frontend tests.
---
<!-- orangekit-seam: vue+node-api v3.13.0 -->

## Quick Start

> If `dev/docs/api/wire-contract.md` exists, that file is canonical for the envelope, error codes and pagination. If it does not exist and you are building the frontend and backend together from scratch, do steps 1 and 2 of "Inner Order Within One Feature" in `workflow-routing.md` first.

### Building a new data screen

- [ ] Add the route to `src/router/routes.ts` — use `meta.requiresAuth` if it must be protected
- [ ] Put the request function and query key in `src/features/<f>/api/` (`resources/data-fetching.md` §4)
- [ ] Write the query composable — a list uses a cursor (`limit` · `cursor`) and the response is `{ data, nextCursor }`
- [ ] Narrow the response with `parseTask`/`parseTaskList` — catch a broken contract at the boundary
- [ ] Draw all three states: `isPending` → `isError` → empty → success (do not reorder them)
- [ ] Put filters and sorting in the URL query, not in component state — those values become the query key
- [ ] For repeated UI, **search `src/components/common/` first** and only build a new one when nothing fits
- [ ] In tests, override the contract envelope with `server.use()` and assert the positive and negative case in the same `it`

### Attaching a new API call

- [ ] Use `get`/`post`/`patch`/`delete` from `src/api/http.ts` — no `fetch` in a component
- [ ] When it is a list and you need `nextCursor`, use `http.page()`
- [ ] A failure is an `ApiError`. Screens branch on **`code`**, not on `status`
- [ ] Screens do not handle 401 — `http.ts` attempts one reissue and raises it when that fails
- [ ] An ownership failure is a 404. Do not separate it from 403; handle both in one screen
- [ ] Move the `details` of a validation failure (`Record<string, string[]>`) under the matching field
- [ ] A changing mutation calls `invalidateQueries({ queryKey: taskKeys.all })` in `onSuccess`

## Architecture Overview

| Layer | What | Trust |
| --- | --- | --- |
| Browser (Vue 3 SPA) | routing · rendering · cache · **displaying** authorization | not trusted |
| HTTP boundary | `Authorization: Bearer` + the `httpOnly` reissue cookie | — |
| Node/Express API | validation · authentication · **the ownership ruling** · the response envelope | the only authority |

- **There is only one boundary.** There is no Server Component and no Server Action — all data enters through the
  browser's single `fetch` channel. So the auth header · error normalization · timeout must be confined to
  **one file**, `src/api/http.ts`; leak them out of it and every screen reinvents them
- **The backend has no data-layer policy engine.** The application layer is the only boundary, so the frontend's
  authorization UI is not a trust boundary — hiding is UX and the ruling is the server's
- **Server state in Vue Query, client state in Pinia.** Overlap the two areas and you have two caches
- **What the wire contract decides**: the envelope (`{ data }` · `nextCursor`) · cursor pagination ·
  the error code table · the surface of authorization failure (401/403/**404**). Those four are the content of the three seam resources

## Directory Structure

```
src/
├── main.ts                  # createApp + plugin registration (pinia · router · VueQueryPlugin)
├── App.vue                  # nothing but <RouterView /> — the screen shell belongs to the layout route
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── env.d.ts                 # the ImportMetaEnv declaration (do not put `*.vue` shading here)
├── router/
│   ├── routes.ts            # the route record tree (single source) + the RouteMeta type extension
│   └── index.ts             # createRouter + global guards + onError
├── layouts/
│   └── DefaultLayout.vue    # the global shell: header · nav · <RouterView />
├── api/                     # the HTTP client — **owned by the seam** (the pack only consumes it)
├── features/
│   └── tasks/
│       ├── api/             # endpoint functions + query keys + query/mutation composables
│       ├── components/      # SFCs used only by this feature
│       └── pages/           # the screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · ListSkeleton
├── stores/                  # Pinia stores (no server data brought in)
├── composables/             # reusable use* logic (reactivity lifted out of SFCs)
├── lib/                     # cn() · safeReturnTo() · pure utilities
└── types/                   # types shared by several features
```

## Core Principles (7 Key Rules)

### 1. Vue Query owns server data — never duplicate it into Pinia

Moving a server response into Pinia gives you two caches and leaves you implementing invalidation · refetching ·
garbage collection by hand. Pinia holds only state the server does not know about (a collapsed sidebar, list density).

```ts
// ✅ server state in a query, client state in a store
const { data: tasks, isPending } = useTasksQuery(filter);
const { isSidebarOpen } = storeToRefs(useUiStore());

// ❌ moving the server response into store state — a duplicated cache
state: () => ({ tasks: [] as Task[] }),
```

### 2. HTTP only in a feature's `api/` layer — a component never calls it directly

If an SFC calls the network directly, the auth header · error normalization · base URL diverge from screen to screen.
Components call composables only, and request functions gather in `features/<f>/api/`.

```ts
// ✅ request function → query composable → component
const { data, isPending } = useTasksQuery(filter);

// ❌ a raw request inside a component — the token and the error shape get reinvented here
const res = await window.fetch('/tasks');
```

### 3. Extract repeated UI into a shared component, but search before you create one

Most duplication comes not from a failure to extract but from a **failure to search**. Before creating a new shared component,
always search `src/components/common/` and `src/components/layout/`.

```bash
rg -l "PageShell|EmptyState|DataTable" src/components --glob '*.vue'
rg -l "rounded-lg border bg-white p-6" src/components --glob '*.vue'
```

```vue
<!-- ✅ tokens (height · type · spacing) are owned in one shared component; call sites choose through props only -->
<Button size="sm" variant="danger">Delete</Button>

<!-- ❌ the call site overrides the tokens with class — the size prop becomes meaningless -->
<Button class="h-11 px-6 text-base font-bold">Delete</Button>
```

### 4. Authorization UI is not a trust boundary — and the failure arrives as 404

The backend of this combination has no data-layer policy engine. Ownership is enforced in exactly **one** place, the server's
application layer, and everything the frontend hides is UX. So **every hiding comes with the matching
failure-response handling.**

And in this combination an ownership failure arrives as **404**, not 403 (contract §5) — so that existence does not
leak. The response carries no information separating "does not exist" from "belongs to someone else".

```ts
// ✅ handle "absent, or not mine" with a single 404
const missing = computed(() => (error.value as ApiError | null)?.code === 'NOT_FOUND');

// ❌ waiting for an ownership failure as 403 — it never arrives in this combination, so the screen stays empty forever
const forbidden = computed(() => (error.value as ApiError | null)?.code === 'FORBIDDEN');
```

### 5. Reactivity flows through references — destructuring cuts it

`ref` · `reactive` · a Pinia store are **proxies**. The moment you pull a value out into a variable, that variable is
a snapshot of that instant and is never updated again. The failure shows up not as an exception but as "the screen does not change",
which makes it the defect found last on this axis.

```ts
// ✅ keep the reference — reach a store through storeToRefs, props through props.x
const { density } = storeToRefs(useUiStore());
const label = computed(() => props.task.title);

// ❌ tearing a value out of the proxy — the screen freezes at the first value
const { density } = useUiStore();
const { task } = reactive({ task: initialTask });
```

### 6. There are no secrets in a browser bundle

A `VITE_*` variable is inlined as a string at build time and stays in the bundle as it is. Signing keys and admin
credentials are all held by the server, and the frontend calls that server's endpoints.

```ts
// ✅ expose only values that may be public; src/config.ts is the one place that reads them
import { config } from '@/config';
const baseUrl = config.apiBaseUrl;
```

### 7. Every data screen has all three states: loading · empty · error

A screen that implements only the happy path goes blank on a slow network or with an expired session. The three states are
not optional; they are the minimum contract of a screen.

```vue
<!-- ✅ draw all three branches. Reorder them and "no data" flashes while loading -->
<ListSkeleton v-if="isPending" :rows="5" />
<ErrorState v-else-if="isError" :error="error" @retry="refetch" />
<EmptyState v-else-if="tasks.length === 0" title="No tasks yet" />
<DataTable v-else :rows="tasks" :columns="columns" />
```

## Common Imports

```ts
// Vue 3 — the compiler macros (defineProps · defineEmits · defineSlots · defineModel ·
// withDefaults · defineOptions) are **not imported**. `<script setup>` handles them at compile time
import { ref, shallowRef, reactive, computed, watch, watchEffect, nextTick,
         onMounted, onUnmounted, onErrorCaptured, toRef, toRefs,
         type Ref, type Component } from 'vue';

// routing (Vue Router 4)
import { RouterLink, RouterView, useRoute, useRouter, createRouter,
         createWebHistory, createMemoryHistory, type RouteRecordRaw } from 'vue-router';

// server state (TanStack Query v5 — the Vue adapter. Not 'react-query')
import { useQuery, useMutation, useQueryClient,
         VueQueryPlugin, QueryClient } from '@tanstack/vue-query';

// global client state (Pinia 2)
import { defineStore, storeToRefs, createPinia, setActivePinia } from 'pinia';

// project-internal (only what this pack owns — the HTTP client is added by the seam)
import { config } from '@/config';
import { cn } from '@/lib/cn';
// the seam of this combination — there is one HTTP boundary (SPA ↔ a separate API server)
// cursor paging is taken with useInfiniteQuery and flattened with select (resources/data-fetching.md §5)
import { http } from '@/api/http';
import { ApiError } from '@/api/errors';
import { queryClient } from '@/api/queryClient';
import { useAuth } from '@/auth/useAuth';
import { useTasksQuery } from '@/features/tasks/api/useTasksQuery';
import { useCreateTaskMutation } from '@/features/tasks/api/useCreateTaskMutation';
import { safeReturnTo } from '@/lib/safeReturnTo';
import type { Task } from '@/types/task';
```

## Component Template

```vue
<script setup lang="ts">
// src/features/tasks/components/TaskCard.vue
// a feature component, so it knows the domain type. components/common/ conversely never imports features/
import { computed } from 'vue';
import { cn } from '@/lib/cn';
import type { Task } from '@/types/task';

const props = withDefaults(
  defineProps<{ task: Task; dense?: boolean }>(),
  { dense: false },
);
defineEmits<{ select: [id: string] }>();
defineSlots<{ actions?: (props: { task: Task }) => unknown }>();

// props is a reactive object — read it as props.x instead of destructuring
const rootClass = computed(() =>
  cn('rounded-lg border border-slate-200 bg-white', props.dense ? 'p-3' : 'p-4'),
);
const createdLabel = computed(() =>
  new Intl.DateTimeFormat('en-US', { dateStyle: 'medium' }).format(new Date(props.task.createdAt)),
);
</script>

<template>
  <article :class="rootClass" @click="$emit('select', task.id)">
    <h3 class="text-sm font-semibold text-slate-900">{{ task.title }}</h3>
    <p class="mt-1 text-xs text-slate-500">{{ createdLabel }}</p>
    <div v-if="$slots.actions" class="mt-3 flex gap-2">
      <slot name="actions" :task="task" />
    </div>
  </article>
</template>
```

- There is no `<style>` block — Tailwind is the only styling system (`resources/styling.md`)
- There is a single root, so the `class` · `aria-*` · listeners the call site passes attach to this `<article>` automatically
- A shared component does not call `useRouter()` · `useQuery()` (that blocks reuse)

## Navigation Guide

| What you want to do | File to read |
| --- | --- |
| Build an SFC · declare props/emits/slot types · extract repeated UI into a shared one · generic components · design-token ownership rules | `resources/component-patterns.md` |
| Write Tailwind classes · when to use :class vs cn() · define variants · no scoped CSS or inline style | `resources/styling.md` |
| Decide whether to introduce global state · write a Pinia store · subscribe with storeToRefs · use a store outside a component · the URL as state | `resources/state-management.md` |
| Add a route · nested layouts · navigation guards · return path validation · route/chunk errors · lazy loading · deep links (history fallback) | `resources/routing.md` |
| Loading skeletons · empty states · error states · the onErrorCaptured boundary · why Suspense is not used · showing form validation errors | `resources/loading-error-states.md` |
| vue-tsc setup · component prop types · env variable types · narrowing API responses · Vitest + @vue/test-utils component/store tests · msw HTTP mocking | `resources/types-and-testing.md` |
| Write the HTTP client · error normalization (`ApiError`) · query/mutation composables · query keys · cache invalidation · consuming cursor pagination | `resources/data-fetching.md` |
| Where the token is kept · one reissue on 401 · login/logout · consuming return path validation · the order of discarding cache and stores on logout | `resources/auth-and-session.md` |
| List plus create from start to finish · assembling the three states and cursor paging · showing validation errors · main.ts wiring · paired positive/negative tests | `resources/complete-example.md` |
