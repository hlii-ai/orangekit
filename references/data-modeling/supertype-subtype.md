<!-- orangekit-rule-version: 3.25.0 · this file is canonical. Parent card: .claude/rules/data-modeling.md -->

# Supertype/subtype (inheritance) design

> **Boundary**: use inheritance design for a **stable, predictable type hierarchy**. If the attributes are dynamic and unpredictable, use JSONB from [`eav-vs-jsonb.md`](./eav-vs-jsonb.md).

**Default: the joined strategy** (parent + child tables sharing a PK, 1:1). With few subtypes and few unique attributes, a single table is also acceptable.

| strategy                 | structure                                                   | advantages                                         | disadvantages                                        | when to apply                                            |
| ------------------------ | ----------------------------------------------------------- | -------------------------------------------------- | ---------------------------------------------------- | -------------------------------------------------------- |
| **joined strategy** (Joined) | parent table (shared attributes) + child table (unique attributes), PK shared as an FK | normalized · NOT NULL possible · FK possible · easy to extend | a JOIN is needed for detail reads · two INSERTs | many subtypes or more expected · many unique attributes · integrity matters |
| **single table** (Single) | one table + a `type` discriminator column, unique attributes nullable | best read performance (no JOIN) · simple queries · FK possible | many NULLs · NOT NULL impossible (unique attributes) · table bloat | few, fixed subtypes · few unique attributes · performance first |

**The core of the joined strategy**: the child table's PK is an FK referencing the parent table's PK (a 1:1 relationship). `FOREIGN KEY (product_id) REFERENCES product(product_id)`. List reads hit the parent table only; detail reads use a `LEFT JOIN`.

**Table-per-Concrete-Class is forbidden**: each child holding a duplicate copy of the shared attributes. ①a `UNION ALL` is needed for a full read ②FKs cannot be set ③changing a shared attribute means changing every table — it is not used in practice.

**Selection criteria**: ①large differences between types and many unique attributes → the joined strategy ②small differences and few unique attributes → a single table ③attributes change dynamically or categories keep growing → JSONB from [`eav-vs-jsonb.md`](./eav-vs-jsonb.md) (not a target for inheritance design)
