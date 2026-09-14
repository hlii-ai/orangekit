---
paths:
  - "dev/docs/prd/**"
  - "dev/docs/database/**"
  - "dev/docs/design/**"
  - "dev/docs/architecture/**"
  - "dev/docs/api/**"
---
<!-- orangekit-rule-version: 3.19.0 -->

# Document Dependency Card

Loaded when you edit a document under `dev/docs/{prd,database,design,architecture,api}/`.
Fix one document and the documents that depend on it drift out of line silently — the same failure as "propagating the same pattern" in code.

## Dependency Graph (6 edges)

Once you have edited a source document, read the verification target and compare **semantic consistency**.

| # | Source (what you edited) | Verification target | Focus of the check |
| --- | --- | --- | --- |
| 1 | `prd/**` | the `database/` data model | do the entity·attribute changes match the schema's assumptions |
| 2 | `prd/**` | `design/**` | do the user flow·feature changes need to show up in screens/components |
| 3 | `prd/**` | `api/**` · `architecture/**` | does the new use case demand an endpoint/contract change |
| 4 | `database/**` | `prd/**` · `api/**` | does the schema change break a field stated in the PRD or the API schema (reverse direction) |
| 5 | `design/**` | `prd/**` · `api/**` | do the new fields·states exposed in the UI exist in the PRD/API contract |
| 6 | `api/**` · `architecture/**` | `database/**` · `prd/**` | is the API contract change consistent with the schema/business rules |

What to compare: are entity names · fields · status values · business rule naming identical across documents.

## When You Find a Mismatch — a decision point

Whether to **update the dependent document now** or **split it off as a TODO** is a decision point (per the operating rules):
present the real difference between the two options (immediate consistency vs an expanded change scope) and let the user choose.

## Completion Criteria

If even one dependent document is in a mismatched state, the document work is not "done". Satisfy one of the two:

- (a) every mismatched item has been **fully synchronized**
- (b) the mismatched items have been **explicitly split off as TODOs**, recorded either at the top of the source document
  or in a `[category: doc-sync]` entry in `docs/lessons.md`

**If you edited a PRD, run `/prd-reviewer` (the post-edit verification scope).** This card is that trigger.

## Exemptions (Semantic Materiality)

Typo fixes · unifying vocabulary · formatting cleanup (headings/indentation/line breaks) · adding comments with no effect on the contract are exempt from verification.

**Never exempt**: renaming a field, adding/removing a status value, renaming an entity, changing a business rule,
changing an API contract, adding/removing a schema column — always subject to verification.
