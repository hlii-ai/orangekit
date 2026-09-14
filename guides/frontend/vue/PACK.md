<!-- orangekit-pack: frontend/vue v3.12.0 verified 2026-08-23 vue@3 vite@5 typescript@5 vue-router@4 pinia@2 tailwindcss@3.4 @tanstack/vue-query@5 vitest@2 @vue/test-utils@2 msw@2 clsx@2 tailwind-merge@2 -->

# vue axis pack — hub fragment

This is the **axis-local fragment to be inserted verbatim** when building a combination hub (`SKILL.md`). A combination that has a
pre-built seam does not use this file — in that case the seam's `HUB.md` holds the full hub text.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and is closed
inside the axis, so it holds whatever the backend axis turns out to be. Nothing here is a function of the combination —
the table at the end of the file states what belongs to the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── main.ts                  # createApp + plugin registration (pinia · router · VueQueryPlugin)
├── App.vue                  # nothing but <RouterView /> — the screen shell belongs to the layout route
├── config.ts                # the **only** file that reads import.meta.env (exports it typed)
├── env.d.ts                 # the ImportMetaEnv declaration (do not put `*.vue` shading in it)
├── router/
│   ├── routes.ts            # the route record tree (single source) + the RouteMeta type extension
│   └── index.ts             # createRouter + global guards + onError
├── layouts/
│   └── DefaultLayout.vue    # Global shell: header · nav · <RouterView />
├── api/                     # The HTTP client — **owned by the seam** (the pack only consumes it)
├── features/
│   └── tasks/
│       ├── api/             # Endpoint functions + query keys + query/mutation composables
│       ├── components/      # SFCs used only by this feature
│       └── pages/           # The screens the routes point at
├── components/
│   ├── common/              # UI shared by two or more features ← search here before making a new one
│   └── layout/              # PageShell · ListSkeleton
├── stores/                  # Pinia stores (server data must not be brought in)
├── composables/             # Reusable use* logic (reactivity pulled out of an SFC)
├── lib/                     # cn() · safeReturnTo() · pure utilities
└── types/                   # Types shared by several features
```
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
### 1. Vue Query owns server data — do not copy it into Pinia

Move a server response into Pinia and you have two caches, and you end up implementing invalidation·refetching·garbage
collection yourself. Pinia holds only state the server knows nothing about (a collapsed sidebar, list density).

```ts
// ✅ Server state in a query, client state in the store
const { data: tasks, isPending } = useTasksQuery(filter);
const { isSidebarOpen } = storeToRefs(useUiStore());

// ❌ Moving the server response into store state — a duplicated cache
state: () => ({ tasks: [] as Task[] }),
```

### 2. HTTP lives only in a feature's `api/` layer — components do not call it directly

When an SFC calls the network itself, the auth header·error normalization·base URL diverge screen by screen.
Components call only composables, and request functions are gathered in `features/<f>/api/`.

```ts
// ✅ Request function → query composable → component
const { data, isPending } = useTasksQuery(filter);

// ❌ A raw request inside a component — both the token and the error format get reinvented here
const res = await window.fetch('/tasks');
```

### 3. Extract repeated UI into a shared component, but search before you build one

Most duplication comes not from a failure to extract but from a **failure to search**. Before creating a new shared
component, always search `src/components/common/` and `src/components/layout/`.

```bash
rg -l "PageShell|EmptyState|DataTable" src/components --glob '*.vue'
rg -l "rounded-lg border bg-white p-6" src/components --glob '*.vue'
```

```vue
<!-- ✅ Tokens (height·typography·spacing) are owned in one shared component, call sites choose through props only -->
<Button size="sm" variant="danger">Delete</Button>

<!-- ❌ The call site overrides the tokens with class — the size prop becomes meaningless -->
<Button class="h-11 px-6 text-base font-bold">Delete</Button>
```

### 5. Reactivity flows through references — destructuring cuts it

`ref`·`reactive`·a Pinia store are **proxies**. The moment you pull a value out into a variable, that variable
is a snapshot of that instant and is never updated again. The failure shows up not as an exception but as
"the screen does not change", which makes it the latest-discovered defect on this axis.

```ts
// ✅ Keep the reference — a store through storeToRefs, props through props.x
const { density } = storeToRefs(useUiStore());
const label = computed(() => props.task.title);

// ❌ Tearing the value out of the proxy — the screen freezes on the first value
const { density } = useUiStore();
const { task } = reactive({ task: initialTask });
```

### 6. There are no secrets in a browser bundle

`VITE_*` variables are inlined as strings at build time and stay in the bundle as they are. Signing keys·admin
credentials are all kept by the server, and the frontend calls that server's endpoints.

```ts
// ✅ Expose only values that may be public, and read them in exactly one place, src/config.ts
import { config } from '@/config';
const baseUrl = config.apiBaseUrl;
```

### 7. Every data screen has all three states: loading·empty·error

A screen that implements only the success path goes blank on a slow network and with an expired session. The three
states are not optional; they are the minimum contract of a screen.

```vue
<!-- ✅ Draw all three branches. Change the order and "no data" flashes during loading -->
<ListSkeleton v-if="isPending" :rows="5" />
<ErrorState v-else-if="isError" :error="error" @retry="refetch" />
<EmptyState v-else-if="tasks.length === 0" title="No tasks yet" />
<DataTable v-else :rows="tasks" :columns="columns" />
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
```ts
// Vue 3 — the compiler macros (defineProps·defineEmits·defineSlots·defineModel·
// withDefaults·defineOptions) are **not imported**. `<script setup>` handles them at compile time
import { ref, shallowRef, reactive, computed, watch, watchEffect, nextTick,
         onMounted, onUnmounted, onErrorCaptured, toRef, toRefs,
         type Ref, type Component } from 'vue';

// Routing (Vue Router 4)
import { RouterLink, RouterView, useRoute, useRouter, createRouter,
         createWebHistory, createMemoryHistory, type RouteRecordRaw } from 'vue-router';

// Server state (TanStack Query v5 — the Vue adapter. Not 'react-query')
import { useQuery, useMutation, useQueryClient,
         VueQueryPlugin, QueryClient } from '@tanstack/vue-query';

// Global client state (Pinia 2)
import { defineStore, storeToRefs, createPinia, setActivePinia } from 'pinia';

// Project-internal (only what this pack owns — the HTTP client is appended by the seam)
import { config } from '@/config';
import { cn } from '@/lib/cn';
```
<!-- /pack-slot -->

<!-- pack-slot: component-template -->
## Component Template

```vue
<script setup lang="ts">
// src/features/tasks/components/TaskCard.vue
// A feature component, so it knows the domain type. components/common/ conversely never imports from features/
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
- There is a single root, so the `class`·`aria-*`·listeners the call site passes attach to this `<article>` automatically
- A shared component never calls `useRouter()`·`useQuery()` (that blocks reuse)
<!-- /pack-slot -->

## What the seam fills in — what this pack does not have

| Hub slot | Why it is a function of the combination |
| --- | --- |
| Architecture Overview | The trust boundary and the data source depend on the backend axis |
| The 2 Quick Start checklists | The pagination model·error code branching depend on the wire contract |
| Core Principle 4 "authorization is not a trust boundary" | The principle is universal, but **whether an unauthorized response is 403 or 404** depends on the backend axis. This rule is mandatory (which is why number 4 is empty here) |
| The HTTP client·auth rows of Common Imports | The authentication method and envelope parsing depend on the backend axis |
| Navigation Guide | `pack.json` supplies the pack resource rows, and the seam adds the seam resource rows |
