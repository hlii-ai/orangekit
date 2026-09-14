<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Operations — how the process comes up, how it dies, and what it leaves behind

This file owns **logging setup · health checks · pool sizing · shutdown and returning the pool · slow-query
observation**. The definitions of `engine`·`session_factory`·`get_session` are owned by `resources/data-access.md`,
`create_app` and `lifespan` by `resources/project-structure.md`, and **migrations by
`resources/migrations.md`** — here they are only **called and observed**.

## 1. Judgment — what gets wired to what

The orchestrator does **different things** with a probe result. Merge the two and a brief DB wobble restarts
every perfectly healthy process, and the restart storm pushes the DB harder still.

| probe | what it looks at | on failure the orchestrator | does it look at the DB |
| --- | --- | --- | --- |
| `GET /healthz` | is the event loop answering | **kills the process** | no |
| `GET /readyz` | are the dependencies alive | **removes traffic only** (the process lives) | `SELECT 1` |
| startup probe | are migrations and warm-up done | grants more startup grace | no |

**The moment `/healthz` looks at the DB it stops being a health check and becomes a restart trigger.** If every pod dies
during a 30-second DB outage, what the returning DB meets is a connection storm.

## 2. Logging setup (`app/obs/logging.py`)

Call `configure_logging` **before `create_app`**, at the import time of the boot module.
uvicorn attaches its own handler to its own logger and turns `propagate` off, so unless you clear that handler
and turn propagation on, **the lines uvicorn prints never become JSON** — only the application log is
structured and the access log stays plain text <!-- verified: ran uvicorn 0.52.4; with the loggers untouched, uvicorn's lines print only in plain-text format -->.

<!-- file: app/obs/logging.py -->
```python
import json
import logging
import sys
from typing import Any


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload: dict[str, Any] = {
            "ts": self.formatTime(record, "%Y-%m-%dT%H:%M:%S%z"),
            "level": record.levelname,
            "logger": record.name,
            "msg": record.getMessage(),
        }
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        for key, value in getattr(record, "extra_fields", {}).items():
            payload[key] = value
        return json.dumps(payload, ensure_ascii=False)


def configure_logging(level: str) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level.upper())
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access"):
        target = logging.getLogger(name)
        target.handlers = []          # strip the handler uvicorn attached
        target.propagate = True       # let it flow to the root JSON handler
```

The boot module (`app/main.py`, canonical source `resources/project-structure.md`) calls
`configure_logging(settings.LOG_LEVEL)` **before** `create_app()`. Environment values come from `settings` — neither this file
nor any file below reads the process environment directly (policy `env-single-entry`).

Gathering the imports at the top or deferring them past the call gives **the same result**: uvicorn sets up its own
logging after importing the app module, so the output of the two shapes did not differ by a single line
<!-- verified: started both shapes under uvicorn 0.52.4; all 9 log lines identical -->. There is no reason to
use a shape that needs `noqa: E402`.

Measured output — even uvicorn's own lines come out as one-line JSON.

```
{"ts": "2026-08-24T00:51:20+0700", "level": "INFO", "logger": "uvicorn.error", "msg": "Application startup complete."}
{"ts": "2026-08-24T00:51:23+0700", "level": "INFO", "logger": "uvicorn.access", "msg": "127.0.0.1:63203 - \"GET /healthz HTTP/1.1\" 200"}
```

## 3. Health checks (`app/obs/health.py`)

<!-- file: app/obs/health.py -->
```python
from fastapi import APIRouter, Response
from sqlalchemy import text

from app.db.session import engine

health_router = APIRouter()


@health_router.get("/healthz")
async def healthz() -> dict[str, str]:
    return {"status": "ok"}


@health_router.get("/readyz")
async def readyz(response: Response) -> dict[str, str]:
    try:
        async with engine.connect() as conn:
            await conn.execute(text("SELECT 1"))
    except Exception:
        response.status_code = 503
        return {"status": "unavailable"}
    return {"status": "ready"}
```

`/readyz` **does not put the exception type into the response.** Driver exception messages carry the host, the port, and
the username, and this path is usually outside authentication. Log it, do not put it in the response.

We cut the DB and actually called both paths to confirm they diverge — `/healthz` keeps returning 200 and
only `/readyz` becomes a 503 <!-- verified: swapped in an unreachable DB and ran it; healthz=200 / readyz=503 -->.

| state | `/healthz` | `/readyz` |
| --- | --- | --- |
| normal | 200 `{"status":"ok"}` | 200 `{"status":"ready"}` |
| DB unreachable | **200** | **503** `{"status":"unavailable"}` |

## 4. Shutdown and returning the pool — `lifespan`

If `create_app` does not pass `lifespan` as `FastAPI(lifespan=lifespan)`, it **silently never runs**.
Even attached, it does not run under the `ASGITransport` of a test — see §4 of `resources/testing.md`.

```python
# app/factory.py — excerpt
@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    async with engine.connect() as conn:
        await conn.execute(text("SELECT 1"))   # warm up so the first request does not pay the connect cost
    yield
    await engine.dispose()                     # actually close the pool's connections
```

End the process without calling `await engine.dispose()` and two different things happen at two different layers.
**One simply appears, the other appears only if you turn it on** — so "there was no warning at all" is not evidence.

| what was omitted | what appears | where it comes from |
| --- | --- | --- |
| the connection was not returned to the pool | `SAWarning: The garbage collector is trying to clean up non-checked-in connection …, which will be terminated.` | SQLAlchemy — independent of the driver <!-- verified: sqlalchemy 2.0.52, printed under the default filters with no flags (positive control) --> |
| it was returned but `dispose()` was not called | a `ResourceWarning` from the driver. **Under the default filters it is ignored and nothing appears** — you have to turn on `PYTHONWARNINGS=always` or `python -W always` to see it | the DBAPI driver <!-- verified: 0 findings without flags, 1 with -W always/PYTHONWARNINGS=always. Observed with aiosqlite; asyncpg's wording unverified --> |

The former means **the connection is force-terminated**, so it is a real defect; the latter is missed cleanup.
From the server's side, a process that dies without `dispose()` leaves idle sessions on the DB, and those sessions
eat into `max_connections` until `tcp_keepalives` or `idle_session_timeout` sweeps them away.

## 5. Pool sizing

A pool is built **per process**. Run 4 workers and there are 4 pools.

```
max per process = pool_size + max_overflow
max per cluster = max per process × worker count × pod count   ≤   max_connections - reserve
```

**The values are not decided here.** The only definition of `engine` is `app/db/session.py` in
`resources/data-access.md`; what follows is commentary on what those arguments mean in operation.

| argument | what it means in operation |
| --- | --- |
| `pool_size` | the steady-state holding. Multiplied by the worker count it has to fit inside the DB budget |
| `max_overflow` | the burst allowance. It is closed once returned |
| `pool_timeout` | the limit on waiting when none is available. Set it long and exhaustion disappears from the metrics |
| `pool_recycle` | discards, ahead of time, idle connections that an intermediate proxy would cut |
| `pool_pre_ping` | does not hand a dead connection to a request (costs one extra round trip per request) |

We confirmed it by actually configuring the asyncpg dialect — the pool implementation is `AsyncAdaptedQueuePool` and
`pool_size`·`max_overflow`·`pool_pre_ping` are reflected as given
<!-- verified: configured the engine with sqlalchemy 2.0.52 + asyncpg 0.31.0 and read back the pool class, size, _max_overflow, and _pre_ping -->.

**Do not set `pool_timeout` large.** Pool exhaustion is usually the result of a slow query or a missed return, and
waiting a long time erases that cause from the metrics while only the response time grows.

## 6. Slow-query observation

Measure the duration with SQLAlchemy's cursor events. **They cannot be attached to an async engine directly** —
attach to `AsyncEngine` and you get `NotImplementedError: asynchronous events are not implemented at this
time.  Apply synchronous listeners to the AsyncEngine.sync_engine or
AsyncConnection.sync_connection attributes.`
<!-- verified: ran sqlalchemy 2.0.52; attaching to AsyncEngine gives NotImplementedError while attaching to sync_engine succeeds -->.
Attach to `engine.sync_engine`.

**This module runs only if someone imports it.** It registers through decorators, so if it is not imported the listeners
are never attached at all — without the single line `import app.obs.sql  # noqa: F401` in the boot module, slow-query
logging stays silent forever. Start it unwired and there are **0** `obs.sql` lines; add the one line and they appear
<!-- verified: started both shapes under uvicorn 0.52.4; 0 lines unwired / 2 lines once wired (positive control) -->.

<!-- file: app/obs/sql.py -->
```python
# app/obs/sql.py — keeps slow queries only
import logging
import time

from sqlalchemy import event

from app.db.session import engine

log = logging.getLogger("obs.sql")
SLOW_MS = 200.0

@event.listens_for(engine.sync_engine, "before_cursor_execute")
def _before(conn, cursor, statement, parameters, context, executemany) -> None:
    conn.info.setdefault("t0", []).append(time.perf_counter())

@event.listens_for(engine.sync_engine, "after_cursor_execute")
def _after(conn, cursor, statement, parameters, context, executemany) -> None:
    elapsed_ms = (time.perf_counter() - conn.info["t0"].pop(-1)) * 1000
    if elapsed_ms >= SLOW_MS:
        log.warning("slow query", extra={"extra_fields": {
            "ms": round(elapsed_ms, 1), "sql": statement[:200]}})
```

- **Stack the timestamps on `conn.info`.** Put them in a module global and concurrent requests overwrite each
  other's start times. With a list the pairs still match even under nested execution
- **Do not put `parameters` into the log.** The bound values carry user data verbatim
- Truncate the statement before logging it. Without truncation one slow query eats the log budget

We confirmed that the events really do fire on an async engine and that the duration is measured (0.178 ms
on `SELECT 1`) <!-- verified: fired before/after_cursor_execute on a sqlalchemy 2.0.52 async engine and obtained the measurement -->.

What gets slow is usually the list query. This axis's list runs on **owner + sort key**, and without that
composite index it becomes a full scan.

```python
# the shape that rides the index (conceptual) — the canonical list_tasks is owned by data-access.md
stmt = (
    select(Task)
    .where(Task.owner_id == owner_id)
    .order_by(Task.created_at.desc(), Task.id.desc())
    .limit(limit)
)
```

Migrations (deploy order · expand-contract · backfill · where `upgrade head` is run) are owned by `resources/migrations.md`.

## Misuse list ① — single-process idioms → multi-worker shapes

| old habit | current shape |
| --- | --- |
| one `/health` serving both liveness and readiness | split into `/healthz` (no DB) · `/readyz` (`SELECT 1`) |
| observing with `print()` | a root handler + `JsonFormatter`, with the uvicorn loggers propagating |
| configuring logging after `create_app()` | at boot-module import time, before `create_app` |
| sizing the pool per pod | there is one pool per process. Multiply by the worker count |
| attaching cursor events to `AsyncEngine` | attach them to `engine.sync_engine` |
| just killing the process on shutdown | `await engine.dispose()` at the end of `lifespan` |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `/healthz` vs `/readyz` | `/healthz` only for what should trigger a restart. Dependency checks go in `/readyz` |
| `pool_size` vs `max_overflow` | steady load is the former, a burst is the latter. The sum is the budget |
| `pool_pre_ping` vs `pool_recycle` | detecting a dead connection is the former, preventing idle expiry is the latter. Use them together |
| `engine.dispose()` vs a connection `close()` | tearing down the whole pool is the former, a per-request return is the latter |
| `before_cursor_execute` vs middleware instrumentation | query duration is the former, request duration is the latter. They are different values |
