<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Error handling — unify the path from one exception to one response

What this file owns is **two modules** — `app/db/errors.py` (SQLSTATE detection) and
`app/http/errors.py` (the status mapping `ERROR_STATUS` · normalization `to_app_error` · field errors
`field_errors`). **It does not own the shape of the response envelope or `AppError` itself** — those are a function of the
wire contract, so the seam puts them in `app/errors.py` and `app/http/handlers.py`. What to raise is decided by each
layer (`data-access.md` · `input-validation.md`).

## 1. Decision tree — where it is caught and where it is raised

| layer | what it raises | does it catch |
| --- | --- | --- |
| `app/db/tasks.py` (repository) | `AppError` · driver exceptions **as-is** | no |
| `app/services/tasks.py` (domain) | `AppError` | only when converting to a domain rule |
| `app/http/routers.py` (router) | raises nothing | no |
| `install_error_handlers` (seam) | — | **this is the only place that catches** |

**Do not use `try/except` in a router.** Add places that catch and the same failure goes out with a different
status code per request path, and that difference is found by users, not by tests. The exception handler
folding once through `to_app_error` and mapping once through `ERROR_STATUS` is the whole of it.

Once a repository raises `HTTPException`, that layering has already collapsed — that function becomes testable
only by standing up HTTP.

## 2. Split across three modules — the layout is the layering discipline

Pile the error symbols into one file and `app/db/tasks.py` pulls `fastapi` in **transitively** for the sake of one
`AppError`. That is because `app/http/errors.py` imports `fastapi` for `RequestValidationError`.
So it is split into three.

| file | what it holds | what it may import |
| --- | --- | --- |
| `app/errors.py` | `AppError` (**seam-owned**) | the standard library only |
| `app/db/errors.py` | the two SQLSTATE detectors | driver knowledge only — knows nothing about HTTP |
| `app/http/errors.py` | `ERROR_STATUS` · `to_app_error` · `field_errors` | `fastapi` · `pydantic` |

The check is not a grep but **a real import**. A transitive dependency is invisible to a string search.

```text
>>> python -c "import app.db.tasks, sys; assert 'fastapi' not in sys.modules"
(no output — passes)
>>> positive control: move AppError and the detectors back into the single file app/http/errors.py, same command
AssertionError          # fastapi·starlette·pydantic are loaded into sys.modules
```

Only with the control is it proved that this check **was in a state where it could see a violation**. A "there is no fastapi"
obtained without a control is not "there is none" but "it was not measured".

<!-- file: app/db/errors.py -->
```python
# app/db/errors.py
from __future__ import annotations

UNIQUE_VIOLATION = "23505"
FOREIGN_KEY_VIOLATION = "23503"


def _sqlstate(exc: BaseException) -> str | None:
    """Look for the SQLSTATE in order: SQLAlchemy wrapper → adapter exception → original driver exception."""
    orig = getattr(exc, "orig", None)
    for current in (exc, orig, getattr(orig, "__cause__", None)):
        if current is None:
            continue
        code = getattr(current, "sqlstate", None) or getattr(current, "pgcode", None)
        if code:
            return str(code)
    return None


def is_unique_violation(exc: BaseException) -> bool:
    return _sqlstate(exc) == UNIQUE_VIOLATION


def is_foreign_key_violation(exc: BaseException) -> bool:
    return _sqlstate(exc) == FOREIGN_KEY_VIOLATION
```

This file imports neither `sqlalchemy` nor `asyncpg` — it only walks with `getattr`. That is why the
repository can call it freely, and why the file does not break when the driver changes.

<!-- file: app/http/errors.py -->
```python
# app/http/errors.py
from __future__ import annotations

from fastapi.exceptions import RequestValidationError
from pydantic import ValidationError

from app.db.errors import is_foreign_key_violation, is_unique_violation
from app.errors import AppError  # owned by the seam

# domain code → HTTP status. **the only mapping table**
ERROR_STATUS: dict[str, int] = {
    "VALIDATION_FAILED": 422,
    "UNAUTHENTICATED": 401,
    "FORBIDDEN": 403,
    "NOT_FOUND": 404,
    "CONFLICT": 409,
    "INTERNAL": 500,
}


def field_errors(exc: ValidationError | RequestValidationError) -> dict[str, list[str]]:
    """Join loc with dots and use it as the key. Do not strip array indices."""
    result: dict[str, list[str]] = {}
    for err in exc.errors():
        loc = err.get("loc") or ()
        key = ".".join(str(part) for part in loc) or "__root__"
        result.setdefault(key, []).append(str(err.get("msg", "")))
    return result


def to_app_error(exc: BaseException) -> AppError:
    """The exception handler must call this first. Everything unknown folds into INTERNAL."""
    if isinstance(exc, AppError):
        return exc
    if isinstance(exc, (ValidationError, RequestValidationError)):
        return AppError("VALIDATION_FAILED", "could not validate the request", field_errors(exc))
    if is_unique_violation(exc):
        return AppError("CONFLICT", "the same task already exists")
    if is_foreign_key_violation(exc):
        return AppError("VALIDATION_FAILED", "the referenced target does not exist")
    return AppError("INTERNAL", "could not process the request")
```

`http/` → `db/` is the normal direction. There is no import in the opposite direction.

Always give `ERROR_STATUS` a default when looking it up — `ERROR_STATUS.get(err.code, 500)`.
If a code absent from the table raises `KeyError`, **the error happens inside the error handler** and even a 500 cannot be built.

## 3. `to_app_error` — folding what it does not know is a security measure

The string of a driver exception carries connection details, table names, constraint names, and the executed SQL. Printing the
`IntegrityError` SQLAlchemy built with `str()` looks like this (real output, values truncated).

```text
(sqlalchemy.dialects.postgresql.asyncpg.IntegrityError) <class 'asyncpg.exceptions.UniqueViolationError'>: <driver message>
[SQL: INSERT INTO tasks ...]
```

Put that in a response body and the whole schema leaks. The point of the last line of `to_app_error`,
`return AppError("INTERNAL", ...)`, is that **it discards the original message**. The original goes to the log —
call `logger.exception(...)` inside the handler and put only a correlation ID in the response.

```python
# tests/test_errors.py (excerpt)
def test_to_app_error_keeps_known_and_folds_unknown() -> None:
    known = AppError("NOT_FOUND", "task not found")
    assert to_app_error(known) is known              # ✅ what it knows passes through unchanged
    folded = to_app_error(RuntimeError("host=db user=admin password=s3cr3t"))
    assert folded.code == "INTERNAL"                 # ✅ what it does not know is folded
    assert "s3cr3t" not in folded.message            # ✅ the original text does not leak
```

All three assertions sit in the same function. Assert only the last line and it stays green whatever `to_app_error` returns;
assert only the first and it stays green even with no folding at all.

## 4. SQLSTATE detection — `exc.orig` is not an asyncpg exception

On `postgresql+asyncpg` the exception is **three layers deep**. The SQLAlchemy 2.0.52 dialect source
(`dialects/postgresql/asyncpg.py:781-797`) translates the asyncpg exception into its own DBAPI exception,
filling in `sqlstate`·`pgcode` and leaving the original in `__cause__` with `raise translated_error from error`.
Each layer carries different attributes.

| layer | class | `sqlstate` | `pgcode` |
| --- | --- | --- | --- |
| `exc` | `sqlalchemy.exc.IntegrityError` | absent | absent |
| `exc.orig` | `sqlalchemy.dialects.postgresql.asyncpg.IntegrityError` | `"23505"` | `"23505"` |
| `exc.orig.__cause__` | `asyncpg.exceptions.UniqueViolationError` | `"23505"` | **absent** |

**The `exc.orig` layer is the only one where `pgcode` is filled in** <!-- verified: confirmed by audit B1 on real PostgreSQL 16.2. The authoring side confirmed the attribute is absent on the exception object asyncpg 0.31 builds -->. That is why `_sqlstate` looks
at each layer in the order `sqlstate` → `pgcode` and uses a `getattr` default — read a missing attribute
directly and the detector dies with `AttributeError`.

**`isinstance(exc.orig, asyncpg.exceptions.UniqueViolationError)` is `False`** (confirmed by running it).
Try to decide by driver class and nothing is caught at all, silently, so every duplicate write becomes a 500.
Deciding by message string does not work either — the following dies when the locale, the driver, or the PostgreSQL version changes.

```python
# ❌ a driver message is not a contract — change the wording and it silently becomes a 500
if "unique constraint" in str(exc):
    raise AppError("CONFLICT", "already exists")
```

```python
# ✅ SQLSTATE is the five-character code PostgreSQL defines
if is_unique_violation(exc):
    raise AppError("CONFLICT", "the same task already exists")
```

`23505`·`23503` match asyncpg's class attributes —
`UniqueViolationError.sqlstate == "23505"`, `ForeignKeyViolationError.sqlstate == "23503"`.
When the driver gives no SQLSTATE (a different DB, an error at the connection stage), `_sqlstate` gives `None` and both
detectors return `False` — **they do not raise.** If a detector blows up, the handler blows up with it.

## 5. `field_errors` — use `loc` as the key, as-is

FastAPI's `RequestValidationError.errors()` gives `loc` as a **tuple**. The first element is where the input
came from (`"body"` · `"query"` · `"path"`), and for an array body an **integer index** follows.
These are shapes instrumented from real requests.

| request | `loc` | `type` |
| --- | --- | --- |
| `title` missing from the `POST` body | `('body', 'title')` | `missing` |
| body is `null` or absent entirely | `('body',)` | `missing` |
| `title` of the 2nd item of an array body is an empty string | `('body', 1, 'title')` | `string_too_short` |
| malformed JSON | `('body', 1)` — **the 1 is a character position, not a field** | `json_invalid` |
| `?limit=999` | `('query', 'limit')` | `less_than_equal` |
| the UUID in the path is malformed | `('path', 'task_id')` | `uuid_parsing` |

`('body', 1, 'title')` → `"body.1.title"`. **Do not strip the index.** Strip it and which item of the array
was wrong disappears, so the form cannot attach the error anywhere. Keep the first element too — strip it and
a query parameter and a body field of the same name collapse into one key, and the `('body', 1)` of malformed JSON
becomes the meaningless key `"1"`.

There are cases where `loc` is an empty tuple — an error raised by `model_validator(mode="after")`. Only then
does it fold into `"__root__"`. **The same error gets a different key depending on the path** (both confirmed by running them):

| where it was called | `loc` | `field_errors` key |
| --- | --- | --- |
| `TaskUpdate.model_validate({})` directly | `()` | `__root__` |
| the same body through a `PATCH` request | `('body',)` | `body` |

That is because FastAPI prefixes the body location. The client has to treat both keys as "an error on the whole
body rather than on a field".

Each entry of `errors()` has the keys `type`·`loc`·`msg`·`input` (+ sometimes `ctx`).
**Do not put `input` into the response as-is** — it is the text the user sent, and if the request carried an auth header
or a password it goes straight back out.

## 6. No existence leaks — 404 and 403 answer different questions

This axis has no row-level policy engine. Ownership lives only in `WHERE owner_id = :owner_id`,
so `get_task` **cannot tell "it does not exist" from "it is someone else's."** That inability is the feature.

| situation | status | why |
| --- | --- | --- |
| a `task_id` that is not yours or does not exist | **404** | split the two and ID substitution alone reveals that someone else's resource exists |
| no token or an expired one | 401 | it has nothing to do with the resource |
| a valid token but insufficient role or scope | 403 | use it **only when the resource identifier is not a secret** |
| a task with the same title already exists | 409 | `is_unique_violation` decides it |

Use 403 for "someone else's resource" and the response itself answers "that resource exists". Use 403 only for an
insufficient role and fold an ownership mismatch into 404. The same goes for the error message — wording like
`"task 42 belongs to user 7"` gives away the same information even with a 404 status code.

## 7. Handler wiring — the seam does it, the pack only fixes the shape

`install_error_handlers(app)` belongs to the seam (`app/http/handlers.py`). The combination decides the envelope
shape, but **the pack fixes the order** — fold, map, then put `field_errors` into `details`.

```python
# app/http/handlers.py (excerpt — owned by the seam)
err = to_app_error(exc)
status = ERROR_STATUS.get(err.code, 500)
```

The handler registers **all three**: `AppError` · `RequestValidationError` · `Exception`.
Omit `Exception` and an unforeseen exception falls through FastAPI's default path and a stack trace goes out;
omit `RequestValidationError` and only the 422 envelope has a different shape, so the client keeps two parsers.

## Misuse list ① — `HTTPException` idioms → `AppError` idioms

| old habit (using `HTTPException` directly) | current shape |
| --- | --- |
| `raise HTTPException(404, "not found")` in the router | the repository or service raises `AppError("NOT_FOUND", ...)` |
| deciding the status code with `try/except` in every layer | one `to_app_error` plus one `ERROR_STATUS` |
| a validation failure as `HTTPException(400)` | the handler turns `RequestValidationError` into a 422 |
| passing the cause through `detail=str(exc)` | `AppError("INTERNAL", fixed wording)` + the cause to the log |
| `except IntegrityError: raise HTTPException(409)` | decide by SQLSTATE with `is_unique_violation(exc)` |
| putting `exc.errors()` straight into `detail` | normalize to `{key: [message]}` with `field_errors(exc)` |
| declaring `@app.exception_handler` per module | `install_error_handlers(app)` once (`create_app` calls it) |
| assuming `RequestValidationError.errors()` has a `url` key | the FastAPI side has none. Only pydantic's `ValidationError.errors()` does, and `include_url=False` turns it off <!-- verified: on a real fastapi 0.141.1 request the keys are only input/loc/msg/type, while pydantic 2.13.4 includes url --> |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `exc.orig` vs `exc.orig.__cause__` | both carry the SQLSTATE, but **the driver class is only on `__cause__`** |
| `isinstance(orig, UniqueViolationError)` vs `sqlstate == "23505"` | the former is always `False` on the asyncpg dialect. Use only the latter |
| `sqlstate` vs `pgcode` | both hold the same value **only at the `exc.orig` layer**. The original asyncpg exception has no `pgcode`, so look at `sqlstate` first |
| `23505` vs `23503` | a duplicate write is the former (409). A reference to a missing target is the latter (422 — the client sent a wrong ID) |
| 403 vs 404 | an insufficient role is 403, **an ownership mismatch is 404**. Make the latter a 403 and existence leaks |
| 409 vs 422 | the schema is right but the state conflicts → 409; the schema is wrong → 422 |
| `pydantic.ValidationError` vs `RequestValidationError` | the former on a direct `model_validate` call, the latter when FastAPI parses the request. `field_errors` accepts both |
| `ERROR_STATUS[code]` vs `.get(code, 500)` | inside a handler, always the latter. A `KeyError` makes even the 500 response impossible |
| `logger.error(str(exc))` vs `logger.exception(...)` | the latter when you need the stack. The former erases where the cause was |
