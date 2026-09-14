<!-- orangekit-pack: backend/gcp-serverless v3.14.0 -->
# Identity Platform ID token verification — the front of the server is the only boundary

What this file owns is only **what a valid credential is** and **how it is verified**
(`src/identity/verify.ts`). **How the token arrives** (a bearer header · a session cookie) · the login flow ·
wiring the `currentUser` middleware · roles are **owned by the seam** (`src/http/auth.ts`). Which status code a
verification failure goes out as is owned by `error-handling.md`.

**This axis has no backup.** Firestore Security Rules are a blanket deny and the server attaches with a service account and
bypasses the rules entirely. The `sub` this function hands back is the `ownerId`, and once this is breached there is nothing behind it.

## 1. What this function accepts — the token decision table

Google issues several kinds of JWT and **they are all RS256, all signed with `googleapis.com`-family keys.**
The only thing that tells them apart is `iss` and `aud`. Mix them up and a service account token can call the user API.

| token | `iss` | `aud` | signing key set | does `verifyIdToken` accept it |
| --- | --- | --- | --- | --- |
| **Identity Platform ID token** (an end user) | `https://securetoken.google.com/<projectId>` | `<projectId>` | `securetoken@system.gserviceaccount.com` | **yes — the only target of this function** |
| **IAM ID token** (service-to-service call) | `https://accounts.google.com` | the URL of the service being called (`https://tasks-….a.run.app`) | the `federated-signon` key set | **refused** |
| Firebase custom token | the service account email | `…identitytoolkit…verifyCustomToken` | the service account private key | refused — it is the material before an exchange |
| OAuth access token | (not a JWT) | — | — | refused — it is not something a signature is verified on |

**To accept service-to-service calls, build a separate boundary.** The moment one function allows two issuers,
it has to recognize two different values of `aud` at once, and from then on the looser of the two checks is the effective boundary.
Cloud Run's IAM authentication belongs in the **service IAM policy** in the first place, not in application code.

## 2. Keep the key set at module top level

Cloud Run is a **resident process** — the container is alive between requests, so the cache of a module-top-level
instance really does live. The return of `createRemoteJWKSet` is itself the cache, and build it per request and the cache is
thrown away every time so **every request round-trips to Google**.

<!-- verified: proxied with a self-generated key pair + a local JWKS server. Across 17 verifications the server received 1 request -->
Confirmed by running it: while one module-top-level instance verified 17 tokens, the JWKS server received **1** HTTP request.

```ts
// ❌ a new key set per request — the cache is thrown away every time
app.use(async (c, next) => {
  const jwks = createRemoteJWKSet(JWKS_URL);   // ❌ it round-trips once per request
  await next();
});
```

## 3. `verifyIdToken` (`src/identity/verify.ts`)

<!-- file: src/identity/verify.ts -->
```ts
// src/identity/verify.ts
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { AppError } from '../errors.js';
import { settings } from '../settings.js';

const JWKS_URL = new URL(
  'https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
);

/** One per process. This value is itself the key cache — do not build it inside a request. */
export const jwks = createRemoteJWKSet(JWKS_URL);

const ISSUER = `https://securetoken.google.com/${settings.IDENTITY_PLATFORM_PROJECT_ID}`;

export type IdTokenClaims = {
  sub: string;
  email?: string;
  email_verified?: boolean;
};

export async function verifyIdToken(token: string): Promise<IdTokenClaims> {
  let payload;
  try {
    ({ payload } = await jwtVerify(token, jwks, {
      algorithms: ['RS256'],
      issuer: ISSUER,
      audience: settings.IDENTITY_PLATFORM_PROJECT_ID,
      requiredClaims: ['sub', 'exp', 'iat'],
      clockTolerance: 60,
    }));
  } catch {
    // The classes are not distinguished — section 5 below
    throw new AppError('UNAUTHENTICATED', 'authentication failed');
  }

  const sub = payload.sub;
  if (typeof sub !== 'string' || sub.length === 0) {
    throw new AppError('UNAUTHENTICATED', 'authentication failed');
  }

  return {
    sub,
    email: typeof payload.email === 'string' ? payload.email : undefined,
    email_verified: payload.email_verified === true,
  };
}
```

The seam defines `AppError` in `src/errors.ts` (in `ERROR_STATUS`, `UNAUTHENTICATED` → 401).
`settings` is owned by `src/settings.ts` — **this file never reads the environment directly.**

## 4. What each single guard blocks — a mutation comparison

Each option was removed one at a time and the same token run through again to observe **whether it really does pass without that guard.**
A guard whose removal does not let it through is defense in depth; one whose removal does is **the only wall**.

<!-- verified: proxied with a self-generated RS256 key pair + a local JWKS. Each row was run once before and once after removing the option -->

| what was removed | the token that then passes | observed | character |
| --- | --- | --- | --- |
| `issuer` | IAM-family tokens whose `iss` is `accounts.google.com` | **PASS** | the only wall |
| `audience` | a token addressed to another project | **PASS** | the only wall |
| `exp` from `requiredClaims` | **a token with no `exp` at all** | **PASS** | the only wall |
| the empty-string guard on `sub` | `sub: ""` | **jose lets it through** | the only wall |
| `algorithms` | HS256 with the public key used as the HMAC secret | still REJECT (`ERR_JOSE_NOT_SUPPORTED`) | defense in depth |

**Two rows matter especially.**

<!-- verified: ran a token with no exp through the installed jose 6.2.10 and observed it — it passes without requiredClaims -->
- **jose does not require `exp` by default.** A token with no `exp` is a token that never expires, and without the option
  it passes normally. `requiredClaims: ['sub', 'exp', 'iat']` is the only line that blocks that one
<!-- verified: observed a sub: "" token passing jwtVerify (payload.sub === "") -->
- **jose counts `sub: ""` as "present".** Put `sub` in `requiredClaims` and an empty string still passes.
  An empty `ownerId` disables the ownership filter, so an explicit length check is needed

`algorithms` was not, as observed, the only wall (the remote key set refuses a symmetric-algorithm request outright), but
**it stays** — that defense is a property of jose's internal implementation and not our contract.

## 5. Fold the failure classes into one

jose tells the cause of a failure apart by code. **That distinction is not passed on to the client.**

| jose error code | the actual cause | what the client receives |
| --- | --- | --- |
| `ERR_JWT_EXPIRED` | expired | `UNAUTHENTICATED` |
| `ERR_JWT_CLAIM_VALIDATION_FAILED` | `iss`·`aud`·`nbf`·a missing required claim | `UNAUTHENTICATED` |
| `ERR_JWKS_NO_MATCHING_KEY` | an unknown `kid` — an attacker's key·right after a rotation | `UNAUTHENTICATED` |
| `ERR_JOSE_ALG_NOT_ALLOWED` | `alg: none` · algorithm confusion | `UNAUTHENTICATED` |
| `ERR_JWS_INVALID` | not the shape of a JWT | `UNAUTHENTICATED` |

Tell them "it expired" and "the signature is wrong" apart and the attacker learns **which axis to fix.**
An expiry response confirms "this token was once valid", and an issuer-mismatch response is a scorecard for guessing the project ID.

**Leave the diagnosis in the server log only.** `log('warn', 'id token rejected', { reason: err.code })` —
load only jose's code into `reason` and **do not load the raw token·the payload·the email address.** A log is a leak path.

## 6. Clock skew and key rotation

**`clockTolerance: 60`.** Let the container clock and Google's issuing clock drift a few seconds apart and the `iat`·`nbf` of a
freshly issued token land in the future, so a normal login is refused. 60 seconds absorbs that skew without meaningfully extending
the lifetime of an expired token.

<!-- verified: a token with iat/nbf 30 seconds in the future passed, while 600 seconds in the future was refused with ERR_JWT_CLAIM_VALIDATION_FAILED -->
Confirmed by running it: a token whose `iat`·`nbf` was **30 seconds** in the future passed, and one **600 seconds** in the future was refused.

**Key rotation.** Google publishes several keys at once and switches over with an overlapping window.

<!-- verified: actually queried the securetoken@system.gserviceaccount.com key set (2026-08-24) -->
- At the moment the real endpoint was queried, **4 RS256 public keys were published at once**, and the response header was
  `cache-control: public, max-age=19348, must-revalidate` (about 5.4 hours)
<!-- unverified: no real GCP project — the rotation period and the actual length of the overlap window were not observed -->
- The rotation **period** itself and the length of the overlap window could not be confirmed

jose's caching behavior was observed by proxy with a local key set server.

<!-- verified: swapped the key on the local JWKS server, changed the kid, re-verified, and instrumented the number of requests the server received -->
| situation | observed |
| --- | --- |
| a `kid` that is not in the cache arrives | it **fetches the key set again** and verification succeeds (1 extra round trip) |
| it arrives again inside the default `cooldownDuration` (30 seconds) | the re-fetch is suppressed and it is refused with `ERR_JWKS_NO_MATCHING_KEY` |
| a token signed with a key that has **disappeared** from the key set | it **keeps passing** while the cache is alive |

The last row is the operational truth — **key revocation does not take effect immediately.** The ceiling on it taking effect is `cacheMaxAge`
(10 minutes by default), and until then the signature of a revoked key is valid. If that is a problem, the answer is to lower `cacheMaxAge`,
not to change the code. It is rather Google's way of publishing, with a generous overlap window, that makes the 30-second cooldown
survivable.

## 7. The subject is `sub`

`sub` is the immutable user ID Identity Platform issues, and **it becomes the `ownerId` exactly as it is.**

| claim | use it as the ownership key | why |
| --- | --- | --- |
| `sub` | **yes** | it is immutable for the life of the account |
| `email` | no | the user can change it, and a released address gets **reused** |
| `email_verified` | no | it is a trust level, not ownership |
| `phone_number` | no | the same reason as email |

A system that made `email` the `ownerId` loses the user their own documents the moment they change address, and whoever
takes that address over **gets those documents.** It is an irreversible decision, so decide it at the start.

The basis for an authorization decision comes **only from a verified token.** A user identifier in the request body·query·header is
input, not a credential — take `ownerId` from the body and someone else's documents can be created or read.

## 8. Do not decode without verifying

A JWT's payload **is readable without checking the signature.** It is base64url, not encryption.

```ts
// ❌ a payload whose signature was never checked — the attacker wrote the value by hand
const claims = JSON.parse(atob(token.split('.')[1]));
const ownerId = claims.sub;                    // ❌ anything at all comes in
// ❌ jose's decodeJwt does not check the signature either
const ownerId2 = decodeJwt(token).sub;         // ❌ the same defect
// ✅ use only claims that passed verification
const { sub } = await verifyIdToken(token);
```

"Decode it for logging only" is not done either. Let a value from before verification into the log and the person judging
from that log reads it as fact.

## Misuse list ① — firebase-admin idioms → jose comparison table

This axis attaches with `@google-cloud/firestore` and **does not use `firebase-admin`** (the `no-firebase-admin` policy).
Move code from the `firebase` axis over as it is and the security boundaries of two axes mix — that one rests on the premise that the rules
block the client, while on this axis the rules are a blanket deny.

| old habit (firebase-admin) | the current shape (jose 6) |
| --- | --- |
| `admin.auth().verifyIdToken(t)` | `verifyIdToken(t)` — `jwtVerify` + `createRemoteJWKSet` |
| the SDK decides `iss`·`aud` implicitly for you | **state** `issuer`·`audience` — leave them out and they are not checked |
| the `checkRevoked: true` option | there is no counterpart. Checking revocation needs its own round trip |
| `decodedToken.uid` | `claims.sub` — the name differs |
| app initialization (`initializeApp`) as a premise | there is no initialization. One key set instance is the whole of it |

## Misuse list ② — confusion pairs

| what gets picked wrong often | the exact condition for applying it |
| --- | --- |
| an end-user ID token vs an IAM ID token | tell them apart by `iss`. The latter is decided by service IAM, not by this function |
| `sub` vs `email` | the ownership key is `sub` alone. `email` is for display |
| `verifyIdToken` vs `decodeJwt` | the latter does not look at the signature — do not use it for a trust decision |
| `clockTolerance` vs `maxTokenAge` | the first absorbs clock skew, the second is a lifetime ceiling measured from `iat`. Different purposes |
| a module-top-level `jwks` vs building one inside a request | the cache only lives in a resident process — top level is the only place |
| distinguishing the failure classes vs folding them into one | the log distinguishes and **the response folds** |
