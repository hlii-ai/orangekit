<!-- orangekit-pack-ledger: backend/fastapi v3.14.0 -->

# fastapi pack — symbol ledger (L0 declaration)

This is the contract the main session declares before authoring. It is the only device that keeps duplicate definitions and **signature
guessing** from appearing when clusters are split and written in parallel.

## provides — this pack defines them

**The "shape" column is mandatory.** Assign only the owning file and leave the shape empty and a sibling cluster
guesses the signature — measured (node-api), one cluster called `getTask(ownerId, id)` as `getTask(id, ownerId)`,
and since both arguments were `string` neither the type checker nor the gate caught it, so every single-item lookup returned
404. Write the argument **order** · the return · what it raises on failure · **what the caller has to wire up**, together.

**The "definition file" is document ownership, not a code path.** For a symbol whose source path is not
self-evident, **nail the path down** in the shape column — measured in fastapi, one cluster imported `Task`
from `app/db/models.py` while the definition was in `app/db/tasks.py`, and **the gate did not catch it either**
(the ledger check only looks at resource files). What caught it was running the type checker.

**The spot that is especially dangerous in this pack**: `owner_id` and `task_id` are **both `UUID`**. Swap the order and
neither Python nor pyright will catch it. Fix the order **`session` → `owner_id` → `task_id`** across every
function. And write the **obligation to consume a field** into the shape — even with a matching signature, not using the *contents*
of an argument produces the same class of fatal defect (measured in aws-serverless: `create_task` dropped `status`).

| symbol | definition file | shape | kind |
| --- | --- | --- | --- |
| `Base` | data-access.md | **`app/db/base.py`** — `class Base(DeclarativeBase)` — puts a naming convention on `MetaData` (constraint names are required for Alembic autogeneration) | declarative base |
| `Task` | data-access.md | **`app/db/tasks.py`** — `class Task(Base)` — `id: Mapped[UUID]` (PK, not a server default — the app makes it) · `title: Mapped[str]` · `status: Mapped[TaskStatus]` · `owner_id: Mapped[UUID]` (**it is the leading column of the composite index — do not give it a standalone `index=True`**) · `created_at: Mapped[datetime]` (tz-aware). The **`(owner_id, created_at, id)` composite index** is the premise of keyset pagination | ORM model |
| `engine` | data-access.md | **`app/db/session.py`** **this is the only definition.** If another file writes the pool values again the two copies diverge — `AsyncEngine` — created at module top level. State `pool_size`·`max_overflow`·`pool_pre_ping` explicitly | engine |
| `session_factory` | data-access.md | **`app/db/session.py`** — `async_sessionmaker[AsyncSession]` — `expire_on_commit=False`. **Left on, attribute access after a commit fires another query and produces I/O in the middle of response serialization** | session factory |
| `get_session` | data-access.md | **`app/db/session.py`** — `async def get_session() -> AsyncIterator[AsyncSession]` — a FastAPI dependency. Opens **one session per request**, commits on success, rolls back on an exception, then closes. Routers receive it only through `Depends(get_session)` | session dependency |
| `list_tasks` | data-access.md | `async def list_tasks(session: AsyncSession, owner_id: UUID, q: TaskQuery) -> tuple[list[Task], str \| None]` — **the owner is second.** The return is `(items, next cursor)`. `WHERE owner_id = :owner_id` is the **only boundary** | list |
| `get_task` | data-access.md | `async def get_task(session: AsyncSession, owner_id: UUID, task_id: UUID) -> Task \| None` — **the order of the two UUIDs is everything.** Missing means `None` (not an exception) | single item |
| `create_task` | data-access.md | `async def create_task(session: AsyncSession, owner_id: UUID, data: TaskCreate) -> Task` — **carries over both `title` and `status` from `data`.** Hard-coding `status` silently discards what the client sent (fatal, measured in aws-serverless). Only `owner_id` comes from the session. A duplicate is `AppError('CONFLICT')` | create |
| `update_task` | data-access.md | `async def update_task(session: AsyncSession, owner_id: UUID, task_id: UUID, patch: dict[str, Any]) -> Task` — `patch` is **already extracted with `exclude_unset=True`** (the router's obligation). Empty means `AppError('VALIDATION_FAILED')`. 0 affected rows means `AppError('NOT_FOUND')` | update |
| `delete_task` | data-access.md | `async def delete_task(session: AsyncSession, owner_id: UUID, task_id: UUID) -> None` — **checks `rowcount`.** 0 means `AppError('NOT_FOUND')`. Without the check, a request to delete someone else's row also returns 204 | delete |
| `encode_cursor` | data-access.md | `def encode_cursor(created_at: datetime, task_id: UUID) -> str` — an opaque string. Do not turn the internal sort key into a wire contract | cursor encoding |
| `decode_cursor` | data-access.md | `def decode_cursor(cursor: str) -> tuple[datetime, UUID]` — failure is `AppError('VALIDATION_FAILED')`. **A cursor is not trusted input** | cursor decoding |
| `Settings` | input-validation.md | `class Settings(BaseSettings)` — `DATABASE_URL` · `LOG_LEVEL` · `ENV`. `model_config = SettingsConfigDict(env_file=…, extra='forbid')` | environment schema |
| `settings` | input-validation.md | a `Settings` instance — **created at module top level.** A validation failure has to be a boot failure (blowing up at request time leaves a half-alive server) | validated environment values |
| `TaskStatus` | input-validation.md | **`app/schemas/task.py`** — `class TaskStatus(StrEnum)` — the members are `OPEN`·`DONE` and **the values are the lowercase `"open"`·`"done"`.** What the wire, the DB, and test assertions use is the **value**, not the member name — leaving this cell empty led a sibling cluster to assert `== "DONE"`, so the flagship block-proof test was permanently red (measured in audit C). The schema, the model, and the query reuse the same enum | status enum |
| `TaskCreate` | input-validation.md | `class TaskCreate(BaseModel)` — `title: str` (1–200) · `status: TaskStatus = TaskStatus.OPEN`. `extra='forbid'` | create body |
| `TaskUpdate` | input-validation.md | `class TaskUpdate(BaseModel)` — `title: str \| None = None` · `status: TaskStatus \| None = None`. **The default of an optional field is `None` and nothing else** — a non-`None` default makes `model_dump()` carry it, so a partial update overwrites the remaining fields (pack-smoke blocks it with a FAIL) | update body |
| `TaskQuery` | input-validation.md | **`app/schemas/task.py`** — `class TaskQuery(BaseModel)` — `limit: int = 20` (1–100) · `cursor: str \| None` · `status: TaskStatus \| None` · **`extra='forbid'`**. The router **receives it as `Annotated[TaskQuery, Query()]`** — `Depends()` ignores `extra='forbid'`, so unknown query parameters pass silently (confirmed by running C1) | list query |
| `TaskOut` | input-validation.md | `class TaskOut(BaseModel)` — `model_config = ConfigDict(from_attributes=True)`. **Do not return the ORM model as-is** — without a response schema, columns added later leak out silently | response schema |
| `ERROR_STATUS` | error-handling.md | **`app/http/errors.py`** — `dict[str, int]` — domain code → HTTP status. **The only mapping table** | status mapping |
| `to_app_error` | error-handling.md | **`app/http/errors.py`** — `def to_app_error(exc: BaseException) -> AppError` — the exception handler **must call it first**. Everything unknown folds into `INTERNAL` (the original message carries the DSN and table names) | normalization |
| `is_unique_violation` | error-handling.md | **`app/db/errors.py`** (it knows nothing about HTTP — `db/` calls it, so putting it under `http/` breaks the layering) — `def is_unique_violation(exc: BaseException) -> bool` — decides on the **SQLSTATE `23505`** of `IntegrityError`. Matching on message strings breaks with locale and driver | duplicate detection |
| `is_foreign_key_violation` | error-handling.md | **`app/db/errors.py`** — `def is_foreign_key_violation(exc: BaseException) -> bool` — SQLSTATE **`23503`** | referential integrity detection |
| `field_errors` | error-handling.md | **`app/http/errors.py`** — `def field_errors(exc: ValidationError \| RequestValidationError) -> dict[str, list[str]]` — joins `loc` with dots and uses it as the key. **Does not strip array indices** — once which item was wrong disappears, the form cannot attach the error | field errors |
| `create_app` | project-structure.md | **`app/factory.py`** — `def create_app() -> FastAPI` — **it does not take a request.** It only mounts routers, registers exception handlers, and attaches the lifespan. It **must call** `install_error_handlers(app)` (the seam) | app assembly |
| `lifespan` | project-structure.md | **`app/factory.py`** **this is the only definition** — `@asynccontextmanager async def lifespan(app: FastAPI) -> AsyncIterator[None]` — warms the pool on startup, `await engine.dispose()` on shutdown. **`create_app` has to pass it as `FastAPI(lifespan=lifespan)`** — unattached, it silently never runs | lifecycle |
| `configure_logging` | operations.md | **`app/obs/logging.py`** — `def configure_logging(level: str) -> None` — called at module import time, **before `create_app`**. Called later, the handlers uvicorn already made survive and every log line is printed twice | logging setup |
| `health_router` | operations.md | `APIRouter` — **goes in `app/obs/health.py`** (not `logging.py`: `readyz` uses `engine`, so merging them makes boot-time logging setup drag in the DB module). `GET /healthz` (process liveness, does not look at the DB) · `GET /readyz` (`SELECT 1`). **Merge the two and a brief DB outage spins a restart loop** | health check |
| `app_client` | testing.md | **`tests/conftest.py`** — `async def app_client(app: FastAPI) -> AsyncIterator[AsyncClient]` — drives the app directly through `ASGITransport`, **without a network**. `base_url='http://test'` is required (httpx cannot build a relative URL) | test client |
| `override_user` | testing.md | **`tests/conftest.py`** — `def override_user(app: FastAPI, user: AuthUser) -> None` — fills `app.dependency_overrides[current_user]`. **Undo it per test** — otherwise the next test runs as the previous user | dependency override |

## requires — the seam has to provide them

`project` has to be defined by the seam; `library` is decided by whether the name appears in an
import statement. **Write the call signature for any symbol the pack calls** — without it, the seam
guesses the argument order (the gate blocks it with a FAIL).

| symbol | kind | shape the pack assumes | why it is a seam |
| --- | --- | --- | --- |
| `AppError` | project | `AppError(code: str, message: str, details: dict[str, list[str]] \| None = None)` — **both leading arguments are `str`, so the order is everything (the code comes first).** The code table must include: `VALIDATION_FAILED` · **`UNAUTHENTICATED`** (`current_user` raises it — if it is missing, a 401 goes out as a 500) · `FORBIDDEN` · `NOT_FOUND` · `CONFLICT` · `INTERNAL`. **Goes in `app/errors.py`** — **not** under `app/http/`. `app/http/errors.py` imports `fastapi`, so putting it there makes `import app.db.tasks` pull fastapi in transitively and breaks the layering discipline (confirmed by running audit A) | the error code table and the field-error shape are a function of the wire contract |
| `install_error_handlers` | project | `def install_error_handlers(app: FastAPI) -> None` — hangs handlers on all three of `AppError` · `RequestValidationError` · `Exception`. **Normalizes with `to_app_error` first, then decides the status with `ERROR_STATUS`.** `create_app` calls it | the response envelope is a function of the wire contract |
| `current_user` | project | `async def current_user(...) -> AuthUser` — a FastAPI dependency. Failure is `AppError('UNAUTHENTICATED')`. Goes in `app/http/auth.py`. **Routers receive it only through `Depends(current_user)`** — if even one router parses the token itself, there are two boundaries | how the token is verified is a function of the combination |
| `AuthUser` | project | at minimum `{ id: UUID, roles: list[str] }` — `id` becomes `owner_id` | same as above |
| `auth_for` | project | `def auth_for(owner_id: UUID, roles: list[str] \| None = None) -> AuthUser` — builds the subject a test hands to `override_user`. **Synchronous** | the claim shape is a function of the authentication method |
| `api_router` | project | `APIRouter` — collects the domain routers, and `create_app` attaches it with `include_router(api_router, prefix='/api')` | the route layout is a function of the combination |

## Known gaps

None. All 6 axis-local mandatory slots are filled, and what looks empty (API endpoints · the authentication boundary ·
the complete example) belongs to the seam declared by `seamSlots` in `pack.json`.

## Symbols appearing in examples — app symbols (the project creates them)

Neither `provides` nor `requires`. They appear in the examples by name only, so having no definition after assembly is normal.

**Register columns and fields too, not just functions and classes.** If a column an example introduces is declared
nowhere, the reader takes it for a column that exists on the model, and running `alembic check` in that state
produces drift (measured in audit C).

| name | appears in | kind |
| --- | --- | --- |
| `TaskService` | project-structure.md (layering example) | service-layer example |
| `priority` | migrations.md (expand-contract example) | **Example-only column.** It is not on the model (`Task`) — it exists to show the flow where §4 adds a column in the expand step and §5's backfill populates it |
