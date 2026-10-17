<!-- orangekit-pack: backend/fastify v3.35.0 -->
# Complete example — one task from migration to response

This file shows in one pass the whole path a single `Task` travels, and it owns the test that runs through that path,
`src/test/tasks.flow.test.ts`. The code for each layer is already in place — the only thing newly defined here is one
test, and the rest connects **which file takes which step**. The wire values are HTTP standard v1, and if the project
has its own API spec, that is canonical.

## 1. Judgment — the owning file per step

| step | code | owning resource |
| --- | --- | --- |
| table · index | `src/db/schema.ts` → `drizzle/NNNN_*.sql` | `resources/data-access.md` §3 · §7 |
| request schema · response schema | `src/schemas/task.ts` | `resources/input-validation.md` §3 |
| query (ownership · affected row count · cursor) | `src/db/tasks.ts` | `resources/data-access.md` §4 · §5 |
| the authenticated subject | `src/http/require-auth.ts` | `resources/auth-boundaries.md` |
| route · envelope | `src/http/routes/tasks.ts` · `src/http/error-handler.ts` | `resources/api-endpoints.md` |
| assembly · 404 · request ID | `src/app.ts` | `resources/project-structure.md` §2 |
| status table · normalization | `src/http/errors.ts` | `resources/error-handling.md` |
| end-to-end test | `src/test/tasks.flow.test.ts` | **this file** §5 |

Write a new feature in this order too (§6). Change the order — say, start with the route — and a draft that returns
the whole row without a response schema comes first, and that draft carries `ownerId`.

## 2. Once at the start — migrations and the test DB

```bash
npx drizzle-kit generate --name init     # src/db/*schema.ts → drizzle/0000_init.sql (commit it)
npx drizzle-kit migrate                  # applies to the development DB — production uses a separate step of the deploy pipeline
TEST_DATABASE_URL=postgres://localhost/app_test npx vitest run   # global-setup applies the same SQL to the test DB
```

`env` validates the auth keys (`AuthEnvSchema`) too, so give the shell that runs `drizzle-kit` the same environment
as the app. For tests, `authTestEnv` fills them in, so there is nothing extra to supply (`resources/testing.md` §2).

## 3. The path of one request — `POST /api/tasks`

| order | where | what it does | if it ends here |
| --- | --- | --- | --- |
| 1 | root `onRequest` | `x-request-id` header = `req.id` (UUID) | — |
| 2 | `onRequest` in the `tasksRoutes` context | `requireAuth` → `req.user` | 401 `UNAUTHENTICATED` |
| 3 | content-type parser | JSON parsing · `bodyLimit` | 400 · 413 · 415 |
| 4 | validator compiler | `TaskCreateSchema` — trim · `status` default · rejects unknown keys | 400 + `details` |
| 5 | handler | `insertTask(ownerOf(req.user), req.body)` | 409 `CONFLICT` (same title) |
| 6 | serializer compiler | `{ data: TaskViewSchema }` — removes `ownerId`, `Date` → ISO | 500 (shape mismatch) |
| 7 | response | 201 + `Location: /api/tasks/{id}` | — |

Step 2 coming before step 3 is why `onRequest` was chosen — an unauthenticated request is a 401 before its body is even
parsed (`resources/project-structure.md` misuse list ②). Wherever it ends, there is one envelope and the root
`errorHandler` emits it.

A hand test once you have a token (how to get a token is in `resources/auth-boundaries.md`):

```bash
H="authorization: Bearer $TOKEN"
curl -si -X POST localhost:3000/api/tasks -H "$H" -H 'content-type: application/json' -d '{"title":"one"}'
# 201, location: /api/tasks/<id>, {"data":{"id":"…","title":"one","status":"open","createdAt":"…"}}
curl -s 'localhost:3000/api/tasks?limit=2' -H "$H"            # {"data":[…],"nextCursor":"<ISO>_<id>" or null}
curl -si -X PATCH localhost:3000/api/tasks/<id> -H "$H" -H 'content-type: application/json' -d '{"status":"done"}'
curl -si -X DELETE localhost:3000/api/tasks/<id> -H "$H"      # 204 — do not set content-type
```

## 4. What a failure looks like to the client

| situation | status | `error.code` | `details` |
| --- | --- | --- | --- |
| empty title · unknown key | 400 | `VALIDATION_FAILED` | `{ title: [...] }` · `{ priority: [...] }` |
| tampered cursor | 400 | `VALIDATION_FAILED` | `{ cursor: [...] }` |
| no token · expired | 401 | `UNAUTHENTICATED` | — |
| missing task · someone else's task | 404 | `NOT_FOUND` | — (the two bodies are byte-for-byte identical) |
| recreating the same title | 409 | `CONFLICT` | — |

The client branches on `code`, not on the status. One 404 draws "missing or not mine" on the same screen.

## 5. The end-to-end test (`src/test/tasks.flow.test.ts`)

The tests in `resources/testing.md` each look at one property (4 ownership pairs · auth over everything). This test
walks **the life of one task** in order and checks that the joints between layers (reading by the `id` from the
create response · sending the cursor back as-is) mesh.

<!-- file: src/test/tasks.flow.test.ts -->
```ts
// src/test/tasks.flow.test.ts
import { afterAll, beforeAll, beforeEach, describe, expect, it } from 'vitest'
import { buildApp, type App } from '../app'
import { pool } from '../db/client'
import { resetDb } from './db'
import { authFor } from './auth'

let app: App
beforeAll(async () => { app = await buildApp({ logger: false }) })
afterAll(async () => { await app.close(); await pool.end() })
beforeEach(resetDb)

describe('the life of one task', () => {
  it('creates · walks · changes · deletes — and is a 404 to anyone else from start to finish', async () => {
    const alice = authFor('alice')
    const bob = authFor('bob')

    const invalid = await app.inject({ method: 'POST', url: '/api/tasks', headers: alice, payload: { title: '' } })
    expect(invalid.statusCode).toBe(400)
    expect(invalid.json().error).toMatchObject({ code: 'VALIDATION_FAILED', details: { title: expect.any(Array) } })

    const ids: string[] = []
    for (const title of ['one', 'two', 'three']) {
      const res = await app.inject({ method: 'POST', url: '/api/tasks', headers: alice, payload: { title } })
      expect(res.statusCode).toBe(201)
      expect(res.json().data).toMatchObject({ title, status: 'open' })
      ids.push(res.json().data.id)
    }

    // The cursor is sent back as-is without interpreting it — two pages cover the three rows exactly once each
    const p1 = (await app.inject({ url: '/api/tasks?limit=2', headers: alice })).json()
    const p2 = (await app.inject({ url: `/api/tasks?limit=2&cursor=${encodeURIComponent(p1.nextCursor)}`, headers: alice })).json()
    expect(p1.data).toHaveLength(2)
    expect(p2.data).toHaveLength(1)
    expect(p2.nextCursor).toBeNull()
    expect(new Set([...p1.data, ...p2.data].map((t: { id: string }) => t.id))).toEqual(new Set(ids))

    const id = ids[0]!
    const done = await app.inject({ method: 'PATCH', url: `/api/tasks/${id}`, headers: alice, payload: { status: 'done' } })
    expect(done.statusCode).toBe(200)
    expect(done.json().data).toMatchObject({ id, title: 'one', status: 'done' })

    // Another user: read · update · delete are all 404 and the list is empty — and the original is unchanged afterwards
    for (const req of [{ method: 'GET' }, { method: 'PATCH', payload: { status: 'open' } }, { method: 'DELETE' }] as const) {
      expect((await app.inject({ ...req, url: `/api/tasks/${id}`, headers: bob })).statusCode, req.method).toBe(404)
    }
    expect((await app.inject({ url: '/api/tasks', headers: bob })).json().data).toEqual([])
    expect((await app.inject({ url: `/api/tasks/${id}`, headers: alice })).json().data.status).toBe('done')

    expect((await app.inject({ method: 'DELETE', url: `/api/tasks/${id}`, headers: alice })).statusCode).toBe(204)
    const gone = await app.inject({ url: `/api/tasks/${id}`, headers: alice })
    expect(gone.statusCode).toBe(404)
    expect(gone.json().error.code).toBe('NOT_FOUND')
  })
})
```

<!-- unverified: this test was not run — its components (4 ownership pairs · cursor · 409) rest on the run observations in resources/testing.md and data-access.md (2026-10-15), and the end-to-end pass after the envelope changed to contract v1's data is first run by pack-smoke -->

The line that re-checks alice's `status: 'done'` after bob's three 404s is the pair — without it, a defect where
someone else's PATCH returns a 404 while actually changing the row (the condition left out and only the affected row
count checked) passes green.

## 6. When adding one more feature — the same order

1. Columns and indexes in `src/db/schema.ts` → `npx drizzle-kit generate` → read the generated SQL and commit it
2. `src/schemas/task.ts` — the create schema (defaults allowed) · the update schema (`.optional()` only) · the response schema (only what is exposed)
3. `src/db/tasks.ts` — first argument `ownerId`, ownership in the `where`, mutations by affected row count
4. `src/http/routes/tasks.ts` — inside the same plugin the auth hook already reaches it. For another domain, a new plugin
5. Tests — one ownership pair (positive 200 + negative 404) **per new function**, plus one end-to-end pass like this file
6. If a wire field the frontend or app sees changes, fix the project API spec first — this pack's example fields are just the four

## Misuse list ① — seam-era · Express habits → this pack's end-to-end shape

| old habit | current form |
| --- | --- |
| write the route first and the schema later | table → schema → query → route → test (§6) |
| reading the create response as `res.json().id` | `res.json().data.id` — a single item is inside the envelope too |
| the client builds the cursor and sends it | send `nextCursor` back as-is — the encoding belongs to the server |
| mocking the DB in the end-to-end test | a real DB + `resetDb` — cursors and ownership are properties of the SQL |
| `migrate` in the boot script | a separate step (`resources/operations.md` §7) |

## Misuse list ② — confusable pairs

| what is often picked wrong | exact condition for applying it |
| --- | --- |
| end-to-end test vs property test | both. The end-to-end test looks at the joints, the property tests at per-function blocking — one end-to-end pass does not replace the 4 ownership pairs |
| no `nextCursor` vs `null` | the key is always there, and it is `null` on the last page |
| a JSON header on `DELETE` vs none | none. A JSON header without a body is a 400 <!-- unverified: FST_ERR_CTP_EMPTY_JSON_BODY was observed with POST in resources/error-handling.md §1 — not run with DELETE --> |
| 400 `details` keys vs form field names | the same — `fieldErrors` spreads the path into the field name. Only a form-wide error uses `_` |
