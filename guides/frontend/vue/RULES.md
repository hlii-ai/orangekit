---
paths:
  - "src/**"
  - "app/**"
  - "packages/**"
  - "apps/**"
  - "lib/**"
---
<!-- orangekit-pack: frontend/vue v3.12.0 -->
<!-- Stack core card — the admission conditions and the retirement procedure are in stack-guide-generator assets/guide-skeleton.md "Stack core card".
     The universal rules (no secrets behind the VITE_ prefix · no v-html · redirect allow-list) belong to security.md, so they are not here. -->

# Vue 3 + Vite core card

The project spec and `.claude/rules/code-conventions.md` take precedence over this card and the `frontend-guide` skill.
Look up wiring and examples in the `frontend-guide` skill when needed.

## Consistency — the project decides the values

- [consistency] Call HTTP only through the one API client module; screens never call `fetch` directly. That module's paths and envelope follow the backend spec. — why models get it wrong: auth headers and error normalization split screen by screen <!-- evidence: policies http-in-api-layer · model-gap: not-observed -->
- [consistency] The `@tanstack/vue-query` cache alone owns server data. Never copy it into Pinia (options or setup stores). — why models get it wrong: with two caches, an update reaches only one <!-- evidence: policies no-server-data-in-store · model-gap: not-observed -->

## Performance & integrity — what breaks silently

- [performance] Import queries from `@tanstack/vue-query`. — why models get it wrong: React examples vastly outnumber Vue ones, so `@tanstack/react-query` leaks in <!-- evidence: policies no-react-query · model-gap: not-observed -->
- [performance] Take store state and getters out with `storeToRefs` (destructure only actions directly). — why models get it wrong: plain destructuring cuts reactivity and the screen stops updating <!-- evidence: policies storetorefs-required · model-gap: not-observed -->
- [performance] Do not assemble class names as strings in `:class`; pick complete class names with an object or array. — why models get it wrong: Tailwind scans the source as strings, so an assembled name is not in the CSS <!-- evidence: policies no-dynamic-class-string · model-gap: not-observed -->
- [performance] Do not use `route.fullPath` as the `:key` of `RouterView`. — why models get it wrong: every query or hash change remounts it and a form being typed into is lost <!-- evidence: policies no-fullpath-key (audit run-verified) · model-gap: not-observed -->
- [performance] Do not override the height, typography or spacing a shared component owns with `class` at the use site; control them with props. — why models get it wrong: a fallthrough `class` is appended without passing through `cn()`'s merge, so CSS order picks the winner <!-- evidence: policies (what humans keep) · model-gap: not-observed -->
