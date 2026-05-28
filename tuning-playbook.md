# SQL Performance Tuning Playbook

> A practitioner's checklist distilled from tuning analytical and reporting
> workloads across **Snowflake, Azure SQL, SQL Server, and Oracle** that feed
> Power BI / Fabric semantic models. The goal is not "clever SQL" — it is
> predictable, plan-stable queries that keep dashboards inside their refresh and
> interaction SLAs.

---

## 0. Method — measure before you touch anything

1. **Capture the actual plan, not the estimated one.** In SQL Server use
   `SET STATISTICS IO, TIME ON` plus the actual execution plan; in Snowflake use
   the Query Profile; in Azure SQL use Query Store. Estimated plans lie when
   statistics are stale.
2. **Record a baseline**: elapsed time, logical reads, spills to tempdb / remote
   disk, and rows-read vs rows-returned. Every change is judged against this.
3. **Change one thing at a time.** Re-measure. Keep the before/after pair — those
   pairs are exactly what the [`before-after/`](../before-after/) folder holds.
4. **Validate row counts and checksums** before and after. A faster query that
   returns different numbers is a regression, not a win.

---

## 1. The biggest wins, in order of frequency

| # | Symptom in the plan | Root cause | Fix |
|---|---------------------|------------|-----|
| 1 | Index Scan where a Seek was expected | Non-sargable predicate (function on the column, leading `%` wildcard, implicit conversion) | Rewrite predicate so the column is bare; fix the data type — see `case02` |
| 2 | High rows-read vs rows-returned, repeated executions of an inner subtree | Correlated subquery evaluated per outer row | Convert to a window function or a single grouped join — see `case01`, `case04` |
| 3 | Eager Spool / huge sort feeding a `DISTINCT` | Join fan-out then de-dup | Aggregate at the right grain or use `EXISTS`; never paper over fan-out with `DISTINCT` — see `case03` |
| 4 | Key Lookup running thousands of times | Non-covering index | Add the needed columns as `INCLUDE` to make the index covering — see `case06` |
| 5 | Index Scan with an `OR` across different columns | `OR` defeats a single seek | Split into `UNION`-ed seekable branches — see `case05` |
| 6 | Hash Match spilling to tempdb | Bad cardinality estimate / stale stats | Update statistics, then consider the join order; spills mean memory grant was too small |

---

## 2. Make predicates sargable (Search-ARGument-able)

A predicate is sargable when the optimizer can use an index seek on it. The
column must appear **alone** on one side of the comparison.

- ❌ `WHERE YEAR(order_date) = 2025` → ✅ `WHERE order_date >= '2025-01-01' AND order_date < '2026-01-01'`
- ❌ `WHERE CAST(account_id AS varchar) = '4471'` → fix the literal's type instead so no conversion is needed
- ❌ `WHERE customer_name LIKE '%corp'` (leading wildcard) → unavoidable scan; consider a reversed-string computed column or full-text index
- ❌ `WHERE ISNULL(status,'X') = 'A'` → ✅ `WHERE status = 'A'` (handle the NULL branch separately if it matters)

Implicit conversion is the silent killer: a `WHERE nvarchar_col = N'123'` against
an `int` column forces a column-side `CONVERT` and kills the seek. Match literal
types to column types.

---

## 3. Replace correlated subqueries and self-joins with window functions

Correlated subqueries (a `SELECT` in the `WHERE`/`SELECT` that references the
outer row) and "join the table to itself to get the previous row" patterns both
re-scan data. Window functions do it in a single pass.

- "Latest row per group" → `ROW_NUMBER() OVER (PARTITION BY k ORDER BY ts DESC)` then filter `= 1`
- "Running total" → `SUM(x) OVER (PARTITION BY k ORDER BY d ROWS UNBOUNDED PRECEDING)` — see `case04`
- "Row's value vs group average / max" → `AVG(x) OVER (PARTITION BY k)` instead of a correlated aggregate — see `case01`
- "Compare to previous period" → `LAG()/LEAD()` instead of a self-join on `d = d-1`

Window functions need a supporting index on `(partition_key, order_key)` to avoid
a sort; otherwise the sort can dominate the cost.

---

## 4. CTEs, temp tables, and materialization

- A CTE is **not** a materialized result in SQL Server / Azure SQL — it is
  inlined and can be evaluated multiple times if referenced more than once. If a
  CTE is referenced repeatedly and is expensive, materialize it into a
  `#temp` table with appropriate statistics.
- Recursive CTEs are fine for hierarchies (org charts, BOM, date spines) but cap
  them with `OPTION (MAXRECURSION n)` and ensure the anchor/recursive members are
  seekable.
- In Snowflake, the result cache and automatic materialized views change this
  calculus — prefer a clustered base table or a materialized view over hand-rolled
  temp tables; let the optimizer prune micro-partitions.

---

## 5. Indexing strategy for analytical workloads

1. **Seek path first.** The leading column(s) of the index should match the most
   selective equality predicates; range predicates go last.
2. **Covering indexes** eliminate Key Lookups: put filter/join columns in the key,
   and `SELECT`-list-only columns in `INCLUDE`. See `case06`.
3. **Columnstore for large fact tables.** For star-schema facts over a few million
   rows feeding aggregations, a clustered columnstore index typically beats rowstore
   by an order of magnitude on scans and gives segment elimination.
4. **Don't over-index OLTP sources.** Every nonclustered index is a write cost.
   For source systems, prefer pushing heavy analytics to a replica / lakehouse.
5. **Maintain statistics.** Stale stats produce bad estimates → bad memory grants →
   spills. Schedule stats updates; enable `AUTO_UPDATE_STATISTICS`.

---

## 6. Snowflake-specific levers

- **Pruning** is everything: cluster large tables on the columns you filter on most
  (often a date), and check `partitions_scanned` vs `partitions_total` in the Query
  Profile.
- Avoid `SELECT *` from wide tables — Snowflake is columnar, so reading unused
  columns is wasted I/O.
- Watch for **exploding joins** (the Profile shows output rows ≫ input rows): a
  missing join key or a many-to-many that should have been de-duplicated upstream.
- Right-size the **warehouse**: a query that spills to remote disk needs a larger
  warehouse for that workload, not a rewrite. Spilling shows in the Profile as
  "Bytes spilled to local/remote storage".
- Use **result cache** and **materialized views** for repeated dashboard queries.

---

## 7. How this connects to Power BI / Fabric

The SQL layer is the foundation under the semantic model. Tuning here pays off in
three places:

- **Import / Incremental Refresh** — faster source queries mean shorter refresh
  windows and smaller refresh failures blast-radius.
- **DirectQuery / Direct Lake** — every visual generates SQL; a non-sargable
  predicate or a fan-out turns a "fast" report into a slow one. Fold transformations
  to the source and keep the model's queries seekable.
- **Aggregations** — pre-aggregated tables only help if the underlying aggregate
  query is itself efficient and the grain is right (see `case03`).

---

## 8. Pre-flight checklist before shipping a query

- [ ] Actual plan reviewed; no unexpected scans, spools, or eager spools
- [ ] Predicates are sargable; no functions/conversions on indexed columns
- [ ] `rows-read ≈ rows-returned` (no silent fan-out)
- [ ] No `DISTINCT` masking a join problem
- [ ] Window functions have a supporting index (no avoidable sort)
- [ ] Statistics current; memory grant not spilling to tempdb / remote disk
- [ ] Row counts and a checksum match the pre-change baseline
- [ ] (Snowflake) partition pruning is effective; no exploding joins
