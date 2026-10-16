<!-- orangekit-pack: app/react-native v1.0.0 -->
# Navigation — file routes · protected groups · deep link validation

This file owns the skeletons of `src/app/_layout.tsx` · `(app)/_layout.tsx` · `(app)/tasks/_layout.tsx`, plus `src/lib/safeInternalHref.ts` ·
`src/lib/useNotificationRouting.ts`.
The state transitions of `useAuth` and the sign-out cleanup order are owned by the seam's `auth-and-session.md`; in a hybrid shell, **which
screens are webviews** and the web ↔ native message schema are owned by the seam's `shell-bridge.md` — the rules in this file hold the same
for native routes whether the app is a shell or the product itself.

## 1. Decision tree — where does a screen go

| Question | Yes → | No → |
| --- | --- | --- |
| Is it visible only after sign-in? | Inside the `src/app/(app)/` group | The root (`sign-in.tsx`) |
| Is it a top-level app menu (bottom tab)? | A `Tabs` child of `(app)/_layout.tsx` | Continue below |
| Do you come back to it with Back, like list → detail? | A screen inside a `Stack` (`tasks/[id].tsx`) | Continue below |
| Does it float briefly over the current context and close? (compose · confirm) | `Stack.Screen options={{ presentation: 'modal' }}` | A regular `Stack` screen |
| Does an identifier go in the path? | A dynamic segment `[id].tsx` — deep links reach it directly | A query parameter |

The `(app)` group does not appear in the URL — `/tasks/42` goes to `src/app/(app)/tasks/[id].tsx`. The protection check sits at **one
group boundary** (`Stack.Protected`). Scatter `if (!signedIn) router.replace(...)` across screens and missing it in a single place
opens the screen. That said, this is UX — the real block is the server returning 401·403.

## 2. The root layout (`src/app/_layout.tsx`)

Provider assembly order: `SafeAreaProvider` → `QueryClientProvider` → navigator. The screen state components and the query hooks
must both run inside it. Call `wireQueryManagers()` **exactly once** in a `useEffect` and return its unsubscribe function as is
(`data-and-offline.md` §2 — call it in the render body and it is torn down and re-registered on every render). The queue send trigger
`useOutboxSync` (`data-and-offline.md`) and notification navigation `useNotificationRouting` (§5) are each called here exactly once.

<!-- file: src/app/_layout.tsx -->
```tsx
// src/app/_layout.tsx
import { useEffect } from 'react';
import { Stack } from 'expo-router';
import { QueryClientProvider } from '@tanstack/react-query';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { queryClient, wireQueryManagers } from '@/lib/queryClient';
import { useAuth } from '@/auth/useAuth';
import { useNotificationRouting } from '@/lib/useNotificationRouting';
import { useOutboxSync } from '@/offline/useOutboxSync';

function RootNavigator() {
  const { status } = useAuth();
  // Both act only after sign-in — nothing is sent or navigated before the verdict or while signed out
  useNotificationRouting(status === 'signedIn');
  useOutboxSync(status === 'signedIn');
  // Pick no screen before the verdict — drawing sign-in here makes it flash on every cold start
  if (status === 'loading') return null;
  return (
    <Stack screenOptions={{ headerShown: false }}>
      <Stack.Protected guard={status === 'signedIn'}>
        <Stack.Screen name="(app)" />
      </Stack.Protected>
      <Stack.Protected guard={status === 'signedOut'}>
        <Stack.Screen name="sign-in" />
      </Stack.Protected>
    </Stack>
  );
}

export default function RootLayout() {
  useEffect(() => wireQueryManagers(), []);
  return (
    <SafeAreaProvider>
      <QueryClientProvider client={queryClient}>
        <RootNavigator />
      </QueryClientProvider>
    </SafeAreaProvider>
  );
}
```

Drawing `null` during `loading` shows an empty frame for a moment. `SplashScreen.preventAutoHideAsync`, which holds the native splash
until the verdict, only works when the `expo-splash-screen` native module is present (without it, it does nothing), and that package
is not in this pack's pkgs — to use it, the project installs it and adds the plugin to `app.config.ts`. <!-- verified: expo-router@57.0.27 build/utils/splash.js — without requireOptionalNativeModule('ExpoSplashScreen'), hide·preventAutoHideAsync return immediately -->

When `guard` turns `false`, the screens inside it drop out of the stack and a user who had one open is moved to the first accessible
screen — do not call `router.replace('/sign-in')` separately after sign-out. <!-- unverified: the relocation behavior on a guard switch was not traced through the installed source -->

## 3. The tab layout (`src/app/(app)/_layout.tsx`)

Import `Tabs` from `expo-router/js-tabs`. <!-- verified: the `@deprecated Use import { Tabs } from 'expo-router/js-tabs'` comment in expo-router@57.0.27 build/exports.d.ts · js-tabs.d.ts re-exports build/layouts/Tabs -->

```tsx
// src/app/(app)/_layout.tsx
import { Tabs } from 'expo-router/js-tabs';

export default function AppTabs() {
  return (
    <Tabs screenOptions={{ headerShown: false }}>
      <Tabs.Screen name="tasks" options={{ title: 'Tasks' }} />
      <Tabs.Screen name="settings" options={{ title: 'Settings' }} />
    </Tabs>
  );
}
```

`Tabs.Screen name="tasks"` points at `tasks/_layout.tsx` (a Stack), the layout of the `tasks/` directory — **it is required.**
List → detail stacks up inside this Stack, so Back from the detail returns to the list in the same tab. `settings` is the single screen
`(app)/settings.tsx`.

```tsx
// src/app/(app)/tasks/_layout.tsx
import { Stack } from 'expo-router';

export default function TasksStack() {
  return (
    <Stack>
      <Stack.Screen name="index" options={{ title: 'Tasks' }} />
      <Stack.Screen name="[id]" options={{ title: 'Task details' }} />
    </Stack>
  );
}
```

## 4. Dynamic segments and narrowing params

The value type of `useLocalSearchParams()` is `string | string[]` — when the same key comes twice in the query, it is an array. If a
screen asserts `string`, a single `?id=1&id=2` makes a call like `.trim` blow up at runtime. <!-- verified: expo-router@57.0.27 build/typed-routes/types.d.ts:89 UnknownOutputParams = Record<string, string | string[]> -->

```tsx
// src/app/(app)/tasks/[id].tsx
import { useLocalSearchParams } from 'expo-router';
import { EmptyView } from '@/components/ScreenStates';

const first = (v: string | string[] | undefined): string | undefined => (Array.isArray(v) ? v[0] : v);

export default function TaskDetailScreen() {
  const id = first(useLocalSearchParams<{ id: string | string[] }>().id);
  // Call the detail query hook (owned by the seam's api-client.md) **above** this return with `enabled: !!id` —
  // put it after the return and the hook count changes with whether id exists, so React raises a hook-order error
  if (!id) return <EmptyView title="Task not found" />;
  return null; // rendering the detail is project screen code
}
```

Turn on `experiments.typedRoutes` in `app.config.ts` and the argument of `router.push` becomes a union of generated path literals,
so a `string` built at runtime is not assignable — it is a value that passed validation, so assert it with `as Href` at the call site. <!-- verified: expo-router@57.0.27 build/typed-routes/types.d.ts:51-53 Href = T['href'] (when generated types exist) · the generated file was not produced -->

## 5. Deep links — paths from outside pass through `safeInternalHref`

With `scheme: 'myapp'` in `app.config.ts`, Expo Router itself opens `myapp://tasks/42` as the `/tasks/42` route —
this path goes through route matching only, so it never leaves the app. The danger is **when we hand a value a link·notification
carried to the router**. When `router.push` receives a value like `//host` · `https:` · `tel:` · `myapp://`, it calls
`Linking.openURL` instead of routing. <!-- verified: expo-router@57.0.27 build/global-state/router.js:139-144 linkTo → Linking.openURL when shouldLinkExternally · build/utils/url.js:13-24 -->

Notification tap — the payload is a value that went through the server·sending tool, and its shape cannot be trusted. This hook is
**the only place notification responses are handled** (the push flow in `permissions-and-devices.md` calls it too — do not attach a
separate response listener). While `ready` is `false` (before the verdict·signed out) it **preserves the response without consuming
it** — before the verdict the `guard` of the `(app)` group is closed, so there is no target screen, and a cold-start notification tap
arrives at exactly that moment. After navigating, it consumes the response with `clearLastNotificationResponse()` so a
remount·re-sign-in does not navigate again on the same response — clearing it also returns `useLastNotificationResponse` to `null`. <!-- verified: expo-notifications@57 build/NotificationsEmitter.js:136-143 emits a cleared event after clear · addNotificationResponseClearedListener in useLastNotificationResponse.js → setLastNotificationResponse(null) -->

<!-- file: src/lib/useNotificationRouting.ts -->
```ts
// src/lib/useNotificationRouting.ts
import { useEffect } from 'react';
import { router } from 'expo-router';
import * as Notifications from 'expo-notifications';
import { safeInternalHref } from '@/lib/safeInternalHref';

export function useNotificationRouting(ready: boolean): void {
  const response = Notifications.useLastNotificationResponse();
  useEffect(() => {
    if (!ready || !response) return;
    if (response.actionIdentifier !== Notifications.DEFAULT_ACTION_IDENTIFIER) return;
    const raw: unknown = response.notification.request.content.data?.path;
    router.push(safeInternalHref(typeof raw === 'string' ? raw : null));
    Notifications.clearLastNotificationResponse(); // consume — never navigate twice on the same response
  }, [ready, response]);
}
```

A relay route — when an email·web page opens a specific app screen with `myapp://open?to=/tasks/42`. The attacker chooses `to`.

```tsx
// src/app/(app)/open.tsx
import { useEffect } from 'react';
import { router, useLocalSearchParams } from 'expo-router';
import { safeInternalHref } from '@/lib/safeInternalHref';

export default function OpenRedirect() {
  const { to } = useLocalSearchParams<{ to?: string | string[] }>();
  const target = Array.isArray(to) ? to[0] : to;
  useEffect(() => { router.replace(safeInternalHref(target)); }, [target]);
  return null;
}
```

`redirectSystemPath({ path })` in `+native-intent.tsx` receives **the full URL including the scheme** — put it into `safeInternalHref`
as is and, being an app scheme, everything falls to the fallback path. There, parse the URL, take out only the path, and pass that in. <!-- verified: expo-router@57.0.27 build/link/linking.js:117-121 — the url of the Linking 'url' event is passed as path unchanged after applyRedirects -->

## 6. `safeInternalHref` (`src/lib/safeInternalHref.ts`)

RN has no `window.location`. Build a `new URL` against a fixed dummy origin and judge in two layers — layer 1 is the **raw value**
(the URL parser deletes control characters·backslashes or turns them into `/`, so reject them **before** normalization), layer 2 is the
**output after** normalization (`/..//host` starts with `/` and has the same origin as a raw value, but becomes `//host` once the dot
segments resolve).

<!-- file: src/lib/safeInternalHref.ts -->
```ts
// src/lib/safeInternalHref.ts
const ORIGIN = 'https://app.invalid';
// Control characters (C0 · DEL) and backslashes — block characters the parser silently fixes before normalization
const UNSAFE_RAW = /[\u0000-\u001f\u007f\\]/;

export function safeInternalHref(raw: string | null | undefined, fallback = '/tasks'): string {
  if (typeof raw !== 'string' || raw === '' || UNSAFE_RAW.test(raw)) return fallback;
  // Schemes (https: · javascript: · myapp:) · relative paths · protocol-relative (//host) end at the raw-value stage
  if (!raw.startsWith('/') || raw.startsWith('//')) return fallback;

  let url: URL;
  try {
    url = new URL(raw, ORIGIN);
  } catch {
    return fallback;
  }
  if (url.origin !== ORIGIN) return fallback;

  // Output after normalization — /..//host becomes //host here
  const path = url.pathname;
  if (!path.startsWith('/') || path.startsWith('//') || path.startsWith('/\\')) return fallback;
  return path + url.search + url.hash;
}
```

| Input | Result | Layer that blocks it |
| --- | --- | --- |
| `//evil.example` · `https://evil.example` · `javascript:alert(1)` · `myapp://x` · `%2f%2fevil.example` | fallback | Raw value (does not start with `/`, or `//`) |
| `/\evil.example` · `\tjavascript:alert(1)` · `/tasks\n\rSet-Cookie: x=1` | fallback | Raw value (backslash · control character) |
| `/..//evil.example` · `/../..//evil.example` | fallback | Output (`//`) |
| `''` · `null` · `undefined` | fallback | Type·empty value |
| `/tasks/42?x=1#a` | `/tasks/42?x=1#a` | Passes |

Every input in the table plus `/%2f%2fevil.example` (→ `/%2f%2fevil.example` unchanged — a nonexistent path on the same origin, so it
goes to not-found) was run through both Node 24's `URL` and the `whatwg-url-minimum` that the Expo native runtime installs globally,
with identical results. A mutant with the output recheck deleted returned `//evil.example` for `/..//evil.example` — layer 2 is not decoration. <!-- verified: ran this fence directly with node --experimental-strip-types · expo@57.0.29 src/winter/runtime.native.ts:21 install('URL') → whatwg-url-minimum. Not verified on a device -->

## 7. Screen error boundaries — a route's `ErrorBoundary` export

An error thrown during render is caught by the `ErrorBoundary` exported from the same file. Without one it bubbles up to the parent
layout's boundary, and if there is none all the way up, a full-screen error appears. `retry()` re-renders that route. <!-- verified: expo-router@57.0.27 build/views/Try.d.ts ErrorBoundaryProps = { retry: () => Promise<void>; error: Error } -->

```tsx
// src/app/(app)/tasks/[id].tsx (excerpt)
import type { ErrorBoundaryProps } from 'expo-router';
import { ErrorView } from '@/components/ScreenStates';

export function ErrorBoundary({ error, retry }: ErrorBoundaryProps) {
  return <ErrorView error={error} onRetry={() => { void retry(); }} />;
}
```

The boundary is for **render exceptions**. A query failure does not throw; it arrives as `isError`, so the three states of
`screens-and-states.md` take it.

## Misuse list ① — hand-built React Navigation · old-version habits → Expo Router 57

| Old habit | Current shape |
| --- | --- |
| Assembling `NavigationContainer` + `createNativeStackNavigator` by hand | File routes — the files under `src/app/` are the screens |
| `if (!user) return <Redirect href="/sign-in" />` on every screen | One place: the root layout's `Stack.Protected guard` |
| `import { Tabs } from 'expo-router'` | `import { Tabs } from 'expo-router/js-tabs'` <!-- verified: @deprecated comment in expo-router@57.0.27 build/exports.d.ts --> |
| Trusting `route.params.id` as a `string` | `useLocalSearchParams` values are `string \| string[]` — narrow them |
| Navigating from a notification with `Linking.openURL(payload.url)` | `router.push(safeInternalHref(...))` — external URLs are not opened |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `router.push` vs `router.replace` | A notification tap is `push` (Back returns to the original screen). A relay route·right after sign-in is `replace` (so the relay screen does not stay in history) |
| Origin comparison alone vs rechecking the output path | Both. `/..//host` passes with the same origin and then becomes `//host` |
| Expo Router's automatic deep links vs navigating to a payload value | Automatic deep links are route matching and never leave the app. Validation happens when we hand a value to `router` |
| A route `ErrorBoundary` vs the `ErrorView` branch | Render exceptions go to the boundary, query failures to the `isError` branch |
| `null` vs rendering `sign-in` during `loading` | `null`. A sign-in screen before the verdict flashes on every cold start |
