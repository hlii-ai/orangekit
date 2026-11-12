# Bridge contract — web screens ↔ native shell

<!-- orangekit-bridge-contract -->

## Contents

- §1 Envelope
- §2 Messages
- §3 Session
- §4 Native routes
- §5 Screens
- §6 Native receipt
- §7 Web hardening

Only for a hybrid RN shell (`appShell` = `rn-webview` · `rn-native-screens`). The main session fills in this form in Step 3-0 as a
**second** scratch file — never as a section of the HTTP wire contract — and pastes the full file verbatim into the frontend and the
app generators. Step 4 compares both sides against that same file:
`guide-gate.sh --pair --contract <this file> --frontend <frontend-guide> --app <app-guide>`.

> **Why a file of its own**: measured on two runs of `react-vite × fastify × rn-native-screens` (2026-10-20), every `high` the
> audits found (5 in one run, 14 in the other) sat on this boundary — route names written in two formats, a sign-in hand-off nobody
> implemented, a refresh failure that signed the web out while native stayed signed in, and a CSP `frame-src` each side left to the
> other. Both runs wrote the bridge as prose inside the HTTP contract, so nothing compared the two sides, and `--pair` demanded the
> bridge tokens of the backend.
>
> **Where to write them** follows `wire-contract.template.md`: values only in list items and table rows, each name in its own
> backticks; one-side-only values and negations go in prose. A section headed by `> surface: app` or `> surface: frontend` is
> required of that side only. A row still holding a `<placeholder>` FAILs the gate.
>
> The values below are defaults. Keep them unless the project already has its own bridge spec — then that spec is canonical, and
> both sides change together.
>
> **The token flow is the user's choice, not this template's.** §2–§3 assume native sends the access token over the bridge — the
> frontend pack's hybrid premise ("the web receives the token from the native bridge"). It collides with the app pack's "Do not inject
> tokens into a webview" (`policies.md`), so it is the Step 3-0 pack-conflict question: ask it, mark no option that breaks a policy as
> Recommended, and if this flow is chosen record the exception in the project. If another flow is chosen, rewrite §2–§3 to match
> before pasting.

## 1. Envelope

- Shape: one JSON string carrying `type` · `version` · `payload`
- Version: `BRIDGE_VERSION` is 1 on both sides; a message whose `version` differs is dropped

Web → native goes through `window.ReactNativeWebView.postMessage`; native → web goes through the `send` reply path of the app
pack's `TrustedWebView` (`webview.md`). `payload` is absent when a row below says none.

## 2. Messages

| `type` | direction | `payload` | answered with |
| --- | --- | --- | --- |
| `bridge.ready` | web → native | none | `auth.token` |
| `auth.refresh` | web → native | none | `auth.token` · `auth.cleared` · `auth.unavailable` |
| `auth.token` | native → web | `accessToken` · `expiresAt` | — |
| `auth.cleared` | native → web | none | — |
| `auth.unavailable` | native → web | none | — |
| `auth.signOut` | web → native | none | `auth.cleared` |
| `nav.openNative` | web → native | `route` | — |

The `payload` cell is `none` or each key in its own backticks. `--pair` checks that each guide uses exactly those keys, so write
each message in code as a one-line literal or type — `{ type: 'auth.token', payload: { accessToken, expiresAt } }`, none means no
`payload` key at all, not `payload: {}` — or read it as `msg.payload.key` inside its `case`; a message it cannot read is REVIEW.

`expiresAt` is epoch milliseconds. When the identity provider returns no lifetime, native sends the access token's `exp` claim × 1000 —
never 0, which makes every web request ask for a refresh.

## 3. Session

- Start: the web posts `bridge.ready` once it can receive, and native answers with `auth.token`
- End: only `auth.cleared` ends the web session
- Transient failure: native answers `auth.refresh` with `auth.unavailable`, and the web keeps its session

Sign-in belongs to native. The WebView is mounted only while native is signed in, so the answer to `bridge.ready` always carries a
token, and the web has no sign-in screen and holds no refresh token. On `auth.cleared` the web clears its caches and stores and waits:
native unmounts the WebView and shows its own sign-in. A reply that never comes (timeout) is treated as `auth.unavailable`, never as
`auth.cleared` — reading silence as sign-out leaves the web signed out while native stays signed in, with nothing to reconcile them.

## 4. Native routes

The names the web may open with `nav.openNative`. The web sends only these, and the native allowlist holds exactly these.

- Routes: <each name in its own backticks — e.g. `camera` · `map`>

A name is bare: lowercase letters, digits and `-`, starting with a letter, at most 64 characters, with **no leading `/`**. A web path
such as `/tasks` is not a native route name, and a native screen the web also renders is not a route here. If the web opens no native
screen, delete the list item and say so in one line of prose.

## 5. Screens

> surface: app

| screen | rendered by | loads |
| --- | --- | --- |
| <the native route group, e.g. `(app)/index`> | <`TrustedWebView` or a native component> | <the web path, or —> |

Every screen the app shows is one row. A `TrustedWebView` screen names the web path it loads; a native screen loads —.

## 6. Native receipt

> surface: app

- Origin: `isTrustedOrigin` runs before any message is parsed, and again on the current URL right before each send

The allowlist compares whole strings against §4 — no prefix match, no normalisation.

## 7. Web hardening

> surface: frontend

- Frames: the page's `Content-Security-Policy` sets `frame-src` to `'none'`, or to the origins the web embeds

Old Android WebViews judge a frame's message by the top-level URL, so `isTrustedOrigin` on the native side cannot tell a third-party
iframe apart (the app pack's `policies.md`). The web side closes that gap; the app guide does not repeat it.
