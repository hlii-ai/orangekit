---
name: brainstorming
description: Use when the user wants to explore an idea, compare approaches, or design a feature before implementation — when what to build is still undecided. Helps turn vague ideas into concrete designs through collaborative dialogue. If what to build is settled and only the project context is missing, use /prompt-enhancer instead; this skill runs first and hands off to it. Not needed for bug fixes, simple config changes, or tasks with already-clear requirements.
---

# Brainstorming Ideas Into Designs

## Overview

Help turn ideas into fully formed designs and specs through natural collaborative dialogue.

Start by understanding the current project context, then ask questions one at a time to refine the idea. Once you understand what you're building, present the design and get user approval.

<HARD-GATE>
Do NOT write any code or take any implementation action until you have presented a design and the user has approved it.
</HARD-GATE>

## Checklist

Complete these items in order:

1. **Explore project context** — check files, docs, recent commits
2. **Ask clarifying questions** — one at a time, understand purpose/constraints/success criteria
3. **Propose 2-3 approaches** — with trade-offs and your recommendation
4. **Present design** — in sections scaled to their complexity, get user approval after each section
5. **Hand off to next Phase** — pass the brainstorming result to the next Phase of the CLAUDE.md workflow

## The Process

**Understanding the idea:**
- Check out the current project state first (files, docs, recent commits)
- **Record the original request**: record the user's first request verbatim (for the Before/After comparison)
- Ask questions one at a time to refine the idea
- Only one question per message - if a topic needs more exploration, break it into multiple questions
- Focus on understanding: purpose, constraints, success criteria

**Diagnosing ambiguity:**

Before asking anything, sort the ambiguity in the user's request into the six categories below, and ask about the ones that apply first:

| Category | Example ambiguity | Example hypothesis options |
|---------|-----------|-------------|
| Scope | Unclear who "users" are | All users / admins only / a specific role |
| Behavior | Failure behavior undefined | Fail silently / show an error / retry automatically |
| Interface | Transport undefined | REST API / GraphQL / WebSocket |
| Data | Data format undefined | JSON / CSV / both |
| Constraints | Performance requirement undefined | <100ms / <1s / no particular requirement |
| Priority | Importance unclear | Must-have (MVP) / nice-to-have (v1.1) / future (v2) |

**Hypotheses as Options:**

Offer concrete hypothesis options instead of open questions, to cut the user's cognitive load:
- **BAD**: "What authentication method do you want?" (the user has to invent the options)
- **GOOD**: "Pick an authentication method: (A) OAuth social login — fastest to implement / (B) Email+Password — full control / (C) Magic Link — no passwords"
- Include a one-line trade-off note on every option

**Exploring approaches:**
- Propose 2-3 different approaches with trade-offs
- Present options conversationally with your recommendation and reasoning
- Lead with your recommended option and explain why

**Presenting the design:**
- Once you believe you understand what you're building, present the design
- Scale each section to its complexity: a few sentences if straightforward, up to 200-300 words if nuanced
- Ask after each section whether it looks right so far
- Cover: architecture, components, data flow, error handling, testing
- Be ready to go back and clarify if something doesn't make sense

## Before/After Summary

Once the design is done and before handoff, produce a **before/after clarification table** and show it to the user.

## After the Design

After the design is approved, move to the next Phase:

| Invocation context | Hand off to |
|----------|----------|
| Inside the planning pipeline (via orangekit-planner) | Return the design summary to orangekit-planner → proceed to research |
| Standalone call — two or more entry conditions unmet | Prompt enhancement → PRD generation → dev docs generation |
| Standalone call — at most one entry condition unmet | Prompt enhancement → implementation |
| Standalone call — extending an existing feature | Hand off to dev docs generation |

### Saving the artifact on a standalone call

On a standalone call (`/brainstorming`), ask the user whether to save once the design is approved.

### Artifact when wired into the planning pipeline

When invoked via orangekit-planner, return the design result as a **structured summary**.

## Key Principles

- **One question at a time** - Don't overwhelm with multiple questions
- **Hypotheses as Options** - Offer concrete hypothesis options instead of open questions. One line of trade-off per option
- **Diagnose before asking** - Sort the ambiguity into categories (Scope/Behavior/Interface/Data/Constraints/Priority) before you ask
- **YAGNI ruthlessly** - Remove unnecessary features from all designs
- **Explore alternatives** - Always propose 2-3 approaches before settling
- **Incremental validation** - Present design, get approval before moving on
- **Before/After tracking** - Record the original request → produce the clarification comparison table when done
- **Be flexible** - Go back and clarify when something doesn't make sense
