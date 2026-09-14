<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Hierarchy design

**Default: Adjacency List + CTE** (`parent_id` FK + `WITH RECURSIVE`). This covers 90%+ of requirements. Introduce a Closure Table only after EXPLAIN ANALYZE proves a performance problem (same premise as denormalization in card §7).

| approach                  | when to apply                  | when not to apply                    | PostgreSQL implementation                                                          |
| ------------------------- | ------------------------------ | ------------------------------------ | ---------------------------------------------------------------------------------- |
| Adjacency List            | depth ≤5, frequent writes, simple trees | frequent ancestor/descendant queries on deep trees | `parent_id BIGINT REFERENCES self` + a `WITH RECURSIVE` CTE            |
| Materialized Path (ltree) | depth 10+, frequent ancestor/descendant searches | frequent node moves (cost of rewriting whole paths) | `CREATE EXTENSION ltree` + a GiST index + the `@>` operator |
| Closure Table             | arbitrary depth, read/write balance needed | simple trees (over-engineering)      | a cross table `(ancestor_id, descendant_id, depth)` + a mandatory self row `(id, id, 0)` |
| Nested Sets               | read-only or changes extremely rare | frequent inserts/deletes (renumbering all lft/rgt) | `lft`/`rgt` INTEGER columns                                  |

**Selection criteria**: ①read/write ratio (read-heavy → ltree/Nested Sets, write-heavy → Adjacency List) ②tree depth (≤5 → Adjacency List, 10+ → ltree) ③change frequency (frequent moves → Adjacency List or Closure Table)

**CTE usage patterns**: ①depth limit: `WHERE depth < {max_depth}` in the recursive case (checked against the parent — note, not `<=`) ②path string: the `CONCAT(parent.path, ' > ', child.name)` pattern (breadcrumbs) ③hierarchical aggregation: collect descendant IDs with a recursive CTE, then aggregate with `WHERE id IN (...)`

**Anti-patterns**: ①introducing a Closure Table before it is needed (YAGNI) ②`parent_id` with no self-FK (no integrity) ③a recursive CTE with no depth limit (risk of an infinite loop — a depth ceiling condition is mandatory) ④no column identifying the root node (`parent_id IS NULL` or `depth = 0`)
