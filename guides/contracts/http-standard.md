# Wire contract — HTTP standard

<!-- orangekit-wire-contract: http-standard v1 -->

**This is the single canonical contract for every axis pack that talks over an HTTP API.** The backend packs (`node-api` · `fastify` ·
`node-nest` · `fastapi` · `aws-container` · `aws-serverless` · `gcp-serverless`) **emit** this contract,
and the frontend and app packs (`react-vite` · `vue` · `vanilla` · `react-native`, plus `nextjs` when it is paired with its own HTTP
backend) **consume** it. Each pack defining its own contract is why every combination had to generate a
seam — the mere difference of calling the same thing `UNAUTHORIZED` in one place and `UNAUTHENTICATED` in another
was enough to make the API client different for every backend.

Out of scope: BaaS (`supabase` · `firebase`) has no HTTP boundary because the frontend attaches directly through the SDK,
and the path where the frontend axis has a server runtime (Server Actions) does not cross this contract either. Those
combinations stay with their per-combination seam and that seam's `contract.md`.

> Contract values go **only in list items and table rows**. Backticks in prose and in quotes are treated as explanation —
> write negations and one-side-only names in prose (form: `assets/wire-contract.template.md`).

## Precedence — the project's spec wins

This contract holds **the example values of the guide's teaching material**. If the project has its own API spec (for example
a contract document in `dev/docs/api/`, or an OpenAPI definition), **that is canonical and this document supplies only the patterns.** Whether the path prefix
is `/v1`, a validation failure is a 422, or the code names differ, follow the project's spec and do not copy the
guide's example values over it. Do not rewrite the contract or ask the user in order to reconcile the two during generation or
installation — the guide's examples and the project's API are different things.

## 0. Domain vocabulary

The same values as `exampleDomain` in every pack's `pack.json`.

- Entity: `Task` · collection: `tasks` · display label: Task
- Frontend call path: `/api/tasks` · backend mount path: `/api/tasks`
- Wire fields: `id` · `title` · `status` · `createdAt`
- `status` values: `open` · `done`

**Do not invent fields.** Measured: while writing the contract the generator made up `todo`/`doing`/`done` states and an
`updatedAt` field on its own, diverged from the pack examples, and cost one more repair round. The example
domain is those four fields and nothing more. The owner column (`ownerId` · DB column `owner_id`) is a server-internal value, so
it need not go on the wire; if it does, use this name. Needing more fields is a matter for the **project's
domain**, not the teaching example — follow "Precedence" above.

## 1. Success response envelope

- Single item: carries `data` only — `{ data: Task }`
- List: a `data` array + `nextCursor`
- Create: 201, the created row in `data`
- Delete: 204, no body

## 2. Error response envelope

- Inside `error`: `code` · `message` · `details` (optional)
- At the top level: `requestId`

`details` is the per-field errors and its shape is `Record<string, string[]>`. An error that applies to the whole form goes under the key
`_`. It is carried only on a validation failure. The server also sends the same request ID in the `x-request-id` response header
— so a response with no body (204 · a proxy error) can still be traced.

## 3. Pagination model

- Model: cursor
- Request parameters: `limit` · `cursor`
- Response field: `nextCursor` (null on the last page)

`limit` is 1–100, default 20. The cursor is an **opaque string** — the encoding (row ID · time+ID ·
DynamoDB key) is decided by the backend pack, and the frontend sends it back without interpreting it. Offsets are not used
— when the list changes often, rows are duplicated or dropped at page boundaries.

## 4. Error code ↔ status mapping

**The client branches on `code`, not on the status code.** So the status codes default to this table,
but in the one place where a framework's default differs you may follow that default — validation failure (FastAPI uses 422).
The authentication and authorization rows (401 · 403 · 404) carry security meaning and are **not changed.**

| code | status | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | 400 | the request body or query does not match the schema, or the JSON is broken. `details` is carried |
| `UNAUTHENTICATED` | 401 | the token is missing or failed verification |
| `FORBIDDEN` | 403 | authenticated but the role is insufficient. **Not used for an ownership failure** |
| `NOT_FOUND` | 404 | the row is missing or belongs to someone else — the two are not distinguished. A missing path is the same |
| `CONFLICT` | 409 | a unique constraint conflict |
| `PAYLOAD_TOO_LARGE` | 413 | the body exceeded the parser limit |
| `UNSUPPORTED_MEDIA_TYPE` | 415 | a non-JSON body |
| `RATE_LIMITED` | 429 | the request limit was exceeded (both a limiter and downstream throttling) |
| `INTERNAL` | 500 | everything else. The cause is not put in the response |

`NETWORK_ERROR` · `TIMEOUT` · `BAD_SHAPE` are codes the client makes up itself — the server
never sends them, so they live only in the frontend and app packs. Do not create a separate code for malformed JSON (a `BAD_REQUEST` kind)
— from the screen's point of view there is nothing to distinguish it from a validation failure.

## 5. The surface of an authorization failure

- Unauthenticated: 401 `UNAUTHENTICATED`
- Authorization failure (ownership): 404 `NOT_FOUND` — **do not leak existence**
- Authorization failure (role): 403 `FORBIDDEN`
- Returning after the session expires: on a 401 the client tries one reissue, and on a second failure sends the user to login

Why an ownership failure goes out as a 404: the backends that use this contract have no data-layer policy engine, so
the application layer is the only boundary, and distinguishing 403 from 404 lets an unauthorized user enumerate which
resources exist. The client handles a 404 on one screen as "missing, or not mine".

## 6. The authentication surface

- Access token delivery: `Bearer` in the `Authorization` header

**How the token is obtained and refreshed is decided by the auth adapter, not by this contract.** What the contract pins
is only the delivery mechanism (Bearer) and the 401 reaction in §5 — which is why the API client and the complete example go into the pack
regardless of the auth method, and only the adapter is swapped. The adapter exports two functions, `getAccessToken()` and
`refresh()`, and the API client calls only those two.

Adapter kinds (prose — not values): **self-issued** (the server puts login · reissue · logout under `/api/auth`
and the refresh token lives in an httpOnly cookie or the app's secure storage) · **external IdP** (OIDC + PKCE — Cognito ·
Auth0 · Identity Platform and the like; the server only verifies through JWKS). A browser client and an app client
differ only in where the refresh token is kept — a cookie versus secure storage.

Authenticating with a server-side session cookie alone (no Bearer) is outside this contract — such a project generates a combination
seam instead of an adapter.

## 7. Paths that bypass the handler

> surface: backend

Errors that occur before the router is reached must go out in **the same envelope** too. If even one leaks out in the framework's default
shape, the client fails to parse only on the rare path — the kind found last in production.

| path | status | code |
| --- | --- | --- |
| a missing path | 404 | `NOT_FOUND` |
| a method that is not allowed | 404 or 405 | `NOT_FOUND` |
| a broken JSON body | 400 | `VALIDATION_FAILED` |
| the body limit exceeded | 413 | `PAYLOAD_TOO_LARGE` |
| a non-JSON body | 415 | `UNSUPPORTED_MEDIA_TYPE` |
| an error thrown by a limiter or auth plugin | 429 · 401 | `RATE_LIMITED` · `UNAUTHENTICATED` |
| an uncaught exception | 500 | `INTERNAL` |

Paths the platform answers in front (API Gateway's default 404 · 413, an authorizer's 401) cannot be blocked by pack code
— the pack in question explains how to configure the gateway's response mapping and records the paths it cannot block under "known constraints".
