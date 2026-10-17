<!-- orangekit-pack: app/react-native v3.35.0 -->
# Release and updates — EAS Build profiles · the OTA boundary · runtimeVersion · forced updates

This file owns `eas.json`, the `runtimeVersion`·`updates` fields of `app.config.ts`, the OTA apply flow, and `src/lib/appVersion.ts`.
Code that reads environment values is owned by `config-and-testing.md` (`src/config.ts`) — here per-profile values are only **put** into `eas.json`.
**The API that hands down the minimum supported version** is a backend contract (the API version negotiation slot), and that call is made with `api-client.md`'s `http` —
the pack supplies only the function that judges the received string.

## 1. Decision tree — does it ship over OTA, or does it need a store build

| What this release changes | Path | Why |
| --- | --- | --- |
| JS·TS code · bundle assets such as images · `EXPO_PUBLIC_*` values | OTA (EAS Update) | Only the bundle changes. The native binary stays as is |
| Adding·removing·upgrading a native module (installing `expo-camera` and the like) | **Store build** | New JS calling a module the old binary does not have crashes |
| Permission strings (`NSCameraUsageDescription` and the like) · adding a config plugin·changing its options | **Store build** | `Info.plist`·`AndroidManifest.xml` are generated at build time |
| Native fields of `app.config.ts` (bundle ID · scheme · icon · splash · the `ios`/`android` blocks) | **Store build** | The same reason — they are prebuild outputs |
| Bumping the Expo SDK · React Native version | **Store build** | The runtime itself changes |

The question to ask: **"Does this change alter the output of `npx expo prebuild`?"** If it does, it is a build. When in doubt, ship a build —
a bad OTA reaches every device already installed, but a bad build stops at review.
`runtimeVersion` is the device that enforces this judgment by machine (§3) — though how much it still relies on human judgment depends on the policy.

## 2. Build profiles (`eas.json`)

One profile binds **one channel** and **one set of environment values**. OTA is delivered by channel, so production updates never mix into a preview build.

<!-- file: eas.json -->
```json
{
  "build": {
    "development": {
      "developmentClient": true,
      "distribution": "internal",
      "channel": "development",
      "env": {
        "EXPO_PUBLIC_APP_ENV": "development",
        "EXPO_PUBLIC_API_BASE_URL": "http://localhost:3000",
        "EXPO_PUBLIC_WEB_ORIGINS": "https://web.dev.example.com"
      }
    },
    "preview": {
      "distribution": "internal",
      "channel": "preview",
      "env": {
        "EXPO_PUBLIC_APP_ENV": "preview",
        "EXPO_PUBLIC_API_BASE_URL": "https://api.staging.example.com",
        "EXPO_PUBLIC_WEB_ORIGINS": "https://web.staging.example.com"
      }
    },
    "production": {
      "channel": "production",
      "autoIncrement": true,
      "env": {
        "EXPO_PUBLIC_APP_ENV": "production",
        "EXPO_PUBLIC_API_BASE_URL": "https://api.example.com",
        "EXPO_PUBLIC_WEB_ORIGINS": "https://web.example.com"
      }
    }
  },
  "submit": { "production": {} }
}
```
<!-- unverified: the eas.json schema (channel · developmentClient · distribution · autoIncrement · env) could not be compared because eas-cli is not in the install -->

- `src/config.ts` validates at boot — a profile missing `APP_ENV`·`API_BASE_URL` throws on the first screen (`config-and-testing.md` §2).
  `EXPO_PUBLIC_WEB_ORIGINS` is optional — for an app with no webview, delete the line and `trustedWebOrigins` becomes `[]`.
- **Do not put secrets here.** The values in `env` are inlined into the bundle. Signing keys·store credentials are managed as EAS secrets·`submit` credentials and never touch JS.
- **OTA does not use the build profile's `env`** — `eas update` rebuilds the bundle with the environment of whoever creates the update.
  Pass the same values so the update carries them. <!-- unverified: eas-cli is not installed, so how eas update resolves env could not be confirmed -->

## 3. The `runtimeVersion` policy — `appVersion` vs `fingerprint`

Updates are delivered only to builds with the same `runtimeVersion`. The install accepts four policies: `nativeVersion` · `sdkVersion` · `appVersion` · `fingerprint`.
<!-- verified: the runtimeVersion.policy union in @expo/config-types@57.0.2 build/ExpoConfig.d.ts:37 -->

```ts
// app.config.ts (excerpt)
export default {
  version: '1.4.0',
  runtimeVersion: { policy: 'fingerprint' },
  updates: { url: 'https://u.expo.dev/00000000-0000-0000-0000-000000000000' },
};
```

| Policy | Where the value comes from | Does it miss native changes? | When to pick it |
| --- | --- | --- | --- |
| `appVersion` | The `version` string as is | **It misses them** — add a native module without bumping `version` and an OTA goes out on the same runtime | When the discipline of bumping `version` on every native change is enforced |
| `fingerprint` | A fingerprint of the native project (computed at build time) | It catches them, because the fingerprint changes | **The default choice** — the machine makes the §1 judgment for you |
| `nativeVersion` | `version` + build number | Same as `appVersion` | When you want to cut off OTA targets per build |

<!-- verified: @expo/config-plugins@57 build/utils/Updates.js:133-165 getRuntimeVersionAsync — appVersion uses getAppVersion; fingerprint is not resolved in the config plugin but leaves a 'file:fingerprint' marker computed at build time -->

`fingerprint` is not a cure-all either — the **behavioral contract** of JS that has no native impact (e.g. the server API changed and the old JS breaks) is not in the fingerprint. That is the job of the forced update in §5.

## 4. The OTA apply flow — check → download → reload

The default (`checkAutomatically: ON_LOAD`) checks and downloads at launch and applies it on the **next cold start**. Call it yourself only when you need it applied immediately.
<!-- verified: @expo/config-types@57.0.2 ExpoConfig.d.ts:121-123 checkAutomatically default ON_LOAD -->

```ts
// src/app/_layout.tsx (excerpt) — at launch and on returning to the foreground
import { useEffect } from 'react';
import { AppState } from 'react-native';
import * as Updates from 'expo-updates';

async function applyPendingUpdate(): Promise<void> {
  if (__DEV__ || !Updates.isEnabled) return;
  try {
    const check = await Updates.checkForUpdateAsync();
    if (!check.isAvailable) return;
    const fetched = await Updates.fetchUpdateAsync();
    if (fetched.isNew) await Updates.reloadAsync(); // put no meaningful code after this line
  } catch {
    // network·server failure — the automatic check tries again on the next launch
  }
}

// Call site: useOtaOnForeground() once, in the body of the root layout component
function useOtaOnForeground(): void {
  useEffect(() => {
    void applyPendingUpdate();
    const sub = AppState.addEventListener('change', (s) => {
      if (s === 'active') void applyPendingUpdate();
    });
    return () => sub.remove();
  }, []);
}
```

- The three functions **reject** in development mode (`__DEV__`) and Expo Go, and when `expo-updates` is disabled — call them without the guard and you get an exception every time during development.
  <!-- verified: the __DEV__ branch CodedError('ERR_UPDATES_DISABLED') in checkForUpdateAsync·reloadAsync of expo-updates@57.0.26 build/Updates.js · build/Updates.d.ts comments -->
- Besides being turned off in config, `isEnabled` can be `false` when `updates.url`·`runtimeVersion` is missing or access to device storage fails. <!-- verified: comment in expo-updates@57.0.26 build/Updates.d.ts:4-12 -->
- `reloadAsync()` restarts JS — a form being filled in·the screen position are lost. If the user is mid-task, defer with a "Restart" button; otherwise leave it to the next cold start.
- Check only at launch·on returning to the foreground. Periodic polling costs battery, and Expo may rate-limit it (the install's `checkForUpdateAsync` comment).

## 5. The forced-update decision (`src/lib/appVersion.ts`)

When the server hands down "versions below this cannot be used", the app shows a blocking screen and sends the user to the store. The decision is one pure function.
**If it cannot decide, it does not block** — so a single bad value from the server, like `"v2"`, does not lock out every user.

<!-- file: src/lib/appVersion.ts -->
```ts
// src/lib/appVersion.ts
// major.minor.patch, no leading zeros. Pre-release (-beta.1)·build metadata (+42) suffixes are accepted but ignored in the comparison.
const VERSION = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;

function parse(v: unknown): readonly [number, number, number] | null {
  if (typeof v !== 'string') return null;
  const m = VERSION.exec(v);
  if (!m) return null;
  const parts = [Number(m[1]), Number(m[2]), Number(m[3])] as const;
  return parts.every(Number.isSafeInteger) ? parts : null;
}

export function isUpdateRequired(current: string, minSupported: string): boolean {
  const a = parse(current);
  const b = parse(minSupported);
  if (a === null || b === null) return false; // an undecidable case is not folded into a forced update
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i];
  }
  return false; // equal means supported
}
```

| Rule | Decision | Why |
| --- | --- | --- |
| Number of digits | Compare as numbers — `1.10.0` > `1.9.9` | String comparison gives `"1.10.0" < "1.9.9"` |
| Pre-release suffixes | Ignored — `1.2.3-beta` is treated as `1.2.3` | Do not block internal builds. If you want semver ordering (`-beta` < release), adjust the server value, not this function |
| Leading/trailing whitespace · a `v` prefix · two parts (`1.2`) | Parse failure → `false` | Do not guess the format. The server contract guarantees `major.minor.patch` |

```ts
// src/app/_layout.tsx (excerpt) — call site: useForceUpdateGate(minSupported) in the root layout
import { useEffect } from 'react';
import Constants from 'expo-constants';
import { router } from 'expo-router';
import { isUpdateRequired } from '@/lib/appVersion';

// minSupported: received through the backend contract (the API version negotiation slot) and passed in. null = not known yet → do not decide
function useForceUpdateGate(minSupported: string | null): void {
  useEffect(() => {
    if (minSupported === null) return;
    const current = Constants.expoConfig?.version ?? '';
    if (isUpdateRequired(current, minSupported)) router.replace('/update-required');
  }, [minSupported]);
}
```

`/update-required` is an **example screen** — the project creates it as `src/app/update-required.tsx` (a screen with only a store link).

`current` is `Constants.expoConfig?.version`, not `expo-application` (the native binary version) — the source the ledger pins.
If `version` is empty, the empty string fails to parse and gives `false`. While running an OTA, `expoConfig` comes from that update's manifest.
<!-- unverified: whether expoConfig.version during an OTA run is the app.config value at the time the update was published was not confirmed on a device — the install's Constants.types.d.ts comment only says "embedded or remote" -->

## 6. What gets caught in store review

These are store policies that cannot be confirmed from the install — before release, compare against each store's current guidelines.

| Item | Why it gets caught |
| --- | --- |
| A permission string that does not explain the actual use | iOS review rejects it. The strings are written in the config plugin options of `app.config.ts` (`permissions-and-devices.md`) <!-- unverified --> |
| Account creation exists but there is no in-app path to delete the account | An App Store review requirement. The deletion API is a backend contract; only the screen entry point lives in the app <!-- unverified --> |
| The Google Play data safety form differs from what is actually collected | Collecting location·push tokens must be declared on the form <!-- unverified --> |
| Changing the app's primary purpose over OTA | Treated as a change that bypasses review. OTA is for bug fixes·small improvements <!-- unverified --> |

## Misuse list ① — old habits → the current shape in Expo SDK 57

| Old habit | Current shape |
| --- | --- |
| `expo publish` · release channels (`releaseChannel`) | `eas update` + the build profile's `channel` <!-- unverified --> |
| Leaving `runtimeVersion: { policy: 'sdkVersion' }` as is | `fingerprint` — `sdkVersion` does not distinguish native changes within the same SDK <!-- verified: the sdkVersion branch of resolveRuntimeVersionPolicyAsync in @expo/config-plugins@57 build/utils/Updates.js --> |
| `fetchUpdateAsync` → `reloadAsync` without looking at the check result | Look at `check.isAvailable` · `fetched.isNew`. Reloading for an update that is not there only blows away the screen |
| `Constants.manifest.version` | `Constants.expoConfig?.version` <!-- verified: manifest @deprecated in expo-constants@57 build/Constants.types.d.ts:153 --> |
| Comparing `current < min` as strings | `isUpdateRequired` — numeric comparison per part |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| OTA vs a store build | If the prebuild output changes, it is a build. Even one line of permission string is a build |
| `runtimeVersion` vs `version` | The former is the OTA compatibility key, the latter the version users see. They are equal only under the `appVersion` policy |
| `fingerprint` vs a forced update | The former prevents native incompatibility, the latter server API incompatibility. You need both |
| Parse failure → `true` vs `false` | `false`. One bad server value locking out every user is the more expensive outcome |
| `Updates.reloadAsync()` vs `Expo.reloadAppAsync()` | The former swaps in the downloaded update's bundle and reloads; the latter only restarts with the same bundle <!-- verified: expo-updates@57.0.26 build/Updates.d.ts:85-90 --> |
| Channels vs branches | A build knows its channel, and updates are published to a branch. Which branch a channel points at decides delivery <!-- unverified --> |
