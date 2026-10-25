---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
  - "infra/**"
---
<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · 0-row mutation = 404 · 404 instead of 403 · no internal details in error responses or logs) belong to security.md, so they are not here.
     This axis is dataLayerPolicyEngine: false — DynamoDB has no row-level enforcement, so the application layer is the only boundary.
     infra/** is included for the per-function IAM item (where the CDK lives). -->

# AWS serverless (Lambda + DynamoDB) core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Paths · id format · key prefixes · envelope · error codes follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. Code→status mapping lives in one table, the envelope is built in one function. — why models get it wrong: handlers that each build `{ statusCode, body }` split the envelope <!-- evidence: policies error-status-single-table · envelope-from-respond · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Put the owner in the partition key (`KeyConditionExpression`) or a `ConditionExpression`. `FilterExpression` and `Scan` are not a boundary. — why models get it wrong: a filter applies after the read and only looks like a query condition <!-- evidence: policies ownership-in-key · no-scan · model-gap: not-observed -->
- [security] Give `DeleteItem`/`PutItem`/`UpdateItem` an existence-and-owner condition expression and turn a failed condition into 404. — why models get it wrong: a delete without a condition succeeds on a missing key, and put silently overwrites <!-- evidence: resources/data-access.md §4 (run-verified on DynamoDB Local) · model-gap: not-observed -->
- [security] After decoding a cursor (`LastEvaluatedKey`), pin it back to the owner partition. — why models get it wrong: base64 is plaintext and DynamoDB does not reject a forged `pk` in a GSI cursor <!-- evidence: resources/data-access.md §5 (run-verified) · model-gap: not-observed -->
- [security] IAM is least privilege per function, one function per route. — why models get it wrong: one `grantReadWriteData` line is convenient, and one breached function opens every domain <!-- evidence: policies no-table-wide-grant · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Create SDK clients and the logger and run the env `safeParse` at module top level. — why models get it wrong: inside the handler every call opens a new connection, and a bad deploy survives until the first request <!-- evidence: policies client-outside-handler · boot-time-env-validation · model-gap: not-observed -->
- [performance] Judge a failed condition down to `CancellationReasons` of `TransactionCanceledException`; fold `ValidationException` to 400 and `ThrottlingException` to 429. — why models get it wrong: judged by exception name alone, all of them become 500 <!-- evidence: ledger isConditionalCheckFailed · isThroughputExceeded · isInvalidRequest (C1 · audit A measured) · model-gap: not-observed -->
- [performance] When a GSI key source attribute (status etc.) changes, update the GSI key attribute in the same `UpdateItem`. — why models get it wrong: miss it and the item stays in the old list or vanishes from the new one <!-- evidence: resources/data-modeling.md GSI section · ledger putTask (audits A·C measured) · model-gap: not-observed -->
- [performance] Build `UpdateExpression` with `#n`/`:v` placeholders and block an empty patch. — why models get it wrong: a reserved word like `status` is rejected, and an empty `SET` is a syntax-error 500 <!-- evidence: resources/data-access.md §3 (run-verified) · policies (what humans keep) · model-gap: not-observed -->
