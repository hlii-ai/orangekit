---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "services/**"
  - "lib/**"
  - "functions/**"
  - "firestore.rules"
  - "firestore.indexes.json"
---
<!-- orangekit-pack: backend/firebase v3.14.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (ownership in the query condition · 0-row mutation = 404 · 404 instead of 403 · no internal details in error responses or logs) belong to security.md, so they are not here.
     This axis is dataLayerPolicyEngine: true, but Security Rules only guard the client SDK path — on the function (firebase-admin) path
     the boundary is the application check alone (pack.json policyEngineNote). functions/** and the rules·index files come from the pack directory layout. -->

# Firebase (Firestore + Cloud Functions v2) core card

The project spec (`dev/docs/api/` etc.) and `.claude/rules/code-conventions.md` take precedence over this card and the `backend-guide` skill.
Look up wiring and examples in the `backend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Function names · collection paths (top-level/sub) · ids · error codes follow existing code or the spec; if there is none, decide once and write it in `code-conventions.md`. — why models get it wrong: it anchors on the guide example values <!-- evidence: guide-skeleton "Stack core card" · model-gap: not-observed -->

## Security — where this stack leaks

- [security] There are two boundaries. Rules guard only the client SDK and `firebase-admin` bypasses them, so a function does the `ownerId` query condition or the in-transaction owner check itself. — why models get it wrong: "the rules are there, so it is safe" <!-- evidence: policies owner-in-query · PACK.md pilot C1 emulator measured · model-gap: not-observed -->
- [security] `onCall` checks `request.auth?.uid` on its first line. Passing in the emulator is not proof of auth. — why models get it wrong: tokenless requests still reach the handler, and the emulator trusts the `uid` of a forged token <!-- evidence: resources/functions-patterns.md §2 · resources/input-validation.md §5 (emulator measured) · model-gap: not-observed -->
- [security] Rules spell out `create`/`update`/`delete` separately, and `update` checks `ownerId` on both `resource` and `request.resource`. Lock the rules even when only functions are used. — why models get it wrong: bundled as `write`, an owner transfer passes or deleting your own doc is denied <!-- evidence: policies rules-split-write · PACK.md Anti-Patterns (C1 measured) · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Check and write in one `runTransaction`, reads before writes, no side effects in the body. — why models get it wrong: `delete()` succeeds on a missing doc, and the transaction function runs several times under contention <!-- evidence: resources/data-access.md §3 (emulator measured) · policies tx-for-check-then-write · model-gap: not-observed -->
- [performance] When `where`+`orderBy` changes, fix `firestore.indexes.json` in the same commit, and put the rules' `ownerId` condition in the client query too. — why models get it wrong: the emulator does not enforce indexes so only that query dies in production, and a query that cannot satisfy the rules is denied, not empty <!-- evidence: resources/data-modeling.md (emulator measured) · policies (what humans keep) · model-gap: not-observed -->
- [performance] Call `.value()` of `params` inside the handler. — why models get it wrong: at top level, a secret kills the deploy analysis and `defineString` deploys silently with an empty value <!-- evidence: resources/input-validation.md §7 (measured) · policies params-value-in-handler · model-gap: not-observed -->
- [performance] Build cursors on a sort with a tie-breaking field, not `createdAt` alone, and write times with `serverTimestamp()`. — why models get it wrong: tied docs drop out at page boundaries for good (9 of 24) <!-- evidence: resources/data-access.md §3 (emulator measured) · policies no-client-timestamp · model-gap: not-observed -->
