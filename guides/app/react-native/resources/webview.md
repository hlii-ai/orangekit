<!-- orangekit-pack: app/react-native v1.0.0 -->
# WebView — showing web content and the trust boundary

This file owns `src/webview/trustedOrigin.ts` (`isTrustedOrigin`) and the WebView's **origin validation · navigation restriction ·
injected script scope**. **Which screens are webviews** and **the web ↔ native message schema** are functions of the app shape
(cross-platform · rn-webview · rn-native-screens) and the web screen axis, so they belong to the seam's `shell-bridge.md`
(when the shape is cross-platform that file does not exist and only the §1 table of this file applies). The list of allowed origins is
read only from `config.trustedWebOrigins` (owned by `config-and-testing.md`).

## 1. Decision tree — when to use a WebView and when not to

| Situation | What to pick | Why |
| --- | --- | --- |
| Embedding our own web screens in the app (hybrid shell · terms · help) | `react-native-webview` + the three devices in this file | We control the origin |
| Sending the user to a third-party site (external links · a payment provider's info page) | `Linking.openURL(url)` — the system browser | The app has no reason to open a bridge to that page. `expo-web-browser` is not in the pack's `pkgs` |
| OAuth sign-in | WebView **forbidden** — the flow in the seam's `auth-and-session.md` | IdPs block embedded WebViews, and it becomes a structure where the app can snoop on password entry |
| Only showing web content, no native features | A WebView, without `onMessage` | The moment you pass `onMessage`, `window.ReactNativeWebView` is injected |

<!-- verified: the onMessage comment in react-native-webview@13.17.0 lib/WebViewTypes.d.ts — "Setting this property will inject this global into your webview" -->

The three devices do not stand in for each other: **navigation restriction** (which pages load) · **message origin validation** (who sent
it) · **injection scope** (what is handed to the page). Have only one and an attacker comes in through the other two holes.

## 2. `isTrustedOrigin` (`src/webview/trustedOrigin.ts`)

<!-- file: src/webview/trustedOrigin.ts -->
```ts
// src/webview/trustedOrigin.ts
export function isTrustedOrigin(url: string, allowed: readonly string[]): boolean {
  if (typeof url !== 'string' || url === '') return false;
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'https:') return false;
  const origin = parsed.origin;
  return allowed.some((o) => o === origin);
}
```

- The unit of comparison is **an exact match of the serialized origin string**. A prefix (`startsWith`)·substring·regex lets
  `https://app.example.evil.com` through
- `allowed` is a value `config` already normalized with `new URL(v).origin`, so case·default ports are aligned.
  Pass a hand-written list (`'https://App.Example/'`) and nothing passes — it fails closed
- Expo SDK 57 swaps the global `URL` for a WHATWG implementation (`whatwg-url-minimum`) — RN's default `URL` is regex-based,
  so its `origin` even carries user info <!-- verified: expo@57 src/winter/runtime.native.ts install('URL') · src/winter/url.ts · the get origin regex in react-native@0.86.3 Libraries/Blob/URL.js -->

### Run results — `allowed = ['https://app.example']`

Below are the results of actually running the same function on two implementations: Node and the `whatwg-url-minimum` the Expo runtime uses.

| Input | `origin` | Result | Verdict |
| --- | --- | --- | --- |
| `https://app.example/tasks/42` | `https://app.example` | `true` | Passes normally |
| `https://app.example.evil.com/` | `https://app.example.evil.com` | `false` | Prefix attack blocked |
| `https://app.example@evil.com/` | `https://evil.com` | `false` | User-info disguise blocked |
| `http://app.example/` | `http://app.example` | `false` | Not https |
| `HTTPS://APP.EXAMPLE/tasks` | `https://app.example` | `true` | Scheme·host case is normalized |
| `https://app.example:443/` | `https://app.example` | `true` | The default port notation is dropped |
| `https://app.example:8443/` | `https://app.example:8443` | `false` | A different origin |
| `https://app.example./` | `https://app.example.` | `false` | A trailing dot is a different host string |
| `https://app.example\@evil.com` | `https://app.example` | `true` | In special schemes `\` is `/` — the actual navigation goes to app.example too |
| `about:blank` · `''` · `not a url` · `javascript:alert(1)` | — | `false` | Parse failure·not https |

## 3. Navigation restriction — `onShouldStartLoadWithRequest` is the only boundary

`originWhitelist` is not a boundary but **a gate in front of the callback**. The install turns each entry into **a regex with no end
anchor**, `^` + escaping + (`*` → `.*`), tests it against the origin, and hands only the requests that pass to `onShouldStartLoadWithRequest`.
**URLs that do not pass skip the callback, and the library opens them itself with `Linking.openURL`** (any scheme, if `canOpenURL`
is true). Omitting the prop does the same thing with the default `['http://*', 'https://*']`.
<!-- verified: react-native-webview@13.17.0 src/WebViewShared.tsx:20-64 defaultOriginWhitelist · createOnShouldStartLoadWithRequest (source comparison + the three functions copied and run) -->

So the list **opens with a lone `'*'` to send every navigation to the callback**, and the verdict is made in the callback with `isTrustedOrigin` only.
A lone `'*'` becomes `^.*`, which passes even an empty origin. The result of running the installed whitelist function together with the callback below
(`allowed = ['https://app.example']`):

| URL | Reaches the callback | Top-frame result | Subframe |
| --- | --- | --- | --- |
| `https://app.example/x` · `HTTPS://APP.EXAMPLE/` | Yes | `true` (loads) | `true` |
| `https://evil.com/` · `mailto:a@b.c` · `tel:+82…` | Yes | `false` + `Linking.openURL` | `false` |
| `http://evil.com/` | Yes | `false` (not sent outside either) | `false` |
| `intent://…` · `otherapp://pay` · `javascript:…` · `about:blank` · `data:…` · `file:///…` | Yes | `false` | `false` |

```tsx
// src/webview/TrustedWebView.tsx — the navigation verdict
const EXTERNAL = new Set(['https:', 'mailto:', 'tel:']);

function onShouldStartLoadWithRequest(req: ShouldStartLoadRequest): boolean {
  if (isTrustedOrigin(req.url, config.trustedWebOrigins)) return true;
  if (!req.isTopFrame) return false; // a subframe leaving is quietly blocked — it does not drag the user out of the app
  let protocol = '';
  try { protocol = new URL(req.url).protocol; } catch { return false; }
  if (EXTERNAL.has(protocol)) void Linking.openURL(req.url).catch(() => {});
  return false; // http:·intent:·other apps' schemes·javascript:·data:·file: are sent nowhere
}
```

- The callback argument is not an event but the `ShouldStartLoadRequest` itself (`req.url` · `req.isTopFrame`) — the library
  strips `nativeEvent` before passing it <!-- verified: react-native-webview@13.17.0 lib/WebViewTypes.d.ts:172 OnShouldStartLoadWithRequest · src/WebViewShared.tsx:60-61 -->
- **`'*'` and this callback are a pair.** Keep `'*'` without the callback and every page loads — change only the list, never drop the callback
- **The remaining gap**: the table above is the JS-layer verdict. Loads for which native does not call this callback (the initial `source` load —
  §6 · Android `iframe` loads — §7) do not go through this verdict <!-- unverified: neither path confirmed on a device -->
- Without the navigation restriction, the injected script of §5 rides along on unfamiliar pages too

## 4. Receiving messages — origin → parse → schema

```tsx
// src/webview/TrustedWebView.tsx — the message receiver
function onMessage(event: WebViewMessageEvent) {
  if (!isTrustedOrigin(event.nativeEvent.url, config.trustedWebOrigins)) return;
  let msg: unknown;
  try {
    msg = JSON.parse(event.nativeEvent.data);
  } catch {
    return; // ignore malformed messages — so a string the web throws cannot kill the app
  }
  onBridgeMessage(msg); // schema check·branching is in shell-bridge.md
}
```

- **The order is the contract.** Look at the origin first — parsing·schema checks only add code that handles untrusted input
- `event.nativeEvent.url` is **the URL of the frame that sent the message** (iOS: `message.frameInfo.request.URL`).
  Even if the top-level page is a trusted origin, a message sent by a third-party `iframe` inside it is judged by that `iframe`'s URL
  <!-- verified: react-native-webview@13.17.0 apple/RNCWebViewImpl.m:798-803 (source comparison, not a device run) -->
  (for Android see §7)
- `data` is always a string — the web side sends it with `postMessage(JSON.stringify(...))`
  <!-- verified: lib/WebViewTypes.d.ts WebViewMessage { data: string } -->
- Even after passing the schema, the action a message asks for (payment · deletion) is judged again by the server. The bridge is not a trust boundary

## 5. The scope of injected scripts — no tokens

| prop | When it runs | Default scope |
| --- | --- | --- |
| `injectedJavaScriptBeforeContentLoaded` | Before the document loads | Main frame only (`…ForMainFrameOnly` defaults to `true`, forced on Android) |
| `injectedJavaScript` | After load | Main frame only (`injectedJavaScriptForMainFrameOnly` defaults to `true`, forced on Android) |

<!-- verified: react-native-webview@13.17.0 lib/WebViewTypes.d.ts:1060-1070 comment — "true (default; mandatory for Android)" -->

Injected scripts ride along again **on every page the top-level frame navigates to**. So the only things that may go in are values that
are safe to publish: a shell marker, the platform, the app version. **No access tokens · refresh tokens · user identifiers** — auth for web
screens is owned by the web-side session (cookies), and how they connect is decided by the seam's `shell-bridge.md` · `auth-and-session.md`.
Do not widen it to subframes with `…ForMainFrameOnly={false}`.

```ts
// src/webview/TrustedWebView.tsx — the injected value
const shellFlag = `window.__APP_SHELL__ = ${JSON.stringify({ platform: Platform.OS })}; true;`;
// ❌ A token in a page global — every page that loads in this webview can read it
const leak = `window.__TOKEN__ = ${JSON.stringify(tokens.accessToken)}; true;`;
```

## 6. Assembly — `TrustedWebView` and the trust verdict per direction

```tsx
// src/webview/TrustedWebView.tsx
type Props = { uri: string; onBridgeMessage: (msg: unknown) => void };

export function TrustedWebView({ uri, onBridgeMessage }: Props) {
  // onMessage · onShouldStartLoadWithRequest · shellFlag are §3–§5
  const ref = useRef<ComponentRef<typeof WebView>>(null); // useRef<WebView> folds props to never and is a type error
  const currentUrl = useRef(uri); // the top-level page currently showing

  // Native → web: judge the top-level URL again right before sending
  const send = (payload: unknown) => {
    if (!isTrustedOrigin(currentUrl.current, config.trustedWebOrigins)) return;
    ref.current?.postMessage(JSON.stringify(payload));
  };

  return (
    <WebView
      ref={ref}
      source={{ uri }}
      originWhitelist={['*']}
      onShouldStartLoadWithRequest={onShouldStartLoadWithRequest}
      onNavigationStateChange={(nav) => { currentUrl.current = nav.url; }}
      onMessage={onMessage}
      injectedJavaScriptBeforeContentLoaded={shellFlag}
      setSupportMultipleWindows={false}
      webviewDebuggingEnabled={__DEV__}
    />
  );
}
```

`send` is handed over as the reply path of `onBridgeMessage` (that wiring is in `shell-bridge.md`). `WebView` is the class `WebView<P = undefined>`,
so passing a `useRef<WebView>` to `ref` makes the props type `never` <!-- verified: react-native-webview@13.17.0 index.d.ts + @types/react@19 · ran typescript@6 tsc -->.

| Direction | Trust verdict | Rationale |
| --- | --- | --- |
| Web → native (`onMessage`) | `isTrustedOrigin` on the sending frame's URL (§4) | Pages·`iframe`s we did not choose can get into the webview |
| Native → web (`postMessage` · `injectJavaScript`) | `isTrustedOrigin` on `currentUrl` **right before sending** (`send` above) | A redirect may already have made it a different page — the reply would land in the wrong page's hands |
| Messages the web receives | Up to the web-side code — `shell-bridge.md` | A function of the web screen axis |

- `setSupportMultipleWindows={false}` (Android): a `target="_blank"` link becomes a navigation of the same webview instead of a new window,
  so it goes through the §3 verdict <!-- unverified: only the prop's existence was confirmed at lib/WebViewTypes.d.ts:859; behavior not confirmed on a device -->
- `uri` itself must be a trusted origin too — the first load may not go through `onShouldStartLoadWithRequest`
  <!-- unverified: whether the callback is called for the initial source load was not confirmed per platform -->. Block it with
  `isTrustedOrigin(uri, config.trustedWebOrigins)` before the screen passes it in

## 7. The `url` of subframe messages — platform differences

What `event.nativeEvent.url` is depends on the platform and the Android WebView version. What was confirmed from the installed source:

| Platform · path | Value in `url` | When a subframe sent it |
| --- | --- | --- |
| iOS (`WKScriptMessage`) | `message.frameInfo.request.URL` — the full URL of the sending frame | That `iframe`'s URL <!-- verified: apple/RNCWebViewImpl.m:798-803 (source comparison) --> |
| Android, a WebView supporting `WEB_MESSAGE_LISTENER` | The listener's `sourceOrigin` — **only the origin** of the sending frame (no path) | That `iframe`'s origin <!-- verified: android/.../RNCWebView.java:250-264 addWebMessageListener(…, Set.of("*"), …) → onMessage(data, sourceOrigin.toString()) (source comparison) --> |
| Android, an unsupported WebView (the `addJavascriptInterface` fallback path) | `mWebView.getUrl()` — **the top-level page URL** | The top-level URL — it cannot tell which frame sent it <!-- verified: android/.../RNCWebView.java:446-449 (source comparison) --> |

- On the first two paths, `isTrustedOrigin` judges the sending frame. Android's `sourceOrigin` is an origin string
  (`https://app.example`), so parsing·comparison work as is. An opaque origin arrives as `"null"` and gives `false`
- **On the third path, a third-party `iframe` inside a trusted page looks like the trusted origin.** So a web screen that opens the bridge
  does not load third-party `iframe`s (enforced with the web-side CSP `frame-src` — the job of `shell-bridge.md`). Which devices take this
  path is decided by the device's WebView version <!-- unverified: the minimum WebView version supporting WEB_MESSAGE_LISTENER is unconfirmed -->
- The subframe block in §3 (`isTopFrame === false` → `false`) is called for every subframe navigation on iOS. Whether Android's
  `shouldOverrideUrlLoading` is called for `iframe` loads was not confirmed <!-- unverified: needs a device run --> —
  so on Android, do not rely on this block; keep the CSP above

## Misuse list ① — old habits → the current shape in react-native-webview 13

| Old habit | Current shape |
| --- | --- |
| RN core `import { WebView } from 'react-native'` | `react-native-webview` — it was removed from core long ago <!-- unverified: the removal version is unconfirmed --> |
| Sending to native with `window.postMessage(data)` | `window.ReactNativeWebView.postMessage(string)` <!-- verified: onMessage comment in lib/WebViewTypes.d.ts --> |
| Writing only the trusted origins in `originWhitelist` and using it as the boundary | Send every navigation to the callback with a lone `'*'`, and judge with `isTrustedOrigin` in `onShouldStartLoadWithRequest` |
| `url.startsWith(TRUSTED)` · `url.includes('app.example')` | `isTrustedOrigin(url, config.trustedWebOrigins)` — exact origin match |
| Putting the token in `injectedJavaScript` to pass the sign-in state | The web session owns it — how they connect is in `shell-bridge.md` |
| `onShouldStartLoadWithRequest={(e) => e.nativeEvent.url …}` | The argument is the request object — `(req) => req.url` |

## Misuse list ② — confusable pairs

| Often chosen wrongly | Exact condition for each |
| --- | --- |
| `originWhitelist` vs `onShouldStartLoadWithRequest` | The former is the gate deciding whether to send to the callback — anything outside the list is opened externally with no verdict, so a lone `'*'`. The verdict happens only in the latter |
| `event.nativeEvent.url` (message) vs the current top-level URL | The receive verdict uses the former (the sending frame). The send verdict uses the latter (the page showing now) |
| `injectedJavaScriptBeforeContentLoaded` vs `injectedJavaScript` | A marker the web code must read when it starts is the former. If it needs the DOM, the latter |
| WebView vs `Linking.openURL` | The former if it is our origin and must stay inside the app. Everything else goes to the system browser |
| A subframe leaving (`isTopFrame === false`) vs the top frame leaving | Subframes are only blocked. Only the top frame sends allowed schemes outside |
