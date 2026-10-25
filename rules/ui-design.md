---
paths:
  - "**/components/**"
  - "**/*.{css,scss}"
  - "**/app/**/page.{tsx,jsx}"
  - "**/app/**/layout.{tsx,jsx}"
---
<!-- orangekit-rule-version: 3.36.0 -->
<!--
  Why paths was narrowed. `**/*.{tsx,jsx,vue,svelte}` is **nearly every frontend file**
  in React·Next, so this card came in on every edit, including ones with nothing to do with deciding
  direction. What this card keeps is "the step that asks whether the choice is specific to this brief",
  and that step is needed in three places — ⓐ components ⓑ stylesheets ⓒ **screen-level files** (`page`·`layout`).
  ⓒ was missed in the first narrowing and an independent pre-release review caught it: the card never
  appeared when `app/dashboard/page.tsx` was redesigned with Edit. The hook's UI-review summons looks only at
  `Write` + a **new** file, so it cannot cover that spot — redesigning an existing screen is exactly where
  direction gets decided. Greenfield (a brand-new first screen) is the spot paths, which matches at read time,
  never covered, and there the hook's summons (Write + new + a UI extension) covers precisely. Together the two
  keep the reach, and only the blanket load of every ordinary component·utility tsx whose direction is already settled was dropped.
-->

# UI Design Judgement Card

Loaded when you build UI or decide a visual direction. It does not carry design common sense —
only **the step that asks whether the choice is specific to this brief** stays. Without that step,
whatever search ranked first becomes the result.

Boundaries: **picking** a style·palette·font **out of data** is the `ui-ux-design` skill,
**framework practice** (the Server/Client boundary·class merging·file placement) is the existing code and `stack-frontend-*.md` (`frontend-guide` if the detailed guide is installed),
and this card handles the **judgement** — before writing, §1~§5 (is that choice specific to this brief),
after writing, §6 (did it come out as planned).

## 1. Default Calibration

The designs AI produces today converge on three clusters. The proof is that they appear whatever the brief says.

| Cluster | Form |
| --- | --- |
| ⓐ | cream background (around `#F4F1EA`) + a high-contrast serif display face + a terracotta accent |
| ⓑ | near-black background + an acid green/vermilion **single-color** accent |
| ⓒ | hairline rules + zero corner radius + newspaper-style multi-column |

**This is not a ban but a check on provenance.**

- If the brief named this direction, **follow it as given.** What the brief says always wins.
- If the brief left that axis blank and the result landed on one of these three, that is a default, not a choice.
  Do not spend that axis's freedom on a default.

**That search recommended it is not evidence.** The `ui-ux-design` data **ships these three as recommended styles** —
`Nature Distilled` (terracotta + soft cream) in `styles.csv` is ⓐ, `Editorial Grid` (drop caps·serif body) is ⓒ,
and `Dark Mode (OLED)`·`Cyberpunk UI` are ⓑ. A BM25 score is **keyword overlap**, not fitness to the brief.
"Because it ranked first in search" is not a justification.

What you draw from the subject's own world beats a default — that field's materials·tools·outputs·idiom are the source of concrete choices.

## 2. The Signature Element

Name the **one thing** this screen will be remembered for. Spend boldness only there and keep the rest quiet.

- With no signature, that screen is a well-made template
- Boldness scattered across several places means none of it is remembered
- Strip ornament that does not serve the brief. **Take one thing away at the end**
- Taking no risk is itself a risk — a pile of safe choices is exactly what a default is

## 3. The Two-Pass Review (before writing code)

**Pass 1 — the token plan.** Settle four things first.

| Item | Form |
| --- | --- |
| Color | 4~6 named hex values |
| Type | Two or more roles — a distinctive display face used sparingly + body. A utility face for captions·figures if needed |
| Layout | A canvas draft (`ui-ux-design` Step 2.6) by default. Without a canvas, **one line per screen**; an ASCII wireframe when a comparison is needed — either way, do not write code with this item left empty |
| Signature | That one thing from §2 |

**Pass 2 — the review.** Check the plan against the brief.

> **Would a similar brief arrive at the same answer?**

If so, that part is your default rather than this brief's choice. Fix it, and **state in one line what you changed and why.**
A pass with no statement is not a review.

**Write code only after it passes.** Derive every color·type decision from the plan — do not invent a new color while writing code.

Use structural devices (numbers·eyebrows·rules·labels) **only when they encode something true** about the content.
`01 / 02 / 03` is right only when the content really is a sequence — if the order is not information, it is ornament.

Match complexity to the direction. Maximalism demands elaborate execution; minimalism demands precision in spacing·type·detail.

## 4. UX Writing

Copy is not ornament but **design material**. Write it with the same degree of intent as spacing·color.
Ask before writing — what must this screen say, and how must it say it for a person to find their way.

| Rule | Example |
| --- | --- |
| Call it by the name the user operates and recognizes — not the system's implementation term | "Notifications" ○ / "Webhook settings" ✗ |
| Active voice. A control says exactly what happens when it is pressed | "Save changes" ○ / "Submit" ✗ |
| One action keeps the same name across the whole flow | a "Publish" button → a "Published" toast |
| Write what it does, not what it sells. Specificity over cleverness | "Export to PDF" ○ / "Experience the magic" ✗ |

- **Errors do not apologize.** Say what happened and how to fix it. In the interface's voice,
  not a person's. Do not leave a vague failure message behind
- **An empty screen is an invitation, not a mood.** Offer the first action
- One element does one job — a label labels, an example exemplifies. Do not quietly make one moonlight as the other
- Sentence case, no padding. Match the tone to the brand and the user

## 5. Record the Review Result

If you generated a design system with the `ui-ux-design` skill, fill in the `## Signature` and
`## Direction review` fields of the artifact (`dev/docs/design/<project>/MASTER.md`).
Leave them empty and the next session runs the same review from scratch.

**If you made a canvas draft, jurisdiction splits** — it does not create two copies.

| | Jurisdiction | Drift |
| --- | --- | --- |
| `MASTER.md` | tokens (color·font·spacing·shadow) · signature · direction review · anti-patterns | — |
| Canvas | element placement · hierarchy · the actual copy · what empty/loading/error look like | — |
| **The overlapping three** | color · font · signature | **this is the only place they diverge** |

- **Write-back**: what the user fixed by hand is the final decision. Right after the canvas is finalized, update the three fields above and
  `## Canvas` (URL·date finalized). A decision that stays only on the canvas does not exist in the next session
- **Reading**: when implementing, read tokens from `MASTER.md`, and placement·hierarchy·copy·the three states from the canvas.
  The entry point is the `## Canvas` section of `MASTER.md`, and **if that section is missing, there is no canvas** —
  then `MASTER.md` (+`pages/`) is the only canonical source, composition included
- **A mismatch among the overlapping three is a defect, not something tolerated.** Do not cover it with "trust the canonical source"; report it
  as a diff — color·font are compared by `design-sync.sh` in `ui-ux-design`, the signature by a person

## 6. Render Proof (after writing code)

A passing build is not proof that a screen appears. `tsc` passes a blank screen and a screen whose console is exploding alike.

**Scout, then act** — do not guess selectors. Operate **only after finding them** in the rendered state.

**Waiting discipline** (in the order people get it wrong)

| Rank | Method | Note |
| --- | --- | --- |
| 1 | Visibility-based — until that element is visible | The only one that can be trusted |
| ✗ | A fixed-time wait | The main cause of flakiness. Do not use it |
| Last resort | `networkidle` | Playwright discourages it — with polling·SSE·websockets it never finishes |

**Three proofs** — ⓐ render screenshots (mobile·desktop) ⓑ **zero console errors·uncaught exceptions·failed requests**
ⓒ is the signature from §2 actually present on screen. Only all three together amount to "verified".

**Actually render the three states** — empty·loading·error. Looking only at the success path is looking at half.

**Undecidable is not a defect** — if there is no browser or the server cannot be brought up, **write that fact down.**
Do not write "verified". The Playwright install command is in Step 6 of the `ui-ux-design` skill
(the plugin does not install it automatically — only the projects that need it install it explicitly).

Execution is Step 6 of the `ui-ux-design` skill — bring it up with the built-in `/run` and point `ui-probe` at that URL.

---

*§1~§4 are adapted from Anthropic's `frontend-design` skill (Apache-2.0, `anthropics/skills`), and
§6 from the `webapp-testing` skill — the waiting discipline was inverted to match what was measured.*
