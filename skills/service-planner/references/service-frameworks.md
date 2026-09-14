# Service planning frameworks

Frameworks and templates for service planning, referenced from SKILL.md.

---

## 1. User Story writing guide

### Form
```
As a [role], in order to [goal], I want to [capability].
```

### The INVEST criteria for a good User Story

| Criterion | Meaning | How to check |
|------|------|----------|
| **I**ndependent | Independent of other stories | Can it be built without a fixed order? |
| **N**egotiable | Open to negotiation | Is the implementation approach left open? |
| **V**aluable | Valuable | Does it deliver value to a user or the business? |
| **E**stimable | Estimable | Can the development cost be estimated? |
| **S**mall | Right-sized | Can it be finished within one sprint? |
| **T**estable | Testable | Can completion be verified? |

### Examples

**A good User Story:**
- "As a buyer, in order to check the total of the items in my cart, I want to see the total amount on the cart page."

**A bad User Story:**
- "The system must be fast." → that is a non-functional requirement, not a User Story
- "As a user, I want to use every feature." → far too large, violates the S in INVEST

### Decomposition levels

```
Theme: "build an e-commerce platform"
  ↓
Epic: "product search system"
  ↓
Feature: "keyword search"
  ↓
User Story: "As a buyer, in order to find the product I want, I want to type a keyword into the search box."
  ↓
Requirement: "FR-001: live autocomplete once 2 or more characters are typed into the search box"
```

---

## 2. MoSCoW priority guide

### Definitions

| Priority | Meaning | Suggested share |
|---------|------|------------|
| **Must** | Cannot launch without it. Delivers the core value | ~60% |
| **Should** | Important, but launch is possible without it. Improves the experience | ~20% |
| **Could** | Nice to have, fine without. A differentiator | ~15% |
| **Won't** | Not in this version. Consider later | ~5% |

### How to decide

| Question | Must | Should | Could |
|------|------|--------|-------|
| Does the service work without it? | No | Yes, but awkwardly | Yes |
| Does the user need it right now? | Immediately | Soon | Later |
| Is it a differentiator against competitors? | Table stakes | Needed to compete | Differentiator |
| Are there technical dependencies? | A prerequisite for others | Independent | Independent |

### Practical tips
- **If Must exceeds 50%** → re-examine the scope (the MVP may need to be narrower)
- **Stating Won't matters** → saying "we are not doing this" out loud is what prevents scope creep
- When in doubt, classify as **Should** → re-assess Must status as development proceeds

---

## 3. How to write Acceptance Criteria

### Given-When-Then (GWT) form

```
Given: [precondition - the initial state of the system/user]
When: [trigger - the action the user performs]
Then: [outcome - the expected system response]
```

### Example

**FR-001: email login**
```
Scenario 1: successful login
Given: a user with a valid account is on the login page
When: they enter the correct email and password and click the login button
Then: they are taken to the dashboard page and their name appears in the header

Scenario 2: wrong password
Given: a user with a valid account is on the login page
When: they enter the correct email and the wrong password and click the login button
Then: the error message "Email or password is incorrect" is shown

Scenario 3: email format validation
Given: the user is on the login page
When: they enter an invalid email format
Then: the inline error "Please enter a valid email address" is shown
```

### Checklist form (for simple requirements)

```
- [ ] Email format validation (contains @, domain checked)
- [ ] Password at least 8 characters
- [ ] Error message shown on login failure
- [ ] Account locked after 5 consecutive failures (30 minutes)
- [ ] JWT token issued on successful login
```

### Which form to choose

| Situation | Recommended form |
|------|----------|
| A feature with complex branches or states | GWT (per scenario) |
| A simple CRUD feature | Checklist |
| A feature that is mostly UI interaction | GWT |
| Data processing / backend logic | Checklist |

---

## 4. Functional requirements table template

### Functional requirements (FR)

| ID | Epic | Feature | Requirement | Priority | Acceptance criteria |
|----|------|---------|-------------|---------|----------|
| FR-001 | [Epic] | [Feature] | [a concrete requirement] | Must | [GWT or checklist] |
| FR-002 | [Epic] | [Feature] | [a concrete requirement] | Should | [GWT or checklist] |
| FR-003 | [Epic] | [Feature] | [a concrete requirement] | Could | [GWT or checklist] |

### ID rules
- `FR-xxx`: Functional Requirement
- `NFR-xxx`: Non-Functional Requirement
- Number sequentially from 001
- Keep incrementing even when the Epic changes (never reuse a skipped number)

---

## 5. Non-functional requirements checklist

### Performance
| ID | Requirement | Criterion | Measurement |
|----|---------|------|------|
| NFR-P01 | Initial page load | LCP < 2.5s | Lighthouse |
| NFR-P02 | API response time | p95 < 500ms | Server monitoring |
| NFR-P03 | Concurrent users | Support [N] or more | Load test |
| NFR-P04 | Image optimization | WebP/AVIF, lazy loading | Lighthouse |

### Security
| ID | Requirement | Criterion | Measurement |
|----|---------|------|------|
| NFR-S01 | Authentication/authorization | JWT + Refresh Token | Security review |
| NFR-S02 | Data encryption | HTTPS required, sensitive data encrypted | SSL check |
| NFR-S03 | Input validation | All user input validated server-side | OWASP check |
| NFR-S04 | DB access control | Table/row level access policies applied | Test |

### Accessibility
| ID | Requirement | Criterion | Measurement |
|----|---------|------|------|
| NFR-A01 | WCAG compliance | Level AA | axe-core |
| NFR-A02 | Keyboard navigation | Every feature reachable by keyboard | Manual test |
| NFR-A03 | Screen readers | Key features compatible with screen readers | NVDA/VoiceOver |

### Compatibility
| ID | Requirement | Criterion | Measurement |
|----|---------|------|------|
| NFR-C01 | Browsers | Latest 2 versions of Chrome, Safari, Firefox | BrowserStack |
| NFR-C02 | Devices | Desktop + mobile responsive | Device testing |
| NFR-C03 | Resolutions | 360px ~ 1920px | CSS media queries |

---

## 6. Information architecture guide

### Site map principles

1. **No more than three levels deep** — the user reaches any feature within three clicks
2. **Group similar features** — related features sit under the same parent menu
3. **Core features first** — frequently used features go at the top of the navigation
4. **Separate by auth state** — clearly separate which screens are reachable before and after login

### Navigation patterns

| Pattern | Fits which service | Characteristics |
|------|-------------|------|
| Top GNB | Few screens (5-7) | Web standard, familiar |
| Sidebar | Many screens, dashboards | Scales well, best on desktop |
| Bottom tab bar | Mobile-first | Thumb-reachable, 5 or fewer |
| Hamburger menu | Hides secondary features | Low discoverability, supplementary |

### Screen data needs (Step 4-4)

Write down, field by field, **what the screen shows and what it takes in**. The wire contract and the draft data model
are derived from this table — without it the contract gets built with no relation to the screens.
It is not an FR: an FR is "what the user can do", and this table is "what data that screen
touches". It does not conflict with the principle of never mapping FRs 1:1 to screens.

| Screen | Fields read | Fields written | List | Empty / loading / error |
| --- | --- | --- | --- | --- |
| Task list | `title` `done` `created_at` | — | ✓ (paginated) | Empty: prompt for a first task · Loading: skeleton · Error: retry |
| Create task | — | `title` | — | Error: per-field message |
| Task detail | `title` `done` `created_at` `updated_at` | `done` | — | Error: missing item → back to the list |

- Put each field in its own backticks — the envelope fields of contract §0 and §1 come from here
- For a list screen, record whether it paginates — that is the basis for the model (cursor/offset) in contract §3
- Record only the error branches the user sees — the error codes in contract §4 are worked back from here

---

## 7. Service plan output template

```markdown
# Service plan: [service name]

**Date**: [YYYY.MM.DD]
**Status**: Draft
**Business plan reference**: [path] (if any)

---

## 1. Core personas

| Item | Content |
|------|------|
| Name/role | [fictional name, occupation] |
| Core needs | [needs] |
| Pain Point | [frustration] |
| Current alternative | [what they use today] |
| Success criterion | [what changes after using the service] |

---

## 2. User scenarios

### Scenario 1: [scenario name]
- **Situation**: [the situation the user is in]
- **Goal**: [what they are trying to achieve]
- **Steps**: [the stages of using the service]
- **Outcome**: [the state they reach]

### Scenario 2: [scenario name]
...

---

## 3. User Stories

| ID | User Story | Related scenario |
|----|-----------|-------------|
| US-001 | As a [role], in order to [goal], I want to [capability] | Scenario 1 |

---

## 4. Information architecture

### 4.1 Screen hierarchy
[site map tree]

### 4.2 Core screens
| Screen | Role | Key features | Related User Story |
|------|------|----------|----------------|
| [screen] | [role] | [features] | US-001 |

### 4.3 Navigation flow
[Mermaid flowchart]

### 4.4 Draft data model
[Mermaid ER diagram + entity table]

---

## 5. Functional requirements (FR)

| ID | Epic | Feature | Requirement | Priority | Acceptance criteria |
|----|------|---------|-------------|---------|----------|
| FR-001 | [Epic] | [Feature] | [requirement] | Must | [acceptance criteria] |

### Priority summary
- **Must**: [N] — [list the core features]
- **Should**: [N]
- **Could**: [N]
- **Won't**: [N] — [why they were excluded]

---

## 6. Non-functional requirements (NFR)

| ID | Category | Requirement | Criterion | Measurement |
|----|---------|---------|------|----------|
| NFR-001 | [category] | [requirement] | [criterion] | [measurement] |

---

## Handoff to understand: the key data for generating the PRD

- **Service name**: [service name]
- **Core features (Must)**: [summary list of the Must features]
- **Target users**: [one-line persona summary]
- **Number of core screens**: [N]
- **Data model**: [list of core entities]
```
