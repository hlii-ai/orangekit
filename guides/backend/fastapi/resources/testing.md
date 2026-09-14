<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Testing — drive the app without a network, and prove the boundary really blocks

This file owns **pytest configuration · the test client · dependency overrides · test DB isolation · block
proofs**. The router and repository implementations are owned by `resources/project-structure.md`·
`resources/data-access.md`, and `AppError`·`current_user`·`auth_for` by the seam.

## 1. Decision tree — at which layer do you test it

| what you are confirming | layer | what you stand up |
| --- | --- | --- |
| ownership filter · field preservation · `rowcount` decision | repository | `db_session` only. No HTTP |
| status code · serialization · dependency wiring | HTTP | `app_client` (`ASGITransport`) |
| pool warm-up · `dispose` · health checks | process | `lifespan_context` (§4) |
| whether the index is really used | DB | real PostgreSQL 16. Not replaced by a stub |

**Do not stand up HTTP for anything that does not need it.** This axis has no row-level policy engine, so
ownership lives only in the `WHERE`, and that decision is caught most cheaply at the repository layer.

```python
# tests/test_tasks.py — repository layer: it takes only a session
async def test_repo_layer_needs_no_http(db_session):
    made = await create_task(db_session, ALICE, TaskCreate(title="t", status=TaskStatus.DONE))
    assert made.status == TaskStatus.DONE                      # ✅ positive: the sent field survives
    assert await get_task(db_session, ALICE, made.id) is not None
    assert await get_task(db_session, BOB, made.id) is None     # ✅ negative: it is absent for others
    rows = (await db_session.execute(select(Task).where(Task.owner_id == ALICE))).scalars().all()
    assert len(rows) == 1
```

The argument order is fixed at **`session` → `owner_id` → `task_id`**. Both are `UUID`, so a swap is caught by
neither Python nor pyright — this test is the only thing that catches it (M10 in §7).

## 2. pytest configuration (`pyproject.toml`)

<!-- file: pyproject.toml -->
```toml
[tool.pytest.ini_options]
asyncio_mode = "auto"
asyncio_default_fixture_loop_scope = "session"
asyncio_default_test_loop_scope = "session"
```

- The default of `asyncio_mode` is **`strict`**, and in strict an async test without
  `@pytest.mark.asyncio` is not skipped but **fails** <!-- verified: ran pytest 9.1.1 + pytest-asyncio 1.4.0; the unmarked test came out FAILED -->.
  With `auto` no marker is needed — either choice leaves no silence
- **If a session-scoped fixture owns the engine, the loop scope has to be session too** — under the default
  `function`, the loop the engine was built on and the loop the test runs on diverge
- Leave `asyncio_default_fixture_loop_scope` empty on 1.4.0 and it **does** emit a `PytestDeprecationWarning`.
  But it comes from `pytest_configure`, so it is **invisible** under a plain `pytest` and under `pytest -W always`
  alike, and shows up only under `PYTHONWARNINGS=always` or `python -W always -m pytest`
  <!-- verified: pytest-asyncio 1.4.0 — 0 findings with no flags and with pytest -W always / 1 finding with python -W always -m pytest and PYTHONWARNINGS=always. The source, plugin.py:295-299, warns unconditionally -->
- **The warning being invisible is not the same as it being absent.** To use "X does not appear" as a conclusion, you first
  have to show a case where that same instrument does produce X. The previous edition of this line was that failure

## 3. Calling the app without a network — `ASGITransport`

```python
# tests/conftest.py — excerpt
async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
    response = await client.get("/api/tasks")
```

`base_url` is **not optional.** Drop it and you get `ValueError: unknown url type: '/api/tasks'`
<!-- verified: ran httpx 0.28.1; a relative-path request without base_url raises ValueError -->. The value can be any
host and is never actually resolved.

## 4. `lifespan` does not run under `ASGITransport`

**This section is the most expensive fact in this file.** `ASGITransport` sends only the HTTP scope, so the
`lifespan` attached to `create_app` is **silently skipped** — the request returns 200 while startup never
ran once <!-- verified: ran fastapi 0.141.1 + httpx 0.28.1; the startup/shutdown hooks were not called -->.
Code that relies on a warmed pool **behaves differently** here. Run it explicitly.

```python
# tests/conftest.py — excerpt  <!-- verified: ran starlette 1.6.0; startup before the request / shutdown on exit -->
async with app.router.lifespan_context(app):   # ✅ startup runs here
    yield app                                   #    shutdown runs when the block is exited
```

## 5. Dependency overrides — without undoing them the next test is contaminated

`app.dependency_overrides` is **a global dictionary hanging off the app object**. Share a module-top-level `app`
without clearing it and the next test, which never planted an override, gets a 200 as the previous user —
and **both are green** <!-- verified: ran fastapi 0.141.1; without a reset the 2nd test got a 200 as the 1st user, 2 passed -->.
There are two ways to block it, and **both are used**.

```python
# tests/conftest.py — excerpt
application = create_app()                     # ✅ ① build a new app per test
application.dependency_overrides.clear()       # ✅ ② clear it explicitly anyway
```

① alone removes the contamination, but the moment someone lifts the app to module top level only ② remains.

## 6. Test DB isolation (`tests/conftest.py`)

**Run each test inside an outer transaction and reverse it at the end.** It is faster than deleting tables,
and parallel workers get separate connections so they do not see each other. This file is the only place that uses
`os.environ` (the exception to policy `env-single-entry`), and since `settings` validates at module top level it has to be
injected **before `app.settings` is imported** — after that it is too late.

<!-- file: tests/conftest.py -->
```python
import os
from typing import AsyncIterator
from uuid import UUID

import pytest
import pytest_asyncio

# This file is the only place that uses os.environ — it has to come before the settings import.
os.environ["DATABASE_URL"] = os.environ.get(
    "TEST_DATABASE_URL", "postgresql+asyncpg://app:app@localhost:5432/app_test"
)

from fastapi import FastAPI                                    # noqa: E402
from httpx import ASGITransport, AsyncClient                   # noqa: E402
from sqlalchemy import func, select                            # noqa: E402
from sqlalchemy.ext.asyncio import AsyncSession                # noqa: E402

from app.db.base import Base                                   # noqa: E402
from app.db.tasks import Task                                  # noqa: E402  (mapper registration)
from app.db.session import engine, get_session                 # noqa: E402
from app.factory import create_app                             # noqa: E402
from app.http.auth import AuthUser, auth_for, current_user     # noqa: E402


@pytest_asyncio.fixture(scope="session")
async def db_schema() -> AsyncIterator[None]:
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)   # migrations do not run — verification is the separate CI step in migrations.md §8
    yield
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
    await engine.dispose()


@pytest_asyncio.fixture
async def db_session(db_schema: None) -> AsyncIterator[AsyncSession]:
    conn = await engine.connect()
    trans = await conn.begin()
    session = AsyncSession(
        bind=conn, expire_on_commit=False, join_transaction_mode="create_savepoint"
    )
    try:
        # Isolation guard — runs at the start of every test. Does not rely on test order.
        empty = select(func.count()).select_from(Task)
        assert (await session.execute(empty)).scalar_one() == 0, "rows from a previous test remain"
        yield session
    finally:
        await session.close()
        await trans.rollback()
        await conn.close()


@pytest_asyncio.fixture
async def app(db_session: AsyncSession) -> AsyncIterator[FastAPI]:
    application = create_app()

    async def _session_override() -> AsyncIterator[AsyncSession]:
        yield db_session

    application.dependency_overrides[get_session] = _session_override
    async with application.router.lifespan_context(application):
        yield application
    application.dependency_overrides.clear()


@pytest_asyncio.fixture
async def app_client(app: FastAPI) -> AsyncIterator[AsyncClient]:
    async with AsyncClient(
        transport=ASGITransport(app=app), base_url="http://test"
    ) as client:
        yield client


def override_user(app: FastAPI, user: AuthUser) -> None:
    app.dependency_overrides[current_user] = lambda: user


@pytest.fixture
def as_user(app: FastAPI):
    def _login(owner_id: UUID) -> AuthUser:
        user = auth_for(owner_id)
        override_user(app, user)
        return user
    return _login
```

**The overridden session does not commit** — the commit boundary is looked at separately at the "process" layer in the §1 table.

**Do not trust isolation; test it.** This pattern holds only when the driver really opens a transaction.
That is why the guard sits **inside the `db_session` fixture rather than in a test** — as a test, whether it catches
anything depends on where it runs in the order (changing the order really did miss M7).
Inside the fixture it runs at the start of every test and **does not rely on order**
<!-- verified: with M7, where the rollback was replaced by a commit, it failed with `rows from a previous test remain / assert 1 == 0` -->.

## 7. Block proofs — delete what, and what turns red

**A test with only a negative assertion is not a guard.** Assert only a 404 on someone else's item and the lookup function
can be replaced with `return None` and stay green. Pair it with the positive **in the same function**.

```python
# tests/test_tasks.py — M1·M2·M6
async def test_read_is_scoped_to_owner(app_client, as_user):
    as_user(ALICE)
    task_id = (await app_client.post("/api/tasks", json={"title": "alice task"})).json()["id"]
    mine = await app_client.get(f"/api/tasks/{task_id}")
    assert mine.status_code == 200                    # ✅ positive — without it, "everything is broken" is indistinguishable
    assert mine.json()["title"] == "alice task"       # ✅ it checks field preservation too
    as_user(BOB)
    assert (await app_client.get(f"/api/tasks/{task_id}")).status_code == 404   # ✅ negative
```

These are the two tests M3·M5 in the table point at. **The values of `status` are lowercase** — in Python use the member
(`TaskStatus.DONE`), in wire JSON use the value (`"done"`). Mix them and the request is blocked with a 422 while the
response assertion is red forever.

```python
# tests/test_tasks.py — M3: a delete is decided by the affected row count
async def test_delete_is_scoped_to_owner(app_client, as_user):
    as_user(ALICE)
    task_id = (await app_client.post("/api/tasks", json={"title": "alice task"})).json()["id"]

    as_user(BOB)
    assert (await app_client.delete(f"/api/tasks/{task_id}")).status_code == 404   # ✅ negative
    as_user(ALICE)
    assert (await app_client.get(f"/api/tasks/{task_id}")).status_code == 200      # ✅ it is still alive
    assert (await app_client.delete(f"/api/tasks/{task_id}")).status_code == 204   # ✅ positive
```

```python
# tests/test_tasks.py — M5: does a sent field survive all the way to storage
async def test_create_carries_every_supplied_field(app_client, as_user):
    as_user(ALICE)
    sent = await app_client.post("/api/tasks", json={"title": "done one", "status": "done"})
    assert sent.json()["status"] == "done"                                  # ✅ positive
    got = await app_client.get(f"/api/tasks/{sent.json()['id']}")
    assert got.json()["status"] == "done"                                   # ✅ it survives to storage
    omitted = await app_client.post("/api/tasks", json={"title": "open one"})
    assert omitted.json()["status"] == "open"                               # ✅ control: the default
```

For a partial update, the subject under test is **the field that was not sent**. M8·M3 confirm whether deleting the
two lines below is caught.

```python
# app/http/routers.py · app/db/tasks.py — the two lines the tests protect
patch = body.model_dump(exclude_unset=True)   # delete it and unsent fields overwrite storage
if result.rowcount == 0:                      # delete it and someone else's delete request also returns 204
    raise AppError("NOT_FOUND", "task not found")
```

This table came from actually breaking the implementation. **A mutation that stays green means there is no test there.**

| mutation | result | assertion that went red |
| --- | --- | --- |
| M1 remove the `owner_id` filter from `get_task` | FAIL | negative `assert 200 == 404` |
| M2 `get_task` always returns `None` | FAIL | **positive** `assert 404 == 200` — all 4 that are listed |
| M3 remove the `rowcount` check from `delete_task` | FAIL | `assert 204 == 404` |
| M4 remove the `owner_id` filter from `delete_task` | FAIL | `assert 204 == 404` |
| M5 `create_task` hard-codes `status` | **PASS at first → FAIL once the test was added** | `assert 'open' == 'done'` |
| M6 `create_task` hard-codes `title` | FAIL | `assert 'x' == 'alice task'` |
| M7 the isolation fixture commits instead of rolling back | ERROR | the `db_session` guard — it comes from a fixture, so it is an ERROR, not a FAIL |
| M8 the router drops `exclude_unset=True` | FAIL | `IntegrityError` — `SET status=None` |
| M9 remove the `owner_id` filter from `update_task` | FAIL | `assert 200 == 404` |
| M10 swap the two `UUID` arguments of `get_task` | FAIL | all 4 that are listed |

**M5 is the reason for this table** — the first 4 tests written caught nothing of the lost `status`.
The table was obtained on an assembly whose routers and `current_user` were filled in by the seam, and M8·M9 use a
`PATCH` route not listed above <!-- verified: ran the assembly. Routes and authentication are seam-owned, so each combination needs re-confirmation -->.

## Misuse list ① — `TestClient`/old idioms → current shapes

| old habit | current shape |
| --- | --- |
| async tests with `TestClient(app)` | `AsyncClient(transport=ASGITransport(app=app), base_url=...)` |
| expecting `ASGITransport` to run startup | run it explicitly with `app.router.lifespan_context(app)` |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| overriding `get_session` vs the real `get_session` | the override when you want isolation, the real thing when you want the commit boundary |
| a session-scoped engine vs a function-scoped loop | mixed, the loops diverge. Match the loop scope to session as well |
| negative assertions only vs a positive/negative pair | without the pair, "everything is broken" looks like "blocked" |
| `TaskStatus.DONE` vs `"done"` | Python uses the member, wire JSON uses the **value (lowercase)**. Mixed, it is a 422 |
