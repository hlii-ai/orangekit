<!-- orangekit-pack: frontend/vue v3.12.0 -->
# Component Patterns

Rules for where a Vue 3 `<script setup lang="ts">` SFC goes, when it is promoted to shared, and what
it is allowed to own.

## 1. The three tiers

| Tier | Location | Knows | Does not know |
| --- | --- | --- | --- |
| Page | `features/<f>/pages/` | route params, query composables, layout assembly | detailed markup |
| Feature component | `features/<f>/components/` | this feature's domain types | other features, routing |
| Common component | `components/common/`, `components/layout/` | the visual contract (props·slots) only | the domain, fetching, routing |

Rule: **dependencies flow downward only.** A shared component never imports from `features/`.
Break that direction and the shared component is tied to one feature, and its reuse is over.

## 2. Search before you build (the duty to look)

Most duplicate components come not from "we never extracted it" but from **"we did not know it existed"**.
Before building a shared candidate, search along at least two axes.

```bash
# ① The name axis — common names for the role you are after
rg -il "pageshell|emptystate|datatable|modal|drawer|badge" src/components src/features --glob '*.vue'

# ② The markup axis — the class combination already in use
rg -l "rounded-lg border .* bg-white" src/components --glob '*.vue'

# ③ Skim the shared directory listings (it takes 30 seconds)
ls src/components/common src/components/layout
```

If the search turns up something **similar but insufficient**, add one prop or slot instead of building a new one.
Create a new file only once you judge the existing one cannot be extended, and record that judgment in the PR.

## 3. When to extract

- Extract when the same block of markup appears a **third** time (twice is coincidence, three times is a pattern)
- When **two or more features** use the same UI, promote it to `components/common/` at the second one
- If it repeats inside one feature only, keep it in `features/<f>/components/` — premature sharing produces
  an "omni-component" with an exploded prop list
- What gets extracted is the **markup and styling**. Data fetching·routing do not come along with it

## 4. SFC file conventions

- One component per file, named `PascalCase.vue`. The same name is used in templates
- The block order is fixed at `<script setup lang="ts">` → `<template>`. There is no `<style>` block
- **`<script setup>` cannot export values** (`export const FOO = 1` → the compile error
  `cannot contain ES module exports`). A type-only export (`export type`) compiles, but types·constants
  shared by several files are owned by a `.ts` file in the same directory so they are easy to find
  (`Column` in §8 is the example) — the reason for the rule is consistency of location, not the compile restriction
- A component is registered in the template just by importing it — there is no `components: {}` option

```vue
<script setup lang="ts">
// src/components/layout/PageShell.vue — owns layout and spacing and nothing else
defineProps<{ title: string }>();
</script>

<template>
  <div class="mx-auto w-full max-w-5xl px-6 py-8">
    <header class="mb-6 flex items-center justify-between">
      <h1 class="text-xl font-semibold text-slate-900">{{ title }}</h1>
      <slot name="actions" />
    </header>
    <slot />
  </div>
</template>
```

❌ A shared shell that knows the domain cannot be reused in the next feature. Do not do the following:

```vue
<script setup lang="ts">
const props = defineProps<{ taskId: string }>();
const { data } = useTaskQuery(props.taskId);   // fetching
const router = useRouter();                     // routing
</script>
```

## 5. Declaring props — by type only

```vue
<script setup lang="ts">
// src/components/common/Button.vue
import { computed } from 'vue';
import { buttonClass, type ButtonSize, type ButtonVariant } from './button-variants';

const props = withDefaults(
  defineProps<{ variant?: ButtonVariant; size?: ButtonSize; loading?: boolean }>(),
  { variant: 'primary', size: 'md', loading: false },
);
const classes = computed(() => buttonClass(props.variant, props.size));
</script>

<template>
  <button :class="classes" :disabled="loading">
    <span v-if="loading" class="mr-2 size-3 animate-spin rounded-full border-2 border-current border-t-transparent" />
    <slot />
  </button>
</template>
```

- Use a **type declaration** instead of a runtime declaration (`props: { size: { type: String } }`). The type is the
  contract and `vue-tsc` checks the call sites
- Supply defaults with `withDefaults`. An optional prop with no default becomes `undefined`, and every calculation
  downstream then has to handle it. **Booleans are the exception** — Vue's Boolean casting turns an absent prop
  into `false`. Even so, stating it shows the contract to the reader
- **Do not destructure props.** Read them as `props.variant` to keep reactivity
- Gather states into a union instead of splitting them across booleans (`status: 'idle' | 'loading' | 'error'`) —
  impossible combinations such as `isLoading && isError` disappear from the type

## 6. emits and v-model

```vue
<script setup lang="ts">
// src/components/common/SearchInput.vue
const emit = defineEmits<{ submit: [value: string]; clear: [] }>();
const keyword = defineModel<string>({ default: '' });   // v-model — Vue 3.4+

function onSubmit() { emit('submit', keyword.value); }
</script>

<template>
  <form class="flex gap-2" @submit.prevent="onSubmit">
    <input v-model="keyword" class="h-10 flex-1 rounded-md border px-3 text-sm" />
    <button type="button" @click="keyword = ''; emit('clear')">Clear</button>
  </form>
</template>
```

- The tuple notation of `defineEmits<{ name: [args] }>()` is the current form — the argument types are checked as written
- What `defineModel()` returns is a **Ref**. Use `.value` in the script and it as-is in the template
- When the parent must own the value, `v-model`; when the parent only needs to know "something happened", `emit`

## 7. Slots

```vue
<script setup lang="ts">
// src/components/common/FormField.vue — owns the placement of label·error·hint and the accessibility wiring
import { computed } from 'vue';

const props = defineProps<{ label: string; inputId: string; error?: string; hint?: string }>();
const hintId = computed(() => (props.hint ? `${props.inputId}-hint` : undefined));
const errorId = computed(() => (props.error ? `${props.inputId}-error` : undefined));
const describedBy = computed(() =>
  [hintId.value, errorId.value].filter(Boolean).join(' ') || undefined,
);
</script>

<template>
  <div class="space-y-1.5">
    <label :for="inputId" class="block text-sm font-medium text-slate-700">{{ label }}</label>
    <slot :described-by="describedBy" />
    <p v-if="hint && !error" :id="hintId" class="text-xs text-slate-500">{{ hint }}</p>
    <p v-if="error" :id="errorId" role="alert" class="text-xs text-danger-600">{{ error }}</p>
  </div>
</template>
```

```vue
<!-- Call site — FormField does not change as the kinds of input grow -->
<FormField label="Title" input-id="title" :error="fieldErrors.title?.[0]" hint="At least 2 characters">
  <template #default="{ describedBy }">
    <input id="title" :aria-describedby="describedBy" class="h-10 w-full rounded-md border px-3" />
  </template>
</FormField>
```

- To branch on whether a slot exists, use `v-if="$slots.actions"` — no empty wrapper spacing is left behind
- Declare slot types with `defineSlots<{ actions?: (p: { task: Task }) => unknown }>()`
- As options accumulate, open a slot instead of adding more props. A component that grows a prop per kind of
  input, as with `type="select" :options ...`, grows again with the next request

## 8. Generic components

<!-- file: src/components/common/table-types.ts -->
```ts
// src/components/common/table-types.ts
// `<script setup>` cannot export, so shared types live outside the SFC
export type Column<T> = {
  key: string;
  header: string;
  value: (row: T) => string;   // a string cell. A rich cell is covered by the `cell-<key>` slot
  class?: string;
};
```

```vue
<script setup lang="ts" generic="T extends { id: string }">
// src/components/common/DataTable.vue
import type { Column } from './table-types';

defineProps<{ rows: T[]; columns: Column<T>[] }>();
</script>

<template>
  <table class="w-full text-sm">
    <thead>
      <tr class="border-b border-surface-border text-left text-xs text-slate-500">
        <th v-for="c in columns" :key="c.key" class="py-2" :class="c.class">{{ c.header }}</th>
      </tr>
    </thead>
    <tbody>
      <tr v-for="row in rows" :key="row.id" class="border-b border-surface-border last:border-0">
        <td v-for="c in columns" :key="c.key" class="py-3" :class="c.class">
          <slot :name="'cell-' + c.key" :row="row">{{ c.value(row) }}</slot>
        </td>
      </tr>
    </tbody>
  </table>
</template>
```

`generic="T extends { id: string }"` enforces the key rule in the type system — there is no place for an
index key. The `:key` of a `v-for` uses the stable identifier the server gave. Use the index and on sort·delete·
optimistic insert the input state attaches to the wrong row.

## 9. Design token ownership and attribute fallthrough

A shared component defines its own **height·typography·spacing·corner radius** and nothing else does. Call sites
choose only through `variant`/`size` props. In Vue this rule holds even more strongly than in React:
a `class` from the call site is **merely concatenated** onto the root element's `class` and never passes through
`cn()`'s tailwind-merge. `p-4` and `p-8` both survive, and CSS file order decides the winner.

- What may be passed through: non-conflicting **positional adjustments** (`mt-4`, `w-full`, `col-span-2`)
- What must not: tokens the component already owns (`h-*`, `px-*`, `text-*`, `rounded-*`)
- With multiple roots the fallthrough target is undetermined and the attributes silently disappear — keep a single
  root, or set `defineOptions({ inheritAttrs: false })` and attach `v-bind="$attrs"` yourself

## 10. Compute derived state with `computed`

Derive a value from props with `ref` + `watch` and you have two sources, and a value one tick late is rendered.

```vue
<script setup lang="ts">
import { computed } from 'vue';
const props = defineProps<{ tasks: Task[] }>();

// ✅ A derived value is a computed — it is cached and tracks its dependencies automatically
const visible = computed(() => props.tasks.filter((t) => t.status !== 'done'));
</script>
```

❌ Do not do the following. `watch` is only for **synchronizing with the outside world** (cancelling a request, timers, saving):

```vue
<script setup lang="ts">
const visible = ref<Task[]>([]);
watch(() => props.tasks, (t) => { visible.value = t.filter((x) => x.status !== 'done'); },
      { immediate: true });
</script>
```

## Misuse list ① — Options API·Vue 2 idiom conversion table

| Old habit | The Vue 3 `<script setup lang="ts">` form |
| --- | --- |
| Wrapping in `export default defineComponent({ ... })` | `<script setup lang="ts">` gives you the type inference by itself |
| `data() { return { n: 0 } }` | `const n = ref(0)` |
| `computed: { double() { return this.n * 2 } }` | `const double = computed(() => n.value * 2)` |
| `props: { task: { type: Object as PropType<Task> } }` | `defineProps<{ task: Task }>()` |
| `this.$emit('select', id)` | `const emit = defineEmits<{ select: [id: string] }>()` → `emit('select', id)` |
| `mounted()` / `beforeDestroy()` | `onMounted(...)` / `onUnmounted(...)` |
| `this.$refs.input` | `const input = ref<HTMLInputElement \| null>(null)` + `ref="input"` in the template |
| The `.sync` modifier | `v-model:propName` (or `defineModel('propName')`) |
| `slot="x"` / `slot-scope="p"` | `<template #x="p">` |
| `filters: { … }` | Removed — use a `computed` or a method |
| `$listeners` | Merged into `$attrs` |
| Global registration with `Vue.component('AppButton', …)` | Importing registers it automatically |
| `functional: true` | An ordinary SFC — the performance advantage of functional components is gone |
| `mixins: [...]` | A composable (`composables/useX.ts`) — name collisions become visible |
| A `<div>` wrapping several roots | Multiple roots are allowed (but mind the fallthrough in §9) |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `ref` vs `reactive` | The default is `ref`. `reactive` is object-only, **cannot be reassigned**, and breaks the instant it is destructured. Large immutable data goes in `shallowRef` |
| `computed` vs `watch` vs `watchEffect` | Producing a value → `computed`. Hanging a **side effect** on a change → `watch` (when you need to know what changed). A side effect whose dependencies may be collected automatically → `watchEffect` |
| `props.x` vs `const { x } = props` | Destructuring copies the value and cuts reactivity. When you really must detach it, `toRef(props, 'x')` |
| `toRef` vs `toRefs` vs `unref` | One field → `toRef`, a whole object → `toRefs`, "might or might not be a Ref" → `unref` |
| `v-if` vs `v-show` | `v-if` mounts/unmounts (component state is lost). Toggled often and must keep state → `v-show` (only CSS changes). The three loading states are **always `v-if`** — no dead tree may be left behind |
| A `v-for` `:key` of index vs `id` | A server list always uses `id`. The index only in a static array that is never reordered·inserted into |
| `v-if` and `v-for` on the same element | Forbidden — the precedence is confusing. Put a `<template v-for>` outside and the `v-if` inside |
| `nextTick()` vs `watch(..., { flush: 'post' })` | Waiting once → `await nextTick()`. A watcher that must run after every DOM update → `flush: 'post'` |
| A slot default vs `v-if="$slots.x"` | With fallback content, `<slot>default</slot>`. When the wrapper itself must go, check `$slots` |
| Injecting a composable into a shared component vs injecting props | The moment a shared component calls `useQuery`/`useRouter` it belongs to one feature |
| Splitting components vs splitting files | The criterion is not the file count but the **scope of reuse**. A fragment nobody uses from outside stays inside the same file's template |
