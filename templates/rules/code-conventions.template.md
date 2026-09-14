<!-- orangekit-doctor: allow-stale-refs -->
<!--
  Generation skeleton for the project-specific code-conventions card.
  orangekit-init Step 7.5 keeps only the stack block that matches the preset, removes the rest,
  and saves the result as `code-conventions.md` under the project's `.claude/rules/`.

  Principles:
  - Project-owned file — do not add an orangekit-rule-version stamp
  - Blocks marked "common" (general naming·code style·commit messages) stay in every preset
  - If project-specific conventions already exist (an existing CLAUDE.md·lint config), confirm with the user and fold them in
  - Remove this comment block and every {{guidance}} placeholder at generation time
  - Field-tested source: conventions proven while building an app service
-->
---
paths:
  - "{{SOURCE_DIR}}/**"
  # Paths the topology requires **must** go here (orangekit-init Step 7.5 item 5 verifies it):
  #   monorepo → shared package paths (e.g. "packages/**")
  #   msa      → service roots        (e.g. "services/**", "apps/**")
  # Leave one out and this card will not load when that path is edited.
---

# Coding Conventions

## Core Principles

<!-- Stack block [nextjs-supabase / react family] — TypeScript+React proven version -->
- **No any** — use unknown or a concrete type
- **Server components first** — `"use client"` only when needed (Next.js only)
- **Import**: the `{{IMPORT_ALIAS}}` alias is required (no relative paths)
- **Function components**: declare with the `function` keyword (preferred over arrow functions)
- Comply with TypeScript strict mode

<!-- Stack block [python-fastapi] -->
- Type hints required — must pass mypy (or pyright) strict
- Validate every input and output with Pydantic v2 models
- Routers only route — business logic is separated into the service layer
- Format/lint: ruff (PEP 8 compliant)

<!-- Stack block [blank] — fill in once the stack is settled. Do not leave it empty; update it the moment it is settled -->

## Naming Rules (common — adjust only the examples to the stack)

| Target                 | Rule                                     | Example                          |
| ---------------------- | ---------------------------------------- | -------------------------------- |
| Component/class files  | PascalCase                               | `ProductCard`, `OrderService`    |
| Function/variable/util/hook files | camelCase                     | `formatPrice`, `useCart.ts`      |
| Constants              | UPPER_SNAKE_CASE                         | `MAX_RETRIES`, `API_BASE_URL`    |
| DB naming              | snake_case · plural tables · `_at` suffix | Details: `.claude/rules/data-modeling.md` (T1 card — loads automatically when a DB path is edited) |
| Types/interfaces       | PascalCase + suffix                      | `OrderResponse`, `UserProfile`   |
| State stores           | use~Store                                | `useAuthStore`                   |

## Code Style (common)

- Define Props/schema types in the same file as the component·module that uses them
- No magic numbers → define them as named constants
- Error handling: catch at the boundary (handler/Error Boundary) and expose only a friendly message to the user

## Commit Messages (common)

- Write in **{{commit language — default: English}}**, format: `tag: description`
- The 8 Conventional Commits types:
  `feat:` new feature | `fix:` bug fix | `refactor:` refactoring | `style:` style/UI |
  `chore:` config/build | `docs:` docs | `test:` tests | `perf:` performance
- Example: `feat: add order creation page`
