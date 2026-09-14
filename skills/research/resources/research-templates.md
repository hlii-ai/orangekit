# Research document templates

The output document structure for each research type. Referenced from Step 5 of SKILL.md.

---

## Shared header (all types)

```markdown
# Research: [topic]

**Date**: [YYYY.MM.DD]
**Data sources**: WebSearch + [name any material the user supplied]
**Confidence**: [high/medium/low] — [rationale]

---
```

## Shared footer (all types)

```markdown
---

## Data sources

| Information | Source | Accessed | Confidence |
|------|------|--------|--------|
| [item] | [URL] | [YYYY.MM.DD] | high/medium/low |

## Limits and what still needs research

- [items that cannot be confirmed via WebSearch]
- [items that need a paid report or first-hand research]
- [items that need real-time data]

## Suggested PRD updates

[Concrete suggestions for how these research results should be reflected in the PRD]
```

---

## Type 1: Competitor analysis

```markdown
## Summary

- [key finding 1]
- [key finding 2]
- [key finding 3]

## Competitor list

| Service | URL | Category | Status |
|---------|-----|------|------|
| [service] | [URL] | direct / indirect | active / shut down |

## Per-competitor analysis

### [service name 1]

| Item | Content |
|------|------|
| **Service URL** | [URL] |
| **Core value** | [the service's core proposition] |
| **Target users** | [main user base] |
| **Revenue model** | [how it monetizes] |
| **Key features** | [list the core features] |
| **Strengths** | [differentiators] |
| **Weaknesses** | [what is lacking] |
| **Sources** | [URLs backing the analysis] |

### [service name 2]
...

## Comparison table

| Criterion | [service 1] | [service 2] | [service 3] | [product name] (target) |
|------|----------|----------|----------|----------------|
| Key features | | | | |
| Target users | | | | |
| Revenue model | | | | |
| Differentiator | | | | |
| Weaknesses | | | | |

## Implications

### What [product name] can learn
- [lessons from the competitors]

### Differentiation opportunities for [product name]
- [opportunities found in competitor weaknesses]
```

---

## Type 2: Market research

```markdown
## Summary

- [key finding 1]
- [key finding 2]
- [key finding 3]

## Market status

### Market size
| Item | Figure | Source | Confidence |
|------|------|------|--------|
| [market size] | [figure] | [URL] | [high/medium/low] |

### Major players
| Service | Market share [unverified] | Characteristics |
|--------|---------------------|------|
| [service] | [figure or unverified] | [characteristics] |

## Trends

### Growth drivers
- [trend 1] — source: [URL]
- [trend 2] — source: [URL]

### Risk factors
- [risk 1] — source: [URL]

## Target market analysis

### Market segmentation
| Segment | Size | Characteristics | Fit for [product name] |
|---------|------|------|----------------|
| [segment] | [size] | [characteristics] | high/medium/low |

## Implications

- [market opportunity for the product]
- [suggested entry strategy]
```

---

## Type 3: Technology research

```markdown
## Summary

- [key finding 1]
- [key finding 2]
- [key finding 3]

## Technology options

| Technology/library | Type | License | Last updated |
|---------------|------|---------|-------------|
| [name] | [type] | [license] | [date] |

## Per-technology analysis

### [technology 1]

| Item | Content |
|------|------|
| **Official docs** | [URL] |
| **GitHub** | [URL] |
| **Pros** | [list the advantages] |
| **Cons** | [list the drawbacks] |
| **Maturity** | [early/stable/legacy] |
| **Community** | [active/moderate/quiet] |
| **Fit for [product name]** | [high/medium/low] — [reason] |

### [technology 2]
...

## Comparison table

| Criterion | [tech 1] | [tech 2] | [tech 3] |
|------|---------|---------|---------|
| Performance | | | |
| Learning curve | | | |
| Ecosystem | | | |
| Compatible with [product name] stack | | | |

## Recommendation

**Recommended**: [technology]
**Why**: [selection rationale]
**Alternative**: [runner-up and why]
```

---

## Type 4: User research

```markdown
## Summary

- [key finding 1]
- [key finding 2]
- [key finding 3]

## Target user groups

| Group | Characteristics | Estimated size | Priority |
|------|------|----------|---------|
| [group] | [characteristics] | [estimate] | high/medium/low |

## Personas

### Persona 1: [name]

| Item | Content |
|------|------|
| **Age/occupation** | [description] |
| **Main needs** | [needs] |
| **Pain points** | [frustrations] |
| **Current alternative** | [what they use today] |
| **Motivation to use [product name]** | [why they would use this product] |

### Persona 2: [name]
...

## User scenarios

### Scenario 1: [scenario name]
```
[situation] → [action] → [expected outcome]
```

## Needs found in communities and reviews

| Source | Content | URL |
|------|------|-----|
| [community/review] | [summary of the user's words] | [URL] |

## Implications

- [the core pain point the product must solve]
- [suggested feature priority]
```

---

## Type 5: Open topic

```markdown
## Summary

- [key finding 1]
- [key finding 2]
- [key finding 3]

## Findings

### [section 1: structure freely to suit the topic]
[content]

### [section 2]
[content]

## Key data

| Item | Content | Source | Confidence |
|------|------|------|--------|
| [item] | [content] | [URL] | [high/medium/low] |

## Implications

- [implications for the product]
```

---

## Confidence criteria

Judge the confidence of the document as a whole and of each data point by these criteria:

| Confidence | Criterion |
|--------|------|
| **High** | Confirmed from official sites, press releases, government statistics, or academic sources |
| **Medium** | Confirmed from reputable media articles or industry-expert blogs |
| **Low** | Personal blogs, unclear sourcing, or dated information. Always tag it `[unverified]` |
