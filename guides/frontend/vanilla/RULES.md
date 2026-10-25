---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "lib/**"
---
<!-- orangekit-pack: frontend/vanilla v3.14.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (no secrets behind the VITE_ prefix · no innerHTML injection · redirect allow-list) belong to security.md, so they are not here. -->

# Vanilla JS + Vite core card

The project spec and `.claude/rules/code-conventions.md` take precedence over this card and the `frontend-guide` skill.
Look up wiring and examples in the `frontend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] The language is JavaScript + JSDoc. No `.ts` files; types are checked by tsc with `checkJs` and `strict` on. When wrapping a call that returns `any`, add `@returns`. — why models get it wrong: TypeScript is the default, and an `any` without `@returns` goes unchecked even under strict <!-- evidence: policies typecheck-on · typecheck-strict · model-gap: not-observed -->
- [consistency] Read env values only in the one config module. No `import.meta.env` in other files. — why models get it wrong: Vite lets you read it anywhere, which bypasses boot-time validation <!-- evidence: policies env-single-entry · model-gap: not-observed -->

## Security — where this stack leaks

- [security] Check the scheme of user values that go into `href`/`src`. — why models get it wrong: it stops at escaping with `textContent` — escaping does not stop `javascript:` <!-- evidence: policies (what humans keep) · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Validate values from the network, `localStorage` or the URL with `safeParse`. `@type` is a claim, not validation. — why models get it wrong: a JSDoc cast passes the type check and looks like validation <!-- evidence: policies boundary-parse · seam-parse-response · model-gap: not-observed -->
- [performance] `subscribe` returns an unsubscribe function, and the caller keeps it and calls it when the screen is torn down. — why models get it wrong: there is no unmount hook, so a dropped subscription lives forever <!-- evidence: policies store-unsubscribe · model-gap: not-observed -->
- [performance] Delegate list events to one root. — why models get it wrong: listeners attached per item pile up on every re-render <!-- evidence: policies delegate-not-per-row · model-gap: not-observed -->
- [performance] A refetch or route change cancels the previous request with `AbortController` and passes the signal all the way to `fetch`. — why models get it wrong: a late earlier response overwrites the later one <!-- evidence: policies abort-on-reload · seam-signal-passed · model-gap: not-observed -->
- [performance] A link intercept lets modifier keys, middle click, `target`, external origins and `download` through. — why models get it wrong: missing any one silently breaks "open in new tab" <!-- evidence: policies intercept-modifier-keys · model-gap: not-observed -->
