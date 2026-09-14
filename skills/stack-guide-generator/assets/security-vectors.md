# Attack vector list for security primitives

**Do not carry a security primitive over from another pack. Write it fresh, and test it by running these vectors.**

Measured (2026-08-23): one return-path validation function was copied from the react-vite pack → the vue pack, and
the same defect was in **all four shipped copies**. All four blocked the direct forms `//host` · `/\host` ·
`javascript:`, and **only the dot-segment form got through.** Three original audits
missed it — reading does not catch it; only running reveals it.

## Usage rules

1. If the pack defines a function of this class, run **every** vector in that section
2. Record `input · expected · actual · verdict` for each vector and **carry it in the returned data**
3. `pack-smoke.sh --vectors` runs them automatically. For a toolchain with no profile, run them by hand and
   report the results — **do not say you ran something you did not run**
4. If even one passes (= fails to block), do not return the pack

---

## A. Return path · redirect validation

Functions that take the post-login return path out of the URL query. `safeReturnTo` ·
`safeInternalPath` · `safeReturnPath` and the like.

**Write the expected value precisely**: the criterion is **not** "it drops to the fallback" but
**"the result never leaves its own origin"**. Measured (2026-08-23), a repaired implementation did not
drop A7 and A8 to the fallback but returned `/%2f%2fevil.example` · `/tasksSet-Cookie:%20x=1`,
and both are **non-existent paths on the same origin**, so an SPA router merely goes to not-found.
Write the expected value as "fallback for everything" and a correct implementation is ruled 2/12 failing.

**But the consumer changes the verdict.** For the same return value:

| Consumer | Are A7 and A8 dangerous |
| --- | --- |
| SPA router (`router.replace` · `navigate`) | No — a non-existent path inside the origin |
| `window.location.assign/href` | It depends on the browser's URL re-interpretation — **must be verified** |
| The `Location` header of a server response | **Yes** — A8's control characters become header splitting (response splitting) |

So when you run the vectors, record **where that function's return value goes** as well.
If the function is used for a server redirect, control characters **must be dropped to the fallback**.

| # | Input | Why it is dangerous |
| --- | --- | --- |
| A1 | `//evil.example` | A protocol-relative URL. The browser goes to an external host |
| A2 | `/\evil.example` | Some browsers normalize a backslash into a slash |
| A3 | `https://evil.example` | An absolute URL |
| A4 | `javascript:alert(1)` | Scheme injection |
| A5 | **`/..//evil.example`** | **What the measurement found.** `new URL()` normalizes the dot segments **after** letting the origin through, so `/..` swallows the leading `/` → the result becomes `//evil.example` again. **Implementations that only compare the origin passed it 4 times out of 4** |
| A6 | `/../..//evil.example` | The multiplied form of A5 |
| A7 | `%2f%2fevil.example` | An encoded separator. `new URL()` does not decode it, so it stays inside the origin — judge a pass by looking at the consumer |
| A8 | `/tasks\n\rSet-Cookie: x=1` | Control character injection. **Written into a server `Location` header it is response splitting** — for an SPA router consumer it passes as long as it stays inside the origin |
| A9 | `\tjavascript:alert(1)` | Bypassing the scheme check with leading whitespace |
| A10 | `` (empty string) · `null` · a number | Type and empty value |
| A11 | `/tasks?filter=open#top` | **Legitimate — it must pass.** Blocking it kills the feature |
| A12 | `/tasks/123` | **Legitimate — it must pass** |

**The repaired shape (canonical)**: validate **the output `pathname`**, not the origin.

```ts
const url = new URL(raw, window.location.origin);
if (url.origin !== window.location.origin) return fallback;   // layer 1: the direct forms
const p = url.pathname;                                        // layer 2: the output **after** normalization
if (!p.startsWith('/') || p.startsWith('//') || p.startsWith('/\\')) return fallback;
return p + url.search + url.hash;
```

Both layers are needed. The gate's `check_security_shapes` blocks **shapes that are missing layer 2** with a FAIL.


### The environment the vector runner sets up — step outside it and the vectors do not run at all

This is the environment in which `pack-smoke.sh` calls your function. **Read it before authoring** — write without knowing this
constraint and the outcome is not "12 vectors passed" but "not one vector ran".

| What the runner provides | Value |
| --- | --- |
| `globalThis.window` | `{ location: { origin: 'https://app.example', href: 'https://app.example/' } }` — **and nothing else** |
| Call shape | `fn(input, FB)` — the fallback string is passed as the second argument |

- **Using `window.location.pathname` · `document` · `history` blows up in the runner.** Write in a shape that needs
  the origin alone — `new URL(raw, window.location.origin)` is that idiom
- The signature may be `(raw) => string` (the second argument is ignored). But **a shape that takes the fallback as an**
  **argument returns the runner's `FB` verbatim, and the runner reads that as "it dropped to the fallback"** —
  by the verdict rule above, that in itself is not a failure
- This constraint surfaced in measurement (vanilla C3): the ledger's signature and the runner's call shape differed, and
  neither document said so

## B. Path normalization · file access

Functions that build a path out of user input (upload keys, static files, template names).

| # | Input | Expected |
| --- | --- | --- |
| B1 | `../../etc/passwd` | Reject |
| B2 | `..%2f..%2fetc%2fpasswd` | Reject (encoded separator) |
| B3 | `....//etc/passwd` | Reject (the form left behind by an implementation that strips `../`) |
| B4 | `/absolute/path` | Reject — the prefix gets ignored |
| B5 | `a/b/../c` | Policy-dependent: pass if `a/c` after normalization is inside the root |
| B6 | `file\x00.png` | Reject (null-byte truncation) |

**Canonical**: do not strip strings; **normalize and then re-check the root prefix**.
`replace('../','')` is broken by B3.

## C. Token · secret comparison

Session tokens · API keys · HMAC signatures · password reset tokens.

| # | Check | Expected |
| --- | --- | --- |
| C1 | Does it compare with `===`/`==` | **No** — use a constant-time comparison (`crypto.timingSafeEqual` · `hmac.compare_digest`) |
| C2 | Does it return immediately for an input of different length | Judge whether length leakage matters in this place, and write that down |
| C3 | Does it put the token into logs or error messages | **No** |
| C4 | Does it respond differently per failure reason | **No** — generalize it. Distinguishing leaks whether the account exists |
| C5 | Is the token generated with `Math.random()` | **No** — use a CSPRNG |

## D. Escaping · rendering

| # | Input | Context | Expected |
| --- | --- | --- | --- |
| D1 | `<img src=x onerror=alert(1)>` | HTML body | Escape |
| D2 | `" onmouseover="alert(1)` | HTML attribute | Attribute-context escaping (the body-context one is not enough) |
| D3 | `javascript:alert(1)` | `href` · `src` | Scheme allowlist |
| D4 | `</script><script>alert(1)</script>` | JSON inside an inline `<script>` | JS string-context escaping |
| D5 | An untrusted string | `v-html` · `dangerouslySetInnerHTML` | **Do not use them** — this is the point where the framework's automatic escaping is switched off |

**Context confusion is this class's signature defect.** Do not write that one kind of escaping covers all four
places.

## E. Authorization decisions

| # | Check | Expected |
| --- | --- | --- |
| E1 | Where does it read the basis for the ownership decision | **Not** from the request body, query, or headers, but from the verified session |
| E2 | Does it respond differently for absence (404) and lack of permission (403) | **It does not distinguish them** — distinguishing lets resource existence be enumerated |
| E3 | Does a mutation (update/delete) put ownership into the query condition | **It does.** Fetch-then-compare is broken by a race |
| E4 | Does it answer a 0-row mutation as a success | **No** — check the affected row count |
| E5 | Is this a stack with no data-layer policy engine | With one, a double defence; **without one, the application layer is the only boundary** — carrying the wording over backwards makes the reader believe they are safe |

E5 is an axis premise. Read `dataLayerPolicyEngine` in `pack.json` before writing.
