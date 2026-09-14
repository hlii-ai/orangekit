<!-- orangekit-seam: vue+node-api v3.13.0 -->
# Complete Example — list plus create, end to end

Assembles one feature from start to finish: reading the task list and creating a new task. **No new symbol is
created** — only what the pack defined and what `resources/data-fetching.md` · `resources/auth-and-session.md`
defined are used. If even one new name turns out to be needed here, those two files are under-filled.

## 1. What this example runs through

| Layer | File | Owner |
| --- | --- | --- |
| Domain type | `src/types/task.ts` | the seam (data-fetching §2) |
| Transport | `src/api/http.ts` · `src/api/errors.ts` | the seam (data-fetching §2 · §3) |
| Session | `src/auth/session.ts` · `src/auth/useAuth.ts` | the seam (auth-and-session §2 · §4) |
| Request · keys | `src/features/tasks/api/tasks.ts` | the seam (data-fetching §4) |
| Composables | `useTasksQuery.ts` · `useCreateTaskMutation.ts` | the seam (data-fetching §5 · §6) |
| Response narrowing | `src/features/tasks/api/tasks.parse.ts` | the pack (types-and-testing §4) |
| Shared UI | `ListSkeleton` · `EmptyState` · `ErrorState` · `DataTable` · `FormField` · `Button` · `PageShell` | the pack |
| Screens | `TaskListPage.vue` · `TaskCreateForm.vue` | this file |

## 2. The list screen (`src/features/tasks/pages/TaskListPage.vue`)

The three states (loading · empty · error) and cursor pagination meet in one screen. Reorder them and
"no data" flashes during loading, or the error screen stays up during a retry.

```vue
<script setup lang="ts">
// src/features/tasks/pages/TaskListPage.vue
import { computed } from 'vue';
import { useRoute } from 'vue-router';
import { useTasksQuery } from '@/features/tasks/api/useTasksQuery';
import type { Task } from '@/types/task';
import type { Column } from '@/components/common/table-types';
import PageShell from '@/components/layout/PageShell.vue';
import ListSkeleton from '@/components/common/ListSkeleton.vue';
import EmptyState from '@/components/common/EmptyState.vue';
import ErrorState from '@/components/common/ErrorState.vue';
import DataTable from '@/components/common/DataTable.vue';
import Button from '@/components/common/Button.vue';
import TaskCreateForm from '../components/TaskCreateForm.vue';

const route = useRoute();
// the URL owns the filter (the pack's state-management.md §8). That value becomes the query key as it is
const filter = computed(() => ({
  status: route.query.status === 'done' ? ('done' as const) : undefined,
  limit: 20,
}));

const { data, isPending, isError, error, isFetching,
        refetch, fetchNextPage, hasNextPage, isFetchingNextPage } = useTasksQuery(filter);

const tasks = computed<Task[]>(() => data.value ?? []);
const columns: Column<Task>[] = [
  { key: 'title', header: 'Title', value: (t) => t.title },
  { key: 'status', header: 'Status', value: (t) => (t.status === 'done' ? 'Done' : 'In progress'), class: 'w-24' },
];
</script>

<template>
  <PageShell title="Tasks">
    <template #actions><TaskCreateForm /></template>

    <ListSkeleton v-if="isPending" :rows="5" />
    <ErrorState v-else-if="isError" :error="error" @retry="refetch" />
    <EmptyState v-else-if="tasks.length === 0" title="No tasks yet"
                description="Create your first task" />
    <template v-else>
      <div v-if="isFetching" class="h-0.5 animate-pulse bg-brand-500" role="status" />
      <DataTable :rows="tasks" :columns="columns" />
      <Button v-if="hasNextPage" variant="secondary" size="md" class="mt-4"
              :disabled="isFetchingNextPage" @click="fetchNextPage()">
        Load more
      </Button>
    </template>
  </PageShell>
</template>
```

`data` is not the page envelope but **a flat `Task[]`** — the `select` of `useTasksQuery` makes it
so. What makes `hasNextPage` false is `nextCursor: null` from contract §3.

## 3. The create form (`src/features/tasks/components/TaskCreateForm.vue`)

This is where the `details` of contract §2 (`Record<string, string[]>`) is moved under the field.

```vue
<script setup lang="ts">
// src/features/tasks/components/TaskCreateForm.vue
import { ref } from 'vue';
import { ApiError } from '@/api/errors';
import { useCreateTaskMutation } from '@/features/tasks/api/useCreateTaskMutation';
import { toUserMessage } from '@/lib/toUserMessage';
import FormField from '@/components/common/FormField.vue';
import Button from '@/components/common/Button.vue';

const title = ref('');
const fieldErrors = ref<Record<string, string[]>>({});
const formMessage = ref('');
const { mutate, isPending } = useCreateTaskMutation();

function onSubmit() {
  fieldErrors.value = {};
  formMessage.value = '';
  // mutate returns no value and throws nothing — failure arrives only through onError
  mutate({ title: title.value }, {
    onError: (e: unknown) => {
      if (e instanceof ApiError && e.code === 'VALIDATION_FAILED' && e.details) {
        fieldErrors.value = e.details;      // per-field errors go under the field
      } else {
        formMessage.value = toUserMessage(e);  // everything else becomes the whole-form message
      }
    },
  });
  title.value = '';
}
</script>

<template>
  <form class="flex items-end gap-2" @submit.prevent="onSubmit">
    <FormField label="Title" input-id="new-task-title" :error="fieldErrors.title?.[0]">
      <template #default="{ describedBy }">
        <input id="new-task-title" v-model="title" :aria-describedby="describedBy"
               class="h-10 w-64 rounded-md border px-3" />
      </template>
    </FormField>
    <Button variant="primary" size="md" :disabled="isPending">Add</Button>
    <p v-if="formMessage" class="text-sm text-red-600" role="alert">{{ formMessage }}</p>
  </form>
</template>
```

On success `useCreateTaskMutation` does the invalidation. The screen does not call `refetch` —
triggering a refetch in two places doubles the list requests for a single create.

## 4. The 404 of a detail screen — absent, or not mine

In contract §5 an ownership failure is 404, not 403. The response carries no information to separate the two cases, so
handle it in **one screen**. Remove the retry button with `retryable="false"` — pressing it again changes nothing.

```ts
// src/features/tasks/pages/TaskDetailPage.vue — excerpt from <script setup>
const missing = computed(() => (error.value as ApiError | null)?.code === 'NOT_FOUND');
```

❌ The branch below is wrong. A 403 arrives only for an insufficient role, so it misses ownership failure forever.

```ts
// ❌ waiting for an ownership failure as 403 — it never arrives in this combination
const forbidden = computed(() => (error.value as ApiError | null)?.code === 'FORBIDDEN');
```

## 5. Wiring (`src/api/queryClient.ts` · `src/main.ts`)

<!-- file: src/api/queryClient.ts -->
```ts
// src/api/queryClient.ts — the app-global instance. Logout empties this from outside a component
import { QueryClient } from '@tanstack/vue-query';

// a failure whose result cannot change is not retried. If a 401 got this far it means
// the reissue in http.ts failed, so there is no reason to try again
const TERMINAL = ['UNAUTHENTICATED', 'FORBIDDEN', 'NOT_FOUND', 'VALIDATION_FAILED', 'BAD_SHAPE'];

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      staleTime: 30_000,
      retry: (count, error) => count < 2 && !TERMINAL.includes((error as { code?: string })?.code ?? ''),
    },
  },
});
```

<!-- verified: measured by running it — a 404 NOT_FOUND ended after 1 request while a 500 INTERNAL was attempted 3 times (the first + 2 retries) -->

<!-- file: src/main.ts -->
```ts
// src/main.ts
import { createApp } from 'vue';
import { createPinia } from 'pinia';
import { VueQueryPlugin } from '@tanstack/vue-query';
import { router } from '@/router';                 // owned by the pack — the global guard is already attached
import { queryClient } from '@/api/queryClient';
import App from './App.vue';
import './index.css';

createApp(App)
  .use(createPinia())                              // before router, because the guard uses a store
  .use(router)
  .use(VueQueryPlugin, { queryClient })            // do not create a new QueryClient
  .mount('#app');
```

**Pass** `queryClient` to `VueQueryPlugin`. Without it the plugin creates its own instance, and
the `queryClient.clear()` of logout empties the side nobody subscribes to — the screen keeps
the previous user's list as it was.

## 6. Tests — the positive and the negative in the same `it` (`TaskListPage.test.ts`)

The pack's default msw handler returns a body with no envelope. The contract of this combination is `{ data, nextCursor }`,
so **every test overrides the contract shape with `server.use()`.**

<!-- file: src/features/tasks/pages/TaskListPage.test.ts -->
```ts
// src/features/tasks/pages/TaskListPage.test.ts
import { flushPromises } from '@vue/test-utils';
import { http as mock, HttpResponse } from 'msw';
import { server } from '@/test/setup';
import { mountWithProviders } from '@/test/mountWithProviders';
import TaskListPage from './TaskListPage.vue';

const row = { id: 't1', title: 'My task', createdAt: '2026-01-01T00:00:00.000Z', status: 'open' };

it('renders the contract envelope, and falls to the error state when the envelope breaks', async () => {
  server.use(mock.get('*/api/tasks', () => HttpResponse.json({ data: [row], nextCursor: null })));
  const ok = mountWithProviders(TaskListPage);
  await ok.router.isReady();
  await flushPromises();
  expect(ok.wrapper.text()).toContain('My task');            // positive: the success path really renders
  expect(ok.wrapper.find('[role="alert"]').exists()).toBe(false);

  // data is not an array → parseTaskList throws ApiError('BAD_SHAPE')
  server.use(mock.get('*/api/tasks', () => HttpResponse.json({ data: { oops: true } })));
  const bad = mountWithProviders(TaskListPage);
  await bad.router.isReady();
  await flushPromises();
  expect(bad.wrapper.get('[role="alert"]').text()).toContain('Something went wrong');  // negative
});
```

The positive assertion has to sit inside the same `it` for the negative assertion to separate "blocked" from "everything is broken".
With only the error assertion, replacing `useTasksQuery` wholesale with a `throw` still stays green.

## Misuse list ① — assembly idiom table

| Old habit | The current form (this combination) |
| --- | --- |
| `await http.get(...)` in a screen, stored in a `ref` | A query composable. Storing it leaves you building the cache · invalidation · GC yourself |
| Calling `refetch()` after a create | `invalidateQueries` in the mutation's `onSuccess` |
| Paging with `page` · `offset` parameters | `limit` · `cursor` (contract §3). With an offset, a changing list duplicates and drops rows |
| `mutate(...).then(...)` / `await mutate(...)` | `mutate(input, { onError })`. There is no return value |
| `mutateAsync` wrapped in `try/catch` for failure | The `onError` callback. It never lets a rejected Promise escape |
| `catch (e) { alert(e.message) }` | `toUserMessage(e)` — the raw server text exposes internal structure |
| An msw handler returning a bare array | Override it with the `{ data: [...], nextCursor: null }` envelope |

## Misuse list ② — confused pairs

| Frequently chosen wrongly | The exact condition for each |
| --- | --- |
| `PageShell` vs `DefaultLayout` | The screen title and spacing are the former (a screen uses it); the app shell and `RouterView` are the latter (a route uses it) |
| `EmptyState` vs `ErrorState` | If the server answered "0 items", the former; if it could not answer, the latter. `data` being `undefined` is not an empty state |
| The `retryable` of `ErrorState` | Retryable by default. `false` for `NOT_FOUND` · `FORBIDDEN` · `VALIDATION_FAILED` |
| `fetchNextPage` vs `refetch` | Reading one more cursor forward is the former, re-reading the pages you hold is the latter |
| `mountWithProviders` vs `mount` | A screen that uses the router · pinia · queries always takes the former. Mount with the latter and the composables cannot find their injections |
| `router.isReady()` vs `flushPromises()` | The first route resolution is the former, the query microtasks the latter. **Both** are needed |
| A new `QueryClient` vs the injected one | Tests make a new one each time; the app has the single one from `main.ts`. Create a new one in the app and logout empties the wrong object |
