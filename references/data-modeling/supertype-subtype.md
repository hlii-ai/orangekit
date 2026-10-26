<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Supertype/subtype (inheritance) design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> Do not use PG table inheritance (`INHERITS`). Use the general-purpose design.
> **Boundary**: use inheritance design for a **stable, predictable type hierarchy** (product types, payment methods).
> If the attributes are dynamic and categories keep growing, it is not a candidate for inheritance (→ [`eav-vs-jsonb.md`](./eav-vs-jsonb.md)).

## Decision criteria

| Strategy | When | Pros | Cons |
| --- | --- | --- | --- |
| **Join strategy** (default · most recommended) | the types differ a lot and have many own attributes. Types keep being added. Integrity matters | normalized, own attributes can be NOT NULL, FKs are possible, adding a type is just adding a table | 2 INSERTs, a JOIN for detail reads |
| **Single table** | few, fixed types. Few own attributes. Full-list reads are frequent and performance comes first | the simplest, no JOIN, FKs are possible | many NULLs make the table wide, and per-type required attributes can be enforced only with `CHECK` |
| A table per concrete class | **do not use** (only special situations such as legacy compatibility) | — | `UNION ALL` for full reads, no way to know which table holds an ID, **no FK possible**, ID collisions between tables, a change to a common column repeated across every table |

- The single table's greatest strength is simplicity. For a simple case, give the single table real consideration.
  Most of the performance loss from joins is solved with an index.
- Even if the ORM can map all three strategies, it does not replace understanding the physical table design.

## Standard design

**Common**: put a **discriminator column** on the parent (or the single table). Make it `NOT NULL`, index it, and fix its value set with a `CHECK` (→ [`common-code.md`](./common-code.md) ENUM + CHECK).
An FK from an outside table (e.g. `orders`) **points at the parent table.**

```sql
-- join strategy
CREATE TABLE products (
  product_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- MySQL: BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY
  product_type VARCHAR(20)  NOT NULL
    CONSTRAINT chk_products_product_type CHECK (product_type IN ('BOOK','ELECTRONICS','CLOTHING')),
  name         VARCHAR(200) NOT NULL,
  price        NUMERIC(12,0) NOT NULL                              -- MySQL: DECIMAL(12,0)
);
CREATE INDEX idx_products_product_type ON products (product_type);

CREATE TABLE books (
  product_id BIGINT PRIMARY KEY REFERENCES products(product_id),  -- PK = an FK to the parent PK. No identity or AUTO_INCREMENT
  author     VARCHAR(100) NOT NULL,                                -- own attributes can be NOT NULL too
  isbn       VARCHAR(13)
);
```

```sql
-- single table: "required per type" for own attributes is supplemented with a type-conditional CHECK
ALTER TABLE products ADD CONSTRAINT chk_products_book_author
  CHECK (product_type <> 'BOOK' OR author IS NOT NULL);
ALTER TABLE products ADD CONSTRAINT chk_products_clothing_size
  CHECK (product_type <> 'CLOTHING' OR size IS NOT NULL);
-- MySQL enforces CHECK from 8.0.16. Every time a type is added, the constraint must be added with it
```

## Write and read procedure

- **In the join strategy, INSERT parent → child, in one transaction.** Put the parent PK you just created into the child PK.
  PG gets it with `INSERT … RETURNING product_id`, MySQL with `LAST_INSERT_ID()`.
  Without a transaction, a failed child INSERT leaves a parent with no child.
- Reads:
  - A list of common attributes → read only the parent.
  - You know the type → `JOIN` with that child.
  - You do not know the type (a detail read by ID) → `LEFT JOIN` every child and map in the app by the discriminator.
    Or read the discriminator first, then read just that one child.
- The more child tables there are, the more joins the "LEFT JOIN every child" read has. On a high-traffic path, use the two-step read that reads the discriminator first.

## Anti-patterns

1. Making a table per concrete class (Table-per-Concrete-Class).
2. The discriminator column is missing, allows NULL, or has an open value set.
3. Giving the child PK its own identity or AUTO_INCREMENT. The 1:1 relationship with the parent PK breaks.
4. Doing the parent and child INSERTs in different transactions.
5. An outside FK pointing at a child table. It blocks you when the type changes or another type must be referenced.
6. Not enforcing per-type required attributes in a single table. A type-conditional `CHECK` can enforce them.
7. Solving dynamic attributes with ever-growing categories through inheritance. Tables or columns explode per type. Solve it with JSON.
