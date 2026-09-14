# Per-perspective analysis prompt templates

Prompt templates to hand to Council Review's three perspective agents.
Substitute `{context_brief}` into each prompt before use.

---

## Technical perspective prompt (Technical Perspective)

```
# Technical Perspective Analysis

Analyze the proposed feature from a technical perspective.

## Subject of analysis
{context_brief}

## Scope of analysis

### 1. Technical feasibility
- Can it be built on the current stack (Next.js 15, TypeScript, Supabase, Tailwind CSS v4)?
- What technical uncertainties or risks are there?
- Complexity estimate: Low / Medium / High

### 2. Architectural impact
- How does it fit the existing architecture?
- Does it need a new module or service?
- Impact on existing code (breaking changes, need for migration)

### 3. Implementation approach
- The technical approach you recommend (with brief reasoning)
- Key technical decisions
- Dependencies on external services/APIs

### 4. Performance and scalability
- Performance impact (DB queries, API calls, rendering)
- Scalability concerns at current and future scale

### 5. Scope recommendation (technical lens)
- Features that are technically essential
- Features complex enough that they can be deferred against their early value
- Technical debt considerations

### 6. Effort estimate
- Expected number of files to change
- Complexity: Low / Medium / High
- Factors that could inflate the effort

### 7. Blind spots (what the technical perspective cannot see)
- Which technical assumptions about this feature are still unverified?
- What is being taken for granted but actually needs checking?
- What would be visible from the business/UX perspective but easy to miss from the technical one?

## Output format
Respond structured by the sections above.
End with a three-line summary: "Technical perspective position: [one-sentence recommendation]"

Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
```

---

## Business perspective prompt (Business Perspective)

```
# Business Perspective Analysis

Analyze the proposed feature from the perspective of business value and ROI.

## Subject of analysis
{context_brief}

## Scope of analysis

### 1. Business value
- What business problem does this feature solve?
- Expected impact on the KPIs
- Revenue/cost impact

### 2. Market fit
- Does it match the target customer's needs?
- Potential for competitive differentiation
- Market timing considerations

### 3. Priority assessment
- Urgency: is it time-sensitive?
- Position on the impact vs effort matrix
- Opportunity cost of building this instead of something else

### 4. Scope recommendation (business lens)
- Features essential to delivering the business value
- Features that raise the value but are not essential
- Features with low business impact that can be deferred

### 5. Risk assessment
- Business risks (market, regulation, competition)
- The cost of not building this feature
- The cost of building it wrong

### 6. Success criteria
- How success will be measured after launch
- The minimum success metric
- Expected time until the value is realized

### 7. Blind spots (what the business perspective cannot see)
- Which assumptions about this feature's business value are still unverified?
- What is assumed as "customers will want it" but actually needs checking?
- What would be visible from the technical/UX perspective but easy to miss from the business one?

## Output format
Respond structured by the sections above.
End with a three-line summary: "Business perspective position: [one-sentence recommendation]"

Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
```

---

## UX perspective prompt (User Experience Perspective)

```
# User Experience Perspective Analysis

Analyze the proposed feature from the perspective of user experience and usability.

## Subject of analysis
{context_brief}

## Scope of analysis

### 1. Validating the user need
- Does it solve a real user pain point?
- How do users solve this problem today?
- Evidence of user demand

### 2. Impact on the user journey
- How does it integrate into the existing user flow?
- Does it need new screens or interactions?
- Cognitive load assessment

### 3. Usability concerns
- Potential usability traps
- Edge cases that could confuse users
- Accessibility (A11y) considerations

### 4. Scope recommendation (UX lens)
- Features essential to a good user experience
- Features that improve UX but can be added later
- Features that could hurt UX

### 5. Interaction design notes
- The key interaction patterns to use
- Error-state and empty-state considerations
- Progressive disclosure opportunities

### 6. User risk
- Risk of user confusion or drop-off
- Learning curve for the new feature
- Impact on existing user workflows

### 7. Blind spots (what the UX perspective cannot see)
- Which assumptions about this feature's user experience are still unverified?
- What is assumed as "users will behave this way" but actually needs checking?
- What would be visible from the technical/business perspective but easy to miss from the UX one?

## Output format
Respond structured by the sections above.
End with a three-line summary: "UX perspective position: [one-sentence recommendation]"

Status: DONE / DONE_WITH_CONCERNS / NEEDS_CONTEXT / BLOCKED
```
