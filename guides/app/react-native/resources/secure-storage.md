<!-- orangekit-pack: app/react-native v1.0.0 -->
# Secure storage — storing tokens and the boundary of plaintext stores

This file owns `src/lib/tokenStore.ts` and the judgment of "what goes in which store".
When tokens are received and refreshed, and how they are attached to requests, is owned by the seam (`auth-and-session.md` · `api-client.md`).
**The order of sign-out cleanup** is also owned by the seam's `useAuth().signOut` — this file only gives the list of what to wipe.

## 1. Decision tree — which store does it go in

| Value | Where it goes | Why |
| --- | --- | --- |
| access · refresh tokens | `tokenStore` (expo-secure-store) | Encrypted by the iOS Keychain · Android Keystore |
| The outbox queue · UI settings · an onboarding-done flag | AsyncStorage | Values whose exposure does not hand over the account. Do not put tokens in the queue `body` |
| Server data cache | Memory (`queryClient`) | Leave it on disk and it survives sign-out. Persisting it is a separate decision |
| Passwords · OTPs · client secrets · signing keys | **Nowhere** | A password is handed to the IdP and discarded. A secret is public the moment it is in the bundle (`EXPO_PUBLIC_*` is inlined at build time) |

The criterion is "what could someone off the device do if they got this value". If they could impersonate the account, it is
SecureStore; if they could do nothing, AsyncStorage; if there is no reason for it to be on the device, do not store it.
**The device is an untrusted environment** — SecureStore protects against other apps and backups, not against the owner of a
jailbroken device. Authorization is always decided by the server.

## 2. `tokenStore` (`src/lib/tokenStore.ts`)

<!-- file: src/lib/tokenStore.ts -->
```ts
// src/lib/tokenStore.ts
import * as SecureStore from 'expo-secure-store';

export type Tokens = {
  accessToken: string;
  refreshToken: string | null;
  expiresAt: number; // epoch milliseconds
};

const KEY = 'auth.tokens.v1';
const OPTIONS: SecureStore.SecureStoreOptions = {
  keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY,
};

function parse(raw: string): Tokens | null {
  try {
    const v: unknown = JSON.parse(raw);
    if (typeof v !== 'object' || v === null) return null;
    const { accessToken, refreshToken, expiresAt } = v as Record<string, unknown>;
    if (typeof accessToken !== 'string' || accessToken === '') return null;
    if (refreshToken !== null && typeof refreshToken !== 'string') return null;
    if (typeof expiresAt !== 'number' || !Number.isFinite(expiresAt)) return null;
    return { accessToken, refreshToken, expiresAt };
  } catch {
    return null;
  }
}

export const tokenStore = {
  async get(): Promise<Tokens | null> {
    let raw: string | null;
    try {
      raw = await SecureStore.getItemAsync(KEY, OPTIONS);
    } catch {
      return null; // a failure of the read itself is not wiped — it may be transient (§5)
    }
    if (raw === null) return null;
    const tokens = parse(raw);
    if (tokens === null) await SecureStore.deleteItemAsync(KEY, OPTIONS).catch(() => undefined);
    return tokens;
  },
  async set(t: Tokens): Promise<void> {
    await SecureStore.setItemAsync(KEY, JSON.stringify(t), OPTIONS);
  },
  async clear(): Promise<void> {
    await SecureStore.deleteItemAsync(KEY, OPTIONS);
  },
};
```

- Write the token set **as one JSON value under one key**. Split the keys and an app that dies mid-refresh mixes a new access token with an old refresh token.
- `set` can throw (save failure). Do not swallow it — show a sign-in whose save failed as a success and the user is signed out on the next run.
- `clear` does not throw for a missing key either. iOS does not look at the status of `SecItemDelete`, and Android commits the removal of a missing key as a success. <!-- verified: expo-secure-store@57.0.4 ios/SecureStoreModule.swift:43-50 · android/.../SecureStoreModule.kt:381-390 (source comparison, not a device run) -->

<!-- verified: unit check against a stub (the author's in-memory stub — not library behavior): only the get/set/clear branches (7 kinds of corrupted values deleted · kept when the read is rejected · the accessibility option passed on every call). Real-device Keychain/Keystore behavior is unverified -->

## 3. Accessibility level — why `AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY`

| Level | Background read while locked | Moves to another device via backup | Verdict |
| --- | --- | --- | --- |
| `WHEN_UNLOCKED` (default) | No | Yes | Background resends·refreshes cannot read the token <!-- verified: expo-secure-store@57.0.4 build/SecureStore.d.ts --> |
| `AFTER_FIRST_UNLOCK` | Yes, after the first unlock following a reboot | Yes | The session follows to a restored new device |
| **`AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY`** | Yes, after the first unlock following a reboot | No | **Adopted** |
| `ALWAYS` · `ALWAYS_THIS_DEVICE_ONLY` | Always | — | `@deprecated` in the install <!-- verified: expo-secure-store@57.0.4 build/SecureStore.d.ts --> |

<!-- verified: constant comments in expo-secure-store@57.0.4 build/SecureStore.d.ts · @default WHEN_UNLOCKED for keychainAccessible · the ALWAYS family @deprecated -->

- `keychainAccessible` is **iOS-only** (`@platform ios`). Excluding items from Android backups is the config plugin's job. If other backup rules already exist, it only warns and does not apply.
  Put `expo-secure-store` in the `plugins` of `app.config.ts` and, with `configureAndroidBackup` defaulting to `true`, SecureStore items are taken out of the auto-backup rules. <!-- verified: expo-secure-store@57.0.4 plugin/build/withSecureStore.js -->
- **A release that changes the level must delete and rewrite.** When the same key exists (`errSecDuplicateItem`), an iOS write only
  `SecItemUpdate`s the value and leaves the accessibility attribute at its old value. Changing the option alone does not migrate the tokens of existing installs. <!-- verified: expo-secure-store@57.0.4 ios/SecureStoreModule.swift:98,120,127-137 (source comparison, not a device run) -->

```ts
// Accessibility level migration (excerpt) — once, on the first run of the release that changed the level, before the auth verdict
async function migrateTokenAccessibility(): Promise<void> {
  const current = await tokenStore.get();
  if (!current) return;
  await tokenStore.clear(); // without the delete, iOS keeps the old accessibility attribute
  await tokenStore.set(current);
}
```

## 4. Key naming rules and size

- A key passes only `/^[\w.-]+$/` — alphanumerics · `_` · `.` · `-`. `auth:tokens` · `auth/tokens` throw `Invalid key provided to SecureStore`
  in JS before reaching native. Values accept strings only — objects go through `JSON.stringify`. <!-- verified: expo-secure-store@57.0.4 build/SecureStore.js:145-155 ensureValidKey · isValidValue -->
- Give the key a version suffix (`.v1`). A release that changes the shape writes a new key and deletes the old one — no branch that parses the old shape stays behind.
- Size: the install's JS layer has no size check, and the iOS byte-limit warning has been removed. <!-- verified: expo-secure-store@57.0.4 CHANGELOG.md 55.0.0 "[iOS] Remove byte limit warning" · no length check in build/SecureStore.js -->
  Even so, tokens are the only thing that goes in. Server data such as user profiles·permission lists is owned by the query cache.

## 5. Corrupted values and read failures — when to wipe and when not to

| Situation | `tokenStore.get()` | Why |
| --- | --- | --- |
| No item | `null` | Signed out |
| Not JSON, or a field has the wrong shape | Deletes the item and returns `null` | Reading again gives the same. Leave it and every run hits the same failure |
| The native read is rejected | Returns `null` without deleting | It may be transient, like a background run before the first unlock after a reboot |
| The Keystore key disappeared after an Android reinstall | `null` | The library deletes the item itself <!-- verified: expo-secure-store@57.0.4 android/.../SecureStoreModule.kt:140,159-169 (source comparison) --> |
| The key was invalidated by a biometric change (`requireAuthentication` items) | `null` | `getItemAsync` resolves to `null` <!-- verified: getItemAsync comment in expo-secure-store@57.0.4 build/SecureStore.d.ts --> |

When `get()` is `null`, the caller (the seam's auth flow) judges the state as signed out. The cost of not wiping on a rejected read
is "this run alone looks signed out"; the cost of wiping is "one transient error loses the session".

iOS Keychain items can survive deleting the app — right after a reinstall the app starts signed in as the old account.
<!-- unverified: this is iOS platform behavior and cannot be confirmed from the installed source. Needs confirmation on a device via delete→reinstall -->
AsyncStorage is wiped together with the app, so keep an install marker there, and when the marker is absent, wipe the tokens:

```ts
// Boot cleanup (excerpt) — called from the boot path in the seam's auth-and-session.md, before the auth verdict
async function clearTokensAfterReinstall(): Promise<void> {
  if ((await AsyncStorage.getItem('install.marker.v1')) !== null) return;
  await tokenStore.clear();
  await AsyncStorage.setItem('install.marker.v1', '1');
}
```

## 6. What to wipe on sign-out

The order (server revocation → `tokenStore.clear()` → `outbox.clear()` → `queryClient.clear()` → store reset) is owned by
`useAuth().signOut` in the seam's `auth-and-session.md`. This list is **what must not be left out**.

| Target | How it is wiped | If left out |
| --- | --- | --- |
| Tokens | `tokenStore.clear()` | The user is signed in again on the next run |
| Server data cache | `queryClient.clear()` | The next user briefly sees the previous user's list |
| Zustand stores | Each store's reset | Selections·filters carry over to the next account |
| The outbox queue | `outbox.clear()` (`data-and-offline.md`) | The previous user's mutations are sent with the next user's token |
| Server-side session·push token registration | The seam's server call | Notifications keep going to a device that signed out |

Even if the server revocation call fails, local cleanup proceeds. Leaving local state behind is the greater risk.
Values unrelated to the account, like the install marker (§5)·UI settings, are not wiped.

## 7. The trade-off of using biometrics (`requireAuthentication`)

`tokenStore` does not use `requireAuthentication`. What happens if you turn it on:

- **Android on every operation, iOS on reading·updating an existing value** require authentication. Every request reads the token, so
  a biometric prompt appears on every request, and a background resend cannot show a prompt, so it fails.
- When the biometrics change (a fingerprint added · a face re-enrolled), the key is invalidated and the value can never be read again — the user is signed out for no apparent reason.
- iOS throws on write if `NSFaceIDUsageDescription` is missing. Add it through the config plugin's `faceIDPermission`.
  In Expo Go it does not work on devices with biometrics. Simulators do not require authentication, so test on a real device.

<!-- verified: requireAuthentication comment in expo-secure-store@57.0.4 build/SecureStore.d.ts · ios/SecureStoreModule.swift:101 MissingPlistKeyException -->

If a biometric lock is a requirement, lock **entry to the app** rather than the token, or keep the secret for high-risk actions under
**a separate key**. Do not mix it into `tokenStore`'s key — authenticated items work fully only on a newly created key, and cannot share
the same `keychainService` with unauthenticated items (the install's `requireAuthentication` comment).

## Misuse list ① — web·old-version habits → the current shape in Expo SDK 57

| Old habit | Current shape |
| --- | --- |
| `localStorage.setItem('token', …)` → carried over to `AsyncStorage` in RN as is | `tokenStore.set(tokens)` — AsyncStorage is a plaintext file |
| An HttpOnly cookie session | The app uses Bearer tokens. The cookie store is outside the app's control and not a premise of this axis |
| `setItemAsync(key, value)` with no options | State the accessibility level — the default `WHEN_UNLOCKED` cannot be read while locked <!-- verified: expo-secure-store@57.0.4 build/SecureStore.d.ts --> |
| `keychainAccessible: SecureStore.ALWAYS` | `@deprecated` in the install. `AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY` <!-- verified: expo-secure-store@57.0.4 build/SecureStore.d.ts --> |
| Splitting tokens across several keys to dodge the byte-limit warning | The iOS byte-limit warning has been removed. Splitting only loses atomicity <!-- verified: expo-secure-store@57.0.4 CHANGELOG.md 55.0.0 --> |
| Keeping tokens in `EXPO_PUBLIC_*` or `app.config.ts` `extra` | There are no secrets in the bundle. Per-device tokens are received at runtime and go in `tokenStore` |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `AFTER_FIRST_UNLOCK` vs `…_THIS_DEVICE_ONLY` | Tokens take the latter. The former moves the session to another device through an iCloud·encrypted backup restore |
| Corrupted value → wipe vs rejected read → wipe | Only a parse failure is wiped. A rejected native read may be transient (§5) |
| `getItemAsync` vs `getItem` (sync) | Async. The sync version blocks the JS thread, and with `requireAuthentication` the app freezes until authentication finishes |
| `keychainAccessible` vs Android backup rules | The former is read only by iOS. Android backup exclusion has to come from registering the config plugin |
| Signed in on screen vs the server's authorization verdict | Having a token does not mean having permission. Protected routes are UX and the verdict is the server's |
