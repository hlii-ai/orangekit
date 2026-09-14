<!-- orangekit-pack: frontend/vue v3.12.0 -->
# State Management (Pinia 2 + where state belongs)

This stack has four places state can live. **Picking the wrong place** is the cause of most state
management problems, so where it belongs comes before how the tool is used.

## 1. The decision tree

```
Is it data the server owns?              → Vue Query (never a global store)
Must it be shareable·restorable by URL?  → route.query / route.params
Is it used by one component and its children only?  → ref / reactive (provide/inject if needed)
Otherwise, is it needed app-wide?        → a Pinia store
```

| State | Place | Why |
| --- | --- | --- |
| Task list, user profile | Vue Query | The server is the truth. Invalidation·refetching are needed |
| List filter·sort | URL | Sharing·refresh·the back button come free |
| Form input values | local `ref` | Nobody needs to see them before submission |
| Modal open/closed | local or Pinia | Pinia if it can be opened from several screens |
| Sidebar collapsed, theme, list density | Pinia | App-wide UI preferences |
| Access token | the auth module (in memory) | owned by the seam's session resource |

**Do not put server data in Pinia.** The moment you do, you start hand-building freshness·invalidation·
optimistic rollback, and that is already Vue Query's job.

## 2. Installation

```ts
// src/main.ts — plugin registration. The order need not be tuned just because a guard uses a store:
// vue-router 4's initial navigation is asynchronous, so the guard body runs after every use() has finished.
// Even so, fix the order below — so a reader sees the direction of dependency at a glance
import { createApp } from 'vue';
import { createPinia } from 'pinia';
import { VueQueryPlugin } from '@tanstack/vue-query';
import App from './App.vue';
import { router } from './router';
import './assets/main.css';

const app = createApp(App);
// ① of loading-error-states.md §6: the last receiver for anything that escaped a boundary
app.config.errorHandler = (err) => { console.error(err); };
app.use(createPinia()).use(router).use(VueQueryPlugin).mount('#app');
```

## 3. Writing a store — the setup store

```ts
// src/stores/ui.ts
import { defineStore } from 'pinia';
import { ref, watch } from 'vue';

export const STORAGE_KEY = 'ui-preferences';   // clearClientState uses the same constant
type Density = 'comfortable' | 'compact';

// Restoration is a pure function outside the store — so a malformed stored value cannot pollute the store
function restore(): { isSidebarOpen: boolean; density: Density } {
  const fallback = { isSidebarOpen: true, density: 'comfortable' as Density };
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw) as Partial<typeof fallback>;
    return {
      isSidebarOpen: typeof parsed.isSidebarOpen === 'boolean' ? parsed.isSidebarOpen : true,
      density: parsed.density === 'compact' ? 'compact' : 'comfortable',
    };
  } catch { return fallback; }
}

export const useUiStore = defineStore('ui', () => {
  const saved = restore();
  const isSidebarOpen = ref(saved.isSidebarOpen);
  const density = ref<Density>(saved.density);

  function toggleSidebar() { isSidebarOpen.value = !isSidebarOpen.value; }
  function setDensity(next: Density) { density.value = next; }
  // A setup store has no $reset() — build it yourself (§7 calls this function)
  function reset() { isSidebarOpen.value = true; density.value = 'comfortable'; }

  // State exactly what is stored. **Tokens·personal data·server data are not stored** —
  // localStorage is read straight out by XSS
  watch([isSidebarOpen, density], ([open, d]) =>
    localStorage.setItem(STORAGE_KEY, JSON.stringify({ isSidebarOpen: open, density: d })));

  return { isSidebarOpen, density, toggleSidebar, setDensity, reset };
});
```

- The store id (`'ui'`) must be globally unique — on a collision the later registration silently wins
- **Return everything**: state made with `ref`, getters made with `computed`, actions made as functions.
  What is not returned is invisible outside the store
- Pinia 2 has no built-in persist. When one `watch` is enough, as above, do not bring in a plugin
- Build the `reset()` that logout will call from the very beginning

There is also the options store notation. **It is a different notation for the same store, so never keep both.**
You get `$reset()` for free, at the cost of making it hard to use other composables inside an action.

```ts
// src/stores/ui.ts — the options notation (if you use the setup notation, do not keep this form)
export const useUiStore = defineStore('ui', {
  state: () => ({ isSidebarOpen: true, density: 'comfortable' as Density }),
  getters: { isCompact: (s) => s.density === 'compact' },
  actions: { toggleSidebar() { this.isSidebarOpen = !this.isSidebarOpen; } },
});
```

## 4. Subscribing — `storeToRefs` is mandatory

A store instance is a **reactive proxy**. Destructure it and the value at that instant is copied and never
updated again. It throws no exception and shows up only as "the screen does not change", so it is found last.

```ts
// ✅ Take state·getters out with storeToRefs — they stay Refs and reactivity lives
const ui = useUiStore();
const { isSidebarOpen, density } = storeToRefs(ui);
// ✅ Actions may be taken directly — the functions are bound to the store
const { toggleSidebar, setDensity } = ui;
```

❌ The following freezes the screen on the first value:

```ts
const { isSidebarOpen } = useUiStore();
```

- In a template you may use the store whole, as `ui.isSidebarOpen` — proxy access is reactive
- `storeToRefs` wraps only state and getters as Refs and leaves actions alone
- `.value` in the script, auto-unwrap in the template — this asymmetry is the source of missing `.value`

## 5. Changing several fields at once

```ts
// Wakes subscribers once. Use it when you want to bundle a partial update into a single transition
useUiStore().$patch({ isSidebarOpen: false, density: 'compact' });
```

`$patch` is a shallow merge. Hand it a whole nested object and the inside is replaced, so when nesting is
needed use the function form (`$patch((s) => { ... })`) or keep the store flat in the first place.

## 6. Using a store outside a component

`useUiStore()` can be called in router guards, HTTP interceptors and event utilities too. There is one
condition: **`app.use(createPinia())` must already have run.**

```ts
// ✅ Called inside a function — by call time pinia is installed
function collapseSidebar() {
  useUiStore().isSidebarOpen = false;
}
```

❌ Call it at module top level and the app never starts, with a `getActivePinia()` error:

```ts
const ui = useUiStore();
function collapseSidebar() { ui.isSidebarOpen = false; }
```

In tests there is no pinia, so install one with `beforeEach(() => setActivePinia(createPinia()))`
(`types-and-testing.md` §7).

## 7. Resetting on logout

When the session ends, clear **both the server cache and the client stores**. Clear only one and the next
user sees fragments of the previous user's screen.

This function is responsible, exactly as its name says, for **the client stores only**. Discarding the server
cache (`queryClient.clear()`) and controlling the ordering are owned by the seam's session resource — clear the
cache in two places and it becomes hard to trace which one actually ran.

<!-- file: src/stores/clearClientState.ts -->
```ts
// src/stores/clearClientState.ts — when a store is added, add it to this list too
import { useUiStore, STORAGE_KEY } from './ui';

export function clearClientState() {
  useUiStore().reset();     // this is why every store must have a reset()
  localStorage.removeItem(STORAGE_KEY);   // never duplicate the literal — change one side and it silently stops clearing
}
```

## 8. Use the URL as state

A list's filter·sort live in the URL, not in component state. Sharing·refresh·the back button work for free,
and the value doubles as the query key.

```vue
<script setup lang="ts">
import { computed } from 'vue';
import { useRoute, useRouter } from 'vue-router';

const route = useRoute();
const router = useRouter();

// A route.query value is string | null | (string | null)[] — always narrow it
const status = computed<'all' | 'open' | 'done'>(() => {
  const raw = route.query.status;
  return raw === 'open' || raw === 'done' ? raw : 'all';
});

function setStatus(next: 'all' | 'open' | 'done') {
  // A filter change uses replace — so filter fiddling does not pile up in the history
  router.replace({ query: { ...route.query, status: next === 'all' ? undefined : next } });
}

// Put the reactive value into the query key as it is. It must be the computed for a URL change to refetch
const { data, isPending } = useTasksQuery(status);
</script>
```

The Vue adapter of Vue Query v5 tracks a `ref`/`computed` held in `queryKey`. Unwrap the value with
`.value` and that instant's snapshot becomes the key, so **changing the filter refetches nothing.**

## 9. When to split a store

- Split by domain: `ui`, `draft`, `notification`
- Split when one store has 20 or more fields, or when unrelated concerns are mixed in it
- Stores do not import one another. When a combination is needed, read each one in a component or composable
- If the app has exactly one store with fewer than 5 fields, that is a sign `provide/inject` would have been enough

## Misuse list ① — Vuex → Pinia idiom conversion table

| Vuex habit | The Pinia 2 form |
| --- | --- |
| `new Vuex.Store({ state, mutations, actions })` | `defineStore('id', () => …)` — **there are no mutations** |
| `commit('setDensity', v)` | Assign directly inside an action: `density.value = v` |
| `dispatch('load')` | Call `store.load()` directly |
| `mapState` / `mapGetters` | `storeToRefs(store)` |
| `getters: { n: (s) => … }` | In a setup store, `computed(() => …)` |
| `store.state.density` | `store.density` — state·getters·actions live on one plane |
| Module `namespaced: true` | Make several stores, one per file (no nesting) |
| `this.$store` | Call `useXStore()` |
| `store.replaceState(...)` | Your own `reset()`, or an options store's `$reset()` |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `storeToRefs(store)` vs `const { x } = store` | State·getters always through `storeToRefs`. When taking only actions, direct destructuring is correct |
| A Pinia store vs a Vue Query result | **A Vue Query result is safe to destructure** — it is not a proxy but an ordinary object holding Refs. A store is a proxy and is dangerous. That is why the same syntax breaks on only one of them |
| `ref` vs `reactive` (inside a store) | In a setup store, `ref`. Return a `reactive` object and `storeToRefs` becomes meaningless and reassignment is blocked too |
| `$patch` vs individual assignment | To bundle several fields into one transition and wake subscribers once, `$patch` |
| `$reset()` vs your own `reset()` | `$reset()` is **for options stores only**. Call it in a setup store and you get a runtime error |
| `store.$subscribe` vs `watch` | When you need a change log for the whole store, `$subscribe`. To react to one field, `watch` |
| Pinia vs Vue Query | If the original lives on the server, Query. If it is a value the server does not even know exists, Pinia |
| Pinia vs the URL | If it must survive a refresh·a shared link, the URL. If it only means something within the session, Pinia |
| Pinia vs `provide/inject` | inject suits **local injection into a subtree** (a form context, a theme). A value read anywhere in the app goes in Pinia |
| `computed` in a query key vs `.value` | A reactive parameter is passed as the computed itself. Unwrap it with `.value` and refetching disappears |
| An action in the store vs in the component | When the same transition happens in several places, a store action. A transition used on only one screen stays in the component |
