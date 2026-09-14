<!-- orangekit-doctor: allow-stale-refs -->
<!--
  Generation skeleton for the project-specific project-structure card.
  orangekit-init Step 7.5 reads this file, replaces every placeholder with a real value, and
  saves it as `project-structure.md` under the project's `.claude/rules/`.

  Principles:
  - Project-owned file — do not add an orangekit-rule-version stamp (not an install-rules update target)
  - If code already exists, fill the tree from a **measured** reading (ls, 2~3 depth). Do not fill it by guessing
  - For a new project, fill it with the target structure from the preset + topology (Step 4.7)
  - Remove this comment block and all {{guidance}} text at generation time
  - Field-tested source: a layout proven while building an app service in a monorepo
-->
---
paths:
  - "{{SOURCE_DIR}}/**"
  # Paths the topology requires **must** go here (orangekit-init Step 7.5 item 5 verifies it):
  #   monorepo → shared package paths (e.g. "packages/**")
  #   msa      → service roots        (e.g. "services/**", "apps/**")
  # Leave one out and this card will not load when that path is edited.
  # A card that does not load is worse than no card — it makes you believe one is there.
---

# Project Structure

The {{single-repo | monorepo | MSA}} structure of {{project name}}. Follow this structure when creating new files/folders.

## Overall Structure

```
{{Measured or target directory tree — one "what lives here" comment line on each major directory.
  Example (monorepo):
  project-root/                       # root = the app
  ├── packages/
  │   └── shared/                     # shared code (types, UI, utils)
  │       └── src/
  │           ├── types/              # shared TypeScript types
  │           ├── ui/                 # common UI components
  │           └── lib/                # common utilities
  └── src/                            # app-only code
      ├── app/                        # routes/pages
      ├── components/                 # app-only components (subfolder per domain)
      ├── lib/                        # business logic·services·external integrations
      ├── hooks/                      # app-only custom hooks
      └── stores/                     # app-only state stores

  For MSA, give a per-service tree under services/ (or apps/) and state where the shared contract lives}}
```

## Import Rules

| Target | Import path |
| ---- | ----------- |
| {{e.g. shared types/utils/UI (monorepo)}} | {{e.g. the `@scope/shared` package alias}} |
| {{e.g. app-only code}} | {{e.g. the `@/` alias (`@/components/...`) — no relative paths}} |

{{For MSA add: no direct code import between services — only through an API call or an event/contract package}}

## Dependency Direction

{{Layer arrows — e.g. web → application → domain → infrastructure
  Write only the lines that must never run backward. Two lines if the structure is simple.
  If it is single-layer, write "single-layer — not applicable". Do not force-fill it}}

`orangekit-reviewer` checks backward imports against this section — if this section is missing, it is reported as undecidable.

## {{shared vs app-only criteria (monorepo) | directory placement criteria (single-repo) | service boundary criteria (MSA)}}

| Location | Criterion |
| ---- | ---- |
| {{e.g. `packages/shared/`}} | {{e.g. shared code independent of the app (types, UI, common utils)}} |
| {{e.g. `src/`}} | {{e.g. code used only by this app (pages, domain components, service logic)}} |

{{Optional rule — keep if it applies: component Props are defined in the component file, only shared types are defined in the shared package's types/}}
