<!-- orangekit-pack: frontend/react-vite v3.35.0 -->
# TypeScript Standards · Frontend Testing

## Table of contents

1. The tsconfig baseline
2. Environment variable types
3. Narrowing types at the API boundary
4. Writing domain types
5. Test tools and placement
6. The render helper
7. Test patterns
8. Misuse list

---

## 1. The tsconfig baseline

```jsonc
// tsconfig.json (the app part)
{
  "compilerOptions": {
    "strict": true,
    "noUncheckedIndexedAccess": true,   // arr[0] becomes T | undefined — catches indexing accidents
    "noUnusedLocals": true,
    "noFallthroughCasesInSwitch": true,
    "verbatimModuleSyntax": true,       // a type import must be `import type`
    "jsx": "react-jsx",                 // the React 17+ transform — no per-file React import
    "moduleResolution": "bundler",
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] }
  }
}
```

```ts
// vite.config.ts — the alias must exist in both places (type checking and bundling are separate)
resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } }
```

Put `npm run typecheck` (= `tsc --noEmit`) in CI and in the `build` script. Vite does not check
types, only transpiles, so type errors pass the build.

## 2. Environment variable types

<!-- file: src/vite-env.d.ts -->
```ts
// src/vite-env.d.ts — the Vite scaffold file. Without the reference below, `import.meta.env` is a type error
/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_API_BASE_URL: string;      // the API origin — do not append the path (/api/...)
  // Used only by the OIDC variant. Leave these empty for the self-issued variant (auth-and-session.md)
  readonly VITE_OIDC_AUTHORITY?: string;
  readonly VITE_OIDC_CLIENT_ID?: string;
  readonly VITE_OIDC_LOGOUT_URL?: string;  // for an issuer that does not publish end_session_endpoint
}
interface ImportMeta { readonly env: ImportMetaEnv }
```

<!-- file: src/config.ts -->
```ts
// src/config.ts — app code (http.ts·auth/session.ts included) never reads import.meta.env directly.
// Values are **read at the call site with a literal key** and passed in — do import.meta.env[name]
// inside a function and Vite's static substitution never happens, so a production build gets all undefined.
function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`Environment variable ${name} is not set.`);
  return value;
}

export const config = {
  apiBaseUrl: required('VITE_API_BASE_URL', import.meta.env.VITE_API_BASE_URL),
  // Needed only when the auth variant is OIDC — whether it is required is decided at boot by that variant's session.ts
  oidc: {
    authority: import.meta.env.VITE_OIDC_AUTHORITY ?? '',
    clientId: import.meta.env.VITE_OIDC_CLIENT_ID ?? '',
    logoutUrl: import.meta.env.VITE_OIDC_LOGOUT_URL ?? '',
  },
} as const;
```

Throwing at boot makes a missing value obvious immediately. Defer it to first use and it is only
discovered by entering a particular screen. This file is the **only place** `import.meta.env` appears. The `oidc` values do not
throw here — that would make a self-issued project require variables it does not use. Instead the OIDC
adapter checks for empty values at module load and produces the same boot failure.

## 3. Narrowing types at the API boundary

`await res.json()` is `any`. Merely asserting a type here means compilation passes even when the server
contract changes, and the error blows up deep inside a screen. Put a **narrowing function** at the boundary and
pass it through the `http` client's `parse` option so that it **actually runs**.

<!-- file: src/features/tasks/api/tasks.types.ts -->
```ts
// src/features/tasks/api/tasks.types.ts — the domain types and their narrowing function live in one file
import { ApiError } from '@/lib/api/errors';

export type TaskStatus = 'open' | 'done';
/** The four wire fields of contract §0 are all there is — do not invent fields */
export type Task = { id: string; title: string; status: TaskStatus; createdAt: string };
export type TaskFilter = { status: TaskStatus | 'all' };
export type CreateTaskInput = { title: string };

export function assertTask(v: unknown): asserts v is Task {
  const t = v as Record<string, unknown> | null;
  if (!t || typeof t.id !== 'string' || typeof t.title !== 'string'
      || (t.status !== 'open' && t.status !== 'done') || typeof t.createdAt !== 'string') {
    throw new ApiError(500, 'BAD_SHAPE', 'The response shape differs from the contract.');
  }
}
export const parseTask = (v: unknown): Task => { assertTask(v); return v; };
```

```ts
// ✅ Call site — the narrowing sits on the request path (data-fetching.md §4)
http.getPage<Task>('/api/tasks?limit=20', { parse: parseTask });

// ❌ Called without parse — it becomes `as T` inside the client, so a field the server drops passes silently
http.getPage<Task>('/api/tasks?limit=20');
```

There is no need to check every field. Checking **only the fields the screen truly depends on** catches most
contract breakage right here. Never omit `parse` on an endpoint whose response a screen actually reads.

## 4. Writing domain types

```ts
// ✅ A discriminated union — impossible combinations disappear from the type (the completion time exists only when done)
type TicketStatus = 'open' | 'in_progress' | 'done';
type Ticket =
  | { id: string; title: string; status: 'done'; completedAt: string }
  | { id: string; title: string; status: 'open' | 'in_progress'; completedAt?: never };

// ✅ Turn a missing branch into a compile error
function label(s: TicketStatus): string {
  switch (s) {
    case 'open': return 'Waiting';
    case 'in_progress': return 'In progress';
    case 'done': return 'Done';
    default: { const _never: never = s; return _never; }
  }
}
```

- Do not use `any`. Take an unknown value as `unknown` and narrow it
- Use a literal union + an `as const` object instead of `enum` (no runtime code is left in the bundle)
- When the server response type (`TaskResponse`) differs from the screen model (`Task`), put the mapping function in the API layer
- Component props inherit native attributes by extending `ComponentPropsWithoutRef<'button'>`

## 5. Test tools and placement

| Target | Tool | Location |
| --- | --- | --- |
| Pure functions·utilities | Vitest | `src/lib/x.test.ts` |
| Hooks (queries/mutations included) | Vitest + Testing Library `renderHook` | next to the hook file |
| Components | Vitest + React Testing Library + `user-event` | next to the component file |
| HTTP | MSW (`setupServer`), mocked at the network layer | `src/test/msw/` |

```ts
// vitest.config.ts (or the test block of vite.config.ts)
test: {
  environment: 'jsdom', setupFiles: ['./src/test/setup.ts'], globals: true,
  // config.ts throws at import time when VITE_API_BASE_URL is missing — define it here so tests run even in a fresh scaffold with no .env
  env: { VITE_API_BASE_URL: 'http://localhost:3000' },
}
```

<!-- file: src/test/setup.ts -->
```ts
// src/test/setup.ts
import '@testing-library/jest-dom/vitest';
import { cleanup } from '@testing-library/react';
import { afterAll, afterEach, beforeAll } from 'vitest';
import { server } from './msw/server';

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }));  // an unmocked request is made to fail
afterEach(() => { server.resetHandlers(); cleanup(); });
afterAll(() => server.close());
```

<!-- file: src/test/msw/handlers.ts -->
```ts
// src/test/msw/handlers.ts — the MSW v2 API
import { http, HttpResponse } from 'msw';

// Handlers must honour the **envelope contract** too. Get the shape wrong here and only the tests pass while the real thing breaks
export const handlers = [
  http.get('*/api/tasks', () => HttpResponse.json({ data: [], nextCursor: null })),
  http.post('*/api/tasks', async ({ request }) => {
    const body = (await request.json()) as { title: string };
    return HttpResponse.json(
      { data: { id: 't1', title: body.title, status: 'open', createdAt: '2026-10-01T00:00:00.000Z' } },
      { status: 201 },
    );
  }),
  // Failure cases are overridden with server.use() inside that one test only
  // HttpResponse.json({ error: { code: 'VALIDATION_FAILED', message: '...',
  //   details: { title: ['At least 2 characters'] } }, requestId: 'req_1' }, { status: 400 })
];
```

<!-- file: src/test/msw/server.ts -->
```ts
// src/test/msw/server.ts — setup.ts owns the lifetime, and each test owns its failure responses via server.use()
import { setupServer } from 'msw/node';
import { handlers } from './handlers';

export const server = setupServer(...handlers);
```

Why MSW rather than stubbing `fetch` directly: the header assembly·error normalization in `http.ts` are
verified along with it, so when the test passes the real path passes too.

## 6. The render helper

<!-- file: src/test/renderWithProviders.tsx -->
```tsx
// src/test/renderWithProviders.tsx
import type { ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { createMemoryRouter, RouterProvider } from 'react-router';
import { render } from '@testing-library/react';

export function renderWithProviders(ui: ReactNode, { route = '/' } = {}) {
  const queryClient = new QueryClient({
    defaultOptions: {
      queries: { retry: false, gcTime: 0 },   // leave retry on and failure tests get slow
      mutations: { retry: false },
    },
  });
  const router = createMemoryRouter([{ path: '*', element: <>{ui}</> }], {
    initialEntries: [route],
  });
  return {
    queryClient,
    ...render(<QueryClientProvider client={queryClient}><RouterProvider router={router} /></QueryClientProvider>),
  };
}
```

**Build a new QueryClient for every test.** Share it and the previous test's cache removes the next test's
loading state, so failures appear sporadically. Reset the Zustand store too, with
`beforeEach(() => useUiStore.getState().reset())`.

## 7. Test patterns

```tsx
// A route module exports the screen as `Component` (routing.md §1) — import it under a different name
import { Component as TaskListPage } from '@/features/tasks/pages/TaskListPage';

it('refreshes the list when a task is created', async () => {
  const user = userEvent.setup();
  renderWithProviders(<TaskListPage />, { route: '/tasks' });

  // Loading → data: findBy* waits until it appears
  expect(await screen.findByRole('heading', { name: 'Tasks' })).toBeInTheDocument();

  await user.type(screen.getByLabelText('Title'), 'Write the report');
  await user.click(screen.getByRole('button', { name: 'New task' }));   // the form from complete-example.md §1

  expect(await screen.findByText('Write the report')).toBeInTheDocument();
});
```

- Query priority: `getByRole` > `getByLabelText` > `getByText` > `getByTestId` (last resort)
- Assert from the user's point of view. Do not inspect a hook's internal state·call counts
- Wait for async with `findBy*`/`waitFor`. Never call `act()` yourself
- Always test at least one error path — return a 500 for that one test with `server.use()`

## 8. Misuse list

### ① Idiom conversion table

| Old habit | The current form |
| --- | --- |
| `jest.fn()` / `jest.mock()` | `vi.fn()` / `vi.mock()` (with `globals: true`, `describe/it/expect` stay as they are) |
| MSW v1 `rest.get(url, (req, res, ctx) => res(ctx.json(x)))` | MSW v2 `http.get(url, () => HttpResponse.json(x))` |
| The root import of `@testing-library/jest-dom` | `@testing-library/jest-dom/vitest` |
| `fireEvent.change(input, ...)` | `await userEvent.type(input, ...)` — reproduces the real input event order |
| Adding `import React from 'react'` out of habit | Unnecessary under `jsx: "react-jsx"` |
| `const enum` / `enum` | A literal union + `as const` |

### ② Confusable pairs

| The pair that gets confused | When each actually applies |
| --- | --- |
| `getBy*` vs `queryBy*` vs `findBy*` | `getBy` means it must be there (fails immediately if not), `queryBy` is **only for asserting absence**, `findBy` is for something that appears asynchronously |
| `as T` vs a type guard | An assertion only silences the compiler; it changes nothing at runtime. External data gets a guard |
| `unknown` vs `any` | Take external input as `unknown`. `any` is contagious and disables type checking |
| `interface` vs `type` | For props·object shapes, either. Unions·mapped·conditional types are only possible with `type` |
| `import type` vs `import` | Under `verbatimModuleSyntax`, `type` is mandatory on a type-only import — without it a runtime import remains |
| Mashing it down with `?.`/`??` vs narrowing the type | A chain of optional chaining is a sign the type is wrong. Narrow at the boundary and everything below is clean |
| A hook test vs a component test | When a hook holds complex cache·invalidation logic, `renderHook`. Otherwise a component test catches more |
| Registering MSW handlers globally vs `server.use()` | The default success response is global. A specific test's failure case is overridden with `server.use()` in that test only |
