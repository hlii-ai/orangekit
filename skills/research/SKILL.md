---
name: research
description: Performs web-search-based research on a given topic and produces a structured document in dev/docs/research/. Use for competitor analysis, market research, technology research, user research, and whenever an external fact needs checking.
---

# Research

A skill that gathers public web information on a given topic and produces a structured research document.

## Limits

- Collecting data from paid reports, private APIs, or services that require authentication
- Guaranteeing exact real-time figures such as prices or user counts
- Complete coverage of local-language data

## Workflow

### Step 1: Identify the research type

| Type                | Trigger keywords                           |
| ------------------- | ------------------------------------------ |
| Competitor analysis | competitor, competing service, alternative |
| Market research     | market, size, trend                        |
| Technology research | technology, comparison, library            |
| User research       | user, needs, pain point                    |
| Open topic          | anything else                              |

The type is what decides which template Step 5 uses. If it is ambiguous, have the user pick one —
collecting without a type gathers sources but never assembles a document.

### Step 2: Check for existing research — the conditions for not writing one

Search `dev/docs/research/` by topic keyword.

| Found | Action |
| --- | --- |
| Same topic, **within 90 days** | **Do not write a new one.** Present the existing document and ask "which items should be refreshed" |
| Same topic, older than 90 days | Open the existing document as the baseline and re-research only what changed (not a full rewrite) |
| Only adjacent topics | Link to them as references and write a new one |
| Nothing | Write a new one |

Why 90 days: markets, prices, and competing services move on a quarterly rhythm, and a shorter window
means rewriting the same document over and over.

### Step 3: Check the user's own data

**Look inside the project before going out to the web.** If the user already has data, it takes
precedence over search results (measured > public estimates):

- Figures, targets, and competitor lists written in the existing plans and PRDs under `dev/docs/`
- Material the user pasted into the conversation · files they named
- The libraries and services the project code actually uses (for technology research)

If there is none, write that down and move on — **the only question here is whether they have material.**

### Step 4: Collect the information

Write down 3-5 search axes for the type first, then run a WebSearch per axis. Searching without writing the axes down
drags you along with the first result.

| Type | Search axes |
| --- | --- |
| Competitor analysis | Service list · pricing/plans · user reviews · **failures and withdrawals** |
| Market research | Market-size sources · growth rate · regulation/policy · major players |
| Technology research | Official docs · benchmarks · migration write-ups · **known limits** |
| User research | Community complaints · reviews · posts about looking for alternatives |

Collection ceiling: **at most 3 searches per axis.** If three do not fill an axis, mark that axis "insufficient data"
and move on — endless searching only delays the document; it does not raise accuracy.

Record every fact with **its URL and publication date**. Cite material whose date you cannot confirm, but
mark it "date unknown".

### Step 5: Produce the structured document

Read the template for the Step 1 type from `resources/research-templates.md` and fill it in as it is.
**Do not add a section the template does not have** — if the structure varies from run to run, the PRD cannot
take this document as-is.

Every type has the shared header + the type's body + the shared footer (data sources · limits · suggested PRD updates).

### Step 6: Save the file and confirm with the user

Save path: `dev/docs/research/<topic>.md`

Self-check before saving — if even one check fails, do not save and report that item:

- [ ] Are all the template's required sections present?
- [ ] Does every cited figure carry a source URL?
- [ ] Is every axis left as "insufficient data" written into "Limits"?

## Reference documents

| File | When to read it |
| --- | --- |
| `resources/research-templates.md` | **In Step 5 only.** Once the type is settled, read only that type's section (do not read all 281 lines) |
| `dev/docs/research/` | Step 2 — checking for existing research |

## Pitfalls

- Always check the date on a WebSearch result — a three-year-old price list looks current
- Guard against search-term bias — search for "failure", "problem", and "limitation" keywords too
- Do not present a single source's figure as "the market size" — if there is only one source, say so
