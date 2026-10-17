<!-- orangekit-pack: backend/fastify v3.35.0 -->
# Auth flow — external IdP (who logs the user in, and what the server prepares)

This file owns the flow in which tokens travel **outside the server**, and what the server prepares in order to
receive them: `src/http/auth-plugin.ts` (CORS) and the IdP registration items. The side that **checks** tokens
(`requireAuth` · environment keys · `authFor`) is owned by `resources/auth-boundaries.md`. The login screen and the
PKCE calls belong to the frontend and app guides.

## 1. Judgment — who does what

| job | done by | this server |
| --- | --- | --- |
| login (Authorization Code + PKCE) | frontend · app ↔ IdP | not involved — there are no `/api/auth` routes |
| refresh (refresh_token grant · silent renewal) | frontend · app ↔ IdP | not involved |
| API calls | frontend · app → this server (`Authorization: Bearer <access token>`) | `requireAuth` verifies against the JWKS |
| after receiving a 401 | the client refreshes once with the IdP → retries → login on failure (contract §5) | emits the same 401 |
| logout | the client discards the token and ends the IdP session | nothing to do (§4) |

**This server holds no secrets at all.** All it uses for verification are public keys (JWKS) and public values
(`iss` · `aud`) — so there is no signing secret to leak and no refresh token table to store. That is this variant's
biggest advantage over self-issued.

## 2. What to register with the IdP

| item | value | why |
| --- | --- | --- |
| API (resource server) | identifier = `OIDC_AUDIENCE` | the access token's `aud` has to point at this API to filter out tokens meant for other apps |
| access token format | a signed JWT (RS256 · ES256) | an opaque token cannot be verified with the JWKS — it would need an introspection (RFC 7662) path |
| client | a public client + PKCE, **no client secret** | an SPA or app has nowhere to hide a secret. The redirect URIs are decided by the frontend and app guides |
| access token lifetime | short (5–15 minutes) | this server cannot revoke issued tokens (§4) |
| discovery values | `issuer` → `OIDC_ISSUER`, `jwks_uri` → `OIDC_JWKS_URI` | copy them character for character — one trailing slash turns everything into a 401 |

Some IdPs, when the authorization request names no audience, issue a token for the userinfo endpoint instead of a JWT
for this API — confirm, together with the frontend and app settings, that the client puts the audience in its login
request
<!-- unverified: each IdP's default token format (e.g. an Auth0 access token obtained without an audience) is from the docs and was not run in this pack -->.

## 3. CORS (`src/http/auth-plugin.ts`)

In this variant `authPlugin` has no routes. The browser calls from another origin carrying the `Authorization`
header, so only preflight requests (OPTIONS) need handling. No cookies are used, so `credentials` stays off.

<!-- file: src/http/auth-plugin.ts -->
```ts
// src/http/auth-plugin.ts
import cors from '@fastify/cors'
import fp from 'fastify-plugin'
import { env } from '../env'

// Wrapped in fp so it attaches to the root — preflight requests have to reach /api/tasks too. The requireAuth hook is not here
export const authPlugin = fp(async (app) => {
  await app.register(cors, {
    origin: env.WEB_ORIGINS,
    methods: ['GET', 'POST', 'PATCH', 'DELETE'],
    exposedHeaders: ['location', 'x-request-id'],
  })
})
```

The allowed origins are the exact list in `WEB_ORIGINS`. The app (React Native) is not a browser and does not go
through CORS — there is no reason to widen the origins because of the app.

## 4. Logout and token lifetime — this server does not revoke

A JWT access token is valid until `exp` as long as the signature matches. Logout is the client discarding the token and
ending the IdP session, and **an access token already issued keeps passing at this server.** That is why the lifetime
is kept short (§2). A domain that demands immediate revocation (account suspension has to take effect at once) needs
introspection that asks the IdP on every request, and that cost (latency · dependence on IdP availability) is not
covered by this pack — it is a project decision.

| situation | result |
| --- | --- |
| the user logs out | the token is discarded on the client side. A stolen copy is valid until `exp` |
| the account is disabled at the IdP | no new tokens are issued. Issued access tokens are valid until `exp` |
| the IdP rotates its signing key | when a token with a new `kid` arrives, `createRemoteJWKSet` refetches the key set |

## 5. When roles become necessary

`AuthUser` is at minimum `{ id }`. When roles (`FORBIDDEN`) become necessary, `requireAuth` moves the claims the IdP
carries (groups · scopes) into `AuthUser`, and the routes that need a role are split into **a separate route plugin**
with a role hook set on that context (`resources/project-structure.md` §6). An ownership failure is a 404 regardless
of role — the role hook does not replace it.

## Misuse list ① — self-issued habits → this variant's shape

| old habit | current form |
| --- | --- |
| putting `/login` · `/callback` on the server | the public client (SPA · app) does it directly with the IdP via PKCE. The server only verifies |
| the server manages the refresh token as a cookie | refresh is client ↔ IdP. This server has neither cookies nor a token table |
| invalidating the token with a logout API | an access token is valid until `exp` — keep the lifetime short, and do immediate revocation via introspection (a project decision) |
| a client secret in the SPA | a public client + PKCE. A secret in the bundle is not a secret |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| `credentials: true` vs off | off, since no cookies are used. Turn it on and cookies ride along on requests from allowed origins |
| signed JWT vs opaque access token | this variant verifies only the former. Receive the latter and everything is a 401 — look at the IdP settings first |
| adding a CORS origin for the app vs leaving it | leave it. A native app's HTTP requests have no CORS |
| role hook vs ownership condition | both. A role is a 403 (a path whose existence is known), ownership is the query condition and a 404 |
