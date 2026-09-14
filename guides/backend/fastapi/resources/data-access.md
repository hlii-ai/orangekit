<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Data access — session lifetime · ownership · cursors

Owns all of `app/db/`: `Base` · `Task` · `engine` · `session_factory` · `get_session` · the task repository · the cursor.
This layer **knows nothing about HTTP.** App assembly and routers are `project-structure.md`, schemas are `input-validation.md`.

> **This axis has no row-level policy engine.** `WHERE owner_id = :owner_id` is the **only boundary**, and
> a query that omits it is not a slow query but a data leak.

## 1. Decision tree — where this access goes and in what shape

| situation | shape |
| --- | --- |
| read one item, 404 if absent | `get_task` returns `None` and **the service** raises it as `AppError('NOT_FOUND')` |
| partial update · delete | `UPDATE … RETURNING` · `DELETE` + `rowcount`. A read-then-write round trip diverges in between |
| unique constraint violation | `flush()` inside a `SAVEPOINT` and split on `is_unique_violation` (§4) |

**The repository takes `session` as an argument** and the argument order in every function is **`session` → `owner_id` → `task_id`** — the last two are both `UUID`, so pyright cannot catch a swap.

## 2. Session and declarative ownership (`app/db/session.py` · `app/db/base.py`)

<!-- file: app/db/session.py -->
```python
from collections.abc import AsyncIterator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.settings import settings

engine = create_async_engine(
    settings.DATABASE_URL,
    pool_size=10,        # steady-state connections
    max_overflow=5,      # momentary excess — sized so the sum stays under PostgreSQL max_connections
    pool_pre_ping=True,  # filters out connections dropped while idle, before the request
    pool_timeout=5,      # waits only 5 seconds when the pool is empty — an unbounded wait hides an outage in a queue
    pool_recycle=1800,   # discards connections older than 30 minutes (PgBouncer·NAT drop them silently)
)

session_factory = async_sessionmaker(engine, expire_on_commit=False)


async def get_session() -> AsyncIterator[AsyncSession]:
    """One session per request. Commit on success, roll back on an exception, then close."""
    session = session_factory()
    try:
        yield session
        await session.commit()
    except Exception:
        await session.rollback()
        raise          # without re-raising, FastAPI cannot build a response
    finally:
        await session.close()
```

**`expire_on_commit=False` is not optional.** With the default (`True`), attribute access after a commit attempts a lazy load, and in async that is **an exception** — `MissingGreenlet` mid-serialization and a 500.
<!-- verified: 2.0.52 · accessing t.title after commit. True → MissingGreenlet, False → returns the value (0 extra SELECTs) -->

Delete the `raise` and you get `FastAPIError: Response not awaited …`, and **an exception newly raised after the
`yield` is not caught by the handler** (`RuntimeError: … response already started.`) — which is why a constraint violation is caught at
`flush()` (§4). The measured order is `open → handler → commit → close` on success and
`open → handler → rollback → close → exception handler` on failure, so **the rollback runs before the handler**.
<!-- verified: ran each of the four shapes on fastapi 0.141.1 / starlette 1.6.0 and instrumented the hook order -->

<!-- file: app/db/base.py -->
```python
from sqlalchemy import MetaData
from sqlalchemy.orm import DeclarativeBase

NAMING_CONVENTION = {   # without names, Alembic cannot build the drop statement
    "ix": "ix_%(table_name)s_%(column_0_N_name)s",
    "uq": "uq_%(table_name)s_%(column_0_N_name)s",
    "ck": "ck_%(table_name)s_%(constraint_name)s",
    "fk": "fk_%(table_name)s_%(column_0_N_name)s_%(referred_table_name)s",
    "pk": "pk_%(table_name)s",
}


class Base(DeclarativeBase):
    metadata = MetaData(naming_convention=NAMING_CONVENTION)
```

The same `UniqueConstraint("owner_id", "title")` is `name=None` without the convention and `'uq_tasks_owner_id_title'` with it. <!-- verified: built the same constraint against two MetaData objects and compared .name -->

## 3. Model and reads (`app/db/tasks.py`) — ownership lives in the `WHERE`

<!-- file: app/db/tasks.py -->
```python
import base64
from datetime import datetime, timezone
from typing import Any, cast
from uuid import UUID, uuid4

from sqlalchemy import (CursorResult, DateTime, Enum as SAEnum, Index, String,
                        UniqueConstraint, delete, literal, select, tuple_, update)
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base
from app.db.errors import is_unique_violation   # SQLSTATE detection — knows no framework
from app.errors import AppError                 # does not import app/http/
from app.schemas.task import TaskCreate, TaskQuery, TaskStatus


class Task(Base):
    __tablename__ = "tasks"
    id: Mapped[UUID] = mapped_column(primary_key=True)          # the app makes it (uuid4)
    title: Mapped[str] = mapped_column(String(200))
    status: Mapped[TaskStatus] = mapped_column(          # the same enum as the schema
        SAEnum(TaskStatus, native_enum=False, length=16, name="task_status"))
    owner_id: Mapped[UUID] = mapped_column()
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))

    __table_args__ = (
        UniqueConstraint("owner_id", "title"),
        Index("ix_tasks_owner_created_id", "owner_id", "created_at", "id"),  # premise of keyset
    )


async def get_task(session: AsyncSession, owner_id: UUID, task_id: UUID) -> Task | None:
    return await session.scalar(
        select(Task).where(Task.owner_id == owner_id, Task.id == task_id)
    )
```

**Every excerpt in §4·§5 is the later part of this same file, and the imports are written here only once.** Put **both
conditions** in `where(...)` — the shape that filters on `Task.id == task_id` alone and compares the owner in Python has already
fetched someone else's row. `owner_id` gets no separate `index=True` because the composite index covers the leading
column, and mapping `status` as `String(16)` makes the value a plain `str` after the DB round trip, so `isinstance` is
`False` and `.value` fails. `SAEnum(native_enum=False)` keeps the DDL **identical** while preserving the type.
<!-- verified: round-tripped a session with both mappings — String(16) gives str, SAEnum gives TaskStatus. CreateTable compiles identically -->

## 4. Mutations — a fixed allowlist of columns and `rowcount`

```python
# app/db/tasks.py
async def delete_task(session: AsyncSession, owner_id: UUID, task_id: UUID) -> None:
    result = cast(CursorResult[Any], await session.execute(
        delete(Task).where(Task.owner_id == owner_id, Task.id == task_id)
    ))
    if result.rowcount == 0:   # someone else's row or no row — without the check a 204 goes out
        raise AppError("NOT_FOUND", "task not found")

async def update_task(session: AsyncSession, owner_id: UUID, task_id: UUID,
                      patch: dict[str, Any]) -> Task:
    bad = set(patch) - {"title", "status"}     # fixed allowlist — owner_id·id cannot be changed
    if bad:
        raise AppError("VALIDATION_FAILED", "field cannot be updated",
                       {k: ["cannot be updated"] for k in sorted(bad)})
    if not patch:                              # some calls do not go through the router
        raise AppError("VALIDATION_FAILED", "no field to update", {"body": ["no fields"]})
    stmt = (update(Task).where(Task.owner_id == owner_id, Task.id == task_id)
            .values(**patch).returning(Task))
    row = (await session.execute(stmt)).scalar_one_or_none()
    if row is None:
        raise AppError("NOT_FOUND", "task not found")
    return row

async def create_task(session: AsyncSession, owner_id: UUID, data: TaskCreate) -> Task:
    task = Task(id=uuid4(), title=data.title, status=data.status,   # carries status over
                owner_id=owner_id, created_at=datetime.now(timezone.utc))
    try:
        async with session.begin_nested():        # SAVEPOINT — rolls back only this INSERT
            session.add(task)
            await session.flush()
    except IntegrityError as exc:
        if is_unique_violation(exc):              # SQLSTATE 23505 (app/db/errors.py)
            raise AppError("CONFLICT", "a task with the same title already exists") from exc
        raise
    return task
```

**Without an allowlist, the `WHERE` boundary is bypassed through `SET`.** Let `owner_id` into `patch` and it becomes
`UPDATE tasks SET owner_id=? WHERE owner_id=? AND id=?`, which **hands your own row to someone else.**
The router's `TaskUpdate` (`extra='forbid'`) blocks it, but this function is also called without a router.

| `update_task(s, ALICE, tid, …)` | no allowlist | fixed allowlist |
| --- | --- | --- |
| `{"owner_id": BOB}` | passes → **ALICE cannot read it · BOB can** | `VALIDATION_FAILED` · owner unchanged |
| `{"title", "status"}` (positive control) | updates normally | **updates normally** — it does not block everything <!-- verified: ran all four cases in one script, re-read the DB, and compared owner_id and readability from both sides --> |

The return type of `AsyncSession.execute()`, `Result[Any]`, has no `rowcount` (the real object for DML is `CursorResult`)
— used without `cast`, pyright raises `reportAttributeAccessIssue`. <!-- verified: pyright 1.1.411 · sqlalchemy 2.0.52 — 1 finding before cast → 0 after -->
Create **carries over every field of `data`** (hard-coding `status` erases the client's value). Do not split on `exc.orig`
with `isinstance` directly — on asyncpg that object is one the SQLAlchemy dialect wrapped, not an asyncpg
exception (confirmed by running C1). Detection uses only the two functions in `app/db/errors.py`.

## 5. Keyset pagination — the cursor is both `(created_at, id)`

```python
# app/db/tasks.py
async def list_tasks(session: AsyncSession, owner_id: UUID,
                     q: TaskQuery) -> tuple[list[Task], str | None]:
    stmt = select(Task).where(Task.owner_id == owner_id)
    if q.status is not None:
        stmt = stmt.where(Task.status == q.status)
    if q.cursor is not None:
        created_at, task_id = decode_cursor(q.cursor)
        stmt = stmt.where(tuple_(Task.created_at, Task.id)
                          < tuple_(literal(created_at), literal(task_id)))
    stmt = stmt.order_by(Task.created_at.desc(), Task.id.desc()).limit(q.limit + 1)
    rows = list((await session.scalars(stmt)).all())
    if len(rows) <= q.limit:
        return rows, None
    last = rows[q.limit - 1]                      # the limit+1-th row is only a "there is more" signal
    return rows[: q.limit], encode_cursor(last.created_at, last.id)
```

On the asyncpg dialect this compiles to `(tasks.created_at, tasks.id) < ($1::TIMESTAMP WITH TIME ZONE, $2::UUID)`
and rides `ix_tasks_owner_created_id` as an `Index Cond`. Wrapping in `literal()` alone removes 2 pyright
`reportArgumentType` findings — passing the type as the second argument leaves the SQL unchanged.
<!-- verified: both shapes compile identically on the asyncpg dialect · pyright 1.1.411 (2 findings without literal → 0 with) · the Index Cond is from audit B1's EXPLAIN on real PostgreSQL 16.2 -->

**With a single sort key, rows disappear on ties.** The seed is 37 `owner` rows across 8 distinct `created_at` values
(seven groups of 5 rows plus one group of 2), and **the loss rate is a function of limit, so it cannot be summarized by one number.**

| limit | 1 | 3 | 5 | 7 | 20 |
| --- | --- | --- | --- | --- | --- |
| `(created_at, id)` | \- | \- | 0 duplicates · 0 lost · 0 foreign rows | \- | \- |
| `created_at` alone | 29 lost (78%) | 16 (43%) | 2 (5%) | 9 (24%) | 2 (5%) <!-- verified: exhaustively walked both shapes per limit with the same seed and the same session. Re-confirmed by audit B1 on PostgreSQL 16 + asyncpg 0.31 --> |

The cursor is an **opaque string** and a decode failure folds into `AppError('VALIDATION_FAILED')`.

```python
# app/db/tasks.py
def encode_cursor(created_at: datetime, task_id: UUID) -> str:
    raw = f"{created_at.isoformat()}|{task_id}".encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")

def decode_cursor(cursor: str) -> tuple[datetime, UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)).decode()
        stamp, _, task_id = raw.partition("|")
        return datetime.fromisoformat(stamp), UUID(task_id)
    except Exception as exc:                      # not trusted input — it must not become a 500
        raise AppError("VALIDATION_FAILED", "cursor cannot be decoded",
                       {"cursor": ["malformed"]}) from exc
```

## 6. N+1 — in async it is not quiet

N+1 in synchronous SQLAlchemy is merely slow, but in async a lazy load is **an exception** — read a relation attribute plainly and
you get `MissingGreenlet` and a 500. The shape it takes is **an `await` inside a loop**. <!-- verified: direct relation-attribute access on 2.0.52 → MissingGreenlet -->

```python
# ❌ 20 items means 20 SELECTs — round trips scale with the count
rows = [await get_task(session, owner_id, task_id) for task_id in ids]
# ✅ 1 SELECT. The ownership filter is still intact
rows = list((await session.scalars(
    select(Task).where(Task.owner_id == owner_id, Task.id.in_(ids)))).all())
```
<!-- verified: counted cursor executions with before_cursor_execute — 20 vs 1 -->

Use `selectinload` **only when a relation is declared**. This pack's `Task` has none, so it is absent from the base shape;
had you added one, `.options(selectinload(Task.<relation>))` reduces 1+N to 2. <!-- verified: on an experimental model with one relation, fetching 5 tasks went from 6 SELECTs to 2 -->

Migrations (Alembic wiring · the limits of autogeneration · expand-contract · deploy order) are owned by `resources/migrations.md`.

## Misuse list ① — SQLAlchemy 1.4 sync → 2.0 async idiom table

| old habit (1.4 sync) | current shape (2.0 async) |
| --- | --- |
| `SessionLocal = sessionmaker(engine)` | `async_sessionmaker(engine, expire_on_commit=False)` |
| `session.commit()` in every function | `get_session` commits once per request |
| passing `.values(**patch)` straight through | reject anything outside the allowlist first |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `session.rollback()` vs `session.begin_nested()` | the former only when discarding the whole request. A SAVEPOINT when swallowing one constraint violation |
| `String(16)` vs `SAEnum(native_enum=False)` | the latter for enum columns. The former becomes `str` after the round trip, so the annotation lies |
| `pool_size` + `max_overflow` vs `pool_recycle` | the **sum** of the first two stays within the DB's `max_connections`. The last is an age cap on a connection |
