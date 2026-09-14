<!-- orangekit-pack: backend/aws-serverless v3.13.0 -->
# Deployment and IAM — the function is the unit of permission

This file owns **the CDK stack composition · least-privilege IAM per function · bundling · deploy order**.
The test harness and handler tests are owned by `resources/testing.md`, and route↔function mapping
(`infra/routes.ts`) by **the seam**. Key design is in `resources/data-modeling.md`,
queries in `resources/data-access.md`, and the handler lifetime in `resources/handler-patterns.md`.

## 1. The decision — where to confirm each fact

Each stage of the deployment pipeline can confirm something different. Pile it all into one stage and the slow one
delays everything; split it wrong and a place appears that nobody ever looks at.

| what you want to confirm | where | tool |
| --- | --- | --- |
| key assembly · cursor encoding · Zod schemas | a unit test | Vitest — they are pure functions, so no event is needed |
| handler wiring (auth→validation→query→envelope) | a handler test | `invokeHandler` + `authFor` |
| the ownership block (is someone else's invisible) | a handler test | as a positive/negative **pair** (§6) |
| whether the IAM is really narrow · the bundle contents | synthesis | after `cdk synth`, the Action list in the template and `cdk.out/asset.*/index.js` (§3·§4) |
| whether a conditional write wins the race | after deployment | the real table. It cannot be reproduced locally |
| timeouts and cold start time | after deployment | CloudWatch. Local timings are not even a reference |

**Synthesis is not a deployment but it is a check.** `cdk synth` writes the template to a file without credentials — this is where the least-privilege claim is judged true or false.

## 2. The table stack (`infra/table.ts`)

The `Construct` that builds the single table and GSI1 and the per-function grant helper live in one file.
**Only with the grant sitting beside the table definition** does the action list get updated along with the table's shape.

<!-- file: infra/table.ts -->
```ts
// infra/table.ts
import { RemovalPolicy } from 'aws-cdk-lib';
import {
  AttributeType, BillingMode, ProjectionType, Table, TableEncryption,
} from 'aws-cdk-lib/aws-dynamodb';
import { PolicyStatement } from 'aws-cdk-lib/aws-iam';
import type { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { Construct } from 'constructs';

const READ_ACTIONS = ['dynamodb:GetItem', 'dynamodb:Query'];
const WRITE_ACTIONS = ['dynamodb:PutItem', 'dynamodb:UpdateItem', 'dynamodb:DeleteItem'];
// batch and transaction are separate actions — the five above call neither BatchWrite nor TransactWrite
const BATCH_ACTIONS = [
  'dynamodb:BatchGetItem', 'dynamodb:BatchWriteItem',
  'dynamodb:TransactWriteItems', 'dynamodb:ConditionCheckItem',
];

export class TaskTable extends Construct {
  readonly table: Table;

  constructor(scope: Construct, id: string) {
    super(scope, id);
    this.table = new Table(this, 'Table', {
      partitionKey: { name: 'pk', type: AttributeType.STRING },
      sortKey: { name: 'sk', type: AttributeType.STRING },
      billingMode: BillingMode.PAY_PER_REQUEST,
      encryption: TableEncryption.AWS_MANAGED,
      pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true },
      removalPolicy: RemovalPolicy.RETAIN,
    });
    this.table.addGlobalSecondaryIndex({
      indexName: 'gsi1',
      partitionKey: { name: 'gsi1pk', type: AttributeType.STRING },
      sortKey: { name: 'gsi1sk', type: AttributeType.STRING },
      projectionType: ProjectionType.ALL,
    });
  }
}

export function grantTaskAccess(
  fn: NodejsFunction, table: TaskTable, mode: 'read' | 'write' | 'batch',
): void {
  const arn = table.table.tableArn;
  fn.addToRolePolicy(new PolicyStatement({
    actions: READ_ACTIONS,
    resources: [arn, `${arn}/index/*`],
  }));
  if (mode === 'write' || mode === 'batch') {
    fn.addToRolePolicy(new PolicyStatement({ actions: WRITE_ACTIONS, resources: [arn] }));
  }
  if (mode === 'batch') {
    fn.addToRolePolicy(new PolicyStatement({ actions: BATCH_ACTIONS, resources: [arn] }));
  }
  fn.addEnvironment('TABLE_NAME', table.table.tableName);
}
```

Synthesis confirmed that `removalPolicy: RETAIN` is emitted as two lines, `DeletionPolicy: Retain` and
**`UpdateReplacePolicy: Retain`** — the latter is decisive in §7.
<!-- verified: the AWS::DynamoDB::Table resource of the aws-cdk-lib 2.266.0 app.synth() template -->

## 3. Least privilege per function — the synthesized policy document is the evidence

"Least privilege" is not a claim but a number counted out of the template. Below is the
**real `AWS::IAM::Policy` document** that came out of synthesizing
`grantTaskAccess(getFn, tasks, 'read')` and `grantTaskAccess(putFn, tasks, 'write')`.

```json
{
  "GetTaskFnServiceRoleDefaultPolicy": [
    { "Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:Query"],
      "Resource": ["<TableArn>", "<TableArn>/index/*"] }
  ],
  "PutTaskFnServiceRoleDefaultPolicy": [
    { "Effect": "Allow", "Action": ["dynamodb:GetItem", "dynamodb:Query"],
      "Resource": ["<TableArn>", "<TableArn>/index/*"] },
    { "Effect": "Allow",
      "Action": ["dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"],
      "Resource": "<TableArn>" }
  ]
}
```

The read function gets **2 actions**, the write function 5, and the `Resource` of the write actions carries
**no** `/index/*` — DynamoDB updates the index, so a function has no reason to write to one.

**The two modes `'read'` and `'write'` cannot call a batch or a transaction.** `resources/data-access.md`
§6 teaches `TransactWriteCommand` · `BatchWriteCommand` · `BatchGetCommand` as normal patterns, yet
the policy document above carries **not one** of `dynamodb:TransactWriteItems` · `BatchWriteItem` · `BatchGetItem` ·
`ConditionCheckItem` — deploy it as it stands and the code passes while the runtime
raises AccessDenied (the failure the first row of the §7 table names). So the modes split into three:

| mode | actions added | when |
| --- | --- | --- |
| `'read'` | `GetItem` · `Query` | single-item and list handlers |
| `'write'` | the above + `PutItem` · `UpdateItem` · `DeleteItem` | single-item mutations |
| `'batch'` | the above + `BatchGetItem` · `BatchWriteItem` · `TransactWriteItems` · `ConditionCheckItem` | only for functions that really call a batch or a transaction |

Do not make `'batch'` the default — the moment one function holds batch permissions, a piercing of that function
**can delete 25 items in a single call.** Not granting it to functions that never call it is the point of this section.
<!-- verified: aws-cdk-lib 2.266.0 app.synth() — the PolicyDocument.Statement copied verbatim -->
Use the table-wide grant helper on another domain table, `usersTable`, in the same stack and **12
actions** come out, pulling in `Scan` · `BatchWriteItem` · `DescribeTable` and even stream reads —
❌ do not use this shape:

```json
[
  { "Action": ["dynamodb:BatchGetItem", "dynamodb:Query", "dynamodb:GetItem",
      "dynamodb:Scan", "dynamodb:ConditionCheckItem", "dynamodb:BatchWriteItem",
      "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem",
      "dynamodb:DescribeTable"] },
  { "Action": ["dynamodb:GetRecords", "dynamodb:GetShardIterator"] }
]
```

2 against 12. <!-- verified: aws-cdk-lib 2.266.0 — the second policy document from the same synthesis run -->
That number is why the `no-table-wide-grant` policy forbids the table-wide grant helper: pierce a read-only
list handler and it can `Scan` the whole table and delete from it. **Without splitting a function per
route this narrowing is impossible in the first place** — have one function serve both listing and deleting
and that function always holds the delete permission.

## 4. Function definitions and bundling (`infra/app.ts`)

```ts
// infra/app.ts
import { App, Duration, Stack } from 'aws-cdk-lib';
import { Architecture, Runtime } from 'aws-cdk-lib/aws-lambda';
import { NodejsFunction } from 'aws-cdk-lib/aws-lambda-nodejs';
import { LogGroup, RetentionDays } from 'aws-cdk-lib/aws-logs';
import { TaskTable, grantTaskAccess } from './task-table';
import { routes } from './routes';          // owned by the seam

const app = new App();
const stack = new Stack(app, 'TasksStack', {
  env: { account: process.env.CDK_DEFAULT_ACCOUNT, region: process.env.CDK_DEFAULT_REGION },
});
const tasks = new TaskTable(stack, 'Tasks');

const fn = (id: string, entry: string) => new NodejsFunction(stack, id, {
  entry, handler: 'handler',
  runtime: Runtime.NODEJS_22_X, architecture: Architecture.ARM_64,
  timeout: Duration.seconds(10), memorySize: 512,   // shorter than the 29s integration ceiling
  logGroup: new LogGroup(stack, `${id}Logs`, { retention: RetentionDays.ONE_MONTH }),
});

const getFn = fn('GetTaskFn', 'src/handlers/tasks-get-one.ts');
grantTaskAccess(getFn, tasks, 'read');
routes(stack, { table: tasks });        // route↔function mapping is owned by the seam
```

Even with a `.ts` `entry`, the `Handler` property is emitted as **`index.handler`** — esbuild bundles source from any
path into one `index.js`, so the source path must never be written into the handler string.
<!-- verified: the AWS::Lambda::Function Handler value in the aws-cdk-lib 2.266.0 synthesized template -->

**The one thing to leave external is `@aws-sdk/*`.** The default `externalModules` of `NodejsFunction` is
`['@aws-sdk/*']` on Node 18+ runtimes that ship SDK v3, and it stays out of the bundle unless you pass
`bundleAwsSDK: true`. **What to bundle** is everything the runtime does not
provide, such as the powertools logger and Zod. Measuring the synthesized `index.js` gives **an 8× spread depending on what is pulled in**:

| what the handler imports | bundle |
| --- | --- |
| the powertools logger + SDK calls only | **74KB** |
| the above + `parse.ts` → `errors.ts` → **Zod** | **603KB** |

**This pack's handlers are the latter.** `parseBody` calls Zod and `toAppError` looks at `z.ZodError`,
so every handler that uses validation pulls Zod into the bundle. Gauge the cold start from the
74KB alone and you are off from reality — this is another reason a function is split per route (a handler with no
validation does not pay the 603KB).
<!-- verified: the synthesized index.js instrumented in two editions on aws-cdk-lib 2.266.0 — 76,252 bytes (74KB) and 618,074 bytes (603KB). Both editions still carried require("@aws-sdk/client-dynamodb") -->

Without `timeout` and `memorySize`, the two properties are **not emitted into the template at all** —
which means the Lambda defaults (3s · 128MB) apply silently. State them explicitly.
<!-- verified: the Timeout/MemorySize keys confirmed absent in a synthesis with both properties removed. The defaults were compared directly against aws-cdk-lib 2.266.0 aws-lambda/lib/function.d.ts:162 (@default Duration.seconds(3)) and 189 (@default 128) -->
## 5. Deploy order and irreversible changes

**The order is table → function → route.** CDK derives dependencies from references, so inside one stack it
is kept automatically — `grantTaskAccess` binds the function role to the table ARN and
`addEnvironment('TABLE_NAME', …)` binds the function to the table name. The problem is **the order that cannot be
expressed as a reference**.

| change | the safe order | if you break it |
| --- | --- | --- |
| deploying code that needs a new action | widen the permission **first** → then deploy the code | send the code first and the runtime gives AccessDenied. The deploy succeeds and the 500s start |
| removing an action that is no longer used | deploy the code **first** → then narrow the permission | reverse the order and a function that still calls that action is alive |
| removing a route | migrate the clients → remove the route → remove the function | delete the function first and the route points at a target that is gone |
| adding a GSI | **one per deployment** | DynamoDB builds only one index per UpdateTable <!-- verified: requesting two GSIs at once against DynamoDB Local 3.3.1 returned LimitExceededException: Only 1 online index can be created or deleted simultaneously. Not instrumented against a real service deployment --> |

**Three things are irreversible.** ① **Changing `partitionKey` or `sortKey`** is a table **replacement**.
Thanks to `UpdateReplacePolicy: Retain` the existing table is not deleted, but what the stack points at is
**a new empty table**, and reverting the template does not bring the data along — finish the key design before
deploying. ② **Deleting a GSI** throws the index data away. Recreating it is a full rebuild, and meanwhile every query
against that index fails. ③ **Changing a `Construct` id** changes the logical ID, so
CloudFormation reads it as "delete then create" — the old table is left an orphan and the new one is empty.

**What is reversible** is the function code, the timeout, the memory, the environment variables and the IAM policy, and a stack
rollback restores them. So a dangerous change is **split into its own deployment** — mix a key change and a code change into one
deployment and the rollback-able half is tied to the half that cannot be rolled back.

## 6. Misuse list ① — old CDK 2 idiom → current shape

| old habit | current shape |
| --- | --- |
| `pointInTimeRecovery: true` | `pointInTimeRecoverySpecification: { pointInTimeRecoveryEnabled: true }` — the former is deprecated <!-- verified: aws-cdk-lib 2.266.0 aws-dynamodb/lib/table.d.ts:220 @deprecated --> |
| `logRetention: RetentionDays.X` | `logGroup: new LogGroup(...)` — the former is deprecated and builds one more custom-resource Lambda <!-- verified: aws-cdk-lib 2.266.0 aws-lambda/lib/function.d.ts:404 @deprecated --> |
| a one-line table-wide grant helper | `grantTaskAccess(fn, table, 'read' \| 'write' \| 'batch')` — 2 to 9 actions |
| `lambda.Function` + a hand-rolled `zip` · `Runtime.NODEJS_18_X` · x86_64 | `NodejsFunction` (esbuild built in) · `Runtime.NODEJS_22_X` · `Architecture.ARM_64` |
| leaving `billingMode` unset and tuning capacity afterwards | `BillingMode.PAY_PER_REQUEST` — throttle detection then runs through `ThrottlingException` |
| one handler serving several routes | one function per route — the unit of least privilege |

## 7. Misuse list ② — confusable pairs

| what gets picked wrong | the exact condition it applies under |
| --- | --- |
| `cdk synth` vs `cdk deploy` | the former is **a check** that runs without credentials. Judge the IAM claim with the former and do the latter after |
| `fn.addToRolePolicy` vs `table.grant*` | with the former we choose the actions. With the latter you take the list the helper chose — the 12-action one comes mixed in |
| `RemovalPolicy.RETAIN` vs `DESTROY` | the former keeps the old table on deletion and **replacement** alike. With the latter, one key change makes the data disappear |
| `externalModules` vs `nodeModules` | the former leaves it out of the bundle and expects the runtime to provide it. The latter installs it into `node_modules` instead of bundling it |
| `Duration.seconds` (the function) vs the integration timeout | with the function value above the 29s integration ceiling, the client gets a 504 while the function keeps running |
