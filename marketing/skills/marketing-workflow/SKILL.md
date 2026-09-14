---
name: marketing-workflow
description: Orchestrates the marketing content pipeline — runs AI prompt generation → scroll-animation site building → SEO optimization in sequence and consolidates the output under dev/docs/marketing/. Use for "marketing campaign", "product landing page", "scroll-stop content", "marketing pipeline". Individual stages are /scroll-stop-prompter · /scroll-stop-builder · /seo-strategy. Manual invocation only.
disable-model-invocation: true
---

# Marketing Workflow Orchestrator

An orchestrator that runs the 3 stages of the marketing content pipeline in sequence and tracks progress.

**Pipeline**: scroll-stop-prompter → scroll-stop-builder → seo-strategy

Completely independent of the code workflow. Output is stored under `dev/docs/marketing/`.

## Workflow

### Step 1: Pick the pipeline mode

| request pattern                             | mode         | stages run    |
| ------------------------------------------- | ------------ | ------------- |
| full campaign / "build a marketing campaign" | full         | 1 → 2 → 3     |
| "prompts only" / "generate prompts"          | prompt-only  | 1             |
| "build a site from this video" / a video file supplied | build-only   | 2             |
| "SEO analysis" / "site audit"                | seo-only     | 3             |
| "prompts + site"                             | prompt-build | 1 → 2         |
| "site + SEO" / video + SEO requested          | build-seo    | 2 → 3         |

### Step 2: Initialize the campaign

1. Confirm the campaign name with the user
2. Create the `dev/docs/marketing/<campaign-name>/` directory
3. Secure the product marketing context (`context.md`)
4. Initialize `progress.md`

### Step 3: Run Stage 1 — prompt generation

Run the `/scroll-stop-prompter` skill workflow (pipeline mode). A USER GATE confirms with the user before moving to Stage 2.

### Step 4: Run Stage 2 — site building

Run the `/scroll-stop-builder` skill workflow. A USER GATE confirms with the user before moving to Stage 3.

### Step 5: Run Stage 3 — SEO optimization

Run the `/seo-strategy` skill workflow.

### Step 6: Complete the campaign

Once every active stage is done, generate a campaign summary.

## Handoff protocol

| Stage | output file  | key data                                   |
| ----- | ------------ | ------------------------------------------ |
| 1 → 2 | `prompts.md` | product name, description, style, AI model recommendation |
| 2 → 3 | `site.md`    | HTML path, section list, frame count, product specs |

## Reference documents

- Product marketing context: `dev/docs/marketing/context-<product>.md` — product name · audience · core value · tone · forbidden phrasing, in a single table
- Campaign summary: `dev/docs/marketing/campaign-<product>.md` — output paths per stage + a list of next actions
- Stage skills are invoked as slash commands — `/scroll-stop-prompter` · `/scroll-stop-builder` · `/seo-strategy`
  (all three are sibling skills in this plugin, so there is no need to write paths)
