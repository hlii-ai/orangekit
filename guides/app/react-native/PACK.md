<!-- orangekit-pack: app/react-native v3.35.0 verified 2026-10-15 expo@57 react@19 react-native@0.86 typescript@6 @types/react@19 expo-router@57 expo-secure-store@57 expo-crypto@57 expo-linking@57 expo-constants@57 expo-location@57 expo-camera@57 expo-notifications@57 expo-updates@57 expo-auth-session@57 expo-web-browser@57 react-native-webview@13 react-native-safe-area-context@5 @tanstack/react-query@5 zustand@5 @react-native-async-storage/async-storage@2 @react-native-community/netinfo@12 jest-expo@57 @react-native/jest-preset@0.86 jest@29 @types/jest@29 @testing-library/react-native@14 -->

# react-native axis pack — hub fragment

This is the **axis-local fragment inserted verbatim** into the hub (`HUB.md` → installed as `app-guide/SKILL.md`). Each fragment
sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and holds for any backend that follows the wire contract
`http-standard@1`, and whether the app is a shell or the product itself. Only what is a function of the shape is missing here — the table at the end of the file states what remains.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
src/
├── app/                        # Expo Router routes — one file is one screen
│   ├── _layout.tsx             # Root: Provider assembly · wireQueryManagers() · Stack + Stack.Protected
│   ├── sign-in.tsx             # Unprotected screen
│   ├── (app)/                  # Protected group — opens only after sign-in
│   │   ├── _layout.tsx         # Tabs (`expo-router/js-tabs` — the root `Tabs` is deprecated in SDK 57)
│   │   ├── settings.tsx        # Settings tab
│   │   └── tasks/
│   │       ├── _layout.tsx     # Stack — stacks list → detail inside the tab (Tabs' name="tasks" points here)
│   │       ├── index.tsx       # List
│   │       └── [id].tsx        # Detail (deep link target)
│   └── +not-found.tsx          # Keep test files outside src/app/ — files in the route directory are bundled as routes
├── config.ts                   # The **only** file that reads EXPO_PUBLIC_* environment values
├── api/                        # http.ts (client · ApiError) · tasks.ts (query hooks) · outboxSend.ts
├── auth/
│   └── useAuth.ts              # Auth variant (self-issued · oidc) — useAuth · getAccessToken · refresh · endSession
├── lib/
│   ├── tokenStore.ts           # expo-secure-store wrapper — tokens live here and nowhere else
│   ├── safeInternalHref.ts     # Path validation for deep links·notification payloads
│   ├── idempotency.ts          # Idempotency keys
│   ├── queryClient.ts          # QueryClient for RN + focus·online manager wiring
│   ├── toUserMessage.ts        # Error → user-facing message
│   └── appVersion.ts           # Forced-update decision
├── offline/
│   └── outbox.ts               # Offline mutation queue (persisted in AsyncStorage)
├── device/
│   ├── permissions.ts          # usePermission — runtime permissions
│   └── push.ts                 # registerForPushAsync — push token issuance
├── webview/
│   └── trustedOrigin.ts        # isTrustedOrigin — webview origin validation
├── components/
│   └── ScreenStates.tsx        # LoadingView · EmptyView · ErrorView
└── stores/                     # Zustand — no server data allowed in
test/
└── renderWithProviders.tsx     # Screen test harness
app.config.ts                   # App config · config plugins · permission strings · runtimeVersion
eas.json                        # Build profiles · update channels
```
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles

### 1. Server data is owned by TanStack Query
Copy a response into the store (Zustand) and you get a second copy that invalidation·retry·focus revalidation never reach. The store holds UI state only, such as filters and modals.

```tsx
// ✅ The list reads from the query cache; the store holds UI state only
const { data } = useTasksQuery();
const useTaskFilter = create<{ onlyOpen: boolean; toggle: () => void }>()((set) => ({
  onlyOpen: false,
  toggle: () => set((s) => ({ onlyOpen: !s.onlyOpen })),
}));
// ❌ Copying the response into the store — updates land only in the cache and this copy goes stale
useEffect(() => { if (data) useTaskStore.getState().setTasks(data.pages.flatMap((p) => p.items)); }, [data]);
```

### 2. HTTP goes through `http` and nothing else
The auth header·`Idempotency-Key`·`ApiError` normalization all live in one place, `http`. A raw call bypasses all three, and `ErrorView` cannot pick a message.

```ts
// ✅ Even inside a query hook's queryFn, go through http
const page = await http.getPage<Task>(`/api/tasks?cursor=${encodeURIComponent(cursor)}`);
// ❌ Raw fetch — the token·idempotency header·error normalization diverge
const res = await fetch(`${config.apiBaseUrl}/api/tasks`);
```

### 3. Tokens live in `tokenStore` only
AsyncStorage is an unencrypted plaintext store. `tokenStore` wraps `expo-secure-store` (iOS Keychain · Android Keystore) and pins the accessibility level. Screens never touch tokens.

```ts
// ✅ Store and delete only through tokenStore
await tokenStore.set({ accessToken, refreshToken, expiresAt: Date.now() + expiresIn * 1000 });
await tokenStore.clear();
// ❌ A token in a plaintext store
await AsyncStorage.setItem('accessToken', accessToken);
```

### 4. No secrets in the bundle
`EXPO_PUBLIC_*` is inlined into the JS bundle at build time — anyone who unpacks the app binary can read it. Keep only values that are safe to publish, and read them in exactly one place, `src/config.ts`. Calls that need a secret are made by the server.

```ts
// ✅ Public values only, read through config
const trusted = isTrustedOrigin(url, config.trustedWebOrigins);
// ❌ A secret in a public env var — and read directly outside config
const secret = process.env.EXPO_PUBLIC_CLIENT_SECRET;
```

### 5. Paths from outside pass through `safeInternalHref`
Deep links · notification payloads · `returnTo` are values an attacker can choose. Validate them as internal paths before handing them to the router, and send failures to `/tasks`.

```ts
// ✅ Notification tap → validate the payload path, then navigate
const raw = response.notification.request.content.data?.path;
router.push(safeInternalHref(typeof raw === 'string' ? raw : null));
// ❌ Handing the payload straight to the router — external URLs·app schemes get through
router.push(raw as string);
```

### 6. Ask for a permission at the moment the feature is used
Asking for everything at app start raises the denial rate, and once permanently denied (`blocked`) the OS dialog never appears again. Only read the state on mount, and steer `blocked` to the Settings app.

```tsx
// ✅ Ask at the moment the user presses the capture button
const camera = usePermission('camera');
const onScanPress = async () => {
  if (camera.state === 'blocked') return camera.openSettings();
  if (await camera.request()) setScannerOpen(true);
};
// ❌ Asking for everything at app start
useEffect(() => { Camera.requestCameraPermissionsAsync(); Location.requestForegroundPermissionsAsync(); }, []);
```

### 7. The idempotency key is generated once, when the mutation is "created"
Generate it at send time and every retry·resend gets a new key, so the server applies the same mutation twice. For offline mutations `outbox.enqueue` creates the key, so the caller does not pass one.

```ts
// ✅ Once, the moment the user presses "Save" — online, create the key and attach it; retries reuse the same key
if (onlineManager.isOnline()) {
  createTask.mutate({ title, key: newIdempotencyKey() });
} else {
  // ✅ Offline, the queue only — enqueue creates the key (take both paths and the same mutation goes out twice under different keys)
  await outbox.enqueue({ method: 'POST', path: '/api/tasks', body: { title } });
}
// ❌ Generated inside mutationFn — a new key on every retry
useMutation({ mutationFn: (title: string) => http.post('/api/tasks', { title }, { idempotencyKey: newIdempotencyKey() }) });
```
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

```tsx
import { useEffect, useState } from 'react';
import { FlatList, Pressable, RefreshControl, Text, View } from 'react-native';
import { Stack, router, useLocalSearchParams } from 'expo-router';
import { Tabs } from 'expo-router/js-tabs';
import { useMutation, useQueryClient, QueryClientProvider } from '@tanstack/react-query';
import { create } from 'zustand';
import * as SecureStore from 'expo-secure-store'; // only inside src/lib/tokenStore.ts
import Constants from 'expo-constants';

import { config } from '@/config';
import { tokenStore, type Tokens } from '@/lib/tokenStore';
import { safeInternalHref } from '@/lib/safeInternalHref';
import { newIdempotencyKey } from '@/lib/idempotency';
import { queryClient, wireQueryManagers } from '@/lib/queryClient';
import { toUserMessage } from '@/lib/toUserMessage';
import { isUpdateRequired } from '@/lib/appVersion';
import { outbox, type OutboxOp, type SendResult } from '@/offline/outbox';
import { LoadingView, EmptyView, ErrorView } from '@/components/ScreenStates';
import { usePermission, type PermissionKind, type PermissionState } from '@/device/permissions';
import { registerForPushAsync } from '@/device/push';
import { isTrustedOrigin } from '@/webview/trustedOrigin';
import { http, ApiError, type Page } from '@/api/http';
import { useTasksQuery, useTaskQuery, useCreateTask, useSetTaskStatus, taskKeys, type Task } from '@/api/tasks';
import { useAuth } from '@/auth/useAuth'; // defined by the auth variant — screens use only status · signIn · signOut
```

Import `Tabs` from `expo-router/js-tabs` — the `Tabs` export at the `expo-router` root is deprecated in the SDK 57 install. <!-- verified: the `@deprecated Use import { Tabs } from 'expo-router/js-tabs'` comment in expo-router@57 build/exports.d.ts -->
Do not import `SafeAreaView` from `react-native` — it is deprecated in the 0.86 install. <!-- verified: @deprecated in react-native@0.86.3 Libraries/Components/SafeAreaView/SafeAreaView.d.ts -->
<!-- /pack-slot -->

<!-- pack-slot: component-template -->
## Screen Template

```tsx
// src/app/(app)/tasks/index.tsx
import { FlatList, RefreshControl } from 'react-native';
import { router } from 'expo-router';
import { useTasksQuery } from '@/api/tasks';
import { LoadingView, EmptyView, ErrorView } from '@/components/ScreenStates';
import { TaskRow } from '@/components/TaskRow';

export default function TasksScreen() {
  const { data, isPending, isError, error, refetch, isRefetching, fetchNextPage, hasNextPage, isFetchingNextPage } =
    useTasksQuery();

  if (isPending) return <LoadingView />;
  // When data is already there, a failed revalidation does not wipe the list — the error screen is only for when there is nothing to show
  if (isError && !data) return <ErrorView error={error} onRetry={() => refetch()} />;

  const tasks = data.pages.flatMap((p) => p.items);
  if (tasks.length === 0) return <EmptyView title="No tasks yet" />;

  return (
    <FlatList
      data={tasks}
      keyExtractor={(t) => t.id}
      renderItem={({ item }) => <TaskRow task={item} onPress={() => router.push(`/tasks/${item.id}`)} />}
      refreshControl={<RefreshControl refreshing={isRefetching} onRefresh={() => refetch()} />}
      onEndReached={() => { if (hasNextPage && !isFetchingNextPage) fetchNextPage(); }}
      onEndReachedThreshold={0.5}
    />
  );
}
```

- **Branch on the three states in order** — loading → error → empty → list. Drop the `isPending` branch and `data` is `undefined` on the first render, so `flatMap` throws.
- **Pass `onRetry` only when a retry can change the outcome** — the template always passes it, but when you are separating out errors that come back the same however often you reload, like 401·403·404, branch on the `code` of `ApiError` and do not pass it (the button disappears). `ErrorView` picks the message with `toUserMessage` — never put `error.message` on screen.
- **Long lists are `FlatList`** — `ScrollView` + `map` mounts every row at once. Guard `onEndReached` with `isFetchingNextPage` so the same page is not requested twice.
- **Screens never touch HTTP·tokens** — data arrives only through `useTasksQuery()` (`api-client.md`). What `TaskRow` looks like is the project's design.
<!-- /pack-slot -->

## What the seam fills in — what this pack does not have

From 3.35.0, Architecture Overview · Quick Start · the HTTP·auth rows of Common Imports · `api-client.md` · `auth-and-session.md` (auth variant) ·
`complete-example.md` · Navigation Guide **are filled by the pack** — the whole hub is `HUB.md`. There is one wire contract, `http-standard@1`,
and only the auth method splits into variants (`variants/auth/self-issued` · `variants/auth/oidc`). What remains is one function of the shape.

| Hub slot · seam file | Why it is a function of the shape |
| --- | --- |
| `shell-bridge.md` (only when the shape is `rn-webview`·`rn-native-screens` — generated per project) | The web ↔ native message schema · which screens are webviews and which are native · screen transition rules. The message schema is a contract shared with the web screen axis. Origin validation uses the pack's `isTrustedOrigin` primitive — do not rewrite it. **Put the web-side CSP `frame-src` in the contract** — old Android WebViews cannot tell which iframe sent a message. Even in a shell, the app's own sign-in is done by this pack's auth variant |
