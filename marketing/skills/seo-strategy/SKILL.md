---
name: seo-strategy
description: 3-mode SEO analysis — page optimization (keywords · LSI · meta · structured data) · full site audit · AI search optimization. The result is an interactive HTML report. Use for "SEO analysis", "SEO optimization", "site audit", "keyword analysis", "meta tags", "AI SEO", "LLM optimization". Called as Stage 3 of marketing-workflow.
---

# SEO Strategy

3-mode SEO analysis and optimization. Produces an interactive HTML report.

## Workflow

### Step 1: Pick the mode

| condition | mode | steps run |
|------|------|----------|
| a request to optimize an article, blog post, or single page | Mode 1 (Article) | 2A → 3A → 4 |
| a request to audit a whole site or a URL | Mode 2 (Audit) | 2B → 3B → 4 |
| "AI SEO", "AI search optimization", "LLM optimization" | Mode 3 (AI SEO) | 2C → 3C → 4 |
| called from marketing-workflow (site.md exists) | Mode 2 (pipeline) | 2B (automatic) → 3B → 4 |

### Steps 2A-2C: Per-mode intake

Collect the information each mode needs. `context.md` under `dev/docs/marketing/` is loaded automatically.

### Step 3A: Article SEO analysis (Mode 1)

Scoring follows `references/scoring-criteria.md`. Keyword analysis, LSI keywords, on-page SEO, content quality, structured data, meta tag generation, buyer-stage mapping.

### Step 3B: Site audit analysis (Mode 2)

Scoring follows `references/scoring-criteria.md` + `references/technical-seo-checklist.md`. Audits 6 categories: Technical SEO (25%), On-Page (25%), Content (20%), Performance (15%), Mobile (10%), Accessibility (5%).

### Step 3C: AI SEO analysis (Mode 3)

Scoring follows `references/ai-seo-guide.md`. Evaluates 3 pillars: Structure (40%), Authority (35%), Presence (25%).

### Step 4: Deliver the report and hand off

Open the HTML report through a local server. Summarize the 3–5 key findings + a list of action items.

## Next.js App Router SEO

Additional checks and recommendations when the project is Next.js based. Details: `references/nextjs-seo-guide.md`

## Reference documents — read each only at its moment

| file | when to read it |
| --- | --- |
| [references/scoring-criteria.md](references/scoring-criteria.md) | at Step 4, when computing the score |
| [references/technical-seo-checklist.md](references/technical-seo-checklist.md) | only in Mode 2 (site audit) |
| [references/nextjs-seo-guide.md](references/nextjs-seo-guide.md) | only when the target is a Next.js project |
| [references/ai-seo-guide.md](references/ai-seo-guide.md) | only in Mode 3 (AI SEO) |

Pipeline integration: the marketing-workflow skill (calls this as Stage 3)
