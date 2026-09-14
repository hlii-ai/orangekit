<!-- orangekit-pack: backend/fastapi v3.14.0 -->
# Input validation — lock the request body, the query, and the environment with the same device

What this file owns is `app/schemas/task.py` (the request/response schemas and the `TaskStatus` enum) and
`app/settings.py` (the environment schema). It does not own **turning a validation failure into a response** —
`app/http/errors.py` (→ `error-handling.md`) and the seam's `install_error_handlers` do that.
It does not own moving validated values into SQL either (`app/db/tasks.py` → `data-access.md`).

## 1. Decision tree — each input fails at a different moment

| what comes in | where it is received | when it fails | failure shape |
| --- | --- | --- | --- |
| request body | the `TaskCreate` · `TaskUpdate` parameter | request | `RequestValidationError` → 422 |
| query string | `Annotated[TaskQuery, Query()]` | request | `RequestValidationError` → 422 |
| path parameter | the `task_id: UUID` annotation | request | `RequestValidationError` → 422 |
| cursor string | `decode_cursor` (`data-access.md`) | request | `AppError("VALIDATION_FAILED")` |
| authenticated subject | `current_user` (seam) | request | `AppError("UNAUTHENTICATED")` |
| process environment | `Settings` | **boot** | `ValidationError` → the process does not come up |

**Request input ends at a 422 and environment input ends at a boot failure.** This axis has no row-level policy engine,
so a value the application lets through goes into the DB as-is. The schema is the only gatekeeper.

`owner_id` is not in this table. **Do not accept a client-sent owner through a schema** — the owner comes only from
`current_user`, and if `owner_id` rides in the body, `extra="forbid"` rejects it with a 422.

## 2. The schema module (`app/schemas/task.py`)

One file holds the request, the response, and the enum. The model (`data-access.md`) and the schema **import and use the
same `TaskStatus`** — keep two copies of the enum and only one of them gains a value.

<!-- file: app/schemas/task.py -->
```python
# app/schemas/task.py
from __future__ import annotations

from datetime import datetime
from enum import StrEnum
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator


class TaskStatus(StrEnum):
    OPEN = "open"
    DONE = "done"


class TaskCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    title: str = Field(min_length=1, max_length=200)
    status: TaskStatus = TaskStatus.OPEN


class TaskUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # ✅ the default of an optional field is None and nothing else — the only marker separating sent from unsent
    title: str | None = Field(default=None, min_length=1, max_length=200)
    status: TaskStatus | None = None

    @field_validator("title", "status")
    @classmethod
    def _reject_explicit_null(cls, value: object) -> object:
        # an omitted field never arrives here (not validating defaults is pydantic's default behavior)
        if value is None:
            raise ValueError("a field cannot be cleared with null")
        return value

    @model_validator(mode="after")
    def _reject_empty_patch(self) -> TaskUpdate:
        if not self.model_fields_set:
            raise ValueError("send at least one field to update")
        return self


class TaskQuery(BaseModel):
    model_config = ConfigDict(extra="forbid")

    limit: int = Field(default=20, ge=1, le=100)
    cursor: str | None = None
    status: TaskStatus | None = None


class TaskOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: UUID
    title: str
    status: TaskStatus
    created_at: datetime
```

All five schemas are either `extra="forbid"` or response-only. The `forbid` on `TaskQuery` **turns on and off depending
on how it is received** — §6 covers that condition.

## 3. Partial update — `exclude_unset=True` is the only safeguard

`PATCH` means "change only the fields that were sent". `model_dump()` **fills unsent fields with their defaults**
and hands them back, so passing it straight into `UPDATE` overwrites the remaining columns.

```text
>>> TaskUpdate.model_validate({"status": "done"})   # output from pydantic 2.13.4
model_dump()                  = {'title': None, 'status': <TaskStatus.DONE: 'done'>}
model_dump(exclude_unset=True) = {'status': <TaskStatus.DONE: 'done'>}
model_fields_set               = {'status'}
```

You can see `title: None` riding along. Pass that through in the router and the title is erased.
So **building `patch` is the router's obligation** — `update_task` receives an already-filtered dict.

```python
# app/http/routers.py (excerpt — the router body is owned by the seam)
patch = body.model_dump(exclude_unset=True)
task = await update_task(session, user.id, task_id, patch)
```

Make the default something other than `None` and not even `exclude_unset` can save you. Run the same input against a
model changed to `title: str = ""` and `model_dump()` gives `{'title': '', ...}` — the syntax is perfect,
the type check passes, and only the title silently becomes an empty string.

```python
# tests/test_schemas.py (excerpt)
def test_partial_update_carries_only_sent_fields() -> None:
    patch = TaskUpdate.model_validate({"status": "done"}).model_dump(exclude_unset=True)
    assert patch == {"status": TaskStatus.DONE}  # ✅ what was sent rides along
    assert "title" not in patch                  # ✅ what was not sent does not
```

Put both assertions **in the same function**. Assert only the `not in` and it stays green even if `model_dump` is replaced with `{}`.

## 4. Explicit `null` and an empty body — the two holes `exclude_unset` does not close

`{"title": null}` is **a sent field**. `title` enters `model_fields_set`, so it passes
`exclude_unset=True`, becomes `patch == {'title': None}`, and reaches a NOT NULL column.
`{}` (an empty body) does the opposite: it builds an empty `patch` and fires a 0-row `UPDATE`.

The two validators in §2 turn each of these into a 422. Real output:

```text
TaskUpdate.model_validate({"title": None}) -> loc=('title',)  type=value_error  msg=Value error, a field cannot be cleared with null
TaskUpdate.model_validate({})              -> loc=()          type=value_error  msg=Value error, send at least one field to update
```

The key is that `field_validator` does not touch an omitted field — put `{"status": "done"}` in and
`title` **never goes through** the validator and is absent from `patch` too (confirmed by running it). The `loc` of a
`mode="after"` model validator is an empty tuple, so it attaches to no field — §5 of `error-handling.md` handles that.

## 5. Unknown keys — the three values of `extra` produce three different accidents

Real results of putting `{"title": "t", "owner_id": "attacker", "is_admin": true}` through each of the three settings.

| `extra` | result | what it means on this axis |
| --- | --- | --- |
| `"ignore"` (default) | `{'title': 't'}` — silently dropped | a typo'd field is ignored and a 200 saying "saved" goes out |
| `"forbid"` | 422, two entries: `loc=('owner_id',)`·`loc=('is_admin',)` | a privilege-escalation attempt dies **at the request stage** |
| `"allow"` | `{'title': 't', 'owner_id': 'attacker', 'is_admin': True}` | `model_dump()` carries the unknown keys along |

`"allow"` is especially dangerous on this axis. The moment the `model_dump()` result is used as the `patch` of an `UPDATE`,
a column the client named reaches SQL directly. **Every request body schema is `"forbid"`.**

## 6. The list query — receive it as `Annotated[TaskQuery, Query()]`

Receive it with `Depends()` and FastAPI does not validate the model as a whole; it **builds an individual query parameter
per field** and passes them all. On that path `extra="forbid"` **does nothing at all.** These are
instrumented results of both approaches with the same schema and the same request.

```text
>>> GET /api/tasks?limit=5&utm_source=ad   (TaskQuery is extra="forbid")
q: TaskQuery = Depends()           -> 200  {"limit":5,"cursor":null,"status":null}
q: Annotated[TaskQuery, Query()]   -> 422  loc=['query','utm_source'] type=extra_forbidden
>>> GET /api/tasks?limit=5                 (no unknown parameter — positive control)
q: Annotated[TaskQuery, Query()]   -> 200  {"limit":5}
```

The last line is the control. **Instrument only the rejection and you cannot tell whether that path simply 422s everything** — you
have to see a normal request get a 200 before the 422 means "blocked".

```python
# app/http/routers.py (excerpt — the router body is owned by the seam)
@router.get("")
async def list_route(q: Annotated[TaskQuery, Query()], ...): ...
```

The `Depends()` path **gives every field** even with `exclude_unset=True` (because FastAPI passed them all explicitly).
The `Annotated` path gives only what was sent — that is the `{"limit":5}` in the output above.
Either way, decide the first page by whether `cursor` is `None`, never by `model_fields_set`.

## 7. Response schema — do not return the ORM as-is

Only `TaskOut`, which carries `from_attributes=True`, goes into a response. Use the `Task` model as the `response_model` and
columns added later leak out silently. Results from running it on a real SQLAlchemy instance.

```text
>>> TaskOut.model_validate(task).model_dump(mode="json")   # Task(..., secret_field="LEAK")
{"id": "ec4a4b00-...", "title": "t", "status": "done", "created_at": "2026-08-23T17:26:30.587457Z"}
"LEAK" in output: False
```

`mode="json"` turns the `StrEnum` into the string `'done'` and the `datetime` into ISO-8601. A plain
`model_dump()` gives the `<TaskStatus.DONE: 'done'>` enum object as-is — meaning what you print to the log
and what you send over the wire differ. With `response_model=TaskOut`, FastAPI takes the `mode="json"`
path on its own.

```python
# app/http/routers.py (excerpt)
@router.get("/{task_id}", response_model=TaskOut)
async def read_task(...) -> Task: ...
```

## 8. The environment schema (`app/settings.py`) — it fails at boot

**This is the only file that reads the environment.** If another file reads it directly, typing, validation, and
boot-time failure are all bypassed.

<!-- file: app/settings.py -->
```python
# app/settings.py
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env", env_file_encoding="utf-8", extra="forbid"
    )

    DATABASE_URL: str
    LOG_LEVEL: str = "INFO"
    ENV: str = "dev"


# ✅ module top level — a validation failure is a boot failure.
# pyright thinks DATABASE_URL was not passed (it does not know the value comes from the environment). Suppress this one line only
settings = Settings()  # pyright: ignore[reportCallIssue]
```

The reason the suppression is needed is the very character of this file — **it fills a required field from the
environment rather than from an argument.** Hang it on that one line only. Turn it off per file and real type errors disappear too.

Import this module without `DATABASE_URL` and **the import itself blows up.** Real output:

```text
RESULT: raised pydantic_core._pydantic_core.ValidationError
errors(): [{"type":"missing","loc":["DATABASE_URL"],"msg":"Field required","input":{}}]
last traceback frame: ('settings_mod.py', 11, '<module>')
```

The traceback points at the `<module>` frame — not during request handling but while the process is coming up.
Move `settings = Settings()` inside a function and this protection disappears, and until the first request arrives
**a half-alive server** answers the health check with a 200.

Where `extra="forbid"` actually bites is not what intuition says. Two cases confirmed by running them:

| where the unknown key is | result |
| --- | --- |
| a process environment variable (`UNRELATED_KEY=x`) | **it passes.** The whole environment is not treated as the schema |
| inside the `.env` file (`UNRELATED_KEY=x`) | **a `ValidationError` equivalent to a 422**, `loc=['unrelated_key']` |

The `loc` is lowercase — because pydantic-settings normalizes keys (for the same reason a lowercase
`database_url` environment variable also fills the `DATABASE_URL` field). **Put only keys this schema knows
in `.env`.** If the deployment has no `.env`, this check never runs at all and only the missing-field check remains.

## Misuse list ① — Pydantic v1 → v2 idiom table

| old habit (v1) | current shape (v2) |
| --- | --- |
| `class Config: orm_mode = True` | `model_config = ConfigDict(from_attributes=True)` |
| `class Config: extra = "forbid"` | `model_config = ConfigDict(extra="forbid")` |
| `.dict()` · `.json()` | `.model_dump()` · `.model_dump_json()` |
| `.dict(exclude_unset=True)` | `.model_dump(exclude_unset=True)` |
| `.parse_obj(x)` · `.from_orm(x)` | `.model_validate(x)` |
| `@validator("f")` | `@field_validator("f")` + `@classmethod` |
| `@root_validator` | `@model_validator(mode="before" \| "after")` |
| `__fields_set__` | `model_fields_set` |
| `Field(..., min_items=1)` | `Field(min_length=1)` (`min_length` for sequences too) |
| `BaseSettings` lives in `pydantic` | `BaseSettings` from the separate `pydantic-settings` package <!-- verified: pydantic.BaseSettings does not exist in pydantic 2.13.4; imported from pydantic-settings 2.15.0 --> |

## Misuse list ② — confusable pairs

| commonly picked wrong | the exact condition for applying it |
| --- | --- |
| `model_dump()` vs `model_dump(exclude_unset=True)` | a full replacement (`PUT`) takes the former, a partial update (`PATCH`) **must** take the latter |
| `exclude_unset` vs `exclude_none` | the former removes "what was not sent". The latter swallows an explicit `null` too and **silently ignores input that should have been rejected** |
| `model_dump()` vs `model_dump(mode="json")` | the former for internal passing and logs, the latter for values going over the wire (`StrEnum`·`UUID`·`datetime` all change) |
| `TaskQuery = Depends()` vs `Annotated[TaskQuery, Query()]` | **this pack is always the latter.** Under `Depends()` `extra="forbid"` is void, so unknown query parameters pass silently |
| `field_validator` vs `model_validator(mode="after")` | the former when the error has to attach to a field via `loc`, the latter for relations between fields (an empty patch and such; its `loc` is `()`) |
| `DATABASE_URL: str` vs `PostgresDsn` | `PostgresDsn` checks the scheme but is a URL object rather than a `str`, so it needs `str()` when passed to the engine. This pack uses `str` <!-- verified: ran TypeAdapter(PostgresDsn) and confirmed it accepts postgresql+asyncpg and rejects mysql --> |
| defining `TaskStatus` separately in the schema and the model | keep it in one place (`app/schemas/task.py`) and let the model import it |
| `Field(min_length=1)` vs a `str \| None` default | a length constraint only bites when a value is present. To forbid omission itself, make it a required field |
