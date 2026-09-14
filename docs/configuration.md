# Configuration Reference

## orangekit.config.json

The configuration file lives at the project root. All fields are optional except `project.name` and `techStack.preset`.

### project

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | (required) | Project name |
| `description` | string | | Project description |
| `language` | BCP-47 tag | `"en"` | Response language. `/orangekit-init` offers `ko` · `en` · `id` · `vi` plus free entry, so any tag is valid. Internal reasoning stays English; industry-standard technical terms (`Bottom Sheet`, `GNB`, `middleware`) stay English in every language |
| `languageLabel` | string | | Endonym shown in the T0 language directive (`한국어`, `Bahasa Indonesia`, `Tiếng Việt`). Falls back to `language` |
| `experienceLevel` | `"senior" \| "mid" \| "junior"` | `"senior"` | Affects response detail level |

### techStack

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `presets` | object | (required) | Two-axis selection: `{frontend, backend}`. See `docs/presets.md` |
| `preset` | string | | Legacy/compat notation `<frontend>+<backend>` |
| `frontend` | object | | Frontend axis: framework, language, packageManager, commands, sourceDir, additionalStack |
| `vcsPlatform` | string | | Code hosting: `github`, `gitlab`. Absent → detected from `git remote`, then asked. Splits issue/PR-MR commands only — not a guide-pack axis |
| `framework` | string | | Primary framework |
| `language` | string | | Primary language |
| `packageManager` | string | `"npm"` | Package manager: `npm`, `pnpm`, `yarn`, `bun`, `uv`, `pip` |
| `commands.build` | string | | Build command |
| `commands.test` | string | | Test command |
| `commands.lint` | string | | Lint command |
| `commands.sonar` | string | | SonarQube scanner command (optional). Read by `health-check` Step 5.5 via `build-parser.sh sonar`; needs `SONAR_HOST_URL` and `SONAR_TOKEN` in the environment — never in this file |
| `additionalStack` | string[] | `[]` | Additional technologies |

### domains

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `sourceDir` | string | `"src"` | Source code root directory |
| `sharedPackage` | string | | Shared package path (requires approval to modify) |
| `importAlias` | string | | Import alias (e.g., `@/`) |

### security — not configurable

Secret blocking is **built into the `security-check` hook**, not a config section. The hook
matches vendor-published key shapes (AWS `AKIA`, GitHub `ghp_`, Stripe, Toss Payments,
KakaoPay, OpenAI `sk-proj-`, Anthropic `sk-ant-`, Google `AIza`, Supabase, PEM private
keys, GCP service-account JSON) and blocks the write with exit 2.

Writing a secret into a `.env*` file that `git check-ignore` confirms is ignored is
**allowed** — that is where secrets belong. A `.env` file that is *not* ignored (e.g.
`.env.example`) is still blocked. See `docs/harness-anatomy.md` § `security-check`.

### Fields that do not exist

`workflow.p0.enabled` / `workflow.p6.enabled`, `customResources`, and `disabledSkills` were
documented in earlier versions but **no script, skill, or rule card ever read them** — setting
them changed nothing. They were removed from this reference, the schema, and the `orangekit-init`
template (evaluation v6 · E-30). Phase routing is decided by `.claude/rules/workflow-routing.md`;
to disable a skill, override it in `.claude/skills/` (see `docs/getting-started.md`).
`doctor --fast` now fails when this file documents a top-level field that nothing reads.

## Example Configuration

```json
{
  "project": {
    "name": "My SaaS App",
    "language": "ko",
    "experienceLevel": "senior"
  },
  "techStack": {
    "presets": { "frontend": "nextjs", "backend": "supabase" },
    "preset": "nextjs+supabase",
    "framework": "Next.js 15 (App Router)",
    "language": "TypeScript (strict mode)",
    "packageManager": "pnpm",
    "commands": {
      "build": "pnpm build",
      "test": "pnpm test",
      "lint": "pnpm lint"
    },
    "additionalStack": ["Tailwind CSS v4", "shadcn/ui", "Zustand", "Supabase"]
  },
  "domains": {
    "sourceDir": "src",
    "sharedPackage": "packages/shared",
    "importAlias": "@/"
  }
}
```
