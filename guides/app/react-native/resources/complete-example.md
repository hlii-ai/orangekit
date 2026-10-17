<!-- orangekit-pack: app/react-native v3.35.0 -->
# Complete example — task details: entry → load → authenticated mutation (online·offline) → result

This file owns `src/app/(app)/tasks/[id].tsx` (complete file) and `src/app/(app)/tasks/new.tsx` (complete file). Everything this
example calls is owned by another resource — query hooks·`ApiError` by `api-client.md`, the three-state components by `screens-and-states.md`,
the outbox·idempotency keys by `data-and-offline.md`, path validation·deep links by `navigation.md`, sign-in by the auth variant's `auth-and-session.md`.
This file stays the same even if the auth method (self-issued·OIDC) changes — screens never touch tokens.

## 1. Flow — where each step is decided

| Step | What happens | Owner |
| --- | --- | --- |
| Entry | Tapping a list row · deep link `myapp://tasks/42` · tapping a notification (passes `safeInternalHref`) | `navigation.md` §5 |
| Guard | Before sign-in the `(app)` group is closed — the screen does not mount | `navigation.md` §2 |
| Load | `useTaskQuery(id)` → `http.get` → `GET /api/tasks/:id` | `api-client.md` §3 |
| Missing·someone else's | Arrives as a single 404 `NOT_FOUND` — one "not found" screen, no retry | contract §5 |
| Action | Status toggle — `PATCH` when online, outbox + optimistic update when offline | this file §2 |
| Expiry | 401 → refresh once → resend. If rejected, sign out → the screen unmounts | `api-client.md` §2 |
| Result | Update the detail cache + invalidate the list. For the outbox, invalidate everything after flush | `data-and-offline.md` §5 |

An "action that needs permission" here means **auth·ownership**. Even when trying to change someone else's task, the server answers 404, so the screen cannot learn it exists.
For actions that need device permissions (camera·location), slot the `usePermission` flow from `permissions-and-devices.md` into the same place (the button's `onPress`).

## 2. Detail screen (`src/app/(app)/tasks/[id].tsx`)

<!-- file: src/app/(app)/tasks/[id].tsx -->
```tsx
// src/app/(app)/tasks/[id].tsx
import { Pressable, Text, View } from 'react-native';
import { useLocalSearchParams } from 'expo-router';
import { onlineManager, useQueryClient } from '@tanstack/react-query';
import { ApiError } from '@/api/http';
import { taskKeys, useSetTaskStatus, useTaskQuery, type Task } from '@/api/tasks';
import { EmptyView, ErrorView, LoadingView } from '@/components/ScreenStates';
import { newIdempotencyKey } from '@/lib/idempotency';
import { toUserMessage } from '@/lib/toUserMessage';
import { outbox } from '@/offline/outbox';

const first = (v: string | string[] | undefined) => (Array.isArray(v) ? v[0] : v);
const NO_RETRY = new Set(['UNAUTHENTICATED', 'FORBIDDEN', 'NOT_FOUND']);

export default function TaskDetailScreen() {
  const id = first(useLocalSearchParams<{ id: string | string[] }>().id);
  // Hooks go above any return — with no id, enabled:false means no request
  const { data: task, isPending, isError, error, refetch } = useTaskQuery(id);
  const setStatus = useSetTaskStatus();
  const qc = useQueryClient();

  if (!id) return <EmptyView title="Task not found" />;
  if (isPending) return <LoadingView />;
  if (isError && !task) {
    // 404 does not separate "missing" from "someone else's" — same screen, no retry button
    if (error instanceof ApiError && error.code === 'NOT_FOUND') return <EmptyView title="Task not found" />;
    const retry = error instanceof ApiError && NO_RETRY.has(error.code) ? undefined : () => void refetch();
    return <ErrorView error={error} onRetry={retry} />;
  }

  const next: Task['status'] = task.status === 'open' ? 'done' : 'open';
  const onToggle = async () => {
    if (onlineManager.isOnline()) {
      setStatus.mutate({ id: task.id, status: next, key: newIdempotencyKey() }); // one key, the moment it is pressed
      return;
    }
    // Offline: change the screen first, then enqueue — enqueue makes the key
    qc.setQueryData<Task>(taskKeys.detail(task.id), { ...task, status: next });
    await outbox.enqueue({ method: 'PATCH', path: `/api/tasks/${encodeURIComponent(task.id)}`, body: { status: next } });
  };

  return (
    <View style={{ flex: 1, padding: 24, gap: 12 }}>
      <Text accessibilityRole="header">{task.title}</Text>
      <Text>{task.status === 'done' ? 'Done' : 'In progress'}</Text>
      <Pressable accessibilityRole="button" disabled={setStatus.isPending} onPress={onToggle}>
        <Text>{next === 'done' ? 'Mark as done' : 'Reopen'}</Text>
      </Pressable>
      {setStatus.isError ? <Text accessibilityRole="alert">{toUserMessage(setStatus.error)}</Text> : null}
    </View>
  );
}
```

- **The branch order is exactly `screens-and-states.md` §1** — loading → error → (a detail uses 404 instead of the empty state) → content.
- If a mutation gets 404 (deleted in the meantime, or ownership changed), `toUserMessage` picks the "Task not found." message.
- If an offline toggle is `drop`ped (outbox judgment 404·400), the optimistic value becomes false — the invalidation after flush (`data-and-offline.md` §5)
  restores the server value.
- `disabled={setStatus.isPending}` blocks double taps. A new key is made per tap, so a double tap is two different mutations.

## 3. Create screen — field errors from `VALIDATION_FAILED` (`src/app/(app)/tasks/new.tsx`)

`details` is `Record<string, string[]>` and form-wide errors arrive under the key `_` (contract §2). The server's wording is outside your control
in language and tone, so read **only which field is wrong** and let the screen choose the message.

<!-- file: src/app/(app)/tasks/new.tsx -->
```tsx
// src/app/(app)/tasks/new.tsx
import { useState } from 'react';
import { KeyboardAvoidingView, Platform, Pressable, Text, TextInput } from 'react-native';
import { router } from 'expo-router';
import { onlineManager } from '@tanstack/react-query';
import { SafeAreaView } from 'react-native-safe-area-context';
import { ApiError } from '@/api/http';
import { useCreateTask } from '@/api/tasks';
import { newIdempotencyKey } from '@/lib/idempotency';
import { toUserMessage } from '@/lib/toUserMessage';
import { outbox } from '@/offline/outbox';

export default function NewTaskScreen() {
  const [title, setTitle] = useState('');
  const create = useCreateTask();
  const invalid = create.error instanceof ApiError && create.error.code === 'VALIDATION_FAILED' ? create.error.details ?? {} : null;

  const onSave = async () => {
    const trimmed = title.trim();
    if (!onlineManager.isOnline()) {
      await outbox.enqueue({ method: 'POST', path: '/api/tasks', body: { title: trimmed } }); // enqueue makes the key
      router.back();
      return;
    }
    create.mutate({ title: trimmed, key: newIdempotencyKey() }, { onSuccess: () => router.back() });
  };

  return (
    <SafeAreaView style={{ flex: 1 }} edges={['bottom']}>
      <KeyboardAvoidingView style={{ flex: 1, padding: 24, gap: 12 }} behavior={Platform.OS === 'ios' ? 'padding' : undefined}>
        <TextInput value={title} onChangeText={setTitle} placeholder="Task title" accessibilityLabel="Task title" />
        {invalid?.title ? <Text accessibilityRole="alert">Please check the title.</Text> : null}
        {invalid?._ ? <Text accessibilityRole="alert">Please check what you entered.</Text> : null}
        {create.isError && !invalid ? <Text accessibilityRole="alert">{toUserMessage(create.error)}</Text> : null}
        <Pressable accessibilityRole="button" disabled={create.isPending || !title.trim()} onPress={onSave}>
          <Text>Save</Text>
        </Pressable>
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}
```

Add `<Stack.Screen name="new" options={{ presentation: 'modal', title: 'New task' }} />` to the Stack in `tasks/_layout.tsx` (`navigation.md` §3)
and it floats over the list and closes. An offline create has no server id yet, so no optimistic row goes into the list (`data-and-offline.md` §6).

## 4. Tests — block the 404, open and change my own task

Cut the boundary at `http` in `@/api/http` (`config-and-testing.md` §6). The auth variant is cut off with a mock, so the same test runs under both variants.

```tsx
// test/screens/TaskDetail.test.tsx
import { fireEvent, screen } from '@testing-library/react-native';
import { onlineManager } from '@tanstack/react-query';
import { useLocalSearchParams } from 'expo-router';
import { ApiError, http } from '@/api/http';
import TaskDetailScreen from '@/app/(app)/tasks/[id]';
import { renderWithProviders } from '../renderWithProviders';

jest.mock('expo-router', () => ({ useLocalSearchParams: jest.fn(), router: { back: jest.fn() } }));
jest.mock('@/auth/useAuth', () => ({ getAccessToken: async () => 't', refresh: async () => false, endSession: async () => {} }));
jest.mock('expo-crypto', () => ({ randomUUID: () => 'key-1' })); // jest-expo's default mock returns undefined (data-and-offline.md §7)
jest.mock('@/api/http', () => ({
  ...jest.requireActual<typeof import('@/api/http')>('@/api/http'),
  http: { get: jest.fn(), getPage: jest.fn(), post: jest.fn(), patch: jest.fn(), delete: jest.fn() },
}));
const mine = { id: 't1', title: 'My task', status: 'open', createdAt: '2026-10-17T00:00:00Z' };

it('shows not-found with no retry for missing or others\' tasks, and shows the title of mine and PATCHes it with an idempotency key', async () => {
  onlineManager.setOnline(true);
  jest.mocked(useLocalSearchParams).mockReturnValue({ id: 'other' });
  jest.mocked(http.get).mockRejectedValueOnce(new ApiError(404, 'NOT_FOUND', 'task not found'));
  const first = await renderWithProviders(<TaskDetailScreen />);
  expect(await screen.findByText('Task not found')).toBeOnTheScreen();
  expect(screen.queryByRole('button')).toBeNull();
  await first.unmount();

  jest.mocked(useLocalSearchParams).mockReturnValue({ id: 't1' });
  jest.mocked(http.get).mockResolvedValueOnce(mine);
  jest.mocked(http.patch).mockResolvedValueOnce({ ...mine, status: 'done' });
  await renderWithProviders(<TaskDetailScreen />);
  expect(await screen.findByText('My task')).toBeOnTheScreen();
  await fireEvent.press(screen.getByRole('button', { name: 'Mark as done' }));
  expect(http.patch).toHaveBeenCalledWith('/api/tasks/t1', { status: 'done' }, { idempotencyKey: 'key-1' });
});
```

Assert only the 404 and an implementation that draws "not found" no matter what it receives passes too — the later "My task" display and the PATCH call are the positive pair.
<!-- unverified: new in 3.35.0 — this author did not run it (pack-smoke target) -->

## Misuse list ① — web screen habits → the current shape of app screens

| Old habit | Current shape |
| --- | --- |
| 403 and 404 as different screens | An ownership failure is a single 404 — one "missing or not yours" screen |
| Disabling the button when offline | Enqueue it and change optimistically — it is sent even after the app is killed |
| Showing `details.title[0]` as is | Read only which field it is, and let the screen choose the message |
| Manually `refetch()`ing the list after a successful save | The hook's `onSuccess` invalidates `taskKeys.list()` |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| Online mutation vs outbox | Only one of the two. Take both and the same mutation goes out twice with different keys |
| Key made at screen mount vs the moment it is pressed | The moment it is pressed. Make it at mount and the second save gets the first response replayed |
| `EmptyView` (404) vs `ErrorView` | 404 is the empty-state message. Other failures are `ErrorView` — 401·403 without a retry |
| Detail cache `setQueryData` vs invalidation | Overwrite the detail with the response·optimistic value; invalidate the list, whose order·count changes |
