<!-- orangekit-pack: frontend/vue v3.12.0 -->
# Loading · Empty · Error States

Every screen that draws data has at least three branches. A screen that implements only the success path goes
white on a slow network, with an expired session, and on an empty account.

## 1. The three states + background refresh

```vue
<script setup lang="ts">
// src/features/tasks/pages/TaskListPage.vue
import { computed } from 'vue';
import { useTasksQuery } from '@/features/tasks/api/useTasksQuery';   // supplied by the seam
import ListSkeleton from '@/components/common/ListSkeleton.vue';
import EmptyState from '@/components/common/EmptyState.vue';
import ErrorState from '@/components/common/ErrorState.vue';
import TaskTable from '../components/TaskTable.vue';

const { data, isPending, isError, error, isFetching, refetch } = useTasksQuery();
const tasks = computed(() => data.value ?? []);
</script>

<template>
  <ListSkeleton v-if="isPending" :rows="5" />
  <ErrorState v-else-if="isError" :error="error" @retry="refetch" />
  <EmptyState v-else-if="tasks.length === 0" title="No tasks yet"
              description="Create your first task" />
  <template v-else>
    <div v-if="isFetching" class="h-0.5 animate-pulse bg-brand-500" role="status" />
    <TaskTable :rows="tasks" />
  </template>
</template>
```

The order matters. Check `isError` first and the error screen stays up during a retry; check the empty state
first and "no data" flashes during loading. The three branches must be `v-if` family — use `v-show`
and all three trees mount at once, so the list tries to read data even while loading.

What Vue Query returns is **an ordinary object holding Refs**. That is why destructuring it keeps reactivity
alive (unlike a Pinia store — `state-management.md` §4). In exchange, reading a value in the script needs
`.value`, while the template unwraps it automatically.

A query disabled with `enabled: false` is the exception — no request has ever gone out, so `isPending` is
permanently true. Apply this rule as written and the skeleton never goes away (§misuse list).

## 2. Choosing how to show loading

| Situation | Presentation |
| --- | --- |
| First entry, a list/card whose layout is known | Skeleton (no layout shift) |
| First entry, an area whose size is unknown | Centered spinner + a reserved minimum height |
| A refetch where data already exists | A thin progress bar at the top, or a slight dimming — do not clear the screen |
| A mutation after a button click | Spinner inside the button + `disabled` (blocks double submits) |
| Something that finishes within 200ms | Show nothing at all (the flicker is worse) |

```vue
<script setup lang="ts">
// src/components/common/ListSkeleton.vue — has the same box sizes as the real layout
withDefaults(defineProps<{ rows?: number }>(), { rows: 3 });
</script>

<template>
  <div class="space-y-3" role="status" aria-label="Loading">
    <div v-for="i in rows" :key="i" class="h-16 animate-pulse rounded-card bg-surface-muted" />
  </div>
</template>
```

## 3. The empty state and the error state are one shared component each

Define the two components in `src/components/common/` **exactly once** and let every screen call them with the
same props. Call them in a different shape per screen and the signature splits, and the types break first.

```vue
<script setup lang="ts">
// src/components/common/EmptyState.vue
withDefaults(defineProps<{ title?: string; description?: string }>(),
             { title: 'No items to display' });
</script>

<template>
  <div class="rounded-card border border-dashed border-surface-border p-10 text-center">
    <p class="text-sm font-medium text-slate-900">{{ title }}</p>
    <p v-if="description" class="mt-1 text-sm text-slate-500">{{ description }}</p>
    <div v-if="$slots.action" class="mt-4 flex justify-center"><slot name="action" /></div>
  </div>
</template>
```

```vue
<script setup lang="ts">
// src/components/common/ErrorState.vue
import { computed } from 'vue';
import { toUserMessage } from '@/lib/toUserMessage';
import Button from './Button.vue';

const props = defineProps<{
  title?: string;
  message?: string;
  error?: unknown;      // pass it and the wording is pulled out here
  retryable?: boolean;  // false means the retry button is not drawn (no permission·missing resource are those cases)
}>();
defineEmits<{ retry: [] }>();

const text = computed(() => props.message ?? toUserMessage(props.error));
</script>

<template>
  <div role="alert" class="rounded-card border border-surface-border p-10 text-center">
    <p class="text-sm font-medium text-slate-900">{{ title ?? 'Something went wrong' }}</p>
    <p class="mt-1 text-sm text-slate-500">{{ text }}</p>
    <Button v-if="retryable !== false" variant="secondary" class="mt-4" @click="$emit('retry')">
      Try again
    </Button>
  </div>
</template>
```

There are two kinds of empty state, and their wording must differ.

- **Nothing yet**: "Create your first task" + a create button (the `#action` slot)
- **No results for the filter**: "No tasks match your filter" + a reset-filter button

## 4. Error → user-facing message

**This pack does not define the error code table.** The list of codes and their status code mapping are a
function of the wire contract, so the seam supplies them. This pack owns exactly two things: the transport-layer
codes the client makes up itself, and the **fallback** that keeps the screen standing whatever arrives.

<!-- file: src/lib/toUserMessage.ts -->
```ts
// src/lib/toUserMessage.ts
import { ApiError } from '@/api/errors';   // supplied by the seam

export function toUserMessage(error: unknown): string {
  if (error instanceof ApiError) {
    switch (error.code) {
      // Failures that never reached the server — these two codes are made by the HTTP client
      case 'NETWORK_ERROR':
      case 'TIMEOUT':
        return 'The connection failed. Please check your network.';
      default:
        // Append the per-code wording from the seam's code table here.
        // Never surface the server's raw message — it leaks the internal structure
        return 'We could not process your request. Please try again shortly.';
    }
  }
  return 'Something went wrong. Please try again shortly.';
}
```

Three rules hold regardless of the code table.

- **No permission·a missing resource are not retry material.** Give them a button and the user keeps pressing it,
  dirtying the server logs and nothing else — remove the button with `:retryable="false"`
- **A rate limit is not retried automatically either.** Throwing again without a backoff hits the limit harder
- **An authentication failure is handled in one place, the HTTP layer, not in a screen.** Put refresh·logout
  branches in individual screens and the same logic appears once per screen

## 5. Do not use `<Suspense>` or `async setup`

Vue 3's `<Suspense>` is still marked experimental, and once you use a top-level `await` in `<script setup>` that
component **must** sit inside a parent `<Suspense>`. The consequences:

- The owner of the loading state moves outside the component and no longer lines up with the three-state rule (§1)
- After the `await`, the current instance context is gone, so registering `onMounted` fails
- The failure path arrives only through `errorCaptured`, so a "retry" UI cannot be built where it is needed

Data loading is handled inside the screen with the query's `isPending`. `<Suspense>` is not used in
this stack.

## 6. The error boundary — `onErrorCaptured`

The net that catches exceptions thrown during render. It goes in three tiers.

```vue
<script setup lang="ts">
// src/components/common/ErrorBoundary.vue
import { ref, onErrorCaptured } from 'vue';
import ErrorState from './ErrorState.vue';

const caught = ref<unknown>(null);

onErrorCaptured((err) => {
  caught.value = err;
  return false;      // it ends here — do not propagate upward
});

function retry() { caught.value = null; }
</script>

<template>
  <ErrorState v-if="caught" :error="caught" @retry="retry" />
  <!-- switching the v-if/v-else branch already forces an unmount and remount — no artificial key is needed -->
  <slot v-else />
</template>
```

- ① At the app root: `app.config.errorHandler` keeps a white screen away whatever slips through
- ② Layout: wrap `<RouterView>` in `<ErrorBoundary>`
- ③ Widget: one dashboard card can die and the rest live on

What `onErrorCaptured` **catches**: exceptions thrown in a descendant component's render·lifecycle hooks·watchers·
template event handlers. **What it does not catch**: an exception in its own `setup`,
a `setTimeout` callback, a Promise rejection left to leak without `await`, and a failed `mutate()` of a mutation.
Each of those is caught where it happens.

## 7. Form validation errors

The shape of the per-field messages (`details`) is set by the seam's contract. This pack decides only **where they
are drawn, under the field** — show a validation failure in a toast and nobody can tell which box is wrong.

```vue
<script setup lang="ts">
import { ref } from 'vue';
import { ApiError } from '@/api/errors';
import { useCreateTaskMutation } from '@/features/tasks/api/useCreateTaskMutation';
import { toUserMessage } from '@/lib/toUserMessage';
import FormField from '@/components/common/FormField.vue';

const title = ref('');
const fieldErrors = ref<Record<string, string[]>>({});
const banner = ref<string | null>(null);
const { mutate, isPending } = useCreateTaskMutation();

function submit() {
  fieldErrors.value = {};
  banner.value = null;
  mutate({ title: title.value }, {
    onError: (e: unknown) => {
      // With details, under the field; without, in the banner at the top of the form — the wording is made in one place
      if (e instanceof ApiError && e.details) fieldErrors.value = e.details;
      else banner.value = toUserMessage(e);
    },
  });
}
</script>

<template>
  <form class="space-y-4" @submit.prevent="submit">
    <p v-if="banner" role="alert" class="text-sm text-danger-600">{{ banner }}</p>
    <FormField label="Title" input-id="title" :error="fieldErrors.title?.[0]" hint="At least 2 characters">
      <input id="title" v-model="title" class="h-10 w-full rounded-md border px-3 text-sm" />
    </FormField>
    <button type="submit" :disabled="isPending" class="h-10 rounded-md bg-brand-600 px-4 text-white">
      Save
    </button>
  </form>
</template>
```

Client validation is **UX guidance up front** and the final verdict is the server's. Put the rule only on the
client and it is bypassed by paths that call the API directly; put it only on the server and round trips pile up — put it in both.

## Misuse list — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `isPending` vs `isFetching` | `isPending` means "there is nothing to show yet" → replace with a skeleton. `isFetching` means "a request is in flight" → keep the current screen + a thin indicator |
| `isPending` vs `isLoading` (v5) | In v5 `isLoading` is `isPending && isFetching`. The first-load branch is `isPending` |
| `isPending` of an `enabled: false` query | A disabled query has `isPending` **permanently true**, so the skeleton never goes away → branch on `isLoading`, or draw the parameter-less state as its own guidance screen |
| Destructuring a query result vs destructuring a store | A query result is an object of Refs, so it is safe. A Pinia store is a proxy and needs `storeToRefs` |
| `.value` in the script vs auto-unwrap in the template | Add `.value` in a template and you get `undefined`; drop it in the script and the Ref object itself is truthy, so **the branch is always taken** |
| A three-way `v-if` vs `v-show` | The three states are always `v-if`. `v-show` leaves a dead tree, so a child reads data even during loading |
| `<Suspense>` vs `isPending` | In this stack, `isPending`. See §5 |
| `onErrorCaptured` vs `isError` | Foreseeable failures (no permission, missing resource) go in the `isError` branch. Only unforeseen render exceptions go to the boundary |
| The return value of `onErrorCaptured` | It must return `false` for propagation to stop. Return nothing and the parent boundary and the global handler catch the same error again |
| `throwOnError` vs the default | The default (false) is the standard. Turn it on only when you want to bundle several queries on one screen and handle the failure once |
| An error banner vs an inline error vs a field error | If the whole screen cannot come up, an inline error screen. The failure of an action just pressed goes in a banner at the top of the form. Field validation goes under the field |
| `role="status"` vs `role="alert"` | A loading announcement is `status` (polite). A failure announcement is `alert` (read immediately) |
| `refetch()` vs `invalidateQueries()` | To call this one query again, `refetch`. To make all related queries stale after a change, `invalidateQueries` |
