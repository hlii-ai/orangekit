# Business planning frameworks

Frameworks and templates for business planning, referenced from SKILL.md.

---

## 1. 5C Analysis guide

The 5C analysis is a framework for understanding the business environment systematically.

| Element | Core question | What to analyze |
|------|----------|------------|
| **Company** | What are our core capabilities? | Technology, people, assets, brand, existing user base |
| **Customer** | Whose problem are we solving? | Segments, needs, purchasing power, how they decide |
| **Competitor** | What alternatives exist? | Direct competitors, indirect competitors, DIY alternatives, switching cost |
| **Collaborator** | Who do we need to work with? | Suppliers, distribution, technology partners, platforms |
| **Climate** | What is the external environment? | PEST (political/economic/social/technological), regulation, trends |

**Analysis tips:**
- Company can be extracted automatically from the project's `CLAUDE.md` and the existing codebase
- Competitor integrates the output of `/research` (competitor analysis)
- Climate integrates the trend data from `/research` (market research)

---

## 2. Lean Canvas template

A nine-box layout that captures the business model at a glance.

```
┌────────────────────────┬────────────────────────┬────────────────────────┐
│  ② Problem             │  ④ Solution            │  ③ Value proposition   │
│  Top 3 problems        │  Top 3 key features    │  UVP in one sentence   │
│                        │                        │                        │
│  Existing alternatives:│                        │  High-level concept:   │
│  [current workaround]  │                        │  [one-line pitch]      │
├────────────────────────┼────────────────────────┼────────────────────────┤
│  ⑧ Key metrics         │                        │  ⑤ Customer segments   │
│  Activity to measure   │                        │  Target customer       │
│                        │                        │  Early adopters:       │
├────────────────────────┤                        ├────────────────────────┤
│  ⑥ Channels            │                        │  ⑨ Unfair advantage    │
│  Customer reach path   │                        │  What cannot be copied │
├────────────────────────┴────────────────────────┴────────────────────────┤
│  ⑦ Cost structure                   │  ① Revenue streams                 │
│  Fixed + variable costs             │  Revenue model + pricing           │
└─────────────────────────────────────┴────────────────────────────────────┘
```

**Fill order**: ① Revenue → ② Problem → ③ UVP → ④ Solution → ⑤ Customer → ⑥ Channels → ⑦ Cost → ⑧ Metrics → ⑨ Unfair advantage

---

## 3. Pricing framework

### Three approaches

| Approach | Basis | When it fits | Upside | Downside |
|------|------|------------|------|------|
| **Cost-based** | Cost + margin | Costs are easy to forecast, B2B | Margin guaranteed | Does not reflect market value |
| **Value-based** | Value the customer perceives | Differentiated solution, SaaS | High margin possible | Value is hard to measure |
| **Competitor-based** | Competitor pricing | Crowded market, red ocean | Market accepts it readily | Price-war trap |

### SaaS pricing tier design guide

| Tier | Role | How to price |
|------|------|----------|
| **Free** | Acquisition, product trial | Free, limited features/quota |
| **Starter** | Drive conversion, core features | Below the competitor price band |
| **Pro** | Main revenue, primary target | Value-based, with competitors as reference |
| **Enterprise** | Large accounts, custom | Negotiated individually |

### Pricing checklist
- [ ] What does the customer pay for their current alternative?
- [ ] What value does our solution save or create?
- [ ] What is the competitor price range?
- [ ] What is the target margin over cost?
- [ ] What is the launch discount / promotion strategy?

---

## 4. Risk matrix template

### Impact × probability matrix

```
Impact ↑
High   │ Monitor      │ Act actively │ Top priority │
       │ (low×high)   │ (med×high)   │ (high×high)  │
Medium │ Accept       │ Monitor      │ Act actively │
       │ (low×med)    │ (med×med)    │ (high×med)   │
Low    │ Accept       │ Accept       │ Monitor      │
       │ (low×low)    │ (med×low)    │ (high×low)   │
       └──────────────┴──────────────┴──────────────→ Probability
         Low            Medium         High
```

### Risk categories

| Category | Typical risks | Checkpoints |
|---------|-------------|------------|
| **Market** | Weak demand, intensifying competition, timing | How to validate the market, competitive response |
| **Technical** | Scalability, security, technical debt | Architecture validation, performance targets |
| **Operational** | Understaffing, burnout, communication | Team composition, process |
| **Legal** | Privacy, licensing, financial regulation | Compliance checklist |

---

## 5. Business plan output template

```markdown
# Business plan: [service name]

**Date**: [YYYY.MM.DD]
**Status**: Draft
**Research reference**: [path] (if any)

---

## Executive Summary

[One paragraph: the problem, the solution, the target customer, the differentiator, the core of the revenue model]

---

## 1. Business environment analysis (5C)

### 1.1 Company
| Item | Content |
|------|------|
| Core capability | [technical/domain expertise] |
| Tech stack | [technologies on hand] |
| Existing assets | [reusable resources] |

### 1.2 Customer
| Segment | Characteristics | Needs | Size |
|---------|------|------|------|
| [Primary] | [characteristics] | [needs] | [estimated size] |
| [Secondary] | [characteristics] | [needs] | [estimated size] |

### 1.3 Competitor
| Service | Type | Strengths | Weaknesses | Differentiation opportunity |
|--------|------|------|------|------------|
| [competitor] | direct/indirect | [strengths] | [weaknesses] | [opportunity] |

### 1.4 Collaborator
- [list of partners / ecosystem]

### 1.5 Climate
- **Trends**: [major trends]
- **Regulation**: [relevant regulation]
- **Technology shifts**: [technical change]

---

## 2. Value Proposition

| Item | Content |
|------|------|
| **Core problem** | [the problem being solved] |
| **Solution** | [the proposed solution] |
| **UVP** | [the differentiated value in one sentence] |

---

## 3. Revenue model and pricing strategy

### Revenue model
- **Type**: [subscription/freemium/transaction fee/other]
- **Rationale**: [why this one]

### Pricing design
| Tier | Price | Included features | Target |
|------|------|----------|------|
| [tier name] | [price] | [features] | [target] |

### Revenue scenarios
| Scenario | Users | ARPU | MRR |
|---------|----------|------|-----|
| Conservative | [number] | [number] | [number] |
| Base | [number] | [number] | [number] |
| Optimistic | [number] | [number] | [number] |

---

## 4. Cost structure

| Item | Type | Monthly cost | Notes |
|------|------|--------|------|
| [item] | fixed/variable | [amount] | [description] |

---

## 5. Go-to-Market strategy

### Phase 1: [initial target]
- Duration: [duration]
- Goal: [goal]
- Channels: [channels]

### Phase 2: [expansion]
- Duration: [duration]
- Goal: [goal]
- Channels: [channels]

---

## 6. Key metrics (KPI)

| Category | Metric | Target | How to measure |
|---------|------|------|----------|
| Growth | [metric] | [target] | [method] |
| Engagement | [metric] | [target] | [method] |
| Revenue | [metric] | [target] | [method] |
| Efficiency | [metric] | [target] | [method] |

---

## 7. Risks and responses

| Risk | Category | Impact | Probability | Response |
|--------|---------|--------|----------|----------|
| [risk] | [category] | [high/med/low] | [high/med/low] | [response] |

---

## Handoff to service: the key decisions service planning needs

- **Target customer**: [core segment]
- **Core value**: [UVP in one line]
- **Revenue model**: [chosen model]
- **Key KPIs**: [top 3 metrics]
- **Constraints**: [technical/budget/time constraints]
```
