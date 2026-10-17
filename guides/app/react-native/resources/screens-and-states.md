<!-- orangekit-pack: app/react-native v3.35.0 -->
# Screens and states — the loading·empty·error states · lists · keyboard and safe area

This file owns `src/components/ScreenStates.tsx` and `src/lib/toUserMessage.ts`. The query hook (`useTasksQuery`) and the
error code table (the values of `ApiError.code`) are functions of the wire contract, so `api-client.md` owns them, and the
screen test harness `renderWithProviders` is owned by `config-and-testing.md`. In a hybrid shell, showing state on screens drawn in a
webview belongs to the web screen axis (which screens are webviews is in `shell-bridge.md`, generated per project).

## 1. Decision tree — which state is judged first

| Order | Condition | Render | Why this order |
| --- | --- | --- | --- |
| 1 | `isPending` | `<LoadingView />` | There is no data yet — read `data` and it is `undefined` |
| 2 | `isError` | `<ErrorView error={error} onRetry={...} />` | A failed first request has neither an empty list nor data |
| 3 | The flattened list is empty | `<EmptyView />` | It succeeded but has 0 items — that is different from an error |
| 4 | Otherwise | The list | |

`isPending` means "no data in the cache" and `isLoading` is `isPending && isFetching`. On an online first render both are
true (the optimistic result before mount fills in `fetchStatus: 'fetching'` ahead of time). Where they split is **an offline first
request** — the same path is held back by `canFetch` and becomes `fetchStatus: 'paused'`, so `isPending: true` · `isLoading: false`.
Branch on `isLoading` and an offline cold start shows a screen that is neither loading nor data. Hang the three-state branch on `isPending`. <!-- verified: @tanstack/query-core@5.104.3 build/modern/queryObserver.js:331-337 merges fetchState into the optimistic result · query.js:548-557 fetchStatus = canFetch(networkMode) ? 'fetching' : 'paused' · ran getOptimisticResult under node — online isLoading true, after onlineManager.setOnline(false) fetchStatus 'paused'·isLoading false -->

When a background revalidation fails while data is already there, `isError` and `data` are present together. Do not wipe the list and
switch to the error screen; keep the list and show something like a banner at the top — that is why branch 2 is full-screen only when
there is no `data`.

## 2. State components (`src/components/ScreenStates.tsx`)

<!-- file: src/components/ScreenStates.tsx -->
```tsx
// src/components/ScreenStates.tsx
import type { ReactNode } from 'react';
import { ActivityIndicator, Pressable, Text, View } from 'react-native';
import { toUserMessage } from '@/lib/toUserMessage';

const center = { flex: 1, alignItems: 'center', justifyContent: 'center', padding: 24, gap: 12 } as const;

export function LoadingView({ label = 'Loading' }: { label?: string }) {
  return (
    <View style={center} accessibilityRole="progressbar" accessibilityLabel={label}>
      <ActivityIndicator />
    </View>
  );
}

export function EmptyView({ title = 'No items to display', action }: { title?: string; action?: ReactNode }) {
  return (
    <View style={center}>
      <Text accessibilityRole="header">{title}</Text>
      {action}
    </View>
  );
}

export function ErrorView({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <View style={center} accessibilityRole="alert">
      <Text>{toUserMessage(error)}</Text>
      {onRetry ? (
        <Pressable accessibilityRole="button" onPress={onRetry} hitSlop={8}>
          <Text>Try again</Text>
        </Pressable>
      ) : null}
    </View>
  );
}
```

Without `onRetry` there is no button — 401·403·404 give the same answer however often you resend, so they get no retry button. The
button must be `Pressable` + `accessibilityRole="button"` for a screen reader to announce it as a "button".

## 3. Error → user-facing message (`src/lib/toUserMessage.ts`)

`error.message` may be the server's internal wording (a stack · SQL · an exception class name). Put only messages chosen by code on
screen. When offline, the connection message comes first whatever the error — the error code in that state is not the cause.

<!-- file: src/lib/toUserMessage.ts -->
```ts
// src/lib/toUserMessage.ts
import { onlineManager } from '@tanstack/react-query';
import { ApiError } from '@/api/http';

const BY_CODE: Record<string, string> = {
  UNAUTHENTICATED: 'Please sign in again.',
  FORBIDDEN: 'You do not have permission to view this task.',
  NOT_FOUND: 'Task not found.',
  VALIDATION_FAILED: 'Please check what you entered.',
};
const OFFLINE = 'You are not connected to the internet. Try again once you are connected.';
const RATE_LIMITED = 'Too many requests. Please try again shortly.';
const GENERIC = 'Something went wrong. Please try again shortly.';

export function toUserMessage(error: unknown): string {
  if (!onlineManager.isOnline()) return OFFLINE;
  if (error instanceof ApiError) {
    const known = BY_CODE[error.code];
    if (known) return known;
    return error.status === 429 ? RATE_LIMITED : GENERIC;
  }
  return GENERIC; // network failure · render exception — never use message as is
}
```

The keys of `BY_CODE` are examples — the actual code values follow the error code table in `api-client.md` §1. A code that
is not in the table folds into the generic message, so the screen does not break.

## 4. The list screen — three states · infinite scroll · pull to refresh

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

- `onEndReached` fires several times per scroll — without the `hasNextPage && !isFetchingNextPage` guard, duplicate requests go out
  with the same cursor
- `refreshing` is `isRefetching`. Use `isFetching` and the top spinner also spins while the next page loads
- `keyExtractor` is the server `id`. With index keys, row state (swipe · focus) moves to the wrong row when a page is appended
- `ScrollView` + `map` renders every item at once — a list beyond a few dozen items is a `FlatList`

## 5. Keyboard and safe area

Import `SafeAreaView` from `react-native-safe-area-context`. <!-- verified: @deprecated in react-native@0.86.3 Libraries/Components/SafeAreaView/SafeAreaView.d.ts --> A `SafeAreaProvider` must
be at the root (`navigation.md` §2). Keyboard avoidance behaves differently per platform — iOS is `padding`, and on Android window
resizing (`softwareKeyboardLayoutMode`, default `resize`) already does it, so leave it `undefined`. <!-- verified: @expo/config-types ExpoConfig.d.ts:574-576 Defaults to `resize` -->

```tsx
// src/app/(app)/tasks/new.tsx (excerpt)
import { KeyboardAvoidingView, Platform } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';

export default function NewTaskScreen() {
  return (
    <SafeAreaView style={{ flex: 1 }} edges={['top', 'bottom']}>
      <KeyboardAvoidingView style={{ flex: 1 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        {/* TextInput · save button */}
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
```

On a Stack screen with a header, drop `'top'` from `edges` so the space under the header is not added twice.

## 6. Screen tests — prove the error screen blocks without a retry

Assert only the negative ("there is no retry button") and the test passes even if `ErrorView` draws nothing. In the same `it`, pair
it with **the message is visible** and **given `onRetry`, a button appears and pressing it calls it**.

```tsx
// src/components/__tests__/ScreenStates.test.tsx
import { fireEvent, screen } from '@testing-library/react-native';
import { onlineManager } from '@tanstack/react-query';
import { renderWithProviders } from '../../../test/renderWithProviders';
import { ErrorView } from '@/components/ScreenStates';
import { ApiError } from '@/api/http';

it('draws the permission message for 403 with no retry button, and a button when onRetry is given', async () => {
  onlineManager.setOnline(true);
  const forbidden = new ApiError(403, 'FORBIDDEN', 'row-level policy violation on tasks');
  const first = await renderWithProviders(<ErrorView error={forbidden} />);
  expect(screen.getByText('You do not have permission to view this task.')).toBeTruthy();
  expect(screen.queryByText(/row-level/)).toBeNull();
  expect(screen.queryByRole('button')).toBeNull();
  await first.unmount();

  const onRetry = jest.fn();
  await renderWithProviders(<ErrorView error={new ApiError(503, 'UNAVAILABLE', 'x')} onRetry={onRetry} />);
  await fireEvent.press(screen.getByRole('button', { name: 'Try again' }));
  expect(onRetry).toHaveBeenCalledTimes(1);
});
```

The assertion that the server wording (`row-level …`) is **absent** only means something when it sits next to the assertion that the
permission message is **present**. In `@testing-library/react-native@14`, `render`·`fireEvent.press`·`unmount` return Promises — drop
an `await` and the assertions run before the render. <!-- verified: @testing-library/react-native@14.1.0 dist/render.d.ts:16 render(): Promise<…> · dist/events/fire-event.d.ts:6 press: … => Promise<void> --> <!-- verified: ran under jest-expo@57, PASS (ApiError·renderWithProviders stubbed) · all 4 ErrorView mutants (empty message · exposing error.message · button always · no button) FAIL -->

## Misuse list ① — web·old-version habits → the current shape in RN + TanStack Query v5

| Old habit | Current shape |
| --- | --- |
| Branching on loading with `if (isLoading)` | `if (isPending)` — does not miss an offline-paused first request |
| `import { SafeAreaView } from 'react-native'` | `SafeAreaView` from `react-native-safe-area-context` |
| A `ScrollView` + `items.map(...)` list | `FlatList` + `keyExtractor` + `onEndReached` |
| `<Text>{error.message}</Text>` | `<ErrorView error={error} />` — the message comes from `toUserMessage` |
| `onPress` on a `TouchableOpacity` with no role | `Pressable` + `accessibilityRole="button"` |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `isRefetching` vs `isFetching` | The pull-to-refresh spinner is `isRefetching`. `isFetching` is also true while the next page loads |
| Full-screen error vs keeping the list | Full screen only when there is no data. A failed revalidation keeps the list |
| `EmptyView` vs `ErrorView` | Succeeded with 0 items is the empty state. Fold a failure into an empty list and the user believes their data vanished |
| Passing `onRetry` vs omitting it | Pass it for network·5xx·429. Omit it for 401·403·404 — resending gives the same result |
| A route `ErrorBoundary` vs `ErrorView` | Render exceptions go to the boundary (`navigation.md` §7), query failures to the `isError` branch |
