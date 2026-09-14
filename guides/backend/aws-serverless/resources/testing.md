<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Tests — the wiring breaks at the event and the claims

This file owns **the test harness and the handler tests**. The data layer's ownership and cursor
regressions are run against a real DynamoDB by `resources/data-access.md` §4·§5, schema unit tests are handled by
`resources/input-validation.md`, and error normalization by `resources/error-handling.md`.
CDK synthesis and the IAM check are in `resources/deploy-and-iam.md`.

**Do not mix the layers.** The tests here prove **the wiring** (event → subject → read → envelope), and
ownership is proven only against a real DynamoDB — let a mock imitate ownership too and you get a test that
cannot prove the block.

## 1. The test harness (`test/invoke.ts`)

It calls the handler **as a real function**. No HTTP and no mock server — a wiring defect comes out of the event shape and the auth claims, so only those two have to be real.

<!-- file: test/invoke.ts -->
```ts
// test/invoke.ts
import type { APIGatewayProxyEventV2, APIGatewayProxyResultV2, Context } from 'aws-lambda';

const CONTEXT: Context = {
  callbackWaitsForEmptyEventLoop: false,
  functionName: 'tasks-test', functionVersion: '$LATEST', memoryLimitInMB: '512',
  invokedFunctionArn: 'arn:aws:lambda:ap-northeast-2:000000000000:function:tasks-test',
  awsRequestId: '00000000-0000-4000-8000-000000000000',
  logGroupName: '/aws/lambda/tasks-test', logStreamName: '2026/08/23/[$LATEST]0',
  getRemainingTimeInMillis: () => 3000,
  done: () => {}, fail: () => {}, succeed: () => {},
};

const BASE = {
  version: '2.0', routeKey: 'GET /api/tasks', rawPath: '/api/tasks', rawQueryString: '',
  headers: {}, isBase64Encoded: false,
  requestContext: { requestId: 'req-test', http: { method: 'GET', path: '/api/tasks' } },
} as unknown as APIGatewayProxyEventV2;

export async function invokeHandler(
  h: (e: APIGatewayProxyEventV2, c: Context) => Promise<APIGatewayProxyResultV2>,
  event: Partial<APIGatewayProxyEventV2>,
): Promise<APIGatewayProxyResultV2> {
  return h({ ...BASE, ...event }, { ...CONTEXT });
}
```

The merge is **shallow**. If the fragment `authFor(ownerId)` hands back carries a `requestContext`, it overwrites the default
`requestContext` wholesale, so the seam's `authFor` has to hand back `http` and `requestId` inside it too
— break that and auth passes while the logging keys vanish.

## 2. Handler tests — put the positive and the negative in the same `it`

**Without the arrange, this test ships red.** The first line of the `it` below is a 200 **only when `t1` already
exists as `u1`'s**. Write nothing about what produces that state and whoever copies it
gets `expected 404 to be 200` — "replaced with a stand-in" is a name, not a method.

The stand-in used at this layer is **a mock of the data-layer module**. What is being proven is the wiring (event → subject →
read → envelope), and ownership itself has to run against a real DynamoDB, so its place is
`test/tasks.ownership.test.ts` in `resources/data-access.md` §4. Mix the two layers and the mock
imitates ownership too, leaving **a test that cannot prove the block**.

```ts
// test/handlers/tasks-get-one.test.ts
import { describe, expect, it, vi } from 'vitest';
import { handler } from '../../src/handlers/tasks-get-one';
import { authFor } from '../../src/http/require-auth';
import { invokeHandler } from '../invoke';

// arrange — vi.mock is hoisted above the imports. The factory cannot reference outer values other than vi
vi.mock('../../src/db/tasks', () => ({
  getTask: vi.fn(async (ownerId: string, id: string) =>
    ownerId === 'u1' && id === 't1'
      ? { id, title: 'mine', status: 'open', ownerId, createdAt: '2026-08-23T00:00:00.000Z' }
      : null),
}));

const call = (owner: string, id: string) =>
  invokeHandler(handler, { ...authFor(owner), pathParameters: { id } }) as
    Promise<{ statusCode: number }>;

describe('GET /api/tasks/{id}', () => {
  it('the owner gets 200 and anyone else 404 — compared inside one it', async () => {
    expect((await call('u1', 't1')).statusCode).toBe(200);   // positive: the feature is alive
    expect((await call('u2', 't1')).statusCode).toBe(404);   // negative: it is blocked
  });

  it('a request with no token is a 401', async () => {
    const r = await invokeHandler(handler, { pathParameters: { id: 't1' } });
    expect((r as { statusCode: number }).statusCode).toBe(401);
  });
});
```

**With only the negative assertion it is not a guard.** `getTask` was swapped wholesale for `return null` and
run: the edition carrying only the negative assertion passed green, while the edition with the positive line
failed with `expected 404 to be 200` — what proves the block is not the 404 but **the contrast between
200 and 404**. <!-- verified: vitest 2.1.9 — the result of running the mutant with getTask replaced by return null -->
`authFor` · `requireAuth` · `respond` are defined by the seam, so after assembly the same test runs again
against the real auth method.

**Three layers of local invocation**: ① `npx vitest run` — runs the handler inside the process (no credentials
needed, DynamoDB calls replaced by stand-ins) ② `npx cdk synth` — checks the template, the IAM and the bundle
③ after deployment, `aws lambda invoke --payload file://event.json out.json` — the point where real IAM and the real
table first intervene.

## 3. Data-layer regression — run it against a real DynamoDB

Ownership and cursors are **not proven by a mock.** The mock knows the answer, so deleting the condition expression
still leaves it green. The two below run for real against DynamoDB Local (the behavior tables are in `resources/data-access.md` §4·§5).

```ts
// test/tasks.ownership.test.ts
it('another owner cannot update it and I can', async () => {
  const mine = await putTask('A', { title: 'mine', status: 'open' });
  expect((await updateTask('A', mine.id, { title: 'edited' })).title).toBe('edited'); // ✅ positive
  await expect(updateTask('B', mine.id, { title: 'hijack' })).rejects.toThrow();      // ✅ negative
  expect((await getTask('A', mine.id))?.title).toBe('edited');                        // original unchanged
});

it('another owner cannot delete it, and the body status reaches the GSI', async () => {
  const done = await putTask('A', { title: 'finished', status: 'done' });
  expect((await listTasks('A', { limit: 10, status: 'done' })).items.map((t) => t.id))
    .toContain(done.id);                                                           // ✅ positive
  await expect(deleteTask('B', done.id)).rejects.toThrow();                        // ✅ negative
  expect(await getTask('A', done.id)).not.toBeNull();                              // original survives
  await deleteTask('A', done.id);
  expect(await getTask('A', done.id)).toBeNull();                                  // ✅ positive
});
```

With only the negative assertion, swapping `updateTask` wholesale for a `throw` still comes out green. The positive assertion
is what separates "blocked" from "entirely broken".

```ts
// test/tasks.cursor.test.ts — delete the re-pinning check and the second assertion goes red
it('a forged cursor is refused on the GSI path too', async () => {
  const page = await listTasks('A', { limit: 1, status: 'open' });
  expect(page.cursor).toBeDefined();                                          // ✅ positive
  const forged = encodeCursor({ ...decodeCursor(page.cursor!), pk: 'USER#B' });
  await expect(listTasks('A', { limit: 1, status: 'open', cursor: forged }))
    .rejects.toThrow();                                                       // ✅ negative
});
```

| what was deleted | the assertion that goes red |
| --- | --- |
| the `ConditionExpression` of `deleteTask` | `rejects.toThrow()` — `DeleteItem` gives 200 on a missing key too, so the exception disappears |
| hardcoding `input.status` → `'open'` in `putTask` | `toContain(done.id)` — the `done` list empties and it wrongly turns up in the `open` list |
| the cursor re-pinning check in `listTasks` | the forged-cursor test (the GSI path) — the path DynamoDB does not refuse |

**A guard is proven not by "it is there" but only by "delete it and it goes red".** This is the result of actually deleting
the three above and checking.

## 4. Misuse list — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| a unit test vs a handler test | key assembly and cursors take the former, auth, envelope and status code the latter — imitate the latter with the former and the wiring goes unchecked |
| the negative assertion alone vs a positive/negative pair | with only the 404, breaking the implementation wholesale still comes out green. Put the 200 in the same `it` |
| a data-layer mock vs a real DynamoDB | the former proves the wiring, the latter ownership. Try to prove ownership with the former and the mock already knows the answer |
