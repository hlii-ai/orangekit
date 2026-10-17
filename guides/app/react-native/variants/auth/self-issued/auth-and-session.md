<!-- orangekit-pack: app/react-native v3.35.0 -->
# Auth and session (self-issued) — sign-in · refresh · sign-out cleanup

This file is the auth variant **self-issued** — the server puts sign-in · refresh · sign-out under `/api/auth`. It owns `src/auth/useAuth.ts` and
`src/app/sign-in.tsx`. Token storage is owned by `tokenStore` in `secure-storage.md`, attaching the token to requests and reacting to 401 by
`http` in `api-client.md`, and the protected-route switch by `Stack.Protected` in `navigation.md`. This file exports the three functions
`api-client.md` calls (`getAccessToken` · `refresh` · `endSession`) and `useAuth`.

## 1. Decision tree — what changes the state

| Event | Resulting state | What it does |
| --- | --- | --- |
| App start | `loading` → `signedIn` / `signedOut` | Reinstall cleanup → `signedIn` if `tokenStore.get()` returns something |
| Sign-in succeeds | `signedIn` | Clear the previous account's leftovers (queue · cache) → store the tokens |
| A request gets 401 → `refresh()` succeeds | Unchanged | Store the rotated token set in one write |
| `refresh()` gets 400 · 401 | `signedOut` | Local cleanup, then `false` — the user must sign in again |
| `refresh()` hits a network failure · 5xx · 429 | Unchanged | **Throws** — a single offline moment does not sign the user out |
| The user signs out | `signedOut` | Server-side revocation (proceeds even on failure) → local cleanup |

Having a token does not mean having permission — `signedIn` is a UX verdict, and the real block is the server's 401 · 404.

## 2. Wire — the app client's shape of `/api/auth`

The app does not use cookies. If the sign-in body carries `client: 'app'`, the server returns the refresh token **in the body**, and the app keeps it
in `tokenStore` (secure storage). Browser clients receive an httpOnly cookie from the same endpoint — the only difference is where it is kept.

| Request | Body | Success response `data` |
| --- | --- | --- |
| `POST /api/auth/login` | `{ email, password, client: 'app' }` | `{ accessToken, refreshToken, expiresIn? }` |
| `POST /api/auth/refresh` | `{ refreshToken }` | Same shape — the refresh token is **new every time** (rotation) |
| `POST /api/auth/logout` | `{ refreshToken }` | 204 |

Without `expiresIn` (seconds), `expiresAt` is stored as `0` and expiry is learned only through 401. If the project API spec fixes the field names, follow it.
The push token register · unregister paths are not in the contract — the project API spec decides them, and the call sites are right after sign-in and next to the server-side revocation in `signOut` below.

## 3. `src/auth/useAuth.ts`

`/api/auth/*` does not go through `http` — `refresh()` is called inside `http`'s 401 handling, so sending it through `http` would recurse, and
since `http` imports this file, an import in the opposite direction would be circular. That is why raw `fetch` is used here and only here.

<!-- file: src/auth/useAuth.ts -->
```ts
// src/auth/useAuth.ts
import { useEffect } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { create } from 'zustand';
import { config } from '@/config';
import { queryClient } from '@/lib/queryClient';
import { tokenStore, type Tokens } from '@/lib/tokenStore';
import { outbox } from '@/offline/outbox';

type Status = 'loading' | 'signedIn' | 'signedOut';
const useStatus = create<{ status: Status }>()(() => ({ status: 'loading' }));
const setStatus = (status: Status) => useStatus.setState({ status });
const INSTALL_MARKER = 'install.marker.v1';
const CLEAR_PENDING = 'session.clear.pending.v1'; // marks that tokenStore.clear() failed during sign-out

async function postAuth(path: string, body: unknown, token?: string): Promise<{ status: number; data: unknown }> {
  const headers: Record<string, string> = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (token) headers.Authorization = `Bearer ${token}`;
  // Network failures are thrown as is — the caller treats them as a "temporary failure"
  const res = await fetch(`${config.apiBaseUrl}/api/auth/${path}`, { method: 'POST', headers, body: JSON.stringify(body) });
  const json: unknown = await res.json().catch(() => null);
  return { status: res.status, data: (json as { data?: unknown } | null)?.data };
}

function toTokens(data: unknown): Tokens | null {
  const d = data as { accessToken?: unknown; refreshToken?: unknown; expiresIn?: unknown } | undefined;
  if (typeof d?.accessToken !== 'string' || typeof d.refreshToken !== 'string') return null;
  const ttl = typeof d.expiresIn === 'number' && d.expiresIn > 0 ? d.expiresIn : 0;
  return { accessToken: d.accessToken, refreshToken: d.refreshToken, expiresAt: ttl ? Date.now() + ttl * 1000 : 0 };
}

const ok = (status: number) => status >= 200 && status < 300;

// Local cleanup — order: tokenStore → outbox → query cache → state. Each step is independent — if one fails the rest still run and the state always ends as signedOut.
// `http` calls this when a request is still 401 after the resend (api-client.md). It bumps the session generation so an in-flight refresh cannot bring tokens back to life late
let generation = 0;
async function attempt(step: () => unknown): Promise<boolean> {
  try {
    await step();
    return true;
  } catch {
    return false;
  }
}

export async function endSession(): Promise<void> {
  generation += 1;
  if (!(await attempt(() => tokenStore.clear()))) {
    // Tokens that could not be wiped are wiped by the next boot — while the mark remains, boot does not read the tokens and retries the wipe
    await attempt(() => AsyncStorage.setItem(CLEAR_PENDING, '1'));
  }
  await attempt(() => outbox.clear());
  await attempt(() => queryClient.clear());
  // Append the project's Zustand store resets here (secure-storage.md §6)
  setStatus('signedOut');
}

export async function getAccessToken(): Promise<string | null> {
  return (await tokenStore.get())?.accessToken ?? null;
}

let refreshing: Promise<boolean> | null = null;

export function refresh(): Promise<boolean> {
  // Even with several concurrent 401s, refresh once — using a rotated refresh token twice makes the server treat it as reuse and revoke the whole session
  refreshing ??= (async () => {
    const gen = generation; // captured before the request — if a sign-out happens meanwhile, the result is discarded
    const current = await tokenStore.get();
    if (!current?.refreshToken) return endSession().then(() => false);
    const { status, data } = await postAuth('refresh', { refreshToken: current.refreshToken });
    if (gen !== generation) return false; // signed out during the request — neither store the tokens nor change the state
    const next = ok(status) ? toTokens(data) : null;
    if (next) {
      await tokenStore.set(next); // access and refresh under one key — they never get mixed
      return true;
    }
    if (ok(status) || status === 400 || status === 401) return endSession().then(() => false);
    throw new Error(`refresh unavailable: HTTP ${status}`); // 5xx · 429 — do not discard the session
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}

async function signIn(input: { email: string; password: string }): Promise<void> {
  const { status, data } = await postAuth('login', { email: input.email, password: input.password, client: 'app' });
  const tokens = ok(status) ? toTokens(data) : null;
  // Do not distinguish the reason — telling "no such account" apart from "wrong password" leaks whether the account exists
  if (!tokens) throw new Error(status === 400 || status === 401 ? 'SIGN_IN_REJECTED' : 'SIGN_IN_UNAVAILABLE');
  await outbox.clear(); // so the previous account's leftover queue is not sent with the new token
  queryClient.clear();
  await tokenStore.set(tokens);
  setStatus('signedIn');
}

async function signOut(): Promise<void> {
  generation += 1; // also discards a refresh that finishes while waiting for the server-side revocation
  const t = await tokenStore.get();
  if (t?.refreshToken) {
    await postAuth('logout', { refreshToken: t.refreshToken }, t.accessToken).catch(() => undefined); // wipe locally even if the server-side revocation fails
  }
  await endSession();
}

let booted: Promise<void> | null = null;
function boot(): Promise<void> {
  booted ??= (async () => {
    // The iOS Keychain can survive app deletion — if the install marker is missing, wipe the previous install's tokens (secure-storage.md §5)
    if ((await AsyncStorage.getItem(INSTALL_MARKER)) === null) {
      await tokenStore.clear().catch(() => undefined);
      await AsyncStorage.setItem(INSTALL_MARKER, '1');
    }
    // If the wipe failed during sign-out, those tokens belong to an already signed-out session — wipe them without reading (if that fails, the catch below sets signedOut)
    if ((await AsyncStorage.getItem(CLEAR_PENDING)) !== null) {
      await tokenStore.clear();
      await AsyncStorage.removeItem(CLEAR_PENDING);
    }
    setStatus((await tokenStore.get()) ? 'signedIn' : 'signedOut');
  })().catch(() => setStatus('signedOut'));
  return booted;
}

export function useAuth(): {
  status: Status;
  signIn: (input: { email: string; password: string }) => Promise<void>;
  signOut: () => Promise<void>;
} {
  const status = useStatus((s) => s.status);
  useEffect(() => {
    void boot(); // boot runs once even if several screens call it
  }, []);
  return { status, signIn, signOut };
}
```

- Access token expiry is not computed ahead of time — per contract §5, a 401 triggers the refresh. `expiresAt` only fills the storage format (`Tokens`).
- If the refresh response is 2xx but has the wrong shape, it is a sign-out. The server has already consumed the old refresh token — holding on to it only gets the next refresh rejected as reuse.
- The `signIn` argument exists only in this variant. The root layout (`navigation.md`) reads only `status`, so switching variants leaves the layout unchanged.

## 4. The sign-in screen (`src/app/sign-in.tsx`)

<!-- file: src/app/sign-in.tsx -->
```tsx
// src/app/sign-in.tsx
import { useState } from 'react';
import { Pressable, Text, TextInput, View } from 'react-native';
import { onlineManager } from '@tanstack/react-query';
import { useAuth } from '@/auth/useAuth';

export default function SignInScreen() {
  const { signIn } = useAuth();
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const onSubmit = async () => {
    setBusy(true);
    setMessage(null);
    try {
      await signIn({ email: email.trim(), password }); // on success, Stack.Protected moves to (app)
    } catch (e) {
      if (!onlineManager.isOnline()) setMessage('You are not connected to the internet.');
      else if (e instanceof Error && e.message === 'SIGN_IN_REJECTED') setMessage('Please check your email or password.');
      else setMessage('Please try again in a moment.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={{ flex: 1, justifyContent: 'center', padding: 24, gap: 12 }}>
      <TextInput value={email} onChangeText={setEmail} placeholder="Email" autoCapitalize="none" keyboardType="email-address" autoComplete="email" textContentType="username" />
      <TextInput value={password} onChangeText={setPassword} placeholder="Password" secureTextEntry autoComplete="password" textContentType="password" />
      {message ? <Text accessibilityRole="alert">{message}</Text> : null}
      <Pressable accessibilityRole="button" disabled={busy || !email || !password} onPress={onSubmit}>
        <Text>{busy ? 'Signing in' : 'Sign in'}</Text>
      </Pressable>
    </View>
  );
}
```

The password lives only briefly in state and is never stored anywhere (`secure-storage.md` §1). `textContentType` · `autoComplete` enable the OS password manager's autofill.

## 5. Tests — concurrent 401s refresh once, and a rejection cleans up

```ts
// test/auth/refresh.test.ts
import { tokenStore } from '@/lib/tokenStore';
import { outbox } from '@/offline/outbox';
import { refresh } from '@/auth/useAuth';

jest.mock('@/lib/tokenStore', () => ({ tokenStore: { get: jest.fn(), set: jest.fn(), clear: jest.fn(async () => {}) } }));
jest.mock('@/offline/outbox', () => ({ outbox: { clear: jest.fn(async () => {}) } }));
const fetchMock = jest.fn();
global.fetch = fetchMock as unknown as typeof fetch;
const res = (status: number, body: unknown) => ({ status, json: async () => body }) as unknown as Response;

it('concurrent refreshes share one request and store the new tokens, and a rejection returns false and clears the queue', async () => {
  jest.mocked(tokenStore.get).mockResolvedValue({ accessToken: 'a1', refreshToken: 'r1', expiresAt: 0 });
  fetchMock.mockResolvedValueOnce(res(200, { data: { accessToken: 'a2', refreshToken: 'r2', expiresIn: 900 } }));
  await expect(Promise.all([refresh(), refresh()])).resolves.toEqual([true, true]);
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(jest.mocked(tokenStore.set).mock.calls[0][0]).toMatchObject({ accessToken: 'a2', refreshToken: 'r2' });

  fetchMock.mockResolvedValueOnce(res(401, { error: { code: 'UNAUTHENTICATED', message: 'reused' } }));
  await expect(refresh()).resolves.toBe(false);
  expect(outbox.clear).toHaveBeenCalledTimes(1);
  expect(tokenStore.clear).toHaveBeenCalledTimes(1);
});
```

<!-- unverified: new in 3.35.0 — this author did not run it (a pack-smoke target) -->

## Misuse list ① — web·old-version habits → the current shape in an app

| Old habit | Current shape |
| --- | --- |
| Receiving the refresh token as an httpOnly cookie | The app receives it in the body via `client: 'app'` and puts it in `tokenStore` — the cookie store is outside the app's control |
| The access token in `AsyncStorage` | `tokenStore.set` — access · refresh under one key |
| Each 401 calling `/api/auth/refresh` on its own | `refresh()` single flight — reuse detection on rotating tokens revokes the session |
| Sign-out = only `tokenStore.clear()` | Server-side revocation → `tokenStore` → `outbox` → query cache → stores |

## Misuse list ② — confusable pairs

| Often picked wrongly | Exact conditions for applying it |
| --- | --- |
| Refresh failure → sign out vs keep | Only 400 · 401 sign out. Network · 5xx · 429 throw and keep the session |
| Using the server's `message` as the sign-in error text | Fixed text. Distinguishing the reason leaks whether the account exists |
| `router.replace` after `signIn` succeeds | Do not call it — when `status` changes, `Stack.Protected` moves the screen |
| `/api/auth/*` through `http` | Raw `fetch`. `refresh()` is called inside `http`'s 401 handling, so it would recurse |
