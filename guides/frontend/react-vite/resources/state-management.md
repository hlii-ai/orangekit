<!-- orangekit-pack: frontend/react-vite v3.36.0 -->
# State Management (Zustand v5 + where state belongs)

This stack has four places state can live. **Picking the wrong place** is the cause of most state
management problems, so where it belongs comes before how the tool is used.

## 1. The decision tree

```
Is it data the server owns?              → TanStack Query (never a global store)
Must it be shareable·restorable by URL?  → useSearchParams / path parameters
Is it used by one component and its children only?  → useState / useReducer
Otherwise, is it needed app-wide?        → a Zustand store
```

| State | Place | Why |
| --- | --- | --- |
| Task list, user profile | TanStack Query | The server is the truth. Invalidation·refetching are needed |
| List filter·sort·page | URL | Sharing·refresh·the back button come free |
| Form input values | local `useState` | Nobody needs to see them before submission |
| Modal open/closed | local or Zustand | Zustand if it can be opened from several screens |
| Sidebar collapsed, theme, list density | Zustand (+persist) | App-wide UI preferences |
| Access token | the auth module (in memory) | see `auth-and-session.md` |

**Do not put server data in Zustand.** The moment you do, you start hand-building freshness·invalidation·
optimistic rollback, and that is already Query's job.

## 2. Writing a store (`src/stores/uiStore.ts`)

```ts
import { create } from 'zustand';
import { persist, createJSONStorage } from 'zustand/middleware';

type UiState = {
  isSidebarOpen: boolean;
  density: 'comfortable' | 'compact';
  toggleSidebar: () => void;
  setDensity: (d: UiState['density']) => void;
  reset: () => void;
};

const initial = { isSidebarOpen: true, density: 'comfortable' as const };

export const useUiStore = create<UiState>()(
  persist(
    (set) => ({
      ...initial,
      toggleSidebar: () => set((s) => ({ isSidebarOpen: !s.isSidebarOpen })),
      setDensity: (density) => set({ density }),
      reset: () => set(initial),
    }),
    {
      name: 'ui-preferences',
      storage: createJSONStorage(() => localStorage),
      partialize: (s) => ({ isSidebarOpen: s.isSidebarOpen, density: s.density }), // actions excluded
    },
  ),
);
```

- `create<T>()(...)` — the curried form, where you give the type argument and **call once more**, is what makes TS inference correct
- Keep the actions in the same object as the state (do not pull them into a separate hook)
- Always use `partialize` with `persist` to state exactly what is stored. **Never put tokens·personal data·server
  data in it** — localStorage is read straight out by XSS
- Build the `reset()` that logout will call from the very beginning

## 3. Narrow the subscription with a selector

```tsx
// ✅ Subscribe to only the slice you need — a change to another field does not re-render
const isSidebarOpen = useUiStore((s) => s.isSidebarOpen);
const toggleSidebar = useUiStore((s) => s.toggleSidebar);

// ✅ Several values at once — it builds a new object, so useShallow is mandatory
const { density, isSidebarOpen } = useUiStore(
  useShallow((s) => ({ density: s.density, isSidebarOpen: s.isSidebarOpen })),
);

// ❌ Subscribing to the whole store — any field changing re-renders
const store = useUiStore();

// ❌ The selector returns a new object every time and there is no useShallow — infinite re-renders
const { density } = useUiStore((s) => ({ density: s.density }));
```

## 4. Reading and writing outside React

Outside the render tree (an HTTP interceptor, an event handler utility) use `getState()`/`setState()`.
They are not hooks, so they do not subscribe and read **the value at the moment of the call**.

```ts
// Clearing the global store in the 401 handler
useUiStore.getState().reset();

// When a subscription is needed, subscribe (it returns a cleanup)
const unsub = useUiStore.subscribe((s) => console.log(s.density));
```

Never use `getState()` during render — it does not notice changes and the screen goes stale.

## 5. When to split a store

- Split by domain: `uiStore`, `draftStore`, `notificationStore`
- Split when one store has 20 or more fields, or when unrelated concerns are mixed in it
- Stores do not import one another. When a combination is needed, read both stores separately in a component or hook
- If the app has exactly one store with fewer than 5 fields, that is a sign Context would have been enough

### Splitting into slices

When concerns have to be separated inside one store, split them into slice functions and then combine them.
The files diverge but the store instance is single, so actions can reference each other through `get()`.

<!-- file: src/stores/slices/sidebar.ts -->
```ts
// src/stores/slices/sidebar.ts
import type { StateCreator } from 'zustand';
import type { FilterSlice } from '@/stores/slices/filter';

export type SidebarSlice = {
  isSidebarOpen: boolean;
  toggleSidebar: () => void;
};

export const createSidebarSlice: StateCreator<SidebarSlice & FilterSlice, [], [], SidebarSlice> =
  (set) => ({
    isSidebarOpen: true,
    toggleSidebar: () => set((s) => ({ isSidebarOpen: !s.isSidebarOpen })),
  });
```

<!-- file: src/stores/slices/filter.ts -->
```ts
// src/stores/slices/filter.ts
import type { StateCreator } from 'zustand';
import type { SidebarSlice } from '@/stores/slices/sidebar';

export type FilterSlice = {
  savedFilters: string[];
  addFilter: (name: string) => void;
};

export const createFilterSlice: StateCreator<SidebarSlice & FilterSlice, [], [], FilterSlice> =
  (set, get) => ({
    savedFilters: [],
    addFilter: (name) => {
      if (get().savedFilters.includes(name)) return;    // other slices' state is readable too
      set((s) => ({ savedFilters: [...s.savedFilters, name] }));
    },
  });
```

<!-- file: src/stores/uiStore.ts -->
```ts
// src/stores/uiStore.ts — where they are combined (**move** to this form when §2's single store outgrows itself.
// It is a different assembly of the same store, so never keep both definitions at once)
import { create } from 'zustand';
import { createSidebarSlice, type SidebarSlice } from '@/stores/slices/sidebar';
import { createFilterSlice, type FilterSlice } from '@/stores/slices/filter';

export type UiState = SidebarSlice & FilterSlice & { reset: () => void };

export const useUiStore = create<UiState>()((set, get, store) => ({
  ...createSidebarSlice(set, get, store),
  ...createFilterSlice(set, get, store),
  // reset is owned by the place that combines them — the logout path survives the split into slices
  reset: () => set({ isSidebarOpen: true, savedFilters: [] }),
}));
```

The first type argument of `StateCreator` is **the combined whole state**, and the last one is the part this
slice contributes. Write the two the same and other slices become invisible from `get()`.
Whichever assembly you use, `reset()` must exist — logout calls it (§6).

## 6. Resetting on logout

When the session ends, clear **both the server cache and the client stores**. Clear only one and the next
user sees fragments of the previous user's screen.

This function is responsible, exactly as its name says, for **the client stores only**. Discarding the server
cache and controlling the ordering belong to the logout procedure (`resources/auth-and-session.md` §6) — clear
the cache in two places and it becomes hard to trace which one actually ran.

<!-- file: src/stores/clearClientState.ts -->
```ts
// src/stores/clearClientState.ts — when a store is added, add it to this list too
import { useUiStore } from '@/stores/uiStore';

export function clearClientState() {
  useUiStore.getState().reset();     // this is why every store must have a reset()
}
```

## Misuse list ① — v4 → v5 idiom conversion table

| v4 habit | The v5 form |
| --- | --- |
| `import create from 'zustand'` | `import { create } from 'zustand'` — the default export was removed |
| `useStore(selector, shallow)` (second argument) | `useStore(useShallow(selector))` — the `equalityFn` argument was removed |
| Comparing directly with `import { shallow } from 'zustand/shallow'` | `import { useShallow } from 'zustand/react/shallow'` |
| When a custom comparison function really is needed | import `createWithEqualityFn` from `zustand/traditional` |
| `persist`'s `getStorage: () => localStorage` | `storage: createJSONStorage(() => localStorage)` |
| `create<T>((set) => ...)` | `create<T>()((set) => ...)` — the curried form |

## Misuse list ② — confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| Zustand vs TanStack Query | If the original lives on the server, Query. If it is a value the server does not even know exists, Zustand |
| Zustand vs URL state | If it must survive a refresh·a shared link, the URL. If it only means something within the session, Zustand |
| Zustand vs Context | Context is strong for **injection** (rarely-changing values such as the theme·current user), and for frequently-changing values it costs a re-render of the whole subtree. A frequently-changing global value goes in Zustand + a selector |
| `set({...})` vs `set((s) => ({...}))` | Depends on the previous value → the function form. Plain overwrite → the object form |
| `set` merging vs replacing | Zustand's `set` is a **shallow merge**. Nested objects are not merged, so you have to spread them in yourself |
| `getState()` vs a hook selector | During render, always the hook. `getState()` only outside render (interceptors·timers·event utilities) |
| What `persist` covers vs what it must not | UI preferences are stored. Tokens·personal data·server data must never be stored |
| An action in the store vs in the component | When the same transition happens in several places, make it a store action. A transition used on only one screen stays in the component |
