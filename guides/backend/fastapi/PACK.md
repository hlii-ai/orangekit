<!-- orangekit-pack: backend/fastapi v3.14.0 verified 2026-08-24 fastapi@0.141 pydantic@2 pydantic-settings@2 sqlalchemy@2 alembic@1 asyncpg@0.31 uvicorn@0.52 pytest@9 pytest-asyncio@1 httpx@0.28 ruff@0.16 pyright@1 -->

# fastapi axis pack — hub fragments

These are the **axis-local fragments to insert verbatim** when building the combination hub (`SKILL.md`). A combination that has
a pre-built seam does not use this file — in that case the seam's `HUB.md` holds the hub in full.

Each fragment sits between `<!-- pack-slot: name -->` and `<!-- /pack-slot -->`, and it closes inside the axis,
so it holds whatever the frontend axis is. Nothing here is a function of the combination —
the table at the end of the file states what belongs to the seam.

<!-- pack-slot: directory-structure -->
## Directory Structure

```
app/
├── main.py                  # boot only — configure_logging() → create_app() (takes no request)
├── factory.py               # create_app(): mount routers + exception handlers + attach lifespan
├── settings.py              # the **only** file that reads the process environment (validates/fails at module top level)
├── db/
│   ├── base.py              # Base(DeclarativeBase) + constraint naming convention (premise of Alembic autogeneration)
│   ├── session.py           # engine · session_factory · get_session dependency
│   └── tasks.py             # task repository — knows nothing about HTTP. takes session as an argument
├── schemas/
│   └── task.py              # Pydantic schemas + the TaskStatus enum (the model uses the same enum)
├── errors.py                # AppError — **owned by the seam.** does not import the framework
├── db/errors.py             # SQLSTATE detection (23505·23503) — knows only asyncpg. knows nothing about HTTP
├── http/
│   ├── errors.py            # ERROR_STATUS · to_app_error · field_errors (imports fastapi)
│   ├── handlers.py          # install_error_handlers — **owned by the seam**
│   ├── auth.py              # current_user · AuthUser — **owned by the seam**
│   └── routers.py           # api_router — **owned by the seam**
├── obs/
│   ├── logging.py           # configure_logging — **does not import the DB**
│   ├── health.py            # health_router — kept apart because readyz uses engine
│   └── sql.py               # slow-query events. **registration-based, so main.py has to import it to run**
└── services/
    └── tasks.py             # domain rules. calls the repository and raises AppError

alembic/
├── alembic.ini              # sqlalchemy.url stays **empty** — env.py takes the connection string from settings
├── env.py                   # hands Base.metadata over as target_metadata (premise of autogeneration)
└── versions/                # migrations — read and fix by hand before committing

tests/
├── conftest.py              # app_client · override_user · test DB isolation
├── test_schemas.py          # schema units — partial update · unknown key · empty object
├── test_errors.py           # error normalization — SQLSTATE detection and the envelope
└── test_tasks.py            # ownership regression — positive and negative in the same test
```

**Layering runs one way**: `routers → services → db`. Once a repository raises `HTTPException` or takes a
`Request`, that layering has already collapsed — its tests will only run if they stand up HTTP.

**The four files under `app/http/` are seam-owned.** The pack only calls them. Having no definition before
assembly is normal, and the gate checks that they are satisfied when run with `--assembly`.
<!-- /pack-slot -->

<!-- pack-slot: core-principles-axis -->
## Core Principles

1. **Ownership lives in the `WHERE`.** There is no row-level policy engine and the app connects to the DB over a
   trusted connection, so a query that omits the owner condition hands back exactly what was asked for. The application check is not
   defense in depth but **the only defense**.
2. **Layering runs one way** (`routers → services → db`). The repository takes `session` as an argument and
   knows nothing about HTTP. A domain failure rises as `AppError` (the seam).
3. **There is one transaction boundary, `get_session`.** It opens one session per request and commits once on success.
   Commit in every repository and one router leaves a half-applied state behind.
4. **The environment is read in one place, `settings`.** `Settings` is validated at module top level, so a bad
   environment is a boot failure — blowing up at request time leaves a half-alive server.
5. **Every boundary has a schema.** Input is `TaskCreate`·`TaskUpdate`·`TaskQuery`, output is `TaskOut` —
   return the ORM model as-is and columns added later leak out silently.
6. **All async, all type hints.** One synchronous session blocks the event loop.
<!-- /pack-slot -->

<!-- pack-slot: common-imports-axis -->
## Common Imports

```python
# app/db/ — the engine and session family come from sqlalchemy.ext.asyncio
from sqlalchemy import delete, select, update
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, selectinload
# app/schemas/ · app/settings.py · routers
from typing import Annotated
from pydantic import BaseModel, ConfigDict, Field, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict
from fastapi import APIRouter, Depends, FastAPI, Query, status
from fastapi.exceptions import RequestValidationError
```

**Where the v1 idioms get confused** — the names are a character or two apart, so copying an old example silently mixes them.

| old habit (Pydantic v1 · SQLAlchemy 1.x) | current shape (Pydantic 2 · SQLAlchemy 2.0) |
| --- | --- |
| `sessionmaker()` | `async_sessionmaker(...)` — the synchronous one blocks the loop in an async router |
| `session.query(Task).filter(...)` | `await session.execute(select(Task).where(...))` |
| `declarative_base()` · `Column(...)` | `class Base(DeclarativeBase)` · `Mapped[...]` + `mapped_column(...)` |
| `class Config: orm_mode = True` | `model_config = ConfigDict(from_attributes=True)` |
| `.dict()` · `parse_obj()` · `@validator` | `.model_dump()` · `model_validate()` · `@field_validator` |
<!-- /pack-slot -->

<!-- pack-slot: architecture-overview -->
## Architecture Overview

```
boot   configure_logging() → create_app(): mount routers · install_error_handlers(app)
                                          · FastAPI(lifespan=lifespan) → engine.dispose() on shutdown
request → api_router (seam, prefix="/api") → domain router
         ├ Depends(current_user) → AuthUser      ← the only auth boundary (failure = 401)
         ├ TaskCreate / Annotated[TaskQuery, Query()] validation (failure = 422)
         └ Depends(get_session) ─── transaction boundary opens (one request = one session)
                ▼
           TaskService (services/tasks.py) — domain rules, raises AppError
                ▼
           db/tasks.py  get_task(session, owner_id, task_id)  ← the owner condition goes here, inside the WHERE
                ▼        PostgreSQL 16 (asyncpg)
   success → get_session commit → TaskOut serialization → JSON   ┐ boundary closes
   exception → get_session rollback → to_app_error(exc) → ERROR_STATUS.get(code, 500) → seam envelope
```

- **There is exactly one place that commits, `get_session`.** Neither the service nor the repository commits.
  That is also why `session_factory` sets `expire_on_commit=False` — if `TaskOut` reading an attribute after
  the commit fires another query, you get I/O in the middle of response serialization.
- **No dependency runs against the arrows — and the file layout enforces that.** It is why the two things
  `db/` uses (`AppError` · SQLSTATE detection) sit outside `http/`. `app/http/errors.py` imports `fastapi`
  for `RequestValidationError`, so putting `AppError` there makes the single line
  `import app.db.tasks` **pull fastapi in transitively** — measured, that is what happened.
  `python -c "import app.db.tasks, sys; assert 'fastapi' not in sys.modules"` is the check for this
  discipline (a string grep cannot see transitivity). `/healthz` on `health_router` does not look at the DB.
<!-- /pack-slot -->

<!-- pack-slot: http-status-and-antipatterns -->
## HTTP status mapping and the recurring anti-patterns

`ERROR_STATUS` is the **only mapping table**. Everywhere, read it in the form `ERROR_STATUS.get(code, 500)` —
subscript access raises `KeyError` on an unknown code, and that `KeyError` becomes a 500 that erases the original code.

| domain code | status | when |
| --- | --- | --- |
| `VALIDATION_FAILED` | 422 | schema violation · empty patch · `decode_cursor` failure |
| `UNAUTHENTICATED` | 401 | `current_user` could not establish a subject |
| `FORBIDDEN` | 403 | the subject is confirmed but the action is not allowed |
| `NOT_FOUND` | 404 | `get_task` returned `None` · `rowcount == 0` — **someone else's row lands here too** |
| `CONFLICT` | 409 | `is_unique_violation` (SQLSTATE 23505) |
| `INTERNAL` | 500 | everything else `to_app_error` folded |

- ❌ **Splitting 404 and 403 by ownership** — "it exists but it is not yours" is a 403 that is an existence leak.
  A row that failed the owner condition is treated as **a row that does not exist**.
- ❌ **Deciding a duplicate from the driver message string** — it changes with locale and version.
  `is_unique_violation`·`is_foreign_key_violation` decide on SQLSTATE (23505·23503).
- ❌ **A router raising `HTTPException` directly** — it bypasses the seam's handler and the envelope becomes two shapes.
- ❌ **Exposing the exception as-is** — the original message carries the DSN and table names. The handler normalizes with
  `to_app_error` first. Do not build field errors per router either — `field_errors` is the only place.
<!-- /pack-slot -->

<!-- pack-slot: quick-start-axis -->
## Quick Start — adding one endpoint

Keep the order. Put the router before the repository and you end up guessing signatures.

| # | step | file to open |
| --- | --- | --- |
| 1 | model columns and indexes (the `(owner_id, created_at, id)` composite index is the premise of keyset pagination) | `app/db/base.py` · `app/db/tasks.py` |
| 2 | generate the migration, then **read and fix it by hand** — index names, type changes, and data migration are beyond autogeneration | `alembic/versions/` |
| 3 | schema and enum — **share** `TaskStatus` with the model | `app/schemas/task.py` |
| 4 | repository function — the argument order is always `session → owner_id → task_id` | `app/db/tasks.py` |
| 5 | domain rules — call the repository and raise `AppError` | `app/services/tasks.py` |
| 6 | router — `Depends(current_user)` · `Depends(get_session)` · `response_model=TaskOut` | the seam's `app/http/routers.py` collects it |
| 7 | tests — drive the app directly with `app_client` and switch the subject with `override_user(app, auth_for(...))` | `tests/conftest.py` · `tests/test_tasks.py` |

```bash
uv run alembic revision --autogenerate -m "add tasks"
uv run alembic upgrade head
uv run alembic check                  # model ↔ schema drift (0 pass · 255 drift)
uv run ruff check . && uv run pyright && uv run pytest
```

**If step 6 is a partial update**, extract the body with `model_dump(exclude_unset=True)` and hand it to `update_task` (the router's
obligation). **Step 7 puts the positive and the negative in the same test** — assert only the 404 and you stay green even after breaking lookup entirely.
<!-- /pack-slot -->

<!-- pack-slot: anti-patterns-axis -->
## Anti-Patterns — most expensive on this axis first

**The top three all come out of the premise that the data layer has no policy engine.** The DB connection is a trusted connection,
so the query hands back exactly what was asked for — the narrative on other axes that "row-level policy is the backup, so the application
check is defense in depth" is **exactly the opposite instruction** here.

| anti-pattern | why it is expensive | instead |
| --- | --- | --- |
| a single-item lookup with no owner condition | nothing stops this query. **One missing line is a leak of every user's data** | call only `get_task(session, owner_id, task_id)` |
| comparing the owner in Python after the query | someone else's row **has already been read**. It stays in the logs, the traces, the timings | push the filter down into the query |
| not looking at `rowcount` after `UPDATE`/`DELETE` | mutating 0 rows still succeeds — a request to delete someone else's row gets a 204 | 0 means `AppError("NOT_FOUND")` |
| calling with the arguments `(session, task_id, owner_id)` | both are `UUID`, so neither the type checker nor the gate catches it. Every single-item lookup silently becomes a 404 | fix `session → owner_id → task_id` |
| `create_task` dropping `data.status` and hard-coding the default | what the client sent silently disappears. The syntax is perfect, so review passes it too | carry over **every** field of `data` |
| using `model_dump()` for a partial update | fields that were never sent overwrite storage with defaults | `model_dump(exclude_unset=True)` |
| returning the ORM model as the response | columns added later leak out silently | `TaskOut` (`from_attributes=True`) |
| a router parsing the token itself | the auth boundary becomes two, and those two will always diverge | `Depends(current_user)` only |
| committing in the service or the repository | one request leaves a half-applied state behind | `get_session` commits once |
| attaching `selectinload` to lists out of habit | every page reads extra relations that will never be serialized | only when the response actually carries them |
| `OFFSET` pagination · treating the cursor as trusted input | deep pages slow down linearly, and a client-built string enters as the sort key | keyset with `encode_cursor`/`decode_cursor`. A decode failure is `VALIDATION_FAILED` |
| building `lifespan` and not passing it to `FastAPI(...)` · calling `configure_logging` after `create_app` | the former silently never runs so connections survive shutdown, the latter leaves the uvicorn handler in place so every log line prints twice | `FastAPI(lifespan=lifespan)` · logging before `create_app` |
<!-- /pack-slot -->

## What the seam fills in

| slot | why it is a function of the combination |
| --- | --- |
| `api-endpoints` | APIRouter shape + request/response envelope. The wire contract decides the envelope |
| `auth-boundaries` | how the token is verified depends on whether the frontend axis has a server runtime |
| `complete-example` | a pass through migration → model → schema → repository → service → router → test |
