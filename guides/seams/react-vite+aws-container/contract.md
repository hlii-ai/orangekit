# Wire contract — react-vite × aws-container

<!-- orangekit-wire-contract: react-vite+aws-container v3.12.0 -->

The canonical contract of a prebuilt seam. On the generation path the main session fills this form at L0, but
this combination is already settled, so it was **derived from the real seam and frozen**. The gate
`--pair --contract <this file>` checks both the frontend and the backend against this document.

## 0. Domain vocabulary (new item)

Both axis packs and the seam use **the same resource name**. Measured: in both prebuilt pairs the frontend
used `/tasks` and the backend `/notes`, so the complete examples could not run against each other — it was a hole
in the contract form, and this section is the repair.

- Entity: `Task` · collection: `tasks` · display label: Task
- Frontend call path: `/tasks`
- Backend mount path: `/api/tasks`

The frontend's base URL (`config.apiBaseUrl`) already includes `/api`, so the two paths point at the same place.

## 1. Success response envelope

- Single: carries `data` only — `{ data: Task }`
- List: a `data` array + `nextCursor`
- Delete: 204, no body

## 2. Error response envelope

Inside `error`: `code` · `message` · `details` (optional), with `requestId` at the top level.

## 3. Pagination model

- Model: cursor **only**
- Request parameters: `limit`, `cursor`
- Response field: `nextCursor` (null on the last page)

Offset-family fields (page · offset · totalCount) are not in this contract. The reason this is written here
rather than in a list is that the gate reads a backtick in a list as "a value that must exist on both sides".

## 4. Error code ↔ status mapping

| code | status | when |
| --- | --- | --- |
| `BAD_REQUEST` | 400 | JSON cannot be parsed, malformed query |
| `UNAUTHORIZED` | 401 | token missing · expired · signature mismatch (reason not distinguished) |
| `FORBIDDEN` | 403 | authenticated but insufficient role · scope (not ownership) |
| `NOT_FOUND` | 404 | resource absent **or** unauthorized access |
| `CONFLICT` | 409 | unique constraint violation, state conflict |
| `PAYLOAD_TOO_LARGE` | 413 | body exceeds the size limit |
| `VALIDATION_FAILED` | 422 | schema validation failed |
| `INTERNAL` | 500 | unexpected exception (do not expose the internal message) |

Codes the client makes on its own (NETWORK_ERROR · TIMEOUT · BAD_SHAPE) live in the frontend guide only — the backend does not emit them, so they are not in the table.

## 5. The surface of authorization failure

- Unauthenticated: 401 `UNAUTHORIZED`
- Authorization failure: **404 `NOT_FOUND`** — do not leak existence. A frontend that handles only 403 goes out of alignment.
  403 arrives only on the non-ownership axis (insufficient role)
- Return after auth expiry: attempt a silent refresh on the first 401 only, and if that fails again send the user
  to login while preserving the return path

Only a value that passed each axis's validation helper is used as the return path — safeReturnTo on the frontend,
safeReturnPath on the backend. The name differs per axis, so this is written here rather than in a list.
