# Getting Started

## Quick Start

> 🪟 **On Windows?** Read this before installing — [`docs/windows-setup.md`](windows-setup.md).
> This plugin's hooks are registered as `"bash <script>"` commands. Without **Git for
> Windows** (Git Bash), they silently do nothing — no error, no warning (WSL users are
> unaffected). The guide is a beginner-friendly, step-by-step walkthrough.

### 1. Install the Plugin

```bash
claude plugin marketplace add hlii-ai/orangekit
claude plugin install orangekit-product@orangekit
```

The first line tells Claude Code where to look, and you only ever run it once per machine. The
second installs the harness itself.

> The marketplace reads `origin/main`, where the latest tagged release is merged (the current version is the README badge). To install from a
> local clone instead — for development, or to try an unreleased change:
>
> ```bash
> claude plugin marketplace add <path to this repo>
> ```

### 2. Initialize Your Project

Start Claude Code in your project directory, then run:

```
/orangekit-init
```

This will interactively:
- Ask what you are building first — web / hybrid app / native / API-only. This is a product question, not a technical one, and it narrows every question that follows
- Ask you to choose a frontend preset (nextjs / react-vite / vue / vanilla / none) and a backend preset (supabase / firebase / aws-serverless / aws-container / gcp-serverless / fastapi / node-api / node-nest / none)
- Collect project information
- Generate `orangekit.config.json` and `CLAUDE.md`
- Install rule cards into `.claude/rules/`
- Create the `dev/` directory structure

### 3. Start Working

```bash
claude
```

The plugin automatically:
- Loads your project context via SessionStart hook
- Blocks hardcoded secrets before they are written
- Blocks stopping when source changed but build/test never ran
- Routes work by reversibility class (Reversible / Costly / Irreversible)

**Three things block; everything else only tells you.** The blocks are hardcoded secrets,
irreversible commands (destructive DDL, force-push to a shared branch), and stopping without a
build. Each message names the next action — read it before looking for a workaround. Anything
phrased as *"cannot determine…"* is a notice, not a block: the harness never folds *undecidable*
into *blocked*, because a false block teaches you to switch the hook off.

## Proving the Screen Renders

`tsc` passes an empty page, and a page whose console is on fire. So after a UI change the harness
says so once per session — it does not block — and the proof itself lives in the `ui-ux-design`
skill:

```bash
npm i -D playwright && npx playwright install chromium   # once, only if the project has a UI
```

Start the app with the built-in `/run`, then point the probe at that URL. It reports console
errors, uncaught exceptions and failed requests (these fail it, exit 1), plus contrast, touch
targets, body size and reduced-motion as warnings that never fail. Screenshots land in
`.claude/.orangekit/ui-probe/`. Missing browser means exit 2 — *undecidable*, not *passed*.

The plugin does not install Playwright for you: a ~94 MB browser has no business in an API-only
project. See `rules/ui-design.md` §6 for the waiting discipline (visibility-based selectors beat
fixed sleeps; `networkidle` is a last resort).

## Zero-Config Mode

The plugin works without `orangekit.config.json` — the five hooks and the reversibility-class workflow are always active. Adding a config enables:
- Project-specific secret patterns
- Build/test command awareness (`build-gate` names the exact command)

## Available Presets

Presets are chosen on two axes — pick one from each.

| Frontend | Stack |
|----------|-------|
| `nextjs` | Next.js 15 App Router + React 19 + Tailwind v4 + shadcn/ui + Zustand |
| `react-vite` | React + Vite SPA + Tailwind + React Router + TanStack Query + Zustand |
| `vue` | Vue 3 Composition API + Vite SPA + Tailwind + Vue Router + Pinia |
| `vanilla` | No framework — standard DOM + ES modules (Vite bundle) |
| `none` | API-only project |

| Backend | Stack |
|---------|-------|
| `supabase` | PostgreSQL + RLS + Auth + Storage + Realtime (BaaS) |
| `firebase` | Firestore + Auth + Storage + Cloud Functions (BaaS) |
| `aws-serverless` | Lambda + API Gateway + DynamoDB + Cognito |
| `aws-container` | ECS/Fargate + ALB + RDS PostgreSQL + Drizzle + Cognito (portable to on-prem) |
| `gcp-serverless` | Cloud Run/Functions + Firestore + Identity Platform |
| `fastapi` | **Python** · FastAPI + SQLAlchemy 2.0 + Pydantic v2 + Alembic (self-hosted) |
| `node-api` | Express 5 + PostgreSQL + Prisma (self-hosted) |
| `node-nest` | NestJS 11 + PostgreSQL + TypeORM 1 + class-validator (self-hosted) |
| `none` | No backend / external REST API |

The **combination** decides the guides. Three combinations ship pre-built guides —
`nextjs` × `supabase`, `react-vite` × `aws-container` and `vue` × `node-api` — and every
other combination generates project-owned guides. The system picks without asking.
See `docs/presets.md`.

## Project Override

Plugin skills live in the `orangekit-product:` namespace and project skills in `.claude/skills/`
**coexist** with them — a same-name copy does not shadow the plugin skill. To take precedence,
give your skill a different name and state the boundary in its `description`:

```bash
# Example: your own brainstorming flow
mkdir -p .claude/skills/my-brainstorming
# In its SKILL.md description: "prefer this skill for brainstorming"
```

Rule cards in `.claude/rules/` are project-owned: edit them freely, `install-rules.sh` keeps a
user-modified card and reports the drift instead of overwriting it. Never edit plugin files —
updates overwrite them. The canonical statement of these rules is `README.md` "Project Override".

## Next Steps

- [Configuration Reference](configuration.md) — Full `orangekit.config.json` options
- [Presets Guide](presets.md) — Detailed preset documentation
- Upgrading from v2? Run `/orangekit-migrate`
