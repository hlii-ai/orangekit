<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# EAV vs JSONB design

**EAV is forbidden in PostgreSQL**. JSONB + a GIN index wins on every axis (tens of thousands of times the performance, a third of the storage).

| when to use JSONB                                 | when not to use JSONB (use regular columns) |
| ------------------------------------------------- | ------------------------------------------ |
| dynamic/extensible schema (user-defined fields, settings) | structure is fixed · queried often · needs index optimization |
| sparse data (optional attributes that are NULL in most rows) | an FK target (relational JOIN needed)    |
| metadata · external API response caches · event payloads | aggregation/sorting targets (regular columns + B-tree preferred) |
| frequent schema evolution (extend without ALTER TABLE)   | the value needs a NOT NULL or CHECK constraint |

**Choosing a GIN index** (extends card §5):

| operator class   | purpose                         | size          | when to apply                   |
| ---------------- | ------------------------------- | ------------- | ------------------------------- |
| `jsonb_path_ops` | `@>` containment searches only  | small (20–30%) | most JSONB searches (the default choice) |
| `jsonb_ops`      | `?`/`?|`/`?&`/`@>` key existence and partial matching | large (60–80%) | only when key-existence search is needed |

**Validation**: a DB `CHECK` constraint (when the structure is fixed) or an app Zod schema (when it is fluid). Same as the existing rule in card §5.

**Anti-patterns**: ①an EAV table (`entity_id`, `attribute`, `value` TEXT) — loses type safety, query performance, and storage efficiency alike ②JSONB used to dodge normalization (dumping structured data into JSONB — violates 1NF, card §4) ③JSONB searches with no GIN index (sequential scan) ④overusing `jsonb_ops` (when only containment is needed, `jsonb_path_ops` saves 60%+ of the index)
