<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Project structure — layer boundaries and app assembly

Owns `create_app`, `lifespan`, and **what calls what**. The data layer is owned by
`data-access.md`, schemas by `input-validation.md`, the error table by `error-handling.md`,
and migrations by `migrations.md`.

The error modules are **split into three along the layers.** With `AppError` in `app/http/`,
the single line `import app.db.tasks` pulls fastapi in transitively and the layering collapses (§1).

| symbol | file | does it import the framework |
| --- | --- | --- |
| `AppError` | `app/errors.py` (**seam-owned**) | no — every layer raises it |
| `is_unique_violation` · `is_foreign_key_violation` | `app/db/errors.py` | no — SQLAlchemy only |
| `ERROR_STATUS` · `to_app_error` · `field_errors` | `app/http/errors.py` | yes — `RequestValidationError` |

`app/errors.py` · `app/http/handlers.py` · `app/http/auth.py` · `app/http/routers.py` are
**seam-owned**. The pack only calls them, and having no definition before assembly is normal.

## 1. Decision tree — which layer is this code

| what this code does | where it goes | what it may not do |
| --- | --- | --- |
| handles status codes, headers, cookies, `Request` | `app/http/` (router) | does not compose SQL |
| decides "who may do what" | `app/services/` | does not take a `Request` |
| builds `select`/`update`/`delete` | `app/db/` | does not raise `HTTPException` |
| reads the process environment | `app/settings.py`, **one place** | does not read at request time |
| happens once in the process lifetime | `lifespan` (`app/factory.py`) | not in a request handler |
| attaches routes, handlers, middleware | `create_app` | does not take request arguments |

**Layering runs one way**: `routers → services → db`. Once a repository raises `HTTPException` or takes a
`Request`, that function becomes testable only by standing up HTTP, and it can no longer be reused from a batch job
or a migration script.

Boundaries are not kept by eye. Import direction is something a machine can see — but **grep is the wrong tool for this job.**

```bash
# ✅ no directory means no check — assert existence first
test -d app/db && test -d app/services || exit 1
# ✅ it sees transitivity: if app/db pulls in a web framework through anything, it dies here
uv run python -c "import app.db.tasks, sys; assert 'fastapi' not in sys.modules"
```

Do not use the shape `! grep -rE "^(from|import) (fastapi|starlette)" app/db/ app/services/`.
**It misses two things, and both look like a pass.**

| situation | `!` + grep | the guard above |
| --- | --- | --- |
| `app/services/` does not exist yet | grep exits 2 → `!` inverts it to **exit 0 (pass)** | exit 1 |
| `app/db/errors.py` imports fastapi directly | exit 1 (caught) | exit 1 |
| `app/db` → `app/schemas` → fastapi (two hops away) | **exit 0 (missed)** | exit 1 |
| a clean tree with no violation | exit 0 | exit 0 — **it does not block everything** <!-- verified: built all four situations in a real tree and compared the exit codes of both guards --> |

## 2. App assembly (`app/factory.py`)

<!-- file: app/factory.py -->
```python
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from sqlalchemy import text

from app.db.session import engine
from app.http.handlers import install_error_handlers
from app.http.routers import api_router
from app.obs.health import health_router


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    async with engine.connect() as conn:   # warm up so the first request does not carry the connect latency
        await conn.execute(text("SELECT 1"))
    yield
    await engine.dispose()                 # return the pool on shutdown


def create_app() -> FastAPI:
    app = FastAPI(title="tasks-api", lifespan=lifespan)
    install_error_handlers(app)            # before the routers — miss the registration and everything is a 500
    app.include_router(health_router)      # at the root with no prefix (probes do not live behind /api)
    app.include_router(api_router, prefix="/api")
    return app
```

`create_app` **takes no arguments.** Start taking configuration as an argument and a different app gets assembled
per test, and from then on the "works in tests, fails in deployment" difference hides inside those arguments.
Environment differences are absorbed by `settings` alone.

**Do not build the `app` instance at module top level.** If importing `factory.py` stands the app up on its own,
every router comes up along with it even when Alembic or a script imports `app.db`.
There is one place that builds the app: `main.py`.

## 3. `lifespan` — unattached, it silently never runs

Define `lifespan` but fail to pass it as `FastAPI(lifespan=lifespan)` and the startup and shutdown code is
skipped in its entirety **with no warning at all**. The ASGI server receives `lifespan.startup.complete` as
normal, so not a trace is left in the logs either, and the pool is never returned on shutdown.

| shape | startup/shutdown logs | what ASGI received |
| --- | --- | --- |
| `FastAPI(lifespan=lifespan)` | both startup and shutdown ran | `lifespan.startup.complete` |
| `FastAPI()` (attachment missing) | **nothing ran at all** | `lifespan.startup.complete` — identical <!-- verified: fed the ASGI lifespan events into both apps directly and compared hook execution against the send messages --> |

If something fails inside `lifespan`, the server does not come up. **Do not build a server that can only come up when the
DB is there** — one `connect()` is enough for a warm-up. **Do not run migrations here** — the reason and the deploy order are owned by §7 of `resources/migrations.md`.

`httpx`'s `ASGITransport` **does not run lifespan.** If a test needs the startup code, it has to wrap with
`async with lifespan(app):`, and the whole test harness is owned by `testing.md`.
<!-- verified: 0 hook log lines when requesting through ASGITransport alone -->

## 4. Boot (`app/main.py`)

<!-- file: app/main.py -->
```python
import app.obs.sql  # noqa: F401  — decorator-registered. without the import, slow-query observation never runs
from app.factory import create_app
from app.obs.logging import configure_logging
from app.settings import settings

configure_logging(settings.LOG_LEVEL)   # before create_app
app = create_app()
```

`app/obs/sql.py` is a module that registers itself with `@event.listens_for(engine.sync_engine, …)`.
If nobody imports it, then even with the file present **not one hook is attached and there are 0 warnings** —
wire it and the same query prints 2. Without `# noqa: F401`, ruff deletes it as an unused import.
<!-- verified: ran the same two queries at SLOW_MS=0 and compared 0 lines without the import against 2 with it -->

`main.py` **takes no requests.** If even one route lives here, that route cannot be tested without starting
`uvicorn app.main:app`.

Call `configure_logging` before `create_app`, and before uvicorn attaches its own handler.
Called later, there are two handlers and every line prints twice.

```bash
uv run uvicorn app.main:app --reload    # development
uv run uvicorn app.main:app --workers 4 # deployment (each worker has its own pool — pool sizing is operations.md)
```

## 5. Dependency-injection wiring — build an alias and remove the repetition

```python
# app/http/routers.py
SessionDep = Annotated[AsyncSession, Depends(get_session)]
UserDep = Annotated[AuthUser, Depends(current_user)]
```

The `app/http/routers.py` excerpts in this section are **seam-owned** (the combination decides the envelope shape). The pack
only fixes the shape that must be kept there. Build the `Annotated` alias once and reuse it —
repeat `session: AsyncSession = Depends(get_session)` per router and missing
`Depends` in any one of them still leaves a plausible-looking signature.

**Receive the session only through `Depends(get_session)`.** If a router calls `session_factory()` itself,
that request has two transactions, and even on an exception `get_session`'s rollback knows nothing about that session.

**Receive the user only through `Depends(current_user)`.** If even one router parses the token itself,
there are two boundaries, and those two will always diverge. The `AuthUser.id` `current_user` returned
is the `owner_id`, and that value goes all the way down to the data layer unchanged.

```python
# app/http/routers.py
from app.db import tasks as repo              # take it as a module alias — prevents name collisions
from app.services import tasks as service


@tasks_router.get("", response_model=list[TaskOut])
async def list_tasks(session: SessionDep, user: UserDep,
                     q: Annotated[TaskQuery, Query()]) -> list[Task]:   # not Depends()
    items, _cursor = await repo.list_tasks(session, user.id, q)
    return items


@tasks_router.post("", response_model=TaskOut, status_code=status.HTTP_201_CREATED)
async def create_task(session: SessionDep, user: UserDep, body: TaskCreate) -> Task:
    return await service.create_task(session, user.id, body)


@tasks_router.patch("/{task_id}", response_model=TaskOut)
async def patch_task(session: SessionDep, user: UserDep, task_id: UUID,
                     body: TaskUpdate) -> Task:
    patch = body.model_dump(exclude_unset=True)   # do not carry fields that were never sent
    return await service.apply_patch(session, user.id, task_id, patch)
```

**Three axis contracts live in this excerpt.** ⓐ A successful create is **201** (at `200` the client cannot tell a
create from an update). ⓑ The list query model is received as `Annotated[TaskQuery, Query()]` —
receive it with `Depends()` and `extra="forbid"` becomes void, so unknown parameters are silently ignored. <!-- verified: received the same TaskQuery both ways — ?limit=5 gives 200 on both, ?limit=5&bogus=1 gives 422 on Annotated / 200 on Depends -->
ⓒ Drop `exclude_unset=True` and the `None` defaults of `TaskUpdate` ride along, so fields that were never sent get overwritten with
`NULL`. This conversion is **the router's obligation** and `update_task` receives an already-filtered `patch`.

## 6. Registering the exception handlers — `create_app` must call it

`install_error_handlers(app)` is defined by the seam and **called by `create_app`.** Miss the
call and `AppError` escapes as an unhandled exception, so a response that should have been a 404 becomes a 500 plus a traceback
— it is not a syntax error, so nothing tells you about the omission.

| `install_error_handlers(app)` | response of a route that raises `AppError("NOT_FOUND", …)` |
| --- | --- |
| called | `404` + `{"error": {"code": "NOT_FOUND", …}}` |
| omitted | an unhandled exception — the server emits a 500 and a traceback <!-- verified: attached the same route to both apps and compared the responses --> |

Hang handlers on all three: `AppError` · `RequestValidationError` · `Exception`. **Even without the last one the body does
not leak** — Starlette's `ServerErrorMiddleware` fixes the body to the plain text `Internal Server Error` at
`debug=False`. The problem is not a leak but **a broken contract**: this pack's
`{"error":{"code":…}}` envelope disappears and the client loses any means of telling what went wrong.

| app | `Exception` handler | response body | contains DSN or table names |
| --- | --- | --- | --- |
| `debug=False` | present | `{"error":{"code":"INTERNAL",…}}` (70B) | no |
| `debug=False` | absent | plain text `Internal Server Error` (21B) | no |
| `debug=True` | absent | traceback (4487B) | **yes** — positive control <!-- verified: raised an exception carrying a DSN string in three apps and substring-checked the bodies --> |

A server started with `FastAPI(debug=True)` emits the traceback as-is. **Do not turn `debug` on in
production.** Normalization is decided by `to_app_error` and the status code by `ERROR_STATUS.get(code, 500)`, both of which live in
`app/http/errors.py` (owned by `error-handling.md`).

## 7. Mounting routers — a different prefix per layer

`api_router` collects the domain routers and `create_app` attaches it once with `prefix="/api"`.
Write `/api` into each router yourself and an omission appears when you change the prefix, and that omission can show up
not as a 404 but as **a path with no authentication on it**.

```python
# app/http/routers.py
tasks_router = APIRouter(prefix="/tasks", tags=["tasks"])
# … route definitions …
api_router = APIRouter()
api_router.include_router(tasks_router)     # final path: /api/tasks
```

Put `health_router` (`/healthz` · `/readyz`) **outside** `/api` — probes do not attach an auth header, and
when the prefix changes the probe dies first. The content of the health checks is owned by `operations.md`.

## 8. The service layer — where the domain rules live

**Services are module functions** — do not wrap them in a class. Put stateless functions in a class and you gain one more
constructor wiring, and that wiring ends up different in routers, tests, and batch jobs.

```python
# app/services/tasks.py
from app.db import tasks as repo
from app.db.tasks import Task
from app.errors import AppError


async def read_task(session: AsyncSession, owner_id: UUID, task_id: UUID) -> Task:
    task = await repo.get_task(session, owner_id, task_id)
    if task is None:
        raise AppError("NOT_FOUND", "task not found")   # a domain code, not a status code
    return task


async def apply_patch(session: AsyncSession, owner_id: UUID, task_id: UUID,
                      patch: dict[str, Any]) -> Task:
    return await repo.update_task(session, owner_id, task_id, patch)   # the repository applies the allowlist
```

The repository returns `None` and the service raises it as `AppError`. That one step of separation splits "absent" (a data
fact) from "404" (an HTTP decision) — when called from a batch job, 404 means nothing.

A thin service that simply passes through to the repository is normal. **Do not delete it for being empty** —
it is the place where permission rules and transactions spanning several repositories will land. The service takes `session`
**as an argument** too.

## Misuse list ① — Flask · older FastAPI → 0.141 idioms

| old habit | current shape (FastAPI 0.141) |
| --- | --- |
| `@app.on_event("startup")` / `"shutdown"` | the `lifespan` context manager + `FastAPI(lifespan=…)` |
| `app = FastAPI()` at module top level | the `create_app()` factory · the instance only in `main.py` |
| global request state such as `g` · `current_app` | explicit injection through `Depends` |
| `q: TaskQuery = Depends()` | `q: Annotated[TaskQuery, Query()]` |
| repeating `session = Depends(get_session)` per router | one `SessionDep = Annotated[…]` alias |
| deciding the status code with `try/except` per router | raise `AppError` and let `install_error_handlers` fold it |
| parsing the token inside the router | one `Depends(current_user)` |
| writing `/api` into the router path yourself | `include_router(api_router, prefix="/api")` |
| the service raising `HTTPException` | `AppError(code, message)` — the first argument is the domain code |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `main.py` vs `factory.py` | the former is boot (logging setup + one instance), the latter is assembly. Routes live in neither |
| `lifespan` vs middleware | once per process is the former, once per request is the latter |
| `include_router(prefix=…)` vs `APIRouter(prefix=…)` | a grouping inside the axis is the latter, the app-wide mount point is the former |
| `Depends(get_session)` vs `session_factory()` | inside a request, always the former. The latter is for scripts and batch jobs only |
| `AppError` vs `HTTPException` | the pack and the services always use the former. The latter appears only inside the seam's handler |
| `/healthz` vs `/readyz` | process liveness is the former (it does not look at the DB), dependency readiness is the latter |
| `create_app()` vs a module-global `app` | what tests and scripts call is the former. The latter is the single name uvicorn points at |
