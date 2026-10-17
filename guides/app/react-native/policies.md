<!-- orangekit-pack-policies: app/react-native v3.35.0 -->

# react-native pack — cross-file invariants

The gate checks **whether the seam obeys the policies this pack declares**. When the place that declares a policy and the
place that enforces it are different, something has to reconcile the two — this file is that device.

## Machine checks (gate `check_policies`)

**Only the lines `codelines()` extracts are checked** — inside a code fence · not a comment · not in a ❌ section.

| id | verdict | scope | regex | exempt files | proof example | counterexample | description |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `vocab-task` | forbid | guide | `\bnote(s)?\b` | — | `const notes = []` | `creates a note` | The vocabulary is Task/task (issued by L0). Split the clusters and the vocabulary diverges |
| `env-single-reader` | forbid | guide | `process\.env(\.EXPO_PUBLIC_\|\[['"]EXPO_PUBLIC_)` | `config-and-testing.md` | `process.env.EXPO_PUBLIC_API_BASE_URL` | `process.env['EXPO_PUBLIC_APP_ENV']` | Environment values are read in exactly one place, `src/config.ts`. When another file reads them, boot-time validation is bypassed. Bracket access with a string literal is the same violation (babel-preset-expo inlines it exactly like dot access — only variable keys·destructuring are not inlined) |
| `no-secret-public-env` | forbid | guide | `EXPO_PUBLIC_[A-Z_]*(SECRET\|PASSWORD\|PRIVATE\|CREDENTIAL)` | — | `EXPO_PUBLIC_CLIENT_SECRET` | `EXPO_PUBLIC_DB_PASSWORD` | `EXPO_PUBLIC_*` is inlined into the JS bundle at build time. Anyone who unpacks the app binary can read it |
| `no-token-in-asyncstorage` | forbid | guide | `AsyncStorage\.(setItem\|multiSet)\(\s*\[?\s*\[?\s*['"]?[A-Za-z_.-]*([Tt]oken\|TOKEN\|[Ss]ession\|SESSION\|[Ss]ecret\|SECRET)` | — | `AsyncStorage.setItem('accessToken', t)` | `AsyncStorage.setItem(REFRESH_TOKEN_KEY, t)` | AsyncStorage is not encrypted. Tokens go only in `tokenStore` (expo-secure-store). Wrapping the key in a constant is the same violation |
| `webview-all-nav-to-callback` | require | file:webview.md | `originWhitelist=\{\[\s*['"]\*['"]\s*\]\}` | — | `originWhitelist={['*']}` | `originWhitelist={['https://app.example']}` | A lone `'*'` is the only way to send every navigation (including `intent:`·other apps' schemes) to `onShouldStartLoadWithRequest` — the boundary is not the list but `isTrustedOrigin` in the callback (confirmed by running react-native-webview@13 `WebViewShared.tsx:36-64`) |
| `webview-nav-callback` | require | file:webview.md | `onShouldStartLoadWithRequest=\{` | — | `onShouldStartLoadWithRequest={onShouldStart}` | `onShouldStartLoadWithRequest(event)` | A lone `'*'` is safe only when paired with the callback — without the callback every page loads. The verdict is made by `isTrustedOrigin` inside the callback |
| `no-narrow-origin-whitelist` | forbid | guide | `originWhitelist=\{\[\s*['"][a-z]+:` | — | `originWhitelist={['https://app.example']}` | `originWhitelist={["mailto:*", 'tel:*']}` | Narrow the list and **the library opens URLs outside it with `Linking.openURL` before the callback runs** — the narrower it is, the more URLs leave the app unchecked. `originWhitelist` is not a security boundary (it is a regex with no end anchor, so `https://app.example.evil.com` passes too) |
| `webview-message-origin` | require | file:webview.md | `isTrustedOrigin\(event\.nativeEvent\.url` | — | `if (!isTrustedOrigin(event.nativeEvent.url, config.trustedWebOrigins)) return;` | `isTrustedOrigin(url, allowed)` | `onMessage` judges the origin by the URL of the frame that sent the message. Accept without that check and any page loaded in the webview can call the bridge |
| `deeplink-validated` | require | file:navigation.md | `router\.(replace\|push)\(safeInternalHref\(` | — | `router.replace(safeInternalHref(url.pathname))` | `export function safeInternalHref(raw: string)` | Deep links·notification payloads are values from outside. They must always pass through this before reaching the router |
| `outbox-key-at-enqueue` | require | file:data-and-offline.md | `key: newIdempotencyKey\(\)` | — | `const op: OutboxOp = { ...input, key: newIdempotencyKey(), createdAt: Date.now() };` | `headers['Idempotency-Key'] = op.key` | The idempotency key is created once, when the mutation is created. Create it at send time and every resend gets a new key, so the server applies it twice |
| `secure-store-accessibility` | require | file:secure-storage.md | `keychainAccessible: SecureStore\.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY` | — | `{ keychainAccessible: SecureStore.AFTER_FIRST_UNLOCK_THIS_DEVICE_ONLY }` | `{ keychainAccessible: SecureStore.ALWAYS }` | State the accessibility level explicitly. The default (`WHEN_UNLOCKED`) cannot be read by background work while the device is locked, and without `THIS_DEVICE_ONLY` the item moves to another device through a backup |
| `no-raw-fetch` | forbid | guide | `(^\|[^.[:alnum:]_])fetch\(` | `api-client.md, auth-and-session.md` | `const res = await fetch(url)` | `return fetch(input, init)` | A raw `fetch` belongs only in `http` in `api-client.md` and in the auth variant's `/api/auth/*` calls (refresh is called inside `http`'s 401 handling, so going through `http` would recurse). When a screen calls it directly, the auth header·idempotency key·error normalization diverge. Member calls (`NetInfo.fetch()`) are not targeted |
| `three-states` | require | guide | `if \(isPending` | — | `if (isPending) return <LoadingView />;` | `const { data, isPending } = useTasksQuery()` | A data screen renders all three states: loading·empty·error |
| `refresh-single-flight` | require | file:auth-and-session.md | `refreshing \?\?= \(async` | — | `refreshing ??= (async () => {` | `refreshing = (async () => {` | Refresh shares the in-flight Promise. Refresh separately on each concurrent 401 and the rotated refresh token is used twice, so the server·IdP treats it as reuse and revokes the whole session — the user is signed out for no reason |
| `api-path-prefix` | forbid | guide | `http\.(get\|getPage\|post\|patch\|delete)(<.*>)?\(\s*./(tasks\|v1)` | — | `http.get<Task>('/tasks/1')` | `http.post('/v1/tasks', body)` | The wire contract's call path is `/api/tasks` (`http-standard@1` §0). If the prefix diverges, only some calls inside the same app become 404 — if the project spec differs, follow the spec but unify it in one place (the call-site paths) |

When `scope` is `guide`, the verdict is made over the whole assembled guide (pack + seam). When it is `seam`, only the seam
files are examined. When it is `file:<filename>`, only that file — this stops a require from degenerating into being
satisfied by the same string in a sibling file.

## For humans to uphold (undecidable by machine)

- **Ask for a permission at the moment the feature is used.** Asking for everything at app start raises the denial rate,
  and once a permission is permanently denied the OS dialog never appears again
- **A config plugin declaration and a runtime request are a pair.** If the permission string in `app.config.ts` (iOS
  `NSLocationWhenInUseUsageDescription` and the like) is missing, the request is denied or — when there is no location key at all — the app is terminated
- **A release that adds or changes a native module does not ship over OTA.** If the `runtimeVersion` is
  the same, the new JS lands on the old binary, calls a module that is not there, and crashes
- **Hiding a screen is not a trust boundary.** Protected routes are UX and the real verdict is the server's
- **On old Android WebViews the URL in `onMessage` is the top-level page, not the frame that sent it** (the `addJavascriptInterface` path). So `isTrustedOrigin` alone cannot tell a third-party iframe apart — the web side's CSP `frame-src` has to be there too (for a hybrid, the seam's `shell-bridge.md` requires it)
- **Do not inject tokens into a webview.** The auth a web screen needs is owned by the web-side session —
  an injected token can be read by every page that loads in that webview
