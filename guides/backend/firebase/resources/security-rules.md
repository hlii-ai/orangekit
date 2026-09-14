<!-- orangekit-pack: backend/firebase v3.14.0 -->
# Firestore Security Rules — a boundary that blocks only the browser

This file owns **the syntax of `firestore.rules` · ownership · field validation · rules unit tests**.
The field names come from `TaskDoc` in `resources/data-modeling.md`, and the checks on the path the rules **cannot**
block (Cloud Functions) are owned by `resources/data-access.md`. The decision of which path to open
(`clientAccessPolicy`) is made by the seam's `auth-boundaries` slot.

## 1. The two boundaries — what the rules block and what they do not

**This section is the most important in the whole pack.** It is a measurement of reading the same document with two SDKs
while all of `firestore.rules` was `allow read: if false`.

| path | read | write |
| --- | --- | --- |
| Client SDK (`firebase@12`) | `permission-denied` — `false for 'get' @ L5` | `permission-denied` |
| `firebase-admin@14` (Cloud Functions) | **Success. The document comes back as-is** | **Success** |

`firebase-admin` attaches with administrator credentials and **does not even evaluate the rules.** However tight
the rules are, **the function path is defenseless** — a function that does not check `ownerId` is the same as having no rules.
Conversely, even if only functions are planned, **keep the rules locked.** "There is a policy engine, so we are safe" is
**only half true** on this axis: the two boundaries do not complement each other, they block **different code paths**.

## 2. Rules skeleton (`firestore.rules`)

**Split everything** — `read` into `get`/`list` and writes into `create`/`update`/`delete`. Bundle them and the invariants of
create and update differ, so one of the two is necessarily loose (measured in §4). This file lives at the repository root
and `firebase.json` and `functions/test/emulator.ts` **read it from disk** — which is why it ships as a complete file.

<!-- file: firestore.rules -->
```
// firestore.rules
rules_version = '2';

service cloud.firestore {
  match /databases/{database}/documents {

    function isSignedIn() { return request.auth != null; }
    function isOwner(res) { return isSignedIn() && res.data.ownerId == request.auth.uid; }

    function validTask(d) {
      return d.keys().hasOnly(['id', 'title', 'status', 'ownerId', 'createdAt', 'updatedAt'])
          && d.keys().hasAll(['id', 'title', 'status', 'ownerId', 'createdAt', 'updatedAt'])
          && d.title is string && d.title.size() > 0 && d.title.size() <= 200
          && d.status in ['open', 'done'];
    }

    match /tasks/{taskId} {
      allow get:  if isOwner(resource);
      allow list: if isSignedIn()
                  && request.query.limit <= 100
                  && resource.data.ownerId == request.auth.uid;

      allow create: if isOwner(request.resource)
                    && validTask(request.resource.data)
                    && request.resource.data.id == taskId
                    && request.resource.data.createdAt == request.time
                    && request.resource.data.updatedAt == request.time;

      allow update: if isOwner(resource)
                    && isOwner(request.resource)
                    && validTask(request.resource.data)
                    && request.resource.data.id == resource.data.id
                    && request.resource.data.createdAt == resource.data.createdAt
                    && request.resource.data.updatedAt == request.time;

      allow delete: if isOwner(resource);
    }

    match /{document=**} {
      allow read: if false;
      allow create, update, delete: if false;
    }
  }
}
```

Permissions across `match` blocks **combine as an OR.** The catch-all denial at the bottom does not reverse another block's
permission — it only blocks collections for which no rules have been written yet. In that block too, writes are written as three.

## 3. `update` looks at `resource` and `request.resource` together

`resource` is **the existing document** and `request.resource` is **the document after the write**. Measured:

| update rule | someone else changing `ownerId` to their own | the owner's legitimate update |
| --- | --- | --- |
| Looks only at `request.resource` | **It passes** — the document is taken wholesale | Passes |
| Looks at both | `permission-denied` | Passes |

Check only the new one and the moment the attacker changes `ownerId` **to their own uid** the owner matches and it passes.
`isOwner(resource) && isOwner(request.resource)` demands "mine before the change and mine after the change", which makes
the transfer itself impossible.

Two more measurements: **`update`'s `request.resource.data` is the merged whole document** — send only `{ title }` and
the rules still see `ownerId`. Flipped around, a rule requiring `updatedAt == request.time` **refuses an update that did
not send `updatedAt`.** On `delete`, `request.resource` is **null**.

## 4. What goes loose when you bundle under `write`

Applying a bundled write rule (based on `request.resource`) and a rule split into four against the same data gave
this result: **the bundled rule passes an update that changes `ownerId` on someone else's document to your own, and at the
same time refuses the owner's own deletion.** Delete has no `request.resource` (§3), so the bundled condition raises an
evaluation error (`Null value error.`). That is, bundling does not merely go loose — it **breaks at the same time**:
it ships with the owner unable to delete their own task while the same rule passes an ownership transfer.
One conditional expression cannot satisfy the invariants of four verbs at once.

## 5. Field validation — how far the rules act as a schema

`validTask` enforces **the key set · the types · the literal set** at the rules layer. What is actually
rejected is carried as vectors by the `create` test in §7 — an unknown field `isAdmin` · a `status` outside
the literals · an empty `title` · someone else's `ownerId` · a client-side `createdAt` · a document ID mismatch.
`createdAt == request.time` is the only way the rules can enforce the server clock.

**No document in this rules file is blocked by `hasAll` alone.** Removing each of the six fields in turn,
**all six cases were refused** regardless of whether `hasAll` was present — the other conditions constrain each field separately.
It stays anyway: the moment **one of those conditions is removed, `hasAll` becomes the only defense**.

## 6. The coupling of rules and queries — `list` evaluates **the query**, not the result

Measured with `resource.data.ownerId == request.auth.uid` in `allow list`:

| query | result |
| --- | --- |
| List with no `where` | **`permission-denied`** — not 0 results |
| `where('ownerId', '==', 'alice')` (yourself) | Passes, 1 document |
| `where('ownerId', '==', 'bob')` (someone else) | **`permission-denied`** — not an empty result |

Firestore does not read the documents and then filter. **If the query cannot prove it satisfies the rules, the query
itself is refused.** So rules and queries always change in the same commit.

`request.query.limit` has one more trap. `where` + `limit(50)` passes and `limit(500)` is refused, but
**a query with no `limit()` is refused too** — `null <= 100` raises `Unsupported operation
error.` **This condition means every query is obliged to carry a `limit()`.**

## 7. Rules unit tests (`functions/test/rules.test.ts`)

**Do not verify rules by reading them without the emulator** — the `resource`/`request.resource` distinction and the evaluation
order are the classic places to get wrong by reading. This file is **the sole owner of the rules tests**, and `withRulesTest` and
`RULES` are owned by `resources/testing-and-deploy.md` (`functions/test/emulator.ts`).

<!-- file: functions/test/rules.test.ts -->
```ts
// functions/test/rules.test.ts
import { describe, expect, it } from 'vitest';
import {
  assertFails,
  assertSucceeds,
  type RulesTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection, deleteDoc, doc, getDoc, getDocs, limit, query,
  serverTimestamp, setDoc, Timestamp, updateDoc, where,
} from 'firebase/firestore';
import { RULES, withRulesTest } from './emulator';
import { COLLECTION } from '../src/firestore/model';

// This is the shipped firestore.rules verbatim — emulator.ts reads it from disk and hands it out as RULES.
// Bake the rules into the test as a string and you stop checking what ships.
const rulesForTasks = RULES;
const LUMPED = /allow\s+[a-z,\s]*\bwrite\b\s*:/;

const seed = (env: RulesTestEnvironment, id: string, ownerId: string) =>
  env.withSecurityRulesDisabled((ctx) =>
    setDoc(doc(ctx.firestore(), COLLECTION, id), {
      id, title: 'Write the report', status: 'open', ownerId,
      createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    }),
  );

describe('firestore.rules — tasks', () => {
  it('the shipped rules are what is checked, and writes are not bundled', () => {
    // ❌ Positive control — the two forms of a "bundled write". The regex has to catch both to be a guard
    expect('  allow write: if isOwner(resource);').toMatch(LUMPED);
    expect('  allow read, write: if false;').toMatch(LUMPED);
    // ✅ What ships is not that shape
    expect(rulesForTasks).toMatch(/match \/tasks\/\{taskId\}/);
    expect(rulesForTasks).toMatch(/allow\s+create\s*:/);
    expect(rulesForTasks).not.toMatch(LUMPED);
  });

  it('the owner reads and others cannot', async () => {
    await withRulesTest(async (env: RulesTestEnvironment) => {
      await seed(env, 't1', 'alice');
      const alice = env.authenticatedContext('alice').firestore();
      const mallory = env.authenticatedContext('mallory').firestore();
      await assertSucceeds(getDoc(doc(alice, COLLECTION, 't1')));
      await assertFails(getDoc(doc(mallory, COLLECTION, 't1')));
    });
  });

  it('an ownership-transfer update is blocked and a title change passes', async () => {
    await withRulesTest(async (env: RulesTestEnvironment) => {
      await seed(env, 't2', 'alice');
      const alice = env.authenticatedContext('alice').firestore();
      const mallory = env.authenticatedContext('mallory').firestore();
      await assertFails(updateDoc(doc(mallory, COLLECTION, 't2'), {
        ownerId: 'mallory', updatedAt: serverTimestamp(),
      }));
      await assertSucceeds(updateDoc(doc(alice, COLLECTION, 't2'), {
        title: 'Report v2', updatedAt: serverTimestamp(),
      }));
    });
  });

  it('a list passes only with a where', async () => {
    await withRulesTest(async (env: RulesTestEnvironment) => {
      await seed(env, 't3', 'alice');
      const alice = env.authenticatedContext('alice').firestore();
      const tasks = collection(alice, COLLECTION);
      await assertFails(getDocs(query(tasks, limit(20))));
      const mine = query(tasks, where('ownerId', '==', 'alice'), limit(20));
      const ok = await assertSucceeds(getDocs(mine));
      expect(ok.docs.map((d) => (d.data() as { ownerId: string }).ownerId)).toEqual(['alice']);
    });
  });

  it('create enforces the spec — valid passes, every violation is refused', async () => {
    await withRulesTest(async (env: RulesTestEnvironment) => {
      const alice = env.authenticatedContext('alice').firestore();
      const good = (id: string) => ({
        id, title: 'Write the report', status: 'open', ownerId: 'alice',
        createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
      });
      await assertSucceeds(setDoc(doc(alice, COLLECTION, 'n1'), good('n1')));
      const rejected: Record<string, Record<string, unknown>> = {
        n2: { isAdmin: true },                      // hasOnly — unknown field
        n3: { status: 'archived' },                 // outside the literal set
        n4: { title: '' },                          // empty title
        n5: { ownerId: 'mallory' },                 // created under someone else's ownership
        n6: { createdAt: Timestamp.fromMillis(0) }, // client-side clock
      };
      for (const [id, patch] of Object.entries(rejected)) {
        await assertFails(setDoc(doc(alice, COLLECTION, id), { ...good(id), ...patch }));
      }
      await assertFails(setDoc(doc(alice, COLLECTION, 'zz'), good('n7'))); // ID != id field
    });
  });

  it('only the owner deletes — a task owned by someone else is not deleted', async () => {
    await withRulesTest(async (env: RulesTestEnvironment) => {
      await seed(env, 'd1', 'alice');
      await seed(env, 'd2', 'alice');
      const alice = env.authenticatedContext('alice').firestore();
      const mallory = env.authenticatedContext('mallory').firestore();
      await assertFails(deleteDoc(doc(mallory, COLLECTION, 'd1')));
      await assertSucceeds(deleteDoc(doc(alice, COLLECTION, 'd2')));
    });
  });
});
```

**Pair the positive and the negative inside the same `it`, and use two actors.** With only a refusal assertion, turning the rules
wholesale into `if false` still goes green, and with only one owner half the rules go unmeasured. As with `LUMPED` in the first
`it`, **put a positive control in front of any "X does not appear"** — without seeing what it catches, it is indistinguishable
from a regex that catches nothing. Measured: the narrow `/allow\s+write\s*:/` **missed** the `allow read, write: if false`
this pack itself was using.

Defects were planted in the rules to confirm this. **10 of 11 went red** — removing `create`'s `validTask` ·
`isOwner(request.resource)` · `id == taskId` · `createdAt == request.time` · deleting the `allow delete`
line · loosening `delete` · removing `update`'s `isOwner(resource)` · removing ownership from `list` and `get` ·
bundling the four as `allow write` (4 red) · reverting the catch-all denial to `allow read, write:`. **The one survivor
was removing `hasAll`**, and that is the redundancy §5 measured.

**Two were green for the wrong reason.** ① The hijack attempt did not send `updatedAt` and tripped a *different* condition.
② The missing-field vector tripped `updatedAt == request.time` rather than `hasAll` — that vector was dropped and replaced by
the measurement in §5. A negative assertion is only evidence once you confirm it is refused **for the condition you intended**.

## Misuse list ① — Realtime Database rules → Firestore rules

Carry RTDB habits over unchanged and they go silently wrong. The right column is measured, the left is stack knowledge. <!-- unverified: the RTDB-side idioms were not reproduced -->

| old habit (RTDB rules) | current form (Firestore rules) |
| --- | --- |
| The two verbs `.read` / `.write` | Split into five: `get`·`list`·`create`·`update`·`delete` |
| A parent's permission **is inherited** by children | It is not. Write a `match` per path or state `{document=**}` |
| `auth.uid` · `now` | `request.auth.uid` · `request.time` |
| `data` / `newData` | `resource.data` / `request.resource.data` |
| Queries have no concept in the rules | `list` evaluates **the query itself**. With no `where` it is refused |

## Misuse list ② — confusable pairs

| often chosen wrong | exactly when it applies |
| --- | --- |
| `resource` vs `request.resource` | Existing vs after the write. `update` takes **both**, `delete` only `resource` (the other is null) |
| `get` vs `list` | A single read and a query are separate verbs. Leave only `list` loose and someone else's documents leak wholesale through the list |
| `create` vs `update` | Create takes only `request.resource`; update also has to preserve the immutable fields (`id`, `createdAt`) |
| `hasOnly` vs `hasAll` | The first blocks unknown fields **on its own**. The second is redundant when a condition already constrains each field separately (measured in §5) |
| Rules vs `firebase-admin` | The rules block only the client SDK. The boundary on the function path is `where('ownerId', '==', ownerId)` |
| An inline rules string vs the shipped file | Bake the rules into the test as a string and **you are not checking the file that ships.** Use `RULES` |
| The rules passing vs the query running | Even past the rules, without the composite index that one query fails in production |
