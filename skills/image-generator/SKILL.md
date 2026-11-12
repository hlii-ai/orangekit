---
name: image-generator
description: Creates raster images such as icons, logo drafts, illustrations, mockups, OG images, and hero art — with an API key it generates directly with gpt-image-2.5-flare, without one it can generate through a logged-in Codex CLI after asking, or produces a prompt to paste into ChatGPT. Use when a picture, thumbnail, cover image, or app icon is needed. Diagrams and charts go to diagram-design; design systems (color, fonts) go to /ui-ux-design.
---

# /image-generator — raster image generation

## Boundary — what is not made here

**This skill covers raster originals only.** Each of the following has a place that does it better,
and what that place produces can be edited, versioned and diffed, while a raster cannot.

| Request | Not here, but |
| --- | --- |
| Architecture, flow, sequence, ER, Gantt and other schematics | the `diagram-design` plugin |
| Charts, graphs, dashboards | `dataviz` (or render in code) |
| Design systems, color, typography, screen design | `ui-ux-design` |
| Capturing an existing screen | playwright (`ui-ux-design`'s `ui-probe.sh`) |
| **Extending a set** of logos or icons | continue the existing SVG system — drawing anew breaks the set |

**Simple shapes, rules and solid-color badges are made in CSS or SVG.** Sending them to a generative
model costs money, gives a different result every time and cannot be edited. Use this skill only for
**what code cannot make — photographs, textures, illustrations, mockups**.

## Step 0 — readiness ruling (3 states)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/image-gen.sh --probe
```

| Output | exit | Next |
| --- | --- | --- |
| `ready` | 0 | go to Step 1 (the API path is available) |
| `codex` | 0 | no key, but the Codex CLI is logged in — go to **Step 1b** (ask first) |
| `codex-login` | 2 | Codex CLI installed but not logged in — tell the user `! codex login` enables the Codex path, then continue in Step 4 handoff mode |
| `no-key` | 2 | **do not block** — go to Step 4, handoff mode |
| `unavailable` | 2 | python3 does not run (on Windows often the Store alias). Likewise, go to handoff mode |

**Do not read undecidable as failure.** Having no key is a normal state, and what to do then is not to
stop but **to hand over a prompt a person can use**.

## Step 1 — consent and billing notice (only when using the API path)

Read `assets.imageProvider` in `orangekit.config.json`.

- `"openai"` → consent already exists. Go to Step 2 without asking
- `"manual"` → the user chose to make it themselves. Go to **Step 4 handoff mode** without asking
- Absent or empty → **ask once.** Show the following verbatim with `AskUserQuestion`

> **The OpenAI Images API is billed separately from a ChatGPT subscription.** The subscription does
> not cover API usage at all; it is charged to the platform account per image.
> Estimates at 1024×1024: low about $0.006 · medium about $0.053 · high about $0.211
> (1536×1024 and 1024×1536 are cheaper at medium $0.041 · high $0.165.)

There are two options — "Generate via API (billed)" · "I'll make it myself (free)".
**Record the answer in `assets.imageProvider` in `orangekit.config.json`** (`openai` or `manual`).
Without recording it you ask every time, and a mechanism that asks every time gets turned off.

The key is **not stored.** Only the environment variable `OPENAI_API_KEY` is used — not `.env`, not
`orangekit.config.json`, not shell configuration (this harness's `security-check` hook blocks that).

## Step 1b — confirmation before the Codex CLI path (every request)

If `assets.imageProvider` is `"manual"`, the user chose to make images themselves — go to Step 4 without asking.
Otherwise **ask before every Codex generation** — this path runs on the user's own ChatGPT account, so it is their call
each time, not a setting. Ask once per request (one question covers every image in that request), with
`AskUserQuestion`, verbatim:

> **Generate this with the Codex CLI?** No API key is needed — it runs on your ChatGPT login and counts toward your
> plan's usage limits (it is not billed per image like the API). The prompt is sent to OpenAI.

Options: "Generate with Codex CLI" · "I'll make it myself (prompt only)". The second goes to Step 4.
Do not record this answer in the config — the next request asks again.

## Step 2 — writing the prompt (both paths share this)

**This step decides the result.** Whether it is sent to the API or pasted into ChatGPT by a person,
**the same prompt** is used — so there is one canonical source, and the only place the paths split is Step 3.

**Keep the order: scene and background → subject → detail → constraints.** In any other order the model
absorbs the subject into the background.

1. **Write the purpose first** — "web hero banner", "app store screenshot", "blog illustration".
   The purpose sets the finish and the composition. Leave it out and the model produces a generic stock image
2. **Make the subject concrete** — down to what percentage of the frame it occupies and where it is looking
3. **For realistic photography, write in camera language** — lens (35mm · 85mm), aperture, light direction, time of day
4. **If text appears, wrap it in exact quotation marks and specify the typeface family and position.**
   If the spelling is tricky, write it letter by letter and demand it be rendered exactly
5. **Gather the constraints at the end** — background color, margins, what not to include, what must not be cropped
6. **If the project has a design system, inject the tokens** —
   put the color hex values and typography direction from `dev/docs/design/<project>/MASTER.md` into the prompt verbatim.
   Without them the artifact sits awkwardly against the screen
7. **Do not lengthen an already detailed brief; only tidy it.** Padding it buries the user's intent

**Stop if you see a secret.** A key, token, internal URL or real customer data mixed into the prompt
goes straight outside. If you find one, do not proceed — tell the user.

**Write the prompt in English** — image models' training distribution is concentrated in English, so the
same instruction is reflected more accurately in English. Explain it to the user in the user's language.

## Step 3 — generation (the API path)

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/image-gen.sh \
  --prompt "<the prompt from Step 2>" \
  --out <save path> \
  --size 1024x1024 --quality medium --format png
```

- Dimension constraints: `a multiple of 16` · longest side 3840 max · aspect ratio within 3:1 · total pixels 655,360–8,294,400.
  **The script validates before the call**, so you are not billed for wrong dimensions
- Pull drafts at `--quality low` to check the direction, and re-pull only what is settled at `medium` or `high`.
  high is **35 times** low — not a value for the exploration stage
- For a long prompt use `--prompt-file <file>` (avoids shell quoting accidents)

**Verification is part of Step 3's single move.** The script checks file existence, non-zero bytes and
the format signature, and prints the response's `usage` **exactly as measured**. Pass those numbers to
the user — say "it cost this much", not "it would have cost about this much".

After generating, **compare the requested dimensions with the actual dimensions.** The model can
restructure the prompt and throw the ratio off. If it is off, tell the user and ask whether to re-pull — do not let it slide silently.

## Step 3b — generation through the Codex CLI (only after a yes in Step 1b)

Write the prompt from Step 2 to a file (quoting accidents again), then:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/image-gen.sh --codex --prompt-file <prompt file> --out <save path>.png
```

| exit | Meaning | Next |
| --- | --- | --- |
| 0 | the image came out of `$CODEX_HOME/generated_images/`, was copied to the save path and its signature checked | verify the dimensions (below) |
| 2 | this Codex CLI has no built-in `image_gen` in `codex exec`, or it is not logged in | say so plainly, then Step 4 handoff mode |
| 1 | Codex ran but produced no image, or timed out | report the reason; offer Step 4 |

`--size` · `--quality` · `--background` are API-only — Codex picks the rendering. **Put the dimensions and any
transparent background in the prompt itself**, and compare the result with what was asked, the same as Step 3.
The script refuses a file that did not appear in Codex's `generated_images` — a placeholder drawn with code is not
a generated image. Codex runs in a read-only sandbox; only the script writes to the project.

## Step 4 — handoff mode (no key, or the user makes it themselves)

**This is not a failure path but a regular path.** The job is not "it cannot be made" but
**to finish a prompt that, pasted into ChatGPT, produces exactly the image that was requested.**

Create `dev/docs/assets/<slug>.prompt.md`. Build it from four blocks:

```markdown
# <what is being made>

## Prompt to paste
<the prompt finished in Step 2 — as one block, with no commentary. This is the part that gets copied as is>

## Spec
| Item | Value |
| --- | --- |
| Dimensions | 1024x1024 |
| Format | PNG |
| Background | opaque white |
| Purpose | <where it is used> |

## Save path
`<the exact path in the project>` — please save it under this exact name.

## What to send next if you do not like it
- Simpler: "Simplify: remove <X>, keep <Y> unchanged."
- Change only the color: "Same image, change only the <part> color to <hex>."
- Change only the composition: "Same subject and style, reframe to <composition>."
```

**Do not drop the last block.** Getting what you want on the first try is rare, and when a person writes
a revision request off the cuff, the good parts of the previous result are blown away with it. Handing
them the sentence "change one thing at a time and keep the rest" in advance is what this file is worth.

Tell the user **where to put what**, too — paste the prompt into ChatGPT (or the Codex desktop app)
and put the image they get at the save path above.

When the file arrives, **verify the spec** — dimensions, format, non-zero bytes. The same bar as the automatic path.

## Limits — what is not promised

- **Transparent background**: `background=transparent` is valid per the API docs, but gpt-image-2.5-flare's
  actual alpha quality has not been verified in this repository. If you need a clean cutout, check the result by eye
- **Dimension determinism**: the model restructures the prompt, so the requested dimensions and the result can diverge
- **The Codex CLI path depends on the Codex version**: `image_gen` was absent from `codex exec` in codex 0.154.0
  (2026-09) and works in codex-cli 0.163.0 (measured 2026-11-08: a 1024×1024 request returned a 1254×1254 PNG in
  ~50 s). The script assumes neither — Codex answers `IMAGEGEN_UNAVAILABLE` when the tool is missing and the run
  ends as undecidable (exit 2), so the skill falls back to handoff instead of failing
- **Codex picks the output size**: the requested dimensions are a request, not a guarantee. When they differ,
  tell the user and offer a local resize (`sips -z H W <file>` on macOS) rather than another Codex run
