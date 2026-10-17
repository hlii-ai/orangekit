<!-- orangekit-pack: app/react-native v3.35.0 -->
# Config and testing — the only module that reads environment values · path aliases · the screen test harness

This file owns `src/config.ts` · `tsconfig.json` · `jest.config.js` · `test/setup.ts` · `test/renderWithProviders.tsx`.
Code that reads `EXPO_PUBLIC_*` lives **only in this file**. Injecting values per build profile (`env` in `eas.json`) is owned by `release-and-updates.md`,
and the actual implementations of `http`·`ApiError`·`useTasksQuery` by `api-client.md` — here they are only mocked in tests.

## 1. Decision tree — where does this value live

| Value | Where it goes | Why |
| --- | --- | --- |
| The API address · the app environment name · trusted web origins | `EXPO_PUBLIC_*` → `src/config.ts` | They differ per build and are safe to publish. They are inlined into the JS bundle at build time |
| App name · bundle ID · permission strings · `runtimeVersion` | `app.config.ts` | Values that go into the native binary. Changing them needs a store build (`release-and-updates.md` §1) |
| Config metadata that must be read at runtime | `extra` in `app.config.ts` → `Constants.expoConfig?.extra` | It ships in the manifest — **also public** |
| Client secrets · signing keys · third-party API keys (billed ones) | **The server** | Anyone who unpacks the binary can read the app bundle and the manifest. The app has no secrets |
| Per-user tokens | `tokenStore` (`secure-storage.md`) | Not a build value but one received at runtime |

The question to ask: **"What happens if a competitor pulls this value out of the app and uses it?"** If it enables billing·account impersonation, the server makes that call instead.

## 2. `src/config.ts` — validate at boot and throw

The bundler substitutes only **static member access** like `process.env.EXPO_PUBLIC_X` (both dot notation and bracket access with a string literal).
Variable keys (`process.env[name]`) and destructuring are not substituted and become `undefined` in a release build.
<!-- verified: babel-preset-expo@57.0.15 build/plugins/inline-env-vars.js toMemberProperty — only Identifier·StringLiteral are accepted as keys, substituted with valueToNode in production -->

<!-- file: src/config.ts -->
```ts
// src/config.ts
export type AppEnv = 'development' | 'preview' | 'production';
const APP_ENVS: readonly AppEnv[] = ['development', 'preview', 'production'];

function required(name: string, value: string | undefined): string {
  const v = value?.trim();
  if (!v) throw new Error(`Environment variable ${name} is empty`);
  return v;
}

function toUrl(name: string, raw: string): URL {
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new Error(`Environment variable ${name} is not a URL: ${raw}`);
  }
  // A URL carrying credentials puts a secret in the bundle — block it before origin silently strips them
  if (url.username || url.password) throw new Error(`Environment variable ${name} contains credentials`);
  return url;
}

function parseAppEnv(raw: string): AppEnv {
  const found = APP_ENVS.find((e) => e === raw);
  if (!found) throw new Error(`Environment variable EXPO_PUBLIC_APP_ENV must be one of ${APP_ENVS.join('|')}: ${raw}`);
  return found;
}

function parseApiBaseUrl(raw: string, appEnv: AppEnv): string {
  const url = toUrl('EXPO_PUBLIC_API_BASE_URL', raw);
  const devHttp = appEnv === 'development' && url.protocol === 'http:';
  if (url.protocol !== 'https:' && !devHttp) {
    throw new Error(`Environment variable EXPO_PUBLIC_API_BASE_URL must be https: ${raw}`);
  }
  if (url.search !== '' || url.hash !== '') {
    throw new Error(`Environment variable EXPO_PUBLIC_API_BASE_URL must not carry a query·hash: ${raw}`);
  }
  return (url.origin + url.pathname).replace(/\/+$/, ''); // strip only trailing slashes — http joins it as `${base}${path}`
}

// Optional values — used only when the auth variant is oidc. Both empty is null; only one set is a config mistake, so it throws
function parseOidc(issuer: string | undefined, clientId: string | undefined): { issuer: string; clientId: string } | null {
  const [i, c] = [issuer?.trim() ?? '', clientId?.trim() ?? ''];
  if (!i && !c) return null;
  if (!i || !c) throw new Error('Environment variables EXPO_PUBLIC_OIDC_ISSUER·EXPO_PUBLIC_OIDC_CLIENT_ID must be set together');
  if (toUrl('EXPO_PUBLIC_OIDC_ISSUER', i).protocol !== 'https:') throw new Error(`Environment variable EXPO_PUBLIC_OIDC_ISSUER must be https: ${i}`);
  return { issuer: i.replace(/\/+$/, ''), clientId: c }; // so appending the discovery path does not produce //
}

// An optional value — apps with no webview leave it empty. An empty array makes isTrustedOrigin false for everything (fail-closed)
function parseWebOrigins(raw: string | undefined): string[] {
  const parts = (raw ?? '').split(',').map((s) => s.trim()).filter((s) => s !== '');
  return parts.map((p) => {
    const url = toUrl('EXPO_PUBLIC_WEB_ORIGINS', p);
    if (url.protocol !== 'https:') throw new Error(`Environment variable EXPO_PUBLIC_WEB_ORIGINS allows only https: ${p}`);
    return url.origin; // normalizes case·default port·path — isTrustedOrigin compares by exact match
  });
}

const appEnv = parseAppEnv(required('EXPO_PUBLIC_APP_ENV', process.env.EXPO_PUBLIC_APP_ENV));

export const config: {
  apiBaseUrl: string;
  appEnv: AppEnv;
  trustedWebOrigins: readonly string[];
  oidc: { issuer: string; clientId: string } | null;
} = {
  apiBaseUrl: parseApiBaseUrl(required('EXPO_PUBLIC_API_BASE_URL', process.env.EXPO_PUBLIC_API_BASE_URL), appEnv),
  appEnv,
  trustedWebOrigins: parseWebOrigins(process.env.EXPO_PUBLIC_WEB_ORIGINS),
  oidc: parseOidc(process.env.EXPO_PUBLIC_OIDC_ISSUER, process.env.EXPO_PUBLIC_OIDC_CLIENT_ID),
};
```

- **Throwing is the feature.** A bad build must die immediately on the first screen to be caught in internal distribution (preview) —
  start quietly with an empty string and every request goes out as a relative path with no visible cause.
- `EXPO_PUBLIC_OIDC_*` (oidc variant only · the client ID is a public value) and `EXPO_PUBLIC_WEB_ORIGINS` are optional. When the web origins are empty it is `[]` and the webview trusts no message. When it has a value it is strict:
  it does not accept `http:` (`isTrustedOrigin` would give `false` anyway, so it is a dead entry, and throwing is what makes the config mistake visible).
- Only the development API allows `http:`, in `development` (a local server). A query·hash in the API address breaks path joining, so it is rejected.
- `URL` is the WHATWG implementation (`whatwg-url-minimum`) the Expo runtime installs — RN's own `URL.origin` is a regex and
  does not normalize case·default ports. <!-- verified: expo@57 src/winter/runtime.native.ts install('URL') · the get origin() regex in react-native@0.86.3 Libraries/Blob/URL.js -->

## 3. `tsconfig.json` — put path aliases directly in this file

<!-- file: tsconfig.json -->
```json
{
  "extends": "expo/tsconfig.base",
  "compilerOptions": {
    "strict": true,
    "paths": {
      "@/*": ["./src/*"]
    }
  },
  "include": ["**/*.ts", "**/*.tsx", ".expo/types/**/*.ts", "expo-env.d.ts"]
}
```

Do not move `paths` into a shared base. jest-expo reads only the `compilerOptions.paths` of **the single file, the project's `tsconfig.json`**,
and turns it into `moduleNameMapper` — it does not follow `extends`.
<!-- verified: jest-expo@57.0.6 src/preset/withTypescriptMapping.js mutateJestMappingFromConfig — only compilerOptions.paths of JSON5.parse(tsconfig.json) -->
The base (`expo/tsconfig.base`) supplies `moduleResolution: bundler` · `jsx: react-jsx` · `customConditions: ["react-native"]`.

## 4. jest config (`jest.config.js` · `test/setup.ts`)

<!-- file: jest.config.js -->
```js
// jest.config.js
/** @type {import('jest').Config} */
module.exports = {
  preset: 'jest-expo',
  setupFiles: ['<rootDir>/test/setup.ts'],
};
```

- **Install `@react-native/jest-preset@0.86` as a devDependency.** It is a peer dependency of jest-expo@57, and without it jest cannot start
  ("The React Native Jest preset that jest-expo relies on has moved to a separate package"). <!-- verified: jest-expo@57.0.6 package.json peerDependencies · running jest without it, jest-preset.js:16 throws this message (confirmed by running) -->
- The global types of `jest`·`it`·`expect` in test files come from `@types/jest@29` — the preset does not supply types.
- **Do not use `transformIgnorePatterns`.** The preset already opens `react-native*` · `@react-native*` · `expo*` · `@expo*` for transformation,
  and every native dependency of this pack matches those prefixes. Override it and you lose the preset's list. <!-- verified: jest-expo@57.0.6 jest-preset.js transformIgnorePatterns -->

| Native dependency | Does jest-expo supply it? | What to do |
| --- | --- | --- |
| Expo modules like `expo-secure-store` · `expo-updates` · `expo-crypto` | Yes — native functions are `jest.fn(async () => {})` | Do not mock them again. Note that `getItemAsync` resolves to `undefined`, not `null` |
| `@react-native-community/netinfo` | Only the native module name — `NetInfo.fetch()` throws while reading `undefined` | Register the library's `jest/netinfo-mock` |
| `@react-native-async-storage/async-storage` | No | Register the library's in-memory mock (below) |
| `react-native-safe-area-context` | No | Register the library's `jest/mock` |

<!-- verified: ran jest-expo@57.0.6 + jest@29 — getItemAsync resolves to undefined · without setup NetInfo.fetch() is a TypeError (isInternetReachable) · AsyncStorage gives "NativeModule: AsyncStorage is null" · all three work with the setup below -->

<!-- file: test/setup.ts -->
```ts
// test/setup.ts
jest.mock('@react-native-async-storage/async-storage', () =>
  require('@react-native-async-storage/async-storage/jest/async-storage-mock'),
);
jest.mock('@react-native-community/netinfo', () => require('@react-native-community/netinfo/jest/netinfo-mock'));
jest.mock('react-native-safe-area-context', () => require('react-native-safe-area-context/jest/mock').default);

// src/config.ts validates the moment it is imported — even when a screen imports it indirectly, missing values throw at load
process.env.EXPO_PUBLIC_APP_ENV = 'development';
process.env.EXPO_PUBLIC_API_BASE_URL = 'https://api.test.invalid';
process.env.EXPO_PUBLIC_WEB_ORIGINS = 'https://web.test.invalid';
process.env.EXPO_PUBLIC_OIDC_ISSUER = 'https://idp.test.invalid'; // the oidc variant requires it at import time — the self-issued variant does not read it
process.env.EXPO_PUBLIC_OIDC_CLIENT_ID = 'test-client';
```

In jest, babel-preset-expo does not inline the values; it rewrites them as references to `env` (= `process.env`) from `expo/virtual/env`, so
the setup's values are read at module load. It is an assignment, not `??=` — so test results do not change with the values in the developer's shell.
<!-- verified: babel-preset-expo@57.0.15 inline-env-vars.js (valueToNode only in production, otherwise an expo/virtual/env reference · assignment expressions skipped) · expo/virtual/env.js `export const env = process.env` · jest-expo run: importing config without the setup gives "EXPO_PUBLIC_APP_ENV is empty", with it, it passes -->

## 5. `test/renderWithProviders.tsx` — a fresh QueryClient per call

In @testing-library/react-native 14, `render` **returns a Promise** — the harness is `async` too, and callers `await` it.
<!-- verified: @testing-library/react-native@14.1.0 dist/render.d.ts `render<T>(…): Promise<{…}>` -->

<!-- file: test/renderWithProviders.tsx -->
```tsx
// test/renderWithProviders.tsx
import type { ReactElement, ReactNode } from 'react';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { render } from '@testing-library/react-native';

export async function renderWithProviders(ui: ReactElement): Promise<Awaited<ReturnType<typeof render>> & { queryClient: QueryClient }> {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false, gcTime: Infinity }, mutations: { retry: false } },
  });
  const Wrapper = ({ children }: { children: ReactNode }) => <QueryClientProvider client={queryClient}>{children}</QueryClientProvider>;
  const result = await render(ui, { wrapper: Wrapper });
  return { ...result, queryClient };
}
```

- **Do not use the shared singleton `queryClient` (`@/lib/queryClient`)** — the previous test's cache fills the next test's first render and skips the loading state.
- `retry: false` — the app config retries 5xx twice. An error-state test waits out the retry delay and times out.
- `gcTime: Infinity` — a finite `gcTime` sets a `setTimeout` when a query goes inactive. The timer left after the test holds up jest's exit.
  With `Infinity`, no timer is set. <!-- verified: @tanstack/query-core@5.104.3 removable.js scheduleGc·utils.js isValidTimeout (Infinity excluded) · compared by running: the same screen test with gcTime 300000 hung on "Jest did not exit" until the 60-second limit, with Infinity it exited in 3 seconds -->

## 6. Screen tests — cut the HTTP boundary with `jest.mock`

A screen calls `http` through `useTasksQuery` (both in `api-client.md`). Cut the boundary at `@/api/http` —
mock all the way to the hook and the real wiring, such as query keys·page flattening, goes untested. `ApiError` must stay real for `instanceof` to hold.

```tsx
// test/screens/TasksScreen.test.tsx
import { screen } from '@testing-library/react-native';
import { http } from '@/api/http';
import TasksScreen from '@/app/(app)/tasks/index';
import { renderWithProviders } from '../renderWithProviders';

jest.mock('@/api/http', () => ({
  ...jest.requireActual<typeof import('@/api/http')>('@/api/http'),
  http: { get: jest.fn(), getPage: jest.fn(), post: jest.fn(), patch: jest.fn(), delete: jest.fn() },
}));
const getPage = jest.mocked(http.getPage);

beforeEach(() => {
  getPage.mockReset();
});

it('draws the list when there are tasks, and the empty state when there are none', async () => {
  getPage.mockResolvedValueOnce({ items: [{ id: 't1', title: 'First task', status: 'open', createdAt: '2026-10-17T00:00:00Z' }], nextCursor: null });
  await renderWithProviders(<TasksScreen />);
  expect(await screen.findByText('First task')).toBeOnTheScreen();
  expect(screen.queryByText('No tasks yet')).toBeNull();
});
```

**Do not put screen tests under `src/app/` (including `__tests__`)** — expo-router bundles every `.tsx` under the app root as a route
with `require.context`. <!-- verified: the require.context regex in expo-router@57 _ctx.ios.js·_ctx.android.js — only +api·+html·+middleware are excluded -->
`@/` points only at `src/`, so imports within `test/` are relative paths. `jest.mock` factories are hoisted to the top of the file.

## 7. Proving the block — does config validation actually block

`config` is evaluated at module load. To evaluate it again per value, `require` it in a fresh module registry with `jest.isolateModules`.
**Put the blocking assertion and the passing assertion in the same `it`** — without the passing assertion, the test stays green even if `config.ts` breaks into always throwing.

```ts
// test/config.test.ts
const BASE = { EXPO_PUBLIC_APP_ENV: 'production', EXPO_PUBLIC_API_BASE_URL: 'https://api.example.com/' };

function load(env: Record<string, string>) {
  const saved = { ...process.env };
  Object.assign(process.env, BASE, env);
  try {
    let mod: typeof import('@/config') | undefined;
    jest.isolateModules(() => { mod = require('@/config'); });
    return mod!.config;
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved); // do not swap the object out — expo/virtual/env holds the original object
  }
}

it('throws at boot for a non-https web origin, and normalizes https to an origin', () => {
  expect(() => load({ EXPO_PUBLIC_WEB_ORIGINS: 'http://web.example.com' })).toThrow('allows only https');
  const ok = load({ EXPO_PUBLIC_WEB_ORIGINS: 'HTTPS://Web.Example.com:443/path , https://help.example.com' });
  expect(ok.trustedWebOrigins).toEqual(['https://web.example.com', 'https://help.example.com']);
  expect(ok.apiBaseUrl).toBe('https://api.example.com'); // the http call site appends the path (/api/tasks)
  expect(load({ EXPO_PUBLIC_WEB_ORIGINS: '' }).trustedWebOrigins).toEqual([]); // an app with no webview
});
```

<!-- verified: ran under jest-expo@57 — this test passes · it fails on each of 2 mutants (web origin https check removed / module always throws). In 3.35.0 the API address input was changed to the form without /v1, and this was not rerun -->

## Misuse list ① — web·old-version habits → the current shape in Expo SDK 57

| Old habit | Current shape |
| --- | --- |
| Reading `.env` with `react-native-config` · `react-native-dotenv` | `EXPO_PUBLIC_*` + `src/config.ts`. The Expo CLI reads `.env` and babel-preset-expo inlines it |
| Reading `process.env.API_URL` directly on every screen | `config.apiBaseUrl` — validation happens once, in one place |
| `const { EXPO_PUBLIC_API_BASE_URL } = process.env` | Destructuring is not substituted — only literal member access |
| `Constants.manifest?.extra` | `Constants.expoConfig?.extra` — `manifest` is `@deprecated` in the install <!-- verified: expo-constants@57 build/Constants.types.d.ts:153 --> |
| `cacheTime: Infinity` | `gcTime` — the install has no `cacheTime` <!-- verified: grep over all of @tanstack/query-core@5.104.3 build/modern — 0 occurrences of cacheTime, gcTime present in removable.js·d.ts --> |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `EXPO_PUBLIC_*` vs `extra` | Both are public. The only difference is lifetime — `EXPO_PUBLIC_*` is in the JS bundle (changes over OTA), `extra` is in the manifest |
| `process.env.EXPO_PUBLIC_X` vs `process.env[key]` | Only the former is inlined. The latter is `undefined` in a release build |
| A shared `queryClient` vs a fresh client per test | The app uses the former, tests the latter — otherwise the cache leaks between tests |
| `jest.mock('@/api/http')` (automock) vs a factory + `requireActual` | An automock empties even the `ApiError` constructor and the fields vanish. Replace only `http` with a factory |
