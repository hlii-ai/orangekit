<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Hierarchy design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> Recursive CTEs are standard SQL, and MySQL supports them from 8.0.
> **The default is an adjacency list + a recursive CTE.** It solves most hierarchy requirements.

## Decision criteria

| Approach | When | Note |
| --- | --- | --- |
| **Adjacency list + recursive CTE** (default) | almost every case. Adding, moving, and deleting are simple | n rows; a self-FK guarantees integrity |
| Closure Table | **tens of thousands of nodes or more**, depth of **10+ levels**, reads overwhelmingly outnumber writes — and **a performance problem has actually been measured** | path rows can grow to O(n²), and moving a subtree is complex |
| Materialized Path (PG `ltree`) | on PG, ancestor/descendant searches on a deep tree are frequent and node moves are rare | the `@>` operator + a GiST index |
| Nested Sets | close to read-only, with extremely rare changes | every insert renumbers `lft`/`rgt` |

- A Closure Table is a design that **moves the recursion from read time to write time**. It is also an alternative on legacy systems that cannot use recursive CTEs (MySQL 5.7 and below).
- If the hierarchy rarely changes, **caching the query result in the app** comes before changing the table structure.
- Fixed-depth self-JOINs, a `UNION ALL` per level, and calling repeatedly from the app per level all break the moment the depth changes. Do not use them.

## Standard design — adjacency list

```sql
-- PostgreSQL
CREATE TABLE categories (
  category_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  parent_id   BIGINT NULL REFERENCES categories(category_id)   -- NULL for a root
);
CREATE INDEX idx_categories_parent_id ON categories (parent_id);
```

```sql
-- MySQL 8 (InnoDB creates an index on the FK column automatically)
CREATE TABLE categories (
  category_id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  name        VARCHAR(100) NOT NULL,
  parent_id   BIGINT NULL,
  FOREIGN KEY (parent_id) REFERENCES categories(category_id)
);
```

## Read procedure — recursive CTE

```sql
-- descendants (for ancestors, flip the JOIN condition to c.category_id = t.parent_id)
WITH RECURSIVE tree AS (
  SELECT category_id, name, parent_id, 1 AS depth,
         CAST(name AS CHAR(1000)) AS path          -- PG: CAST(name AS TEXT) — VARCHAR(n) has a different type from the recursive term and errors
    FROM categories WHERE category_id = :root
  UNION ALL
  SELECT c.category_id, c.name, c.parent_id, t.depth + 1,
         CONCAT(t.path, ' > ', c.name)
    FROM categories c
    JOIN tree t ON c.parent_id = t.category_id
   WHERE t.depth < :max_depth                      -- checked against the parent's depth: `<`. With `<=` it descends one level too far
)
SELECT * FROM tree;
```

- **CAST the path string to a roomy type in the anchor.** In a MySQL recursive CTE the anchor decides the column type.
  Without the CAST, trouble starts the moment the path exceeds the anchor column's length (e.g. `name VARCHAR(100)`).
  In strict mode you get `Data too long for column 'path'`, and in non-strict mode it is truncated.
  Short test data does not reveal it.
- `UNION ALL` is required by the syntax. A recursion must always end on a depth condition. The last safety net when a cycle gets into the data is:
  - MySQL: `cte_max_recursion_depth` (default 1000)
  - PG: from 14 up, the `CYCLE category_id SET is_cycle USING path_ids` clause
- Subtree aggregation: collect the descendant IDs with a CTE, then aggregate with `WHERE category_id IN (SELECT category_id FROM tree)`.
- A breadcrumb attaches path accumulation to an anchor that starts at the root (`parent_id IS NULL`).

## Write procedure

**Adjacency list**
- Adding is a single INSERT.
- Moving is the one line `UPDATE categories SET parent_id = :new_parent WHERE category_id = :id`.
- **Prevent cycles when moving.** Reject it if the new parent is the node itself or one of its descendants.
  First check whether `:new_parent` is in the descendant CTE. A DB constraint cannot stop this.
- **Do not delete a node that has children.** Block it in the app, or move or delete the children first.
  With a self-FK the DB rejects it too. Deleting a whole subtree with `ON DELETE CASCADE` is done only when intended.

**Closure Table**

```sql
-- node table (no parent_id) + path table
CREATE TABLE category_paths (
  ancestor_id   BIGINT NOT NULL REFERENCES categories(category_id),   -- MySQL: use a FOREIGN KEY clause
  descendant_id BIGINT NOT NULL REFERENCES categories(category_id),
  depth         INT    NOT NULL,                  -- itself = 0, a direct child = 1
  PRIMARY KEY (ancestor_id, descendant_id)
);
CREATE INDEX idx_category_paths_descendant_id ON category_paths (descendant_id);  -- for ancestor lookups
CREATE INDEX idx_category_paths_depth ON category_paths (depth);                  -- for direct-child and depth-limited reads

-- add a node (:n under parent :p) — one transaction
INSERT INTO category_paths VALUES (:n, :n, 0);                     -- the self row (mandatory)
INSERT INTO category_paths (ancestor_id, descendant_id, depth)
SELECT ancestor_id, :n, depth + 1 FROM category_paths WHERE descendant_id = :p;

-- reads
SELECT … WHERE p.ancestor_id = :id;                     -- all descendants
SELECT … WHERE p.descendant_id = :id;                   -- all ancestors
SELECT … WHERE p.ancestor_id = :id AND p.depth = 1;     -- direct children
```

- Deletion order: delete the path rows (`descendant_id = :n`) first, then the node. Block it for a node that has children.
- Moving a subtree means cutting the existing paths and rebuilding the new ones. It is expensive, so do not pick a Closure Table when moves are frequent.

## Anti-patterns

1. Introducing a Closure Table before the need is measured (YAGNI). The implementation and maintenance cost is high.
2. No self-FK on `parent_id`. It can point at a parent that does not exist.
3. A recursive CTE with no depth condition. It recurses forever on cyclic data.
4. Writing the depth condition as `<=`. It is checked against the parent's depth, so it descends one level further than you want.
5. On MySQL, not CASTing the path column in the anchor. On a deep tree the path exceeds the anchor column's length and errors or is truncated.
6. Not checking for cycles when moving a node.
7. Reading the hierarchy with a fixed-depth self-JOIN or a per-level `UNION ALL`.
8. Leaving the self row (depth 0) out of a Closure Table. The "subtree including itself" read breaks.
9. No rule that identifies the root. Settle on one, such as `parent_id IS NULL`.
