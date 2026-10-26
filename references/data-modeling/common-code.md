<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Common-code design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> A business column stores a **code value, not a display string** — for example `'ORDER'`, not `'Order Complete'`.
> Storing display strings makes the spellings drift apart (`Order complete` · `ORDER_COMPLETE`), lets typos in (`Shiping`),
> forces a bulk UPDATE with locks whenever a name changes, and blocks multi-language display as well.

## Decision criteria — pick one approach per code column

| Q1 Does business logic (`if`/`switch`) use it? | Q2 Do display names or attributes change often? | Approach | Examples |
| --- | --- | --- | --- |
| No (display only) | — | **common-code table** | bank, occupation, signup channel |
| Yes | No | **app ENUM + DB `CHECK`** | gender, a simple status |
| Yes | Yes | **hybrid**: the ENUM owns the code values, the table owns display names and attributes | order status, member tier, coupon type |

- **Start with an ENUM** and move to hybrid when display names or attributes must change in production. Going hybrid on everything from day one is over-design.
- ENUM means the application language's enum (TypeScript `as const`, Java `enum`, and so on) — not the DB `ENUM` type.
  Even adding one value needs an ALTER, so do not use the DB `ENUM` type.
- `CHECK` is a cheap safety net kept in the DB. Unlike an FK, it needs no group-constant column.
  When a value changes, one migration finishes the job.

## Standard design — shared group/detail tables

Manage the codes of every domain in **one pair of tables: a group table + a detail table**. This is the form used most in practice.
Pooling them into a single table with no group makes `CANCEL` (order cancel) and `CANCEL` (payment cancel) collide on the PK.

```sql
-- PostgreSQL
CREATE TABLE common_code_groups (
  group_code   VARCHAR(50)  PRIMARY KEY,
  group_name   VARCHAR(100) NOT NULL,
  description  VARCHAR(500),
  attr1_name   VARCHAR(50),               -- documents what attr1 is (e.g. 'Discount rate (%)')
  attr2_name   VARCHAR(50),
  attr3_name   VARCHAR(50),
  is_active    BOOLEAN      NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TABLE common_codes (
  group_code   VARCHAR(50)  NOT NULL REFERENCES common_code_groups(group_code),
  code         VARCHAR(50)  NOT NULL,
  name         VARCHAR(100) NOT NULL,
  name_en      VARCHAR(100),              -- when a second display language is needed
  description  VARCHAR(500),
  sort_order   INTEGER      NOT NULL DEFAULT 0,
  attr1        VARCHAR(100),
  attr2        VARCHAR(100),
  attr3        VARCHAR(100),
  is_active    BOOLEAN      NOT NULL DEFAULT true,
  created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
  PRIMARY KEY (group_code, code)
);
```

```sql
-- MySQL 8
CREATE TABLE common_code_groups (
  group_code   VARCHAR(50)  NOT NULL PRIMARY KEY,
  group_name   VARCHAR(100) NOT NULL,
  description  VARCHAR(500),
  attr1_name   VARCHAR(50),
  attr2_name   VARCHAR(50),
  attr3_name   VARCHAR(50),
  is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
);
CREATE TABLE common_codes (
  group_code   VARCHAR(50)  NOT NULL,
  code         VARCHAR(50)  NOT NULL,
  name         VARCHAR(100) NOT NULL,
  name_en      VARCHAR(100),
  description  VARCHAR(500),
  sort_order   INT          NOT NULL DEFAULT 0,
  attr1        VARCHAR(100),
  attr2        VARCHAR(100),
  attr3        VARCHAR(100),
  is_active    BOOLEAN      NOT NULL DEFAULT TRUE,
  created_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at   DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (group_code, code),
  FOREIGN KEY (group_code) REFERENCES common_code_groups(group_code)
);
```

**A business table holds only the code value.** Do not put an FK to the common-code table.

```sql
-- common-code group (display only): no FK, validated in the app
payment_method VARCHAR(20) NOT NULL,
-- ENUM-only code: a CHECK as the DB safety net
order_status   VARCHAR(20) NOT NULL DEFAULT 'ORDER'
  CONSTRAINT chk_orders_order_status
  CHECK (order_status IN ('ORDER','PAID','SHIPPING','DELIVERED','CANCEL')),
```

- **Use the composite natural key `(group_code, code)` and do not add a surrogate key.** This is an exception to the card §3 surrogate-key principle, for two reasons:
  `order_status_id = 10` cannot be read without a join, and a string code maps 1:1 to the app ENUM name.
- **Why no FK from business tables**: a composite FK would force a constant column like `order_status_group = 'ORDER_STATUS'` onto every business table.
  That wastes storage and muddies the design, and on high-volume transaction tables every INSERT also pays for the FK check.
  Integrity is carried by the app ENUM validation (hybrid · ENUM) and the `CHECK` above.
  The FK from the detail table to the group table stays.
- **Never delete a code — deactivate it**: `is_active = false`. Existing rows keep the code, and it only drops out of the choices for new input.
- **Extra attributes**: if they are fixed at 2–3, use `attrN` columns and document their meaning in the group's `attrN_name` (e.g. discount rate per tier, fee rate per payment method).
  If there are many attributes or they change often, use an `attributes` JSON column (→ [`json-columns.md`](./json-columns.md)).
  `attrN` is a string, so convert in the app any value you calculate with as a number.

## Write and read procedure

- **Reads do not join.** Business queries read only the code value, and the app turns it into a display name through a code map.
  Putting a code join in every query doubles the length of the SQL and scatters the same join everywhere (join hell).
- **Keep the code map in a local cache with a TTL.** Codes number in the hundreds, rarely change, and are read very often, so they suit a cache.

  | Situation | TTL |
  | --- | --- |
  | General | **60 seconds** |
  | Changes must show up fast | 10–30 seconds |
  | Almost never changes | 300 seconds or more |

  Preload it when the app starts.
  A local cache without a TTL drifts apart across multiple servers, and broadcasting changes is hard to make safe.
  Redis solves the sync problem but pays a network hop every time.
- **Do not build the cache yourself.** A `Map` plus a timer brings concurrency bugs and memory leaks. Use a proven cache library.
- If you must read without a cache, fetch the codes in use with **a single IN list**. Looking them up row by row is N+1.
- When a SQL join is unavoidable, as in an admin screen or a report, use **both keys** in the condition:
  `JOIN common_codes c ON c.group_code = 'ORDER_STATUS' AND c.code = o.order_status`.
  Joining on `code` alone mixes in the same code from other groups.
- Build a dropdown list with `WHERE group_code = ? AND is_active ORDER BY sort_order`.
- **Hybrid operating rules**
  - A developer adds codes. Change the ENUM and the DB together and deploy.
  - An operator changes display names and attributes from an admin screen. No redeploy is needed.
  - **An ENUM↔DB sync test is mandatory.** Put a test in CI that compares the ENUM's value set with that group's set in `common_codes`.
    If possible compare at app startup too, and stop the startup on a mismatch.

## Anti-patterns

1. Storing a display string in a business column (`'Order Complete'`). The spellings drift, typos creep in, and a rename needs a bulk UPDATE.
2. A flat code table with no group (`code` alone as the PK). The same code value in different groups collides.
3. Meaningless code values (`1`, `2`, `3`). Use values that read, like `PENDING` and `PAID`.
4. Giving the code table a surrogate key (`code_id`) and having business tables reference that number. The data cannot be read without a join.
5. Adding a group-constant column to a business table just to build a composite FK to the common codes.
6. Joining the code table in every read query (join hell). Looking codes up separately row by row (N+1).
7. A local cache without a TTL, or a hand-rolled cache.
8. Branching logic on string literals (`if (status === 'PAID')`). Use the ENUM.
9. Hybrid with no ENUM↔DB sync test. A code appears on only one side and blows up at runtime.
10. Making every code hybrid from the start (over-design).
11. DELETEing a code row. Past data points at a code that has vanished, so deactivate it with `is_active = false`.
12. Leaving the `group_code` condition out of a SQL join.
