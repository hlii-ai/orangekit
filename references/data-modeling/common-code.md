<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Common-code table design

**Default: `TEXT` + `CHECK`** (card §5). Split out into a separate reference table only the codes that must be added dynamically in production.

| approach         | when to apply                                 | when not to apply                   |
| ---------------- | --------------------------------------------- | ----------------------------------- |
| `TEXT` + `CHECK` | values almost never change (status, type, enumerations) | codes are added/removed often in production |
| dedicated reference table | FK integrity needed · dynamic additions · sort order and display names | 3 or fewer fixed codes (CHECK is enough) |
| app constants + Zod | DB-independent type safety · shared with the frontend | DB-level consistency needed across multiple services |

**Reference table structure** (split per domain): `{domain}_codes` — `code_id` (PK BIGINT), `code_value` (UNIQUE, the FK target), `display_name`, `sort_order INTEGER`, `is_active BOOLEAN DEFAULT true`. Partial index: `WHERE is_active = true`. Reference it by using `code_value` as the FK (readable without a join).

**OTLT (One True Lookup Table) is forbidden**: putting every code into a single generic table (`group_code` + `code`) means — ①loss of FK integrity (any group's code can be referenced) ②no per-column CHECK constraints ③loss of type safety ④a less readable ERD.

**Anti-patterns**: ①an OTLT design ②code values with no business meaning (`pending`, `active`, `completed` instead of `1`, `2`, `3`) ③mixing static codes (unchangeable) with dynamic codes (added in production) ④using magic strings directly with no reference table

**Deciding between a common code and an app ENUM**:

| situation                              | choice                                                                                 | reason                                              |
| -------------------------------------- | -------------------------------------------------------------------------------------- | --------------------------------------------------- |
| display only (dropdowns), not involved in logic | a DB reference table (or `TEXT`+`CHECK`)                                      | operational flexibility first — change the DB without a redeploy |
| business logic (`if`/`switch`) branches on it | an app ENUM (TypeScript `as const`, etc.)                                       | type safety · compile-time checking · IDE completion |
| logic branches + display names/attributes change often | **hybrid**: an app ENUM (code values, type safety) + a DB reference table (display names, attributes, operational flexibility) | combines both advantages. **An ENUM↔DB sync verification test is mandatory** |

**Read strategy**: look up common-code display names through an **app-level local memory cache (TTL 60 seconds)**, not a SQL join. This avoids join hell.

**Natural key exception**: common-code reference tables are the exception to the surrogate-key principle in card §3 — `code_value` (a string) is used directly as the FK target. Reasons: ①data readability (meaning is clear without a join) ②an easy 1:1 mapping to app ENUM names. The FK constraint is optional (it can be omitted when app-level validation suffices).
