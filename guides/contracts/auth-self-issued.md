# Auth adapter wire — self-issued

<!-- orangekit-wire-contract: auth-self-issued v1 -->

A sub-contract of `http-standard.md` §6. In combinations where the server issues logins and tokens itself (`authKind: self-issued`),
**the self-issued variants of the web, app and server packs do not deviate from this table by a single character.** If the project has its own
auth spec, that is canonical (`http-standard.md` "Precedence"). Basis: measured in the pilot, the app sent an extra `client` in the reissue
body and the server's strict schema returned a 400.

| endpoint | browser request | app request | success response |
| --- | --- | --- | --- |
| `POST /api/auth/login` | `{ email, password }` | `{ email, password, client: 'app' }` | 200 `{ data: { accessToken, refreshToken? } }` — `refreshToken` only for the app; the browser gets the httpOnly cookie `rt` (`Path=/api/auth`) |
| `POST /api/auth/refresh` | no body · no `Content-Type` · cookie | `{ refreshToken }` (no other keys) | same shape as login; the refresh token is rotated every time |
| `POST /api/auth/logout` | no body · cookie | `{ refreshToken }` | 204, invalidates that whole family (idempotent) |

Every failure is a 401 `UNAUTHENTICATED`, with no distinction of reason (unknown account, wrong password, reuse detected).
For a browser request authenticated by cookie alone, the server matches `Origin` exactly against the allow list (CSRF).
