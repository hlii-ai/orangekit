---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
---
<!-- orangekit-pack: backend/aws-container v3.35.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · 0-row mutation = 404 · 404 instead of 403 · no internal details in error responses or logs) belong to security.md, so they are not here.
     This axis is dataLayerPolicyEngine: false — the application layer is the only boundary. -->

# AWS container (ECS/Fargate + RDS) core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Path prefix · id type · success/error envelope · error codes follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. — why models get it wrong: it anchors on the guide example values <!-- evidence: guide-skeleton "Stack core card" · guide-ab T-D (fastify pack UUID) · model-gap: not-observed -->
- [consistency] Keep the (owner, id) argument order of query functions the same as the existing query layer. — why models get it wrong: both are `string`, so a swap compiles and every single-item fetch becomes 404 <!-- evidence: ledger shape column (node-api measured getTask reversed) · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Isolate queries with no owner condition (admin) in a separate module behind a role guard. Never add an `isAdmin` flag to the same function. — why models get it wrong: with no policy engine, one wrongly passed flag opens the whole table <!-- evidence: policies ownership-in-query (what humans keep) · model-gap: not-observed -->
- [security] Pass only the parsed update DTO to Drizzle `update().set()`. — why models get it wrong: passing `Partial<$inferInsert>` lets `ownerId` ride into set and hands the row to someone else <!-- evidence: ledger updateOwnedTask · model-gap: not-observed -->
- [security] RDS TLS is `rejectUnauthorized: true` plus the RDS CA bundle (`ca`). — why models get it wrong: turned on without the CA it fails with `SELF_SIGNED_CERT_IN_CHAIN`, and gets reverted to `false` <!-- evidence: resources/data-access.md TLS section · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Parse `process.env` once at boot in one validation module with `safeParse`, and `exit(1)` on failure. — why models get it wrong: read at the use site, a missing key blows up only on one path after deploy <!-- evidence: policies env-single-entry · boot-time-env-validation · model-gap: not-observed -->
- [performance] Register public paths (health check · login URL) before the auth middleware, and point the ALB health check at a path that does not touch the DB. — why models get it wrong: Hono runs in registration order so the health check 401s; touching the DB replaces every task on an RDS failover <!-- evidence: policies (what humans keep) · react-aws-guide-set-2026-08-22 order inversion · resources/deployment-and-operations.md · model-gap: not-observed -->
- [performance] Dockerfile `CMD` in exec form, SIGTERM runs `server.close` → `pool.end()`, ECS `stopTimeout` > drain time. — why models get it wrong: in shell form PID 1 is the shell, SIGTERM never arrives and every deploy drops connections <!-- evidence: resources/deployment-and-operations.md shutdown section · model-gap: not-observed -->
- [performance] The pool is a module singleton and `autoscaling max × pool max` stays under `max_connections`. Migrations run as a one-off task, not at boot. — why models get it wrong: sized by the usual task count, scale-out means refused connections, and boot migrations race each other <!-- evidence: ledger pool·db · policies (what humans keep) · model-gap: not-observed -->
