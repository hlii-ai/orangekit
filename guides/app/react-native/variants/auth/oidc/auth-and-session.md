<!-- orangekit-pack: app/react-native v3.35.0 -->
# Auth and session (external IdP · OIDC) — PKCE sign-in · refresh · sign-out cleanup

This file is the auth variant **oidc** — an external IdP (Cognito · Auth0 · Identity Platform, etc.) issues the tokens and the server
only verifies them with JWKS. It owns `src/auth/useAuth.ts` and `src/app/sign-in.tsx`. Token storage is owned by `tokenStore` in
`secure-storage.md`, attaching the token to requests and reacting to 401 by `http` in `api-client.md`, and the IdP address · client ID
by `config.oidc` in `config-and-testing.md`. This file exports the three functions `api-client.md` calls (`getAccessToken` · `refresh` · `endSession`) and `useAuth`.

## 1. Decision tree — the sign-in method

| What to pick | Verdict | Why |
| --- | --- | --- |
| Authorization Code + PKCE, system browser (`expo-auth-session` + `expo-web-browser`) | **Adopt** | Prevents code interception without a client secret. Reuses the browser's IdP session (SSO) |
| The IdP sign-in page in an in-app `WebView` | Forbidden | IdPs block embedded WebViews, and it is a structure where the app can snoop on password entry (`webview.md` §1) |
| Implicit (tokens in the redirect URL) | Forbidden | No refresh token, and the tokens are left in URLs · history |
| A confidential client that uses a client secret | Forbidden | `EXPO_PUBLIC_*` is inlined into the bundle — an app has no secrets |

Register it in the IdP console as a **public native client**, and add `myapp://oauthredirect` (app scheme +
`oauthredirect`) to the allowed redirect URIs. Depending on the IdP, receiving a refresh token requires the `offline_access` scope (Auth0) — adjust it in `SCOPES` below.

## 2. State transitions

| Event | Resulting state | What it does |
| --- | --- | --- |
| App start | `loading` → `signedIn` / `signedOut` | Reinstall cleanup → `signedIn` if `tokenStore.get()` returns something |
| `signIn()` succeeds | `signedIn` | Code exchange → clear the previous account's leftovers → store the tokens |
| The user closes the browser | Unchanged | Does nothing — it is not an error |
| The IdP rejects `refresh()` (`TokenError`) | `signedOut` | Local cleanup, then `false` |
| `refresh()` fails on the network | Unchanged | **Throws** — a single offline moment does not sign the user out |
| Sign-out | `signedOut` | Revoke the refresh token (proceeds even on failure) → local cleanup |

## 3. `src/auth/useAuth.ts`

<!-- file: src/auth/useAuth.ts -->
```ts
// src/auth/useAuth.ts
import { useEffect } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as AuthSession from 'expo-auth-session';
import * as WebBrowser from 'expo-web-browser';
import { create } from 'zustand';
import { config } from '@/config';
import { queryClient } from '@/lib/queryClient';
import { tokenStore, type Tokens } from '@/lib/tokenStore';
import { outbox } from '@/offline/outbox';

WebBrowser.maybeCompleteAuthSession(); // closes the popup in a web build — does nothing on native

// If the variant is oidc and the values are missing, die at boot — do not let it surface only when the sign-in button is pressed
if (!config.oidc) throw new Error('The environment variables EXPO_PUBLIC_OIDC_ISSUER · EXPO_PUBLIC_OIDC_CLIENT_ID are empty');
const { issuer, clientId } = config.oidc;
const SCOPES = ['openid', 'profile', 'offline_access'];
const redirectUri = AuthSession.makeRedirectUri({ path: 'oauthredirect' });
const INSTALL_MARKER = 'install.marker.v1';
const CLEAR_PENDING = 'session.clear.pending.v1'; // marks that tokenStore.clear() failed during sign-out

type Status = 'loading' | 'signedIn' | 'signedOut';
const useStatus = create<{ status: Status }>()(() => ({ status: 'loading' }));
const setStatus = (status: Status) => useStatus.setState({ status });

let discovery: AuthSession.DiscoveryDocument | null = null;
async function getDiscovery(): Promise<AuthSession.DiscoveryDocument> {
  discovery ??= await AuthSession.fetchDiscoveryAsync(issuer);
  return discovery;
}

function toTokens(t: AuthSession.TokenResponse, previousRefresh: string | null = null): Tokens {
  const expiresAt = t.expiresIn ? (t.issuedAt + t.expiresIn) * 1000 : 0; // issuedAt is in seconds
  return { accessToken: t.accessToken, refreshToken: t.refreshToken ?? previousRefresh, expiresAt };
}

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
  // Even with several concurrent 401s, refresh once — using a rotating refresh token twice makes the IdP treat it as reuse and reject it
  refreshing ??= (async () => {
    const gen = generation; // captured before the request — if a sign-out happens meanwhile, the result is discarded
    const current = await tokenStore.get();
    if (!current?.refreshToken) return endSession().then(() => false);
    try {
      const next = await AuthSession.refreshAsync({ clientId, refreshToken: current.refreshToken }, await getDiscovery());
      if (gen !== generation) return false; // signed out during the request — neither store the tokens nor change the state
      await tokenStore.set(toTokens(next, current.refreshToken)); // IdPs that do not rotate do not return the refresh token again
      return true;
    } catch (e) {
      if (gen !== generation) return false;
      if (e instanceof AuthSession.TokenError) return endSession().then(() => false); // invalid_grant etc. — the IdP's rejection
      throw e; // network · discovery failure — do not discard the session
    }
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}

async function signIn(): Promise<void> {
  const doc = await getDiscovery();
  const request = new AuthSession.AuthRequest({ clientId, scopes: SCOPES, redirectUri, usePKCE: true });
  const result = await request.promptAsync(doc);
  if (result.type === 'cancel' || result.type === 'dismiss') return; // the user closed it
  if (result.type !== 'success') throw new Error('SIGN_IN_FAILED');
  const token = await AuthSession.exchangeCodeAsync(
    { clientId, code: result.params.code, redirectUri, extraParams: { code_verifier: request.codeVerifier ?? '' } },
    doc,
  );
  await outbox.clear(); // so the previous account's leftover queue is not sent with the new token
  queryClient.clear();
  await tokenStore.set(toTokens(token));
  setStatus('signedIn');
}

async function signOut(): Promise<void> {
  generation += 1; // also discards a refresh that finishes while waiting for the server-side revocation
  const t = await tokenStore.get();
  if (t?.refreshToken) {
    await getDiscovery()
      .then((doc) => AuthSession.revokeAsync({ clientId, token: t.refreshToken ?? '', tokenTypeHint: AuthSession.TokenTypeHint.RefreshToken }, doc))
      .catch(() => undefined); // wipe locally even if the revocation fails
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

export function useAuth(): { status: Status; signIn: () => Promise<void>; signOut: () => Promise<void> } {
  const status = useStatus((s) => s.status);
  useEffect(() => {
    void boot(); // boot runs once even if several screens call it
  }, []);
  return { status, signIn, signOut };
}
```

- `AuthRequest` does the `state` check and generates the PKCE verifier — do not build them yourself. <!-- unverified: expo-auth-session@57's handling of a state mismatch and the TokenError · TokenTypeHint exports were not checked against the installed source (assumes the API is kept under the versioning scheme from SDK 55 on) -->
- The app receives the tokens directly through `exchangeCodeAsync`. The server only verifies the signature · `iss` · `aud` of `Authorization: Bearer` with JWKS (owned by the backend guide).
- `signOut` revokes only the app's tokens. The browser's IdP session remains, so the next `signIn` may finish without a password — if there is a shared-device
  requirement, open the discovery's `endSessionEndpoint` with `WebBrowser.openAuthSessionAsync`.

## 4. The sign-in screen and the redirect route

<!-- file: src/app/sign-in.tsx -->
```tsx
// src/app/sign-in.tsx
import { useState } from 'react';
import { Pressable, Text, View } from 'react-native';
import { onlineManager } from '@tanstack/react-query';
import { useAuth } from '@/auth/useAuth';

export default function SignInScreen() {
  const { signIn } = useAuth();
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const onPress = async () => {
    setBusy(true);
    setMessage(null);
    try {
      await signIn(); // on success, Stack.Protected moves to (app)
    } catch {
      setMessage(onlineManager.isOnline() ? 'Could not sign in. Please try again in a moment.' : 'You are not connected to the internet.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <View style={{ flex: 1, justifyContent: 'center', padding: 24, gap: 12 }}>
      {message ? <Text accessibilityRole="alert">{message}</Text> : null}
      <Pressable accessibilityRole="button" disabled={busy} onPress={onPress}>
        <Text>{busy ? 'Signing in' : 'Sign in'}</Text>
      </Pressable>
    </View>
  );
}
```

On Android, when the IdP redirects back to `myapp://oauthredirect?code=…`, that URL also reaches Expo Router. Without a route,
`+not-found` flashes briefly, so add a redirect route — the code exchange uses the result `promptAsync` already received.
<!-- unverified: whether the redirect URL is also delivered to the router on Android with expo-router@57 + expo-web-browser@57 was not confirmed on a device -->

```tsx
// src/app/oauthredirect.tsx
import { Redirect } from 'expo-router';

export default function OAuthRedirect() {
  // On success Stack.Protected soon moves to (app); on cancel · failure the sign-in screen remains — it never stays on a blank screen
  return <Redirect href="/sign-in" />;
}
```

## 5. Tests — a refresh rejection leads to cleanup, a network failure keeps the session

```ts
// test/auth/refresh.test.ts
import * as AuthSession from 'expo-auth-session';
import { tokenStore } from '@/lib/tokenStore';
import { outbox } from '@/offline/outbox';
import { refresh } from '@/auth/useAuth';

jest.mock('@/lib/tokenStore', () => ({ tokenStore: { get: jest.fn(), set: jest.fn(), clear: jest.fn(async () => {}) } }));
jest.mock('@/offline/outbox', () => ({ outbox: { clear: jest.fn(async () => {}) } }));
jest.mock('expo-web-browser', () => ({ maybeCompleteAuthSession: jest.fn() }));
jest.mock('expo-auth-session', () => {
  class TokenError extends Error {}
  return { TokenError, makeRedirectUri: () => 'myapp://oauthredirect', fetchDiscoveryAsync: jest.fn(async () => ({})), refreshAsync: jest.fn() };
});

it('cleans up with false when the IdP rejects, and throws and keeps the tokens on a network failure', async () => {
  jest.mocked(tokenStore.get).mockResolvedValue({ accessToken: 'a1', refreshToken: 'r1', expiresAt: 0 });
  jest.mocked(AuthSession.refreshAsync).mockRejectedValueOnce(new Error('Network request failed'));
  await expect(refresh()).rejects.toThrow('Network');
  expect(tokenStore.clear).not.toHaveBeenCalled();

  jest.mocked(AuthSession.refreshAsync).mockRejectedValueOnce(new AuthSession.TokenError('invalid_grant' as never));
  await expect(refresh()).resolves.toBe(false);
  expect(tokenStore.clear).toHaveBeenCalledTimes(1);
  expect(outbox.clear).toHaveBeenCalledTimes(1);
});
```

<!-- unverified: new in 3.35.0 — this author did not run it (a pack-smoke target). expo-auth-session is a mock, so the real error shapes are unverified -->

## Misuse list ① — web·old-version habits → the current shape in Expo SDK 57

| Old habit | Current shape |
| --- | --- |
| `AuthSession.startAsync` · Expo proxy (`auth.expo.io`) redirect | `AuthRequest.promptAsync` + app-scheme redirect (`makeRedirectUri`) <!-- unverified: when startAsync · the proxy were removed was not checked against the installed source --> |
| Adding `react-native-app-auth` to Expo managed | This pack uses `expo-auth-session` — it works without a config plugin |
| `oidc-client-ts` (for browsers) in RN | It assumes browser storage · redirects. Apps use `expo-auth-session` |
| Tokens in `AsyncStorage` | `tokenStore.set` — access · refresh under one key |

## Misuse list ② — confusable pairs

| Often picked wrongly | Exact conditions for applying it |
| --- | --- |
| Treating `result.type === 'cancel'` as an error | The user closed it — leave it as is, with no message |
| `idToken` vs `accessToken` for the API | `accessToken` for the API. `idToken` is for the client to know the user |
| Refresh failure → sign out vs keep | Only `TokenError` (IdP rejection) signs out. Network failures throw and keep the session |
| Revoking app tokens vs ending the IdP session | `revokeAsync` covers only the app tokens. To cut browser SSO too, use `endSessionEndpoint` |
