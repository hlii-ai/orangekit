---
name: scroll-stop-prompter
description: Generates 3 kinds of AI image/video prompts (assembled, deconstructed, transition) per target model for turning product photos or footage into scroll-stop content, and emits an HTML preview. Use for "generate AI prompts", "product prompts", "scroll-stop prompts". Called as Stage 1 of marketing-workflow.
---

# Scroll-Stop Prompter

Generates 3 kinds of AI image/video prompts for producing a product's "scroll-stop" content and delivers them as an HTML preview page.

## Workflow

### Step 1: Determine the task type

| condition                                            | mode       | steps run         |
| ---------------------------------------------------- | ---------- | ----------------- |
| called from marketing-workflow (a campaign directory exists) | pipeline   | 2 → 3 → 4 → 5     |
| called on its own                                    | standalone | 2 → 3 → 4         |
| only one prompt type requested ("assembled only", "video only") | single     | 2 → 3 (that one only) → 4 |

### Step 2: User intake

Collect with AskUserQuestion: product name, product description, visual style, target AI model.

### Step 3: Generate the prompts

Generate 3 prompts: Prompt A (Assembled Shot), Prompt B (Deconstructed Shot), Prompt C (Video Transition).

For the detailed elements of each prompt and the per-model optimization mapping, see `references/prompt-guide.md`.

### Step 4: Generate the HTML preview page

Generate the HTML from the `assets/prompt-page-template.html` template.

### Step 5: Pipeline handoff (pipeline mode only)

Save `prompts.md` into the campaign directory.

## Prompt-writing principles

- **Concrete visual description**: "brushed aluminum with subtle anodized finish" instead of "sleek"
- **Lighting description required**: state the lighting setup in every prompt
- **Background consistency**: keep the background tone the same across all 3 prompts
- **Model-specific syntax**: follow each AI model's parameter format

## Reference documents

- Detailed prompt guide: [references/prompt-guide.md](references/prompt-guide.md)
- HTML preview template: [assets/prompt-page-template.html](assets/prompt-page-template.html)
- Pipeline integration: the marketing-workflow skill (calls this as Stage 1)
