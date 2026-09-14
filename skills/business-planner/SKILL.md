---
name: business-planner
description: Validates an idea or feature from a business standpoint and produces a business plan. Use for "business planning", "business model", "monetization", "market entry", "viability analysis", and for new features that need a revenue-model or market-entry decision.
---

# Business Planner

Validates an idea or feature from a business standpoint and produces a structured business plan.
Establishes the business case for "why should we build this?"

## Workflow

### Step 1: Identify the input and set the scope of analysis

| Input situation | Steps to run |
|----------|----------|
| Invoked with research results (via orangekit-planner) | Step 2 → Step 3 → Step 4 → Step 5 |
| Invoked directly by the user (no research) | Step 3 → Step 4 → Step 5 |
| Request to revise an existing business plan | Step 3 (load the existing document) → Step 4 → Step 5 |

### Step 2: Integrate the research

Read the documents in `dev/docs/research/` and extract the data that feeds the business plan.

### Step 3: Analyze the business environment

Analyze using the 5C Analysis guide in `references/business-frameworks.md`.

Ask the user **one question at a time** for each item (the brainstorming pattern):
3-1. Company (own capabilities)
3-2. Customer
3-3. Competitor
3-4. Collaborator
3-5. Climate

### Step 4: Design the business model

Design the business model from the 5C analysis.

4-1. Value Proposition
4-2. Revenue model
4-3. Cost structure
4-4. Go-to-Market strategy
4-5. Key metrics (KPI)
4-6. Risk matrix

### Step 5: Save the business plan and confirm

**Save path**: `dev/docs/business/business-plan-<name>.md`

## Reference documents

`references/business-frameworks.md` is 234 lines. **Read only the section for the current Step** —
reading it whole burns half the context before the 5C questions even start.

| Step | Section to read |
| --- | --- |
| Step 3 | §1 5C Analysis guide |
| Step 4 | §2 Lean Canvas · §3 Pricing · §4 Risk matrix |
| Step 5 | §5 Business plan output template |

- Business plans live in `dev/docs/business/` · research lives in `dev/docs/research/`
