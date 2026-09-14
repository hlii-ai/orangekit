<!-- orangekit-pack: frontend/vue v3.12.0 -->
# TypeScript Standards · Frontend Testing


## 1. The tsconfig baseline and type checking

```jsonc
// tsconfig.app.json
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,   // arr[0] becomes T | undefined — catches indexing accidents
    "noUnusedLocals": true,
    "noFallthroughCasesInSwitch": true,
    "verbatimModuleSyntax": true,       // a type import must be `import type`
    "moduleResolution": "bundler",
    "jsx": "preserve",                  // this value is safe even if you never write tsx inside .vue
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] }
  },
  "include": ["src/**/*.ts", "src/**/*.vue", "env.d.ts"]
}
```

```ts
// vite.config.ts — the alias must exist in both places (type checking and bundling are separate)
resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } }
```

**Type checking is `vue-tsc --noEmit`.** Plain `tsc` cannot read `.vue` files, so the components drop out of
the check entirely. Put `npm run typecheck` in CI and in the `build` script — Vite only transpiles, so
type errors pass the build.

## 2. Environment variable types

```ts
// env.d.ts
/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL: string;
}
interface ImportMeta { readonly env: ImportMetaEnv }
```

**Do not add** a `declare module '*.vue'` shim. With plain `tsc`·vue-tsc 1.x·an editor without Volar, this
declaration blankets every component's props·emits as `any` and disables type checking while it still looks
alive. From vue-tsc 2 onward the SFC's real type wins and it is harmless, but it is still unnecessary and it is
a trap that comes back the moment the tooling changes, so it does not go in.

<!-- file: src/config.ts -->
```ts
// src/config.ts — the only file in which import.meta.env appears
function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`Environment variable ${name} is not set.`);
  return value;
}

export const config = {
  apiBaseUrl: required('VITE_API_BASE_URL', import.meta.env.VITE_API_BASE_URL),
  basePath: import.meta.env.BASE_URL,   // the deployment base path Vite provides — the router uses it
} as const;
```

Values are **read at the call site with a literal key** and passed in. Read them inside a function with
`import.meta.env[name]` and Vite's static substitution never happens, so a production build gets all `undefined`.
Throwing at boot makes a missing value obvious immediately — defer it to first use and it is only discovered
by entering a particular screen. No secrets go here: `VITE_*` is inlined into the bundle.

## 3. Component props types

- The type given to `defineProps<T>()` **may be an imported type** (Vue 3.3+). `PropType` is not needed
- Supply defaults with `withDefaults`. An optional prop's type uses `?:` and is paired with its default
- Remove impossible combinations with a discriminated union: `{ status: 'done'; completedAt: string } | { status: 'open'; completedAt?: never }`
- Do not use `any`. Take an unknown value as `unknown` and narrow it
- Use a literal union + an `as const` object instead of `enum` (no runtime code is left in the bundle)
- When a component instance type is needed, use `InstanceType<typeof MyComponent>`

## 4. Narrowing types at the API boundary

A response body is `unknown`. Merely asserting here means compilation passes even when the server contract
changes, and the error blows up deep inside a screen. Put a **narrowing function** at the boundary, on the request path.

<!-- file: src/features/tasks/api/tasks.parse.ts -->
```ts
// src/features/tasks/api/tasks.parse.ts
import { ApiError } from '@/api/errors';   // supplied by the seam
import type { Task } from '@/types/task';  // the domain type is defined by the seam too

export function assertTask(v: unknown): asserts v is Task {
  const t = v as Record<string, unknown> | null;
  if (!t || typeof t.id !== 'string' || typeof t.title !== 'string') {
    throw new ApiError('BAD_SHAPE', 'The response shape differs from the contract.');
  }
}

export const parseTask = (v: unknown): Task => { assertTask(v); return v; };
export const parseTaskList = (v: unknown): Task[] => {
  if (!Array.isArray(v)) throw new ApiError('BAD_SHAPE', 'The list response is not an array.');
  return v.map(parseTask);
};
```

```ts
// Inside the seam's query composable — the narrowing sits on the request path
const raw: unknown = await http.get('/tasks');
const tasks = parseTaskList(raw);
```

There is no need to check every field. Checking **only the fields the screen truly depends on** catches most
contract breakage right here. Never omit the narrowing on an endpoint whose response a screen actually reads.

> `Task` and `ApiError` are not defined by this pack (`requires` in `ledger.md`). What this pack
> owns is **where the narrowing goes and how failure is thrown**; the actual fields and error
> codes are set by the wire contract.

## 5. Test tools and placement

| Target | Tool | Location |
| --- | --- | --- |
| Pure functions·utilities | Vitest 2 | `src/lib/x.test.ts` |
| Composables | Verified by mounting in a shell component (`mount(defineComponent({ setup: () => (useX(), () => null) }))`) | next to the composable file |
| Components | Vitest + `@vue/test-utils` 2 | next to the component file |
| Pinia stores | Vitest + `setActivePinia` | next to the store file |
| HTTP | msw 2 (`setupServer`), mocked at the network layer | `src/test/msw/` |

```ts
// vite.config.ts — the Vitest configuration goes here. Make a separate vitest.config.ts and you have to
// register the vue() plugin there again, and leaving it out means a .vue import is not even parsed
//
// defineConfig must come from 'vitest/config'. The one from 'vite' has no test key, which is a type error
// under strict TS and turns red the vue-tsc --noEmit this pack told you to put in CI
import { defineConfig } from 'vitest/config';

plugins: [vue()],
test: { environment: 'jsdom', setupFiles: ['./src/test/setup.ts'], globals: true },
```

<!-- file: src/test/msw/handlers.ts -->
```ts
// src/test/msw/handlers.ts — the msw v2 API
import { http, HttpResponse } from 'msw';

// The **response envelope shape is the seam's contract**. Get the shape wrong here and only the tests pass while the real thing breaks —
// replace these bodies with that contract when the seam is attached
export const handlers = [
  http.get('*/tasks', () => HttpResponse.json([])),
  http.post('*/tasks', async ({ request }) => {
    const body = (await request.json()) as { title: string };
    return HttpResponse.json({ id: 't1', status: 'open', ...body }, { status: 201 });
  }),
];
```

<!-- file: src/test/setup.ts -->
```ts
// src/test/setup.ts
import { setupServer } from 'msw/node';
import { handlers } from './msw/handlers';

export const server = setupServer(...handlers);

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));   // an unmocked request is made to fail
afterEach(() => server.resetHandlers());
afterAll(() => server.close());
```

msw's `http` and the API client's `http` share a name. Test files do not import the API client, so there is no
actual collision, but when one file needs both, give one an alias.
Why `fetch` is not stubbed directly: with msw the client's header assembly and error normalization are
verified along with it, so when the test passes the real path passes too.

## 6. The mount helper

<!-- file: src/test/mountWithProviders.ts -->
```ts
// src/test/mountWithProviders.ts
import { mount, type MountingOptions } from '@vue/test-utils';
import { createPinia } from 'pinia';
import { createRouter, createMemoryHistory } from 'vue-router';
import { VueQueryPlugin, QueryClient } from '@tanstack/vue-query';
import type { Component } from 'vue';
import { routes } from '@/router/routes';

type Options = MountingOptions<Record<string, unknown>>;

export function mountWithProviders(component: Component, options: Options = {}) {
  // Build a new QueryClient for every test. Share it and the previous test's cache removes the next
  // test's loading state, so failures appear sporadically
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false, gcTime: 0 },   // leave retry on and failure tests get slow
      mutations: { retry: false },
    },
  });
  const router = createRouter({ history: createMemoryHistory(), routes });
  const wrapper = mount(component, {
    ...options,
    global: {
      ...options.global,
      // This is a merge, not an overwrite — if the caller passes global.plugins, pinia·router·query
      // disappear entirely (putting the spread last does exactly that)
      plugins: [
        createPinia(), router, [VueQueryPlugin, { queryClient }],
        ...(options.global?.plugins ?? []),
      ],
    },
  });
  return { wrapper, router, queryClient };
}
```

## 7. Test patterns

```ts
// src/features/tasks/pages/TaskListPage.test.ts
import { flushPromises } from '@vue/test-utils';
import { mountWithProviders } from '@/test/mountWithProviders';
import { http, HttpResponse } from 'msw';
import { server } from '@/test/setup';
import TaskListPage from './TaskListPage.vue';

it('draws the empty state when the list is empty', async () => {
  const { wrapper, router } = mountWithProviders(TaskListPage);
  await router.isReady();          // a screen that uses the router waits for the first resolution
  await flushPromises();           // flush every pending microtask (query resolution)

  expect(wrapper.text()).toContain('No tasks yet');
});

it('draws the error state and a retry button when the request fails', async () => {
  server.use(http.get('*/tasks', () => HttpResponse.error()));   // overridden for this test only
  const { wrapper } = mountWithProviders(TaskListPage);
  await flushPromises();

  expect(wrapper.get('[role="alert"]').text()).toContain('The connection failed');
  await wrapper.get('button').trigger('click');   // trigger must be awaited for the DOM to update
});
```

```ts
// src/stores/ui.test.ts — install a fresh pinia per store test. Without it the previous test's state leaks
beforeEach(() => setActivePinia(createPinia()));

it('reset() returns the values to their initial state', () => {
  const ui = useUiStore();
  ui.toggleSidebar();
  ui.reset();
  expect(ui.isSidebarOpen).toBe(true);
});
```

- Hang selectors on accessibility attributes: `wrapper.get('[role="alert"]')`, `wrapper.get('[aria-label="Delete task"]')`.
  `data-testid` is a last resort — hanging on accessibility attributes makes the selector itself an accessibility check
- Assert from the user's point of view. Do not inspect a composable's internal state·call counts
- Always test at least one error path — fail it with `server.use()` in that test only
- Do not stub child components (`shallow: true`). Stubbing them leaves the slot·props contract unchecked

## 8. Misuse list

### ① Idiom conversion table

| Old habit | The current form |
| --- | --- |
| `tsc --noEmit` | `vue-tsc --noEmit` — `tsc` cannot read `.vue` |
| Adding a `declare module '*.vue'` shim | Do not add it — every component type becomes `any` |
| `props: { x: { type: String as PropType<T> } }` | `defineProps<{ x: T }>()` |
| `jest.fn()` / `jest.mock()` | `vi.fn()` / `vi.mock()` (with `globals: true`, `describe/it/expect` stay as they are) |
| msw v1 `rest.get(url, (req, res, ctx) => res(ctx.json(x)))` | msw v2 `http.get(url, () => HttpResponse.json(x))` |
| `@vue/test-utils` v1 `wrapper.setData(...)` | It does not work on a `<script setup>` component — inject through props or a store |
| Asserting immediately after `wrapper.find(...).trigger('click')` | `await wrapper.get(...).trigger('click')` |
| Inspecting `wrapper.vm.someInternal` | `<script setup>` does not expose its bindings — assert on the rendered result |
| `localVue` / `createLocalVue` (VTU v1) | `global: { plugins, stubs, provide }` |
| `enum` / `const enum` | A literal union + `as const` |

### ② Confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `vue-tsc` vs `tsc` | To check components, always `vue-tsc` |
| A `defineProps` type declaration vs a runtime declaration | The type declaration is the default. A runtime declaration only when runtime validation (`validator`) is genuinely needed |
| `mount` vs `shallowMount` | The default is `mount`. Narrow it only when a heavy child tree makes the test slow |
| `wrapper.get` vs `wrapper.find` | `get` fails immediately if absent (when existence is assumed), `find` is **for asserting absence** |
| `nextTick()` vs `flushPromises()` | To wait one DOM update tick, `nextTick`. To flush pending Promises (query resolution) as well, `flushPromises` |
| `await trigger(...)` vs a bare call | `trigger` returns a Promise. Assert without `await` and you see the DOM before the update |
| With vs without `setActivePinia` | Mandatory when testing a store directly. For component tests the pinia in `global.plugins` is enough |
| `unknown` vs `any` | Take external input as `unknown`. `any` is contagious and disables type checking |
| `import type` vs `import` | Under `verbatimModuleSyntax`, `type` is mandatory on a type-only import — without it a runtime import remains |
| `interface` vs `type` | For props·object shapes, either. Unions·mapped·conditional types are only possible with `type` |
| Mashing it down with `?.`/`??` vs narrowing the type | A chain of optional chaining is a sign the type is wrong. Narrow at the boundary and everything below is clean |
| A global msw handler vs `server.use()` | The default success response is global. A specific test's failure case is overridden with `server.use()` in that test only |
