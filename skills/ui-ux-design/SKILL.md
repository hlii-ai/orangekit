---
name: ui-ux-design
description: "UI/UX design intelligence — generates a design system from UI styles, color palettes, font pairings, industry-specific reasoning and chart types. Use for UI/UX design, screen design, design systems, choosing color/typography/style, landing pages, dashboard layouts, component styling, and building new pages or screens."
---

# UI/UX Design Intelligence

A design intelligence skill built on a BM25 search engine. Generates an optimal design system from industry-specific reasoning rules and a CSV database.

> `${CLAUDE_SKILL_DIR}` in the commands below is **substituted by Claude Code** — do not fill the path in by hand.
> (Hardcoding a project override path fails in a plugin-only install)

**Source**: [nextlevelbuilder/ui-ux-pro-max-skill](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) v2.2.1

## Search domains

| Domain | Data | Use |
|--------|--------|------|
| `product` | products.csv (100+) | UI patterns by product category |
| `style` | styles.csv (67) | visual style recommendations |
| `color` | colors.csv (96) | color palettes |
| `typography` | typography.csv (57) | font pairings |
| `landing` | landing.csv | landing page patterns |
| `chart` | charts.csv (25) | data visualization |
| `ux` | ux-guidelines.csv (99) | UX best practices |
| `react` | react-performance.csv | React performance optimization |
| `web` | web-interface.csv | web interface patterns |
| `icons` | icons.csv | icon library recommendations |

## Workflow

### Step 1: Identify the task type

Identify the task type from the user's request and branch to the matching Step:

| Task type | Identifying condition | Steps to run |
|----------|----------|----------|
| Design system generation | new project, full style guide, design renewal | Step 2 → 2.5 → **2.6 → 2.7** → 3 → 4 → 5 |
| Per-page design | designing a specific page/screen | Step 2 (page mode) → 2.5 → **2.6 → 2.7** → 3 → 5 |
| Domain search | only need information on one area (color, typography, style, etc.) | Step 3 |
| Stack guidelines | need a framework-specific implementation guide | Step 4 |

Information to extract from the requirements — if `dev/docs/service/service-plan-<name>.md` exists,
**read the screen list and user flows from there** (the P0-D artifact). Otherwise pull them from the user's request:
- **Product type**: e-commerce, SaaS, etc. (default: E-commerce)
- **Style keywords**: minimal, modern, glassmorphism, etc.
- **Industry/domain**: e-commerce, community, services, etc.
- **Stack**: nextjs, shadcn, react, html-tailwind (default: nextjs + shadcn)

### Step 2: Generate the design system

Pass the project name to the `-p` option (e.g. `-p "MyProject"`).

Full design system:

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<product type> <industry> <keywords>" --design-system -p "<project name>" -f markdown
```

persist mode (for ongoing reference):

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<query>" --design-system --persist -p "<project name>" -o dev/docs/design
```

Per-page override:

```bash
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<query>" --design-system --persist -p "<project name>" -o dev/docs/design --page "<page name>"
```

Output structure:
```
dev/docs/design/<project-slug>/
├── MASTER.md          # the full design system
└── pages/
    └── <page>.md      # per-page overrides
```

### Step 2.5: Direction review (the gate before writing code)

Do not move the generated result straight into code. Put it through the review in `.claude/rules/ui-design.md`:

- **Did it land on one of the 3 default clusters** (cream+serif+terracotta / near-black+acid accent / ruled multi-column) —
  if the brief did not specify it and it landed there anyway, that is a default, not a choice
- Is the **signature element** named — the one thing this screen will be remembered for
- **Does a similar brief produce the same answer** — if so, fix it and state what was changed and why

A search score is keyword match, not fitness to the brief. **Being ranked first is not a basis.**
If you saved with `--persist`, fill in the `## Signature` and `## Direction review` fields of `MASTER.md`.

Do not write code toward a direction that did not pass the review.

### Step 2.6: Draft canvas — invoked by default

If Step 2.5 passed and **there is at least one new or redesigned screen, make a canvas.** It is the
default, not an option — it is where the direction is agreed before code, and deferring it to P4 means
the argument happens in the most expensive place.

**There are only two cases for skipping**: ⓐ `/design` is unavailable or saving is disabled —
**that is undecidable, not a defect**, go to Step 4 without a canvas ⓑ the user explicitly declines.
Neither of them blocks implementation.

**Invoke it only after Step 2.5.** `/design` does not know the 3-default-cluster calibration in
`.claude/rules/ui-design.md` §1 — give it only the brief and out come exactly the cream+serif,
near-black+acid accent and ruled multi-column the review meant to stop. Pass the tokens **pinned to settled values**:

```
/design <project> N screens — <screen1> · <screen2> · <screen3>

Pinned tokens (do not invent new ones) — carried over from MASTER.md:
- Color: <4–6 named hex values>
- Type: display <font> / body <font>
- Layout: <the one sentence from pass 1>
- Signature: <the single one named in §2> — spend the boldness only here and keep the rest quiet
Spec: <390x844, etc.>
Use real copy (no lorem). Include empty, loading and error states as artboards too.
```

The last line **pulls the "3 states" of Step 6 forward, ahead of implementation** — right now those
three are only discovered at the render proof.

The user edits the canvas directly and saves. **What they fixed by hand is the final design decision.**

### Step 2.7: Write-back + comparison

Do this immediately after the canvas is settled. A decision that lives only in the canvas can be
neither grepped nor diffed, and so does not exist in the next session.

1. Read the published Artifact and take it down as local HTML.
2. Update four places in `dev/docs/design/<project>/MASTER.md`:

| What to update | With what |
|----------|--------|
| `### Color Palette` · `### Typography` | the hex values and fonts changed in the canvas |
| `## Signature` | a new naming if the signature changed |
| `## Direction review` | one line on what was changed and why |
| `## Canvas` **(create it if absent)** | canvas URL · date settled · artboard list |

The `## Canvas` section is **the only path by which the next session finds the screen composition**.
Without this section the canvas is ruled not to exist (the script below reads it that way).

3. Compare — **exit 0 is this Step's termination predicate**:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/design-sync.sh --master dev/docs/design/<project>/MASTER.md --canvas <downloaded.html>
```

| Exit code | Meaning | Action |
|----------|-----|------|
| 0 | colors and fonts match | compare only the signature by eye and move to the next Step |
| 1 | mismatch | **the write-back is not finished.** Report the diff to the user and take their judgement — do not block |
| 2 | undecidable | if "no canvas used", proceed as is · if "declared but unreachable", report that fact |

The script looks at colors and fonts, and **a person looks at the signature** — it is prose, so set operations are impossible.
Do not write that you confirmed by eye something that could have been measured.

**If Step 2.6 was skipped, skip Step 2.7 too** — there is nothing to write back. Instead go to Step 4
with one layout item from direction review pass 1 left per screen.

### Step 3: Supplementary search by domain

When detailed information on a specific area is needed:

```bash
# Style search
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "modern e-commerce card" --domain style

# Color palette
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "trust marketplace" --domain color

# UX guidelines
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "group buying flow" --domain ux

# Chart recommendations
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "progress tracker" --domain chart

# Font pairing
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "modern clean korean" --domain typography
```

### Step 4: Apply the stack guidelines

> The stack guidelines support **only 4**: `nextjs` · `shadcn` · `react` · `html-tailwind`.
> For any other stack (Vue, Svelte, vanilla, etc.) skip this Step and use only Steps 1–3 —
> style, palette, typography and UX rules are stack-invariant and remain valid as they are.

```bash
# Next.js specific guidelines
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<query>" --stack nextjs

# shadcn/ui specific guidelines
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<query>" --stack shadcn

# Tailwind CSS guidelines
python3 ${CLAUDE_SKILL_DIR}/scripts/search.py "<query>" --stack html-tailwind
```

### Step 5: Linking to the frontend guidelines

Implementation **reads two documents** — jurisdiction is split, so reading only one loses the other:

| What you read | Where |
|---------|--------|
| Color · font · spacing · shadow · signature · anti-patterns | `MASTER.md` |
| Element placement · hierarchy · real copy · what empty/loading/error look like | **the canvas** (pointed to by `## Canvas`) |

If there is no `## Canvas` section, there is no canvas, and `MASTER.md` (+ `pages/`) is the only
canonical source, composition included — do not go hunting for a canvas.

The canonical source for stack practice (component boundaries, class merging, file placement) is the
project's `frontend-guide` skill. Example (the Next.js combination):
- Server/Client Component separation
- Component declarations with the `function` keyword
- The `cn()` utility + Tailwind CSS styling
- Use of shadcn/ui components
- The `@/` path alias

### Step 6: Render proof (after the code is written)

If Step 2.5 is the gate **before writing**, this is the gate **after writing**. Passing a typecheck is
not evidence that a screen appears — the canonical source for the ruling norms is `.claude/rules/ui-design.md` §6.

**Prior install (once, if this project does not have it yet)** — the plugin does not install Playwright
automatically (so that a Chromium download is not forced on every consumer project).
Run the following at the project root as it is:

```bash
npm i -D playwright && npx playwright install chromium
```

With pnpm/yarn:

```bash
pnpm add -D playwright && pnpm exec playwright install chromium
# or
yarn add -D playwright && yarn playwright install chromium
```

Bring the server up with the built-in `/run` (this skill does not manage servers). Point the probe at that URL:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/ui-probe.sh --url http://localhost:3000 --ready "main"
```

Give `--ready` a selector that means rendering is complete — **visibility-based waiting is the most reliable.**
If you need to find a selector, widen the inventory with `--recon` (the default is 8 per kind, to save context).
A console error, uncaught exception or failed request means exit 1. Quality measurements are WARN and
do not raise the exit code. No browser means exit 2 — **undecidable, not a pass.**

## Quality checklist (Pre-Delivery)

The items `ui-probe` measures in Step 6 are marked *(measured)* — a person looks at the rest.
**Do not write that you confirmed by eye something that could have been measured.**

- [ ] Text contrast ratio 4.5:1 or higher *(measured)*
- [ ] Touch targets at least 44x44px *(measured · mobile viewport)*
- [ ] Hover state must not shift the layout
- [ ] cursor-pointer on interactive elements *(measured)*
- [ ] SVG icons used (no emoji)
- [ ] Mobile-first responsive (min 16px body text) *(measured · body median)*
- [ ] Keyboard navigation possible
- [ ] prefers-reduced-motion checked *(measured)*

## Reference documents

- Quick reference: [references/quick-reference.md](references/quick-reference.md)
- Frontend guidelines: `.claude/skills/frontend-guide/SKILL.md` (generated per stack)
- Design judgement norms: `.claude/rules/ui-design.md` (auto-loaded when editing UI files) — §6 is the canonical source for the render proof
- Render probe: [scripts/ui-probe.sh](scripts/ui-probe.sh) (`--help` for usage)
- Token comparison: [scripts/design-sync.sh](scripts/design-sync.sh) (`--help` for usage)
- Design output: `dev/docs/design/`

## Project custom resources

> If `.md` files exist at the paths below, they are referenced automatically when the design system is generated. If the files do not exist, this section is ignored.

| Category | Path | Use in this skill |
|---------|------|-------------------|
| Design principles | `.claude/resources/design-principles/` | applying brand guides and design principles to UI/UX decisions |
| Domain knowledge | `.claude/resources/domain-knowledge/` | reflecting domain-specific UX patterns and industry-specific design rules |
