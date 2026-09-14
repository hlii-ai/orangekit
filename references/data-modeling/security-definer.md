<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# SECURITY DEFINER function authoring conventions

> The shared authoring standard for PostgreSQL SECURITY DEFINER functions — `_history` triggers, sensitive RPCs, Vault functions, and so on.
> These rules were promoted from defect patterns verified repeatedly in production (missing search_path, ambiguous argument names, permission bypass).

### 18.1 The 5-step checklist (applies to every SECURITY DEFINER function)

| #   | step                            | pattern                                                                                                                                       | risk if omitted                                                                                             |
| --- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| 1   | declare `SET search_path`       | `LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions` (with vault, `vault, public, extensions`)                            | depends on the session search_path → same-name object attack / a Supabase Security Advisor warning          |
| 2   | `p_` prefix on argument names   | `CREATE FUNCTION fn(p_user_id BIGINT, p_key_id TEXT)`                                                                                         | ambiguous error (42702) against external view/table column names — blocks entry to the function itself      |
| 3   | explicit prefix when reading external objects | `WHERE vault.decrypted_secrets.name = p_key_id`                                                                                 | without the argument prefix the ambiguous error returns                                                     |
| 4   | explicit `REVOKE EXECUTE` + `GRANT` | `REVOKE EXECUTE ON FUNCTION public.fn(args) FROM PUBLIC, anon, authenticated; GRANT EXECUTE ON FUNCTION public.fn(args) TO service_role;` | under Supabase's default GRANT policy anon/authenticated hold EXECUTE → permission bypass via a direct client RPC call |
| 5   | post-check DO block + e2e       | in the migration body, verify `pg_proc.proconfig` + `has_function_privilege` with `RAISE EXCEPTION` / confirm a 42501 block when calling the RPC as an anon client | applied ≠ working. Latent defects such as runtime ambiguity and permission leakage escape all the way to production |

### 18.2 Extra duties for `_history` trigger functions + DO verification block placement convention

A trigger function that INSERTs into a `_history` table applies both the trigger section of [`change-history.md`](./change-history.md) and this document:

- Steps 1–5 above + **a mandatory explicit INSERT policy on the `_history` table** (prevents the accident where history recording fails silently under RLS deny-by-default)
- **When NOT NULL/CHECK on an operational table changes, change `_history` in the same step** (fix only the source and the history INSERT fails on a constraint violation)

**DO verification block placement convention**:

- Always place the DO block at the **end of the migration body** (right after `REVOKE` / `GRANT`)
- Before `COMMIT` — Postgres runs a migration as a single transaction, so if the DO block fails with RAISE EXCEPTION the whole migration rolls back (the intended behavior)
- Make the checks **deterministic**: `pg_proc.proconfig` exists / `has_function_privilege` returns false / `pg_cron.job` exists / a catalog row COUNT — print one pass message with `RAISE NOTICE`, and `RAISE EXCEPTION` only on an intended block
- Anti-pattern: non-deterministic checks (e.g. production seed row COUNT >= N) or checks that depend on data yet to be introduced — the migration risks aborting itself. Split seeds out into a separate ON CONFLICT INSERT and make the check depend only on **the definition of the object just written**

### 18.3 Anti-patterns

- ① declaring only `REVOKE FROM PUBLIC` and omitting anon/authenticated — Supabase grants anon a separate default GRANT, so revoking PUBLIC alone does not block it
- ② using common column names such as `name`, `key_id`, `type` as argument names — risk of collision with system views such as vault/storage/pg_catalog
- ③ skipping the anon RPC call check after applying the migration — a DO block post-check partially covers it, but e2e is decisive
- ④ recording the standard pattern in lessons and then reproducing the same defect in the very next migration — when writing a lesson, grep exhaustively for the same pattern still present and run the corrective migration at the same time
- ⑤ **do not attempt an INSERT/UPDATE with external dependencies (FK · RLS · triggers) inside a DO verification block and then catch the EXCEPTION** — layered exceptions you did not intend (FK violation · CHECK violation · RLS denial) get caught and the flow proceeds on a wrong verdict. Use only static catalog checks: `pg_constraint` + `pg_get_constraintdef` LIKE / `information_schema.columns` / `pg_proc.proconfig` / `has_function_privilege`

### 18.4 A companion dynamic e2e is mandatory (the limits of static verification)

SECURITY DEFINER RPCs + RLS policies let defects pass in silence under module-level static verification alone (DO blocks · grep · typecheck · db:types). Static verification guarantees "structure" and cannot guarantee "dynamic coupling":

- ① a column the new RPC depends on is missing from the migration (`42703 column does not exist`) — a DO catalog check does not grep as far as the column references inside the function body
- ② an RLS UPDATE policy declares only `USING` and omits `WITH CHECK` — a `42501` block at the moment a viewer-privileged UPDATE runs (a `pg_policy` catalog check confirms only that the policy exists)
- ③ an argument name is ambiguous against an external view column (`42702`) — syntax passes + apply passes + runtime fails

**Mandatory pattern**: when adding a new SECURITY DEFINER RPC or RLS policy, write **one e2e that actually calls it** alongside the module-level DO block. Binding static and dynamic verification into the same unit of work closes the find-defect → corrective-migration → push cycle in a single pass.

**Three extra self-check axes when writing a verification script** (common to e2e SQL/MCP/CLI alike):

- ① permissions of the execution environment (service_role / anon) — MCP execute_sql and the like must confirm permissions
- ② ability to receive results (whether `RAISE NOTICE` is received, RETURNS TABLE vs row count) — this varies by environment
- ③ a 1:1 match between intent and expression in time/type conversions (mentally run one sample value)

If any of those three axes fails, the e2e looks like it passed while not performing the intended scenario.
