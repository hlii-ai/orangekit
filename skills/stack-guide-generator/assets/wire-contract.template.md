# Wire contract

<!-- orangekit-wire-contract -->

The canonical source pasted into both agents **identically, down to the wording** when the two guides are generated **in isolation**.
The main session fills in this form in Step 3-0 as a single scratch file, and in Step 4
`guide-gate.sh --pair --contract <this file>` compares both sides against that same file.

> **Where to write them**: contract values go **only in list items (`-`) and table rows (`|`)**. Backticks in prose paragraphs and
> block quotes (`>`) are treated as explanation and the gate does not compare them. So a negation such as "this is not in
> the contract", or a helper name used by one side only, **goes in prose** — put it in a list and the gate reads it
> as a value that must be present on both sides.
>
> **Filling rules**: wrap field names and error codes **in backticks individually**
> (`` `nextCursor` ``, `` `NOT_FOUND` ``). Put a whole envelope inside one backtick span and
> the gate has no token to extract, so the comparison passes silently. Write status codes as bare numbers.
> Leave an undecided item as `<...>` and the gate catches it as a FAIL right there.

## 0. Domain vocabulary (required — leave it empty and the gate catches it as a FAIL)

The two guides must use **the same resource name**. Measured, in both prebuilt pairs the frontend used
`/tasks` while the backend used `/notes`, so the complete examples could not run against each other — the cause was nailing down the envelope, the codes, and
the pagination while leaving the vocabulary empty.

- Entity: <e.g. `Task`> · collection: <e.g. `tasks`> · display label: <e.g. Task>
- Frontend call path: <e.g. `/tasks`> · backend mount path: <e.g. `/api/tasks`>

> **If there is an axis pack, do not invent one.** Carry `exampleDomain` from `guides/<axis>/<pack>/pack.json`
> over verbatim — the pack's examples are already written in that vocabulary, so deciding otherwise misaligns them at once.

## 1. Success response envelope

- Single: carries `data` only — <e.g. `{ data: Note }`>
- List: <each field name in its own backticks — e.g. a `data` array + `nextCursor`>
- Delete: <the status code and whether there is a body — e.g. 204, no body>

## 2. Error response envelope

<each field name in its own backticks — e.g. `code` · `message` · `details` (optional) inside `error`,
and `requestId` at the top level>

## 3. Pagination model

- Model: <cursor or offset — **only one**. Mix the two and the frontend's list screen goes wrong wholesale>
- Request parameters: <e.g. `limit`, `cursor`>
- Response fields: <e.g. `nextCursor` (null on the last page)>

## 4. Error code ↔ status mapping

If the frontend branches its screens on `code`, this table must be present **identically on both sides**.
Codes the client produces for itself (network failure and the like) live in the frontend guide only.

| code | status | when |
| --- | --- | --- |
| `<CODE>` | <status> | <condition> |

## 5. The surface of authorization failure

- Unauthenticated: <status code + code — e.g. 401 `UNAUTHORIZED`>
- Authorization failure: <with **no existence leakage** it is 404. If the frontend handles only 403 they misalign>
- Return after auth expiry: <is there a reissue, and at which status code>

## 6. The authentication surface (required for a self-built auth backend)

**Measured evidence (2026-08-23)**: on the `vue × node-api` seam, the two authors each decided the auth
endpoints and the token transport **on their own**. They happened to agree, but **the gate cannot catch it when they do not** —
because the contract had no such section, `--pair` had no token to compare. It is exactly the same class of hole that
produced §0 Domain vocabulary.

**This section is unusually full of one-side-only values — put them in a list and a perfectly good combination FAILs.**
Measured during development: writing cookie attributes (`Path` · `SameSite` · `Secure` · the cookie name) into a list made the gate
demand them of the frontend too. The frontend **cannot see** an `httpOnly` cookie. Put only values both sides see
into lists, and push the rest down into "server only" · "frontend only" prose.

- Mount path: <e.g. `/api/auth`> · endpoints: <e.g. `/login` · `/refresh` · `/logout`>
- Access token transport: <e.g. `Bearer` in the `Authorization` header>
- Login success envelope: <**only the fields the frontend actually reads** — e.g. `accessToken`>
- If cross-origin: <what the frontend sends — e.g. `credentials`>

**Server-only goes in prose**: the cookie name · `Path` · `SameSite` · `Secure` · `Vary` and so on.
**Frontend-only goes in prose too**: the full path the frontend calls is split across the server's mount + route registration,
so it is normal for the strings to differ.

> This section may be empty when the backend is a BaaS, or in a combination where the frontend axis has a server runtime —
> in that case the authentication never crosses the HTTP boundary. **If you left it empty, write that fact in prose**
> (no silent omission).
