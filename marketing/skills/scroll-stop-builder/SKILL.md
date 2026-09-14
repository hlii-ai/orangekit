---
name: scroll-stop-builder
description: Builds an Apple-style scroll-driven animation website from a video file — FFmpeg frame extraction + Canvas rendering, with 13 optional sections to combine. Use for "scroll-stop site", "scroll animation website", "video scroll site", "Apple-style scroll". Called as Stage 2 of marketing-workflow.
---

# Scroll-Stop Builder

Video file → frame extraction → a Canvas scroll-animation website.

The same technique as Apple's product pages: frames of a sequence are drawn onto a Canvas and mapped to scroll position.

## Prerequisites

- FFmpeg must be installed (`brew install ffmpeg`)
- Video 3–10 seconds, first frame must be a white background
- A local server is required (frames cannot load from `file://`)

## Workflow

### Step 1: Determine the task type

| condition | mode | steps run |
|------|------|----------|
| called from marketing-workflow (prompts.md exists) | pipeline | 2 (partial) → 3 → 4 → 5 → 6 → 7 |
| called on its own + a URL supplied | standalone-url | 2 → 3 → 4 → 5 → 6 |
| called on its own + content supplied directly | standalone-manual | 2 → 3 → 4 → 5 → 6 |

### Step 2: User interview

Collect the brand/product name, logo, accent color, background color, and mood/vibe. Confirm the section toggles.

### Step 3: Analyze the video and extract frames

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/extract-frames.sh   # ${CLAUDE_SKILL_DIR} = the Base directory shown when the skill loads "<VIDEO_PATH>" "<OUTPUT_DIR>" [TARGET_FPS]
```

### Step 4: Generate the HTML site

Generate it as a single HTML file. For each section's implementation, see `references/sections-guide.md`.

### Step 5: Apply the design system

Compose fonts, colors, card styles, buttons, and effects from the interview results.

### Step 6: Apply the content and serve

```bash
cd "<OUTPUT_DIR>" && python3 -m http.server 8080
```

### Step 7: Pipeline handoff (pipeline mode only)

Save `site.md` into the campaign directory.

## Reference documents

- Section implementation guide: [references/sections-guide.md](references/sections-guide.md) (~250 lines, HTML/CSS/JS for each of the 13 sections)
- HTML scaffold: [assets/html-template.html](assets/html-template.html)
- Frame extraction script: [scripts/extract-frames.sh](scripts/extract-frames.sh)
- Pipeline integration: the marketing-workflow skill (calls this as Stage 2)
