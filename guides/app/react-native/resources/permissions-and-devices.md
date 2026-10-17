<!-- orangekit-pack: app/react-native v3.35.0 -->
# Permissions and device features — runtime permissions · location · camera · push tokens

This file owns `src/device/permissions.ts` (`usePermission`) and `src/device/push.ts` (`registerForPushAsync`),
plus the judgment of "when to ask for a permission and what to do when it is denied". The call that **registers** the push token
**with the server** belongs to the project's API spec, and the place it is called from is the auth variant's `auth-and-session.md`. The path validation function for
notification payloads, `safeInternalHref`, is owned by `navigation.md` — here it is only imported.

## 1. Decision tree — when to ask

| Situation | What to do | Why |
| --- | --- | --- |
| App start · the first onboarding screen | **Do not ask** — `usePermission` only reads on mount | A dialog with no context gets denied, and once denials pile up the OS stops asking |
| The moment the user presses that feature (`state === 'undetermined'`) | A one-line explanation first → `request()` when the user presses "Continue" | The OS dialog's wording cannot be changed. Give the reason on an app screen first |
| `state === 'denied'` (can ask again) | Show the explanation again and `request()` | Android can ask once more after the first denial |
| `state === 'blocked'` (permanently denied) | A "Turn on in Settings" button → `openSettings()` | Calling `request()` returns `false` with no dialog |
| The screen works without the permission | Disable only the feature and leave the screen as is | A permission denial that blocks the whole app also fails store review |

**The permission check is UX.** Coordinates are values the device sent, too, and can be forged — if the server uses a value in a decision, the server validates it again.

## 2. Config plugins and permission strings (`app.config.ts`)

A runtime request and a config plugin declaration are a pair. With no location key at all, expo-location kills the app with
`RCTFatal` **just from reading** the permission, and with only `NSLocationWhenInUseUsageDescription` missing the request is denied with
`ERR_LOCATION_INFO_PLIST` <!-- verified: expo-location@57.0.21 ios/Requesters/EXBaseLocationRequester.m:38-41 · EXForegroundPermissionRequester.m:24-28 (source comparison, not a device run) -->.
The strings go in as plugin options — the option names were read from the installed plugin source.
<!-- verified: expo-location@57.0.21 plugin/build/withLocation.d.ts · expo-camera@57.0.6 plugin/build/withCamera.d.ts · expo-notifications@57.0.23 plugin/build/withNotifications.d.ts -->

```ts
// app.config.ts
plugins: [
  ['expo-location', {
    locationWhenInUsePermission: 'Uses your current location to show where the task happens on a map.',
    // Foreground only — no background · motion keys
    locationAlwaysAndWhenInUsePermission: false, locationAlwaysPermission: false, motionUsagePermission: false,
  }],
  ['expo-camera', { // if you do not record video, do not declare the microphone either
    cameraPermission: 'Uses the camera to attach photos to tasks.', microphonePermission: false, recordAudioAndroid: false,
  }],
  ['expo-notifications', { icon: './assets/notification-icon.png', color: '#ffffff' }],
],
extra: { eas: { projectId: '<the UUID that eas init wrote>' } },
```

- **Omit a string and a default English string goes in** (`Allow $(PRODUCT_NAME) to access your location`).
  The default string was confirmed in the install <!-- verified: expo-location@57.0.21 plugin/build/withLocation.js LOCATION_USAGE · @expo/config-plugins build/ios/Permissions.js applyPermissions -->.
  App Store review rejects strings that do not say "why it is used" <!-- unverified: external policy -->
- **`false` deletes that key from `Info.plist`.** Omit it and it **goes in** with the default string — when the options are left empty,
  expo-location fills even the Always-family keys with default strings <!-- verified: @expo/config-plugins build/ios/Permissions.js — delete if permissions[k] === false, otherwise value || existing || default -->
- Android permissions (`ACCESS_FINE_LOCATION` · `CAMERA`) are added to the manifest by the plugin. `RECORD_AUDIO` goes in unless
  turned off, because `recordAudioAndroid` defaults to `true` <!-- verified: expo-camera@57.0.6 plugin/build/withCamera.js -->
- Plugin options take effect only in a native build — even a string change is a new build, not an OTA (`release-and-updates.md`)

## 3. `usePermission` (`src/device/permissions.ts`)

Location and camera are handled with the same state machine. The state is built from three fields of the OS response (`granted` ·
`status` · `canAskAgain`). When the app comes back from the Settings app (`AppState` → `'active'`) it **reads again** — the user turned
it on in Settings but the screen stays at `blocked`: that is the most common defect in this hook.

<!-- file: src/device/permissions.ts -->
```ts
// src/device/permissions.ts
import { useCallback, useEffect, useState } from 'react';
import { AppState, Linking } from 'react-native';
import type { PermissionResponse } from 'expo';
import * as Location from 'expo-location';
import { Camera } from 'expo-camera';

export type PermissionKind = 'location' | 'camera';
export type PermissionState = 'undetermined' | 'granted' | 'denied' | 'blocked';

type Source = { read: () => Promise<PermissionResponse>; ask: () => Promise<PermissionResponse> };
const SOURCES: Record<PermissionKind, Source> = {
  location: { read: Location.getForegroundPermissionsAsync, ask: Location.requestForegroundPermissionsAsync },
  camera: { read: Camera.getCameraPermissionsAsync, ask: Camera.requestCameraPermissionsAsync },
};

function toState(r: PermissionResponse): PermissionState {
  if (r.granted) return 'granted';
  if (r.status === 'undetermined') return 'undetermined';
  return r.canAskAgain ? 'denied' : 'blocked';
}

export function usePermission(kind: PermissionKind): {
  state: PermissionState;
  request: () => Promise<boolean>;
  openSettings: () => Promise<void>;
} {
  const [state, setState] = useState<PermissionState>('undetermined');

  useEffect(() => {
    let alive = true;
    const read = () => {
      // A failed read does not change the state — it does not throw
      SOURCES[kind].read().then((r) => { if (alive) setState(toState(r)); }, () => {});
    };
    read(); // only read on mount — do not ask
    const sub = AppState.addEventListener('change', (s) => { if (s === 'active') read(); });
    return () => { alive = false; sub.remove(); };
  }, [kind]);

  const request = useCallback(async () => {
    try {
      const r = await SOURCES[kind].ask();
      setState(toState(r));
      return r.granted;
    } catch {
      return false;
    }
  }, [kind]);

  const openSettings = useCallback(() => Linking.openSettings().catch(() => {}), []);

  return { state, request, openSettings };
}
```

- **Until the first read finishes it is `'undetermined'`.** Do not hang an effect that calls `request()` automatically at this
  moment — call it only when a button is pressed. For a user who already allowed it, the OS returns `granted` right away with no dialog
- On iOS, one denial turns `canAskAgain` `false`, so it goes straight to `blocked`. Android can ask once more after a denial, so it
  passes through `denied` <!-- unverified: platform behavior — cannot be confirmed from the installed JS. Needs confirmation on a device -->

## 4. Location — foreground only, used from a screen

This pack handles **foreground location only**. Background location (`requestBackgroundPermissionsAsync` ·
`startLocationUpdatesAsync`) comes with a separate permission (iOS Always · Android `ACCESS_BACKGROUND_LOCATION`), separate
`Info.plist` keys, and a justification submitted for store review, so it is **outside the pack's scope** — if you need it, handle it as a separate decision.
A one-off read is `getCurrentPositionAsync` (it can take a few seconds), a fast approximation is `getLastKnownPositionAsync` (it can be
`null`), and tracking while the screen is up is `watchPositionAsync` — `remove()` the returned subscription in the effect cleanup.
<!-- verified: expo-location@57.0.21 build/Location.d.ts getCurrentPositionAsync · getLastKnownPositionAsync(→ LocationObject | null) -->

```tsx
// src/app/(app)/tasks/[id].tsx — the attach-location button part
const location = usePermission('location');

async function attachLocation() {
  if (location.state === 'blocked') return location.openSettings();
  if (location.state !== 'granted' && !(await location.request())) return;
  const pos = await Location.getCurrentPositionAsync({ accuracy: Location.Accuracy.Balanced });
  setDraft((d) => ({ ...d, lat: pos.coords.latitude, lng: pos.coords.longitude }));
}

return (
  <View>
    {location.state === 'blocked' ? <Text>Location permission is off. You can turn it on in Settings.</Text> : null}
    <Button title={location.state === 'blocked' ? 'Turn on in Settings' : 'Attach current location'} onPress={attachLocation} />
  </View>
);
```

The explanation does not need its own screen — one line right above the button is enough. What matters is that **the OS dialog appears
after the user's action**.

## 5. Camera — `CameraView` and `usePermission`

expo-camera also exports its own hook, `useCameraPermissions()`. **This pack settles on `usePermission('camera')` alone** — so the
`blocked` decision and steering to the Settings app go through the same state machine as location, and screens do not have two branches
of permission API. Both call the same native functions (`getCameraPermissionsAsync` · `requestCameraPermissionsAsync`). <!-- verified: expo-camera@57.0.6 build/index.js — useCameraPermissions = createPermissionHook({ getMethod, requestMethod }), and the Camera object exposes the same two functions -->

```tsx
// src/app/(app)/tasks/capture.tsx
const camera = usePermission('camera');
const ref = useRef<CameraView>(null);

if (camera.state !== 'granted') {
  return <Button title={camera.state === 'blocked' ? 'Turn on in Settings' : 'Allow camera'}
    onPress={camera.state === 'blocked' ? camera.openSettings : camera.request} />;
}
return (
  <CameraView ref={ref} style={{ flex: 1 }} facing="back">
    <Button title="Capture" onPress={async () => setPhoto(await ref.current?.takePictureAsync())} />
  </CameraView>
);
```

The `Camera` object is marked `@hidden` in the installed d.ts but is an exported value — the two permission functions are exposed only through that object
<!-- verified: expo-camera@57.0.6 build/index.d.ts:59-68 · build/index.js -->.

## 6. Push tokens (`src/device/push.ts`)

This goes only as far as **issuing** the token. Registering it with the server, and unregistering on sign-out, is done from
`auth-and-session.md`'s place (which API to send it to and how it links to the user are the backend contract).

<!-- file: src/device/push.ts -->
```ts
// src/device/push.ts
import { Platform } from 'react-native';
import { isRunningInExpoGo } from 'expo';
import Constants from 'expo-constants';
import * as Notifications from 'expo-notifications';

function allowed(p: Notifications.NotificationPermissionsStatus): boolean {
  return p.granted || p.ios?.status === Notifications.IosAuthorizationStatus.PROVISIONAL;
}

export async function registerForPushAsync(): Promise<string | null> {
  // Expo Go does not support remote push — tokens only come out of a development build
  if (isRunningInExpoGo()) return null;

  // On Android 13+ the permission dialog appears only once at least one channel exists — the channel comes first (OS behavior, not confirmed on a device)
  if (Platform.OS === 'android') {
    await Notifications.setNotificationChannelAsync('default', { name: 'Default', importance: Notifications.AndroidImportance.DEFAULT });
  }

  const current = await Notifications.getPermissionsAsync();
  let ok = allowed(current);
  if (!ok && current.canAskAgain) ok = allowed(await Notifications.requestPermissionsAsync());
  if (!ok) return null;

  // The library itself looks in the same order — it throws when absent, so check first and fold to null
  const projectId = Constants.easConfig?.projectId ?? Constants.expoConfig?.extra?.eas?.projectId;
  if (typeof projectId !== 'string' || projectId === '') return null;

  const token = await Notifications.getExpoPushTokenAsync({ projectId });
  return token.data;
}
```

- **Do not use `expo-device`** — it is not in the pack's `pkgs`, and the install does not block token requests even on simulators
  (it only warns on the iOS 26.0 simulator) <!-- verified: expo-notifications@57.0.23 ios/ExpoNotifications/PushToken/PushTokenModule.swift:34-41 (source comparison, not a device run) -->.
  Instead, filter out Expo Go, which definitely has no remote push, with `isRunningInExpoGo()` — on Android Expo Go
  the token request throws <!-- verified: expo-notifications@57.0.23 build/warnOfExpoGoPushUsage.js -->
- The `projectId` lookup order (`easConfig.projectId` → `expoConfig.extra.eas.projectId`) is the same as the library's internals
  <!-- verified: expo-notifications@57.0.23 build/getExpoPushTokenAsync.js — throws ERR_NOTIFICATIONS_NO_EXPERIENCE_ID when absent -->
- `getExpoPushTokenAsync` makes a request to the Expo server — it throws on offline·server error·native registration failure, and that is
  propagated as is. The caller (the auth flow) catches it and calls again on the next activation
- **When to call it**: the moment "Get notifications" is pressed, or at app start **only when it is already `granted`** (token refresh).
  This function goes as far as asking, so on the start path the caller first decides by reading only:

```ts
// src/auth/… — the auth variant's boot path (after the sign-in check)
const { granted } = await Notifications.getPermissionsAsync(); // read only — no dialog
// Fold failures to null and retry on the next activation — if there is a token, send it to the server registration API (owned by the project's API spec)
const token = granted ? await registerForPushAsync().catch(() => null) : null;
```

## 7. Notification tap → navigating to a screen

Notification responses are handled in **one place**, `useNotificationRouting` (owned by `navigation.md`, `src/lib/useNotificationRouting.ts`).
The root layout calls it once as `useNotificationRouting(status === 'signedIn')` — payload path validation
(`safeInternalHref`) and consumption (`clearLastNotificationResponse`) are there. This file owns only as far as issuing the token.
Whether to show a notification while the app is in the foreground is decided by `Notifications.setNotificationHandler` (once, at module top level)
<!-- verified: expo-notifications@57.0.23 build/NotificationsHandler.d.ts — shouldShowBanner · shouldShowList · shouldPlaySound · shouldSetBadge -->.

## Misuse list ① — old habits → the current shape in Expo SDK 57

| Old habit | Current shape |
| --- | --- |
| `Permissions.askAsync(Permissions.LOCATION)` from `expo-permissions` | Per-module functions — `Location.requestForegroundPermissionsAsync()` · `Camera.requestCameraPermissionsAsync()` |
| `Location.requestPermissionsAsync()` (no foreground·background split) | `requestForegroundPermissionsAsync()` — background is a separate function·separate review |
| Rendering `import { Camera } from 'expo-camera'` as a component | `<CameraView>` — `Camera` is an object bundling the permission functions <!-- verified: expo-camera@57.0.6 build/index.d.ts — CameraView is the component, Camera is a function object --> |
| Requesting a token only on real devices with `Device.isDevice` | `expo-device` is not in this pack — filter out only Expo Go and try everywhere else (§6) |
| Calling `getExpoPushTokenAsync()` with no arguments | Pass `{ projectId }`, and fold to `null` when absent |
| `shouldShowAlert: true` in the notification handler | `shouldShowBanner` · `shouldShowList` — the former is deprecated <!-- verified: expo-notifications@57.0.23 build/Notifications.types.d.ts:612-615 @deprecated --> |
| `Linking.openURL('app-settings:')` | `Linking.openSettings()` — works on both platforms |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `denied` vs `blocked` | `denied` can be asked again (`request()`). `blocked` is `canAskAgain === false` — only the Settings app is left |
| `usePermission('camera')` vs `useCameraPermissions()` | This pack uses only the former. They call the same native functions, so mixing them puts state in two places |
| Omitting a plugin option vs `false` | Omitting it **adds** the default English string. To leave it out, use `false` |
| `getPermissionsAsync` vs `requestPermissionsAsync` | The former reads (no dialog, on mount), the latter asks (only from a user action) |
| `getExpoPushTokenAsync` vs `getDevicePushTokenAsync` | The former if you send through the Expo push service. The latter if you send to FCM/APNs directly — the backend contract decides |
