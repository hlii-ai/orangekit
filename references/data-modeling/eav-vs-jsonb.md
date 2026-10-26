<!-- orangekit-rule-version: 3.38.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Dynamic attribute design — regular columns vs JSON vs EAV

> Scope: the principles are common to relational DBs, and the syntax is given for both PostgreSQL and MySQL 8.
> **Always think hard about a regular-column design first.** Solve with JSON **only the part** that still will not resolve.
> EAV is the **last resort**, for when JSON cannot be used, as on a legacy system.
> The concrete design, indexes, and validation of a JSON column are in [`json-columns.md`](./json-columns.md).

## Decision criteria

| Situation | Choice |
| --- | --- |
| The structure is settled. Search, sort, aggregation, FK, and NOT NULL are needed | **regular columns** |
| The type hierarchy is stable and predictable | **inheritance design** (→ [`supertype-subtype.md`](./supertype-subtype.md)) |
| Attributes differ per category. Attributes keep being added or cannot be predicted. Operators or sellers define the attributes | **core columns + JSON hybrid** |
| A legacy DB with no JSON type, or a form builder that manages the attribute definitions themselves as data | **EAV + an attribute-definition table** |

- Do not introduce JSON or EAV on a vague worry that "the attributes might change later". Use them only when **the uncertainty is certain**.
- **Never put a core attribute in the dynamic area (JSON · EAV).** An attribute that is read often, used as a search condition, and matters for integrity (price · brand · status) is a column of the main table.
  Put only supplementary attributes in the dynamic area.
- JSON beats EAV. It needs no pivot queries, it preserves types (EAV compares strings, where `'64' >= '300'` is true), it is 1 row rather than N rows per entity, and it can express nesting.
  But JSON still carries EAV's core drawback: weak DB-level integrity and no FKs. JSON is the second-best option.

## If you must use EAV — standard design

```sql
-- attribute definitions (metadata): prevents typo fragmentation · display names · per-category attribute list · dynamic form generation
CREATE TABLE attribute_definitions (
  attr_def_id   BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,  -- MySQL: AUTO_INCREMENT
  category_id   BIGINT REFERENCES categories(category_id),
  attr_name     VARCHAR(100) NOT NULL,
  attr_label    VARCHAR(100) NOT NULL,
  attr_type     VARCHAR(20)  NOT NULL CHECK (attr_type IN ('TEXT','NUMBER','DATE','BOOLEAN','SELECT')),
  is_required   BOOLEAN NOT NULL DEFAULT false,
  is_searchable BOOLEAN NOT NULL DEFAULT false,
  display_order INT     NOT NULL DEFAULT 0,
  options       VARCHAR(500),            -- choices for SELECT. If used often, normalize into a separate table
  UNIQUE (category_id, attr_name)
);

-- attribute values: typed columns keep sorting, range comparison, and indexes working
CREATE TABLE product_attributes (
  attribute_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  product_id   BIGINT NOT NULL REFERENCES products(product_id),
  attr_def_id  BIGINT NOT NULL REFERENCES attribute_definitions(attr_def_id),
  val_text     VARCHAR(255),
  val_number   NUMERIC(18,4),            -- MySQL: DECIMAL(18,4)
  val_date     DATE,
  UNIQUE (product_id, attr_def_id)       -- prevents entering the same attribute twice on the same product
);
```

- Separate the metadata (attribute definitions) from the real data (attribute values). The frontend reads `attr_type` and `is_required` to build the input form dynamically.
- The DB does not do integrity checks such as required-ness and type match. **The app validates against the definition table.**
- Surveys and form builders are legitimate EAV cases. `survey_questions` holds the definitions and `survey_responses` holds the values.

## Read procedure (EAV)

- A single-attribute search puts **both the attribute and the value** in the condition. Putting only the value mixes in the same value of other attributes.
- A multi-attribute AND search uses one `product_id IN (SELECT …)` per condition.
- To spread rows into columns, use `MAX(CASE WHEN attr_def_id = … THEN val_text END)` with `LEFT JOIN … GROUP BY`.
  If a screen ends up repeating such queries, that is a signal to move to JSON or regular columns.

## Anti-patterns

1. Introducing EAV or JSON only on a vague possibility of future change.
2. Putting core attributes (price · brand · status) in EAV or JSON.
3. Entering the `attr_name` string freely, with no attribute-definition table. Typos fragment the attributes.
4. A single string value column. Number and date comparisons become string comparisons.
5. No UNIQUE on `(entity_id, attr_def_id)`.
6. Newly designing EAV on a DB that can use JSON.
7. JSON used to dodge normalization — cramming settled-structure data into JSON (a card §4 1NF violation).
