# Wire contract — nextjs × supabase

<!-- orangekit-wire-contract: nextjs+supabase v3.12.0 -->

The canonical contract of a prebuilt seam. This combination is already settled, so it was
**derived from the real seam and frozen**. The gate `--pair --contract <this file>` checks both sides against this document.

## 0. Domain vocabulary (new item)

Both axis packs and the seam use **the same resource name**. Measured: in both prebuilt pairs the frontend
used `/tasks` and the backend `/notes`, so the complete examples could not run against each other — it was a hole in
the contract form, and this section is the repair.

- Entity: `Task` · collection: `tasks` · display label: Task

The frontend of this combination does not call its own REST routes with fetch — a Server Component reads the data
layer directly and mutations go through a Server Action. So the paths (`/tasks` · `/api/tasks`) are not
subject to vocabulary matching; they are only a record of where the backend mounts.

## 0.5. There are two boundaries (specific to this combination)

Next.js embeds a server runtime, so the client↔server boundary exists in **two forms**.
The five wire-contract items apply to ① only; ② is a separate contract. Fixing only one of them and generating
throws the whole form-error flow out of alignment.

Boundary ① is Route Handler ↔ fetch and uses the HTTP envelope of §1–§5 below. Boundary ② is Server
Action ↔ useActionState and has no HTTP status code — it uses the type contract of §6.

**In this combination ② is the primary one.** The frontend's Server Components read the data layer directly, so
① is closer to a surface for external consumers and webhooks. That is why §1–§5 are declared `surface: backend` —
requiring them on both sides makes a healthy combination FAIL forever.

## 1. Success response envelope

> surface: backend

The contract of the Route Handler boundary (①). The frontend does not consume this envelope — it uses the action contract of §6.

- Single: carries `data` only — `{ data: Task }`
- List: a `data` array + `page` · `total`
- Delete: 200, body `{ data: null }`

## 2. Error response envelope

> surface: backend

Same as above.

Inside `error`: `code` · `message` · `details` (optional). Codes are **lowercase snake_case**
(`validation_error`) — not SCREAMING_SNAKE.

## 3. Pagination model

> surface: backend

Same as above. The frontend's list screen is read directly by a Server Component.

- Model: **offset only**
- Request parameters: `page`, `limit`
- Response fields: `page` · `total` (implemented with Supabase `range()`)

totalPages is not a wire field — the frontend derives it from total and the page size.

Cursor-family fields (nextCursor) are not in this contract.

## 4. Error code ↔ status mapping

> surface: backend

HTTP status exists only at the Route Handler boundary. The action boundary has no status code.

| code | status | when |
| --- | --- | --- |
| `validation_error` | 400 | Zod failure, FK/CHECK violation |
| `invalid_json` | 400 | body cannot be parsed |
| `unauthenticated` | 401 | `getUser()` returns null |
| `forbidden` | 403 | signed in but not permitted (RLS `42501`) |
| `not_found` | 404 | absent **or** hidden by RLS (`PGRST116`) — do not leak existence |
| `conflict` | 409 | unique collision (`23505`) |
| `rate_limited` | 429 | limit backed by external storage (no in-memory) |
| `internal_error` | 500 | unexpected exception — do not expose the internal message |

## 5. The surface of authorization failure

> surface: backend

A contract on the shape of the HTTP response. The frontend-side auth flow (middleware session refresh · protected routes)
appears as a redirect rather than a status code, so no token is required here.

- Unauthenticated: 401 `unauthenticated`
- Authorization failure: **404 `not_found`** — a row hidden by RLS arrives as `PGRST116`, and separating that
  out as a 403 leaks existence. 403 is used only for insufficient role (`42501`)
- Return after auth expiry: the middleware refreshes the session, and on failure redirects to login
  while preserving the return path. Only a value that passed `safeInternalPath` is used as the return path
- **Match the response format to the path**: `/api/*` returns the error envelope above, page paths return a redirect

## 6. Server Action contract (boundary ②)

> surface: frontend

The frontend defines the action and the frontend consumes it. This type does not exist in the backend guide.

```ts
export interface ActionState {
  error?: string                       // short message to show the user
  fieldErrors?: Record<string, string[]>
  values?: Record<string, string>      // refill the form on failure
}
```

- Do not `throw` a domain error out across the boundary — return it in the type
- On success, `redirect()` or `revalidatePath()` and then return an empty state
- The previous state from `useActionState` arrives as the first argument (`_prev`)
