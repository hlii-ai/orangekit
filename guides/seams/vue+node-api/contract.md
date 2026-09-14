# Wire contract — vue × node-api

<!-- orangekit-wire-contract: vue+node-api v3.13.0 -->

The canonical contract of this combination. The gate `--pair --contract <this file>` checks both sides against this document.

> Contract values are written **only in list items and table rows**. Backticks in prose and block quotes are treated as explanation —
> a negation, or a helper name used by one side only, goes in prose.

## 0. Domain vocabulary

The `pack.json` of both axis packs already fixes the same values (`vue` and `node-api` both carry
`entity: Task` · `collection: tasks`). They are carried over unchanged.

- Entity: `Task` · collection: `tasks` · display label: Task
- Frontend call path: `/api/tasks` · backend mount path: `/api/tasks`

This combination **has only one boundary.** Vue is an SPA and node-api is a separate server, so there is a single
HTTP boundary between the browser's `fetch` and the Express router — there is no second boundary of
Server Components · Server Actions the way `nextjs × supabase` has. So every section below applies to
both sides (there is no `surface:` declaration).

## 1. Success response envelope

- Single: carries `data` only — `{ data: Task }`
- List: a `data` array + `nextCursor`
- Create: 201, the created row in `data`
- Delete: 204, no body

## 2. Error response envelope

- Inside `error`: `code` · `message` · `details` (optional)
- `requestId` at the top level

`details` holds per-field errors and its shape is `Record<string, string[]>`. It is carried only on a validation failure.

## 3. Pagination model

- Model: cursor
- Request parameters: `limit` · `cursor`
- Response field: `nextCursor` (null on the last page)

Offsets (`page` · `skip`) are not used — when a list changes often, rows are duplicated or dropped at the page
boundary. The backend pack decides whether a next page exists with `take: limit + 1`.

## 4. Error code ↔ status mapping

The frontend branches its screens on `code`, so this table must exist verbatim on both sides.

| code | status | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | 400 | the request body · query does not match the schema. `details` is carried |
| `UNAUTHENTICATED` | 401 | the token is missing or failed verification |
| `FORBIDDEN` | 403 | authenticated but the role is insufficient. **Not used for ownership failure** |
| `NOT_FOUND` | 404 | the row is absent or belongs to someone else — the two are not distinguished |
| `CONFLICT` | 409 | unique constraint collision |
| `PAYLOAD_TOO_LARGE` | 413 | the body exceeded the parser limit |
| `INTERNAL` | 500 | everything else. The cause is not carried in the response |

`NETWORK_ERROR` · `TIMEOUT` · `BAD_SHAPE` are codes the client makes on its own —
the server does not send them, so they live in the frontend guide only.

## 5. The surface of authorization failure

- Unauthenticated: 401 `UNAUTHENTICATED`
- Authorization failure (ownership): 404 `NOT_FOUND` — **does not leak existence**
- Authorization failure (role): 403 `FORBIDDEN`
- Return after auth expiry: on a 401 the frontend attempts one reissue, and on a second failure sends the user to login

Ownership failure is returned as 404 because of a premise of the backend axis — there is no data-layer policy
engine, so the application layer is the only boundary, and distinguishing 403 from 404 would let an unauthorized
user enumerate the existence of resources. The frontend handles 404 in one screen as "absent, or not mine".

## 6. The authentication surface

This combination is an SPA (separate origin) + its own server, so authentication crosses the HTTP boundary — hence this section.

**Only values both sides can see go in a list.** Cookie attributes are decided by the server alone and the frontend never sees them
(httpOnly) — putting them in a list makes the gate require them of the frontend too, and a healthy combination FAILs.

- Mount path: `/api/auth` · endpoints: `/login` · `/refresh` · `/logout`
- Access token delivery: `Bearer` in the `Authorization` header
- Login success envelope: `accessToken`
- Cross-origin: the frontend sends `credentials`

**Server only (the frontend cannot see these)**: the reissue token is carried in an `httpOnly` cookie named `rt`,
its path narrowed to `/api/auth`, and because this is cross-site it is `SameSite=None; Secure`. The server echoes the
concrete origin back and emits `Access-Control-Allow-Credentials` and `Vary: Origin`.
The server may also emit an expiry hint on the login response (something like `expires_in`), but **the frontend of this
combination does not use it** — it reissues reactively on a 401, so it does not lean on clock synchronization.

**Frontend only**: `/api/auth/login` · `/logout` are the full paths the frontend calls, while the server mounts
the router at `/api/auth` and then registers `/login` — the strings diverging is normal.

Reissue happens **once** (§5). If a rotated reissue token is reused, the family is invalidated.
