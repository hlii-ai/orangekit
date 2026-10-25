---
paths:
  - "src/**"
  - "app/**"
  - "apps/**"
  - "packages/**"
  - "lib/**"
  - "app.config.*"
---
<!-- orangekit-pack: app/react-native v3.35.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (no secrets behind the EXPO_PUBLIC_ prefix · redirect allow-list · a screen guard is not a boundary) belong to security.md, so they are not here. -->

# Expo + React Native core card

The project spec and `.claude/rules/code-conventions.md` take precedence over this card and the `app-guide` skill.
Look up wiring and examples in the `app-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Call HTTP only through the one API client module; screens never call `fetch` directly. Path prefix and envelope follow the backend spec and are matched in that one module. — why models get it wrong: some calls end up with a different prefix and 404 <!-- evidence: policies no-raw-fetch · api-path-prefix · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Keep tokens only in `expo-secure-store`, with `keychainAccessible` set explicitly. AsyncStorage is plaintext. — why models get it wrong: AsyncStorage looks like the web's localStorage slot <!-- evidence: policies no-token-in-asyncstorage · secure-store-accessibility · model-gap: not-observed -->
- [security] Validate a deep link or notification payload path as an internal path before handing it to the router. — why models get it wrong: it looks like an in-app value, not user input <!-- evidence: policies deeplink-validated · model-gap: not-observed -->
- [security] A WebView's boundary is the origin check inside `onShouldStartLoadWithRequest`/`onMessage`, not `originWhitelist`. Leave the list as a lone `'*'` and inject no token. — why models get it wrong: narrow the list and the library opens out-of-list URLs outside the app before the callback runs <!-- evidence: policies no-narrow-origin-whitelist · webview-nav-callback · webview-message-origin (run-verified) · model-gap: not-observed -->
- [security] Logout also empties the offline queue, and cuts off any in-flight send so it cannot send new items afterwards. — why models get it wrong: the previous user's mutations go out under the next user's token <!-- evidence: react-native-app-pack L0 defects #2·#12 · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Create the idempotency key of an offline mutation once, at enqueue time. — why models get it wrong: created at send time, every resend gets a new key and the server applies it twice <!-- evidence: policies outbox-key-at-enqueue · model-gap: not-observed -->
- [performance] Token refresh shares the in-flight Promise. — why models get it wrong: concurrent 401s each refreshing reuse a rotated token and the session is revoked <!-- evidence: policies refresh-single-flight · model-gap: not-observed -->
- [performance] A release that changes native modules or permissions bumps `runtimeVersion` and ships through the store. A permission request is paired with its usage string in `app.config`. — why models get it wrong: OTA swaps only JS and crashes on the old binary; without the string the request is denied or the app exits <!-- evidence: policies (what humans keep) · model-gap: not-observed -->
