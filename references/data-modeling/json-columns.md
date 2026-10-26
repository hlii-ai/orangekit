<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# JSON column design

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL (`JSONB`) and MySQL 8 (`JSON`).
> **Use JSON when you need partial schema flexibility.** Keep the core structure in regular columns, and solve only the part that will not resolve with JSON.
> Avoid the temptation of "it's convenient, so just bundle it in". The regular-column vs JSON vs EAV decision is in [`eav-vs-jsonb.md`](./eav-vs-jsonb.md).

## Decision criteria

| Put it in JSON | Keep it as a regular column |
| --- | --- |
| Supplementary attributes that differ per category | Values searched or sorted often (`WHERE price BETWEEN … ORDER BY price`) |
| Attributes added so often you cannot ALTER every time | Aggregation and statistics targets (each row's JSON must be parsed, so it is slow) |
| An unpredictable schema: user-defined fields, external API responses, settings | Values that need an FK reference — **you cannot put an FK on a value inside JSON** |
| Point-in-time snapshots (product info at the time of an order), event payloads, metadata (SEO · analytics) | Core transactional data such as money and stock quantity, and fields that must be present on every row |

**Standard shape — a hybrid table**: core attributes are columns (index targets), supplementary attributes go in `attributes`, and metadata goes in `metadata`.

```sql
CREATE TABLE products (
  product_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,   -- MySQL: BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY
  name       VARCHAR(200) NOT NULL,
  category   VARCHAR(100) NOT NULL,
  brand      VARCHAR(100) NOT NULL,
  price      NUMERIC(12,0) NOT NULL,                             -- MySQL: DECIMAL(12,0)
  status     VARCHAR(20)  NOT NULL DEFAULT 'ACTIVE',
  attributes JSONB,          -- per-category supplementary attributes        MySQL: JSON
  metadata   JSONB,          -- supplementary info such as SEO and analytics   MySQL: JSON
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_products_category_brand_price ON products (category, brand, price);
```

## Standard design — read indexes

**A JSON attribute used in a search condition must have an index strategy.** Without an index it is a full scan.
When many attributes are searched often, that is a signal to promote them to regular columns.

| Goal | PostgreSQL | MySQL 8 |
| --- | --- | --- |
| Equality or range search on one attribute | an expression index `CREATE INDEX … ON products (((attributes->>'storage')::int))` | **a generated column + index (the standard)**: `ADD COLUMN v_storage INT GENERATED ALWAYS AS (attributes->'$.storage') VIRTUAL`, then `CREATE INDEX` |
| WHERE only, keeping the schema clean | same as above | a functional index (8.0.13+) `CREATE INDEX … ON products ((JSON_VALUE(attributes, '$.storage' RETURNING UNSIGNED)))` — **double parentheses and a type** are required |
| Search for an array element | GIN `CREATE INDEX … USING GIN (attributes jsonb_path_ops)` + `attributes @> '{"ports":["HDMI"]}'` | a multi-valued index (8.0.17+) `CREATE INDEX … ON products ((CAST(attributes->'$.ports' AS CHAR(20) ARRAY)))` + `'HDMI' MEMBER OF(attributes->'$.ports')`, `JSON_CONTAINS`, `JSON_OVERLAPS` |
| Search for key existence | GIN default `jsonb_ops` + `?`, `?|`, `?&` | `JSON_CONTAINS_PATH(attributes, 'one', '$.s_pen')` (no index) |

- **For a MySQL generated column, `VIRTUAL` is the standard.** An index on a VIRTUAL column is stored on disk too, so performance is the same as STORED.
  STORED duplicates storage and slows writes, so use it only for heavy computation or a PK.
- On MySQL, if you also use the value often in the SELECT list, pick a generated column; if only in WHERE, pick a functional index.
- The optimizer uses an index **only when the query expression matches the index definition's expression.** Write the query with the same path and the same type conversion as the index.
- For the PG GIN operator class, use `jsonb_path_ops` if you only do containment (`@>`) searches — the index is smaller. If you also search for key existence, use `jsonb_ops`.

## Standard design — structure validation

The JSON type validates only syntax. A price stored as a string, a typo in a key, a missing required key — all are stored. **Block required keys and types with CHECK.**
Complex validation belongs to the app schema (Zod and the like). CHECK is limited for complex validation and carries a performance overhead.

```sql
-- PostgreSQL
CONSTRAINT chk_products_attr_brand CHECK (attributes ? 'brand'),
CONSTRAINT chk_products_attr_price CHECK (jsonb_typeof(attributes->'price') = 'number')

-- MySQL 8.0.16+
CONSTRAINT chk_products_attr_brand CHECK (JSON_CONTAINS_PATH(attributes, 'one', '$.brand')),
CONSTRAINT chk_products_attr_price CHECK (JSON_CONTAINS_PATH(attributes, 'one', '$.price')
                                          AND JSON_TYPE(attributes->'$.price') = 'INTEGER')
```

## Write and read procedure

| Operation | PostgreSQL | MySQL 8 |
| --- | --- | --- |
| Extract a value (keep the JSON type) | `attributes->'price'` | `attributes->'$.price'` (= `JSON_EXTRACT`) |
| Extract a value (as a string) | `attributes->>'price'` | `attributes->>'$.price'` (quotes removed) |
| Extract with a type | `(attributes->>'price')::numeric` | `JSON_VALUE(attributes, '$.price' RETURNING DECIMAL(12,0))` |
| Partial update | `jsonb_set(attributes, '{price}', '1000')` · `attributes - 'key'` | `JSON_SET` (modify if present, add if not), `JSON_INSERT` (add only), `JSON_REPLACE` (modify only), `JSON_REMOVE`, `JSON_ARRAY_APPEND` |
| Spread an array into rows | `jsonb_to_recordset(variants) AS v(sku text, stock int)` (PG17+ can also use `JSON_TABLE`) | `JSON_TABLE(variants, '$[*]' COLUMNS (sku VARCHAR(50) PATH '$.sku', stock INT PATH '$.stock'))` |

- MySQL `->>` returns a **string**. For number and boolean comparisons use `->` or `JSON_VALUE … RETURNING`.
  Comparing numbers with `->>` becomes a string comparison where `'64' >= '300'` is true. PG's `->>` is `text` too, so cast it.
- Do not replace the whole document — use a **partial-update function**.
- Write key names in **snake_case starting with a letter**. In a MySQL path, a key that starts with a digit needs quotes (`'$."5g"'`).
- Keep the JSON size reasonable. Key strings are stored on every row, so the same data takes more space than regular columns.

## Anti-patterns

1. Putting settled-structure core data in JSON. That is dodging normalization and a card §4 1NF violation.
2. Keeping search, sort, or aggregation targets inside JSON. If aggregation is the main purpose, pull that field out into a regular column.
3. Referencing another table by an ID inside JSON. You cannot put an FK on it, so orphan references appear.
4. No index on a JSON attribute that is searched.
5. Making a generated column `STORED` on MySQL for no reason.
6. Comparing numbers or booleans on a `->>` result.
7. Validating required keys and types nowhere (neither CHECK nor an app schema).
8. Reading the whole document, editing it, and overwriting it wholesale. Concurrent updates overwrite each other and the write cost grows.
9. Key names that start with a digit or contain spaces.
