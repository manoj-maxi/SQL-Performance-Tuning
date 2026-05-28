# SQL Performance Tuning

> I worked on real-world SQL optimization cases With the —> complex joins, CTEs, window functions, and query tuning — that whcih each shown as a **before / after** pair with the execution-plan reasoning and the measured improvement. 
Dialect: T-SQL (SQL Server / Azure SQL) with Snowflake notes where relevant.

![SQL](https://img.shields.io/badge/SQL-T--SQL%20%7C%20Snowflake-blue)
![Tuning](https://img.shields.io/badge/Focus-Query%20Optimization-orange)

---

## Cases I Used

| # | Problem | Technique | Result |
|---|---------|-----------|--------|
| 1 | Correlated subquery per row | Rewrite to window function | 18s → 1.2s |
| 2 | Non-SARGable predicate (function on column) | Make predicate SARGable + index | 9.4s → 0.3s |
| 3 | `DISTINCT` masking a fan-out join | Fix join grain with pre-aggregation CTE | 22s → 2.1s |
| 4 | Running total via self-join | `SUM() OVER (...)` window frame | 31s → 0.9s |
| 5 | `OR` predicates defeating index seeks | `UNION ALL` of seekable branches | 6.8s → 0.4s |
| 6 | Missing covering index + key lookups | Covering index with `INCLUDE` | 4.1s → 0.2s |

Each case lives in [`before-after/`](before-after/) with both queries and the analysis. The reusable patterns are summarized in [`docs/tuning-playbook.md`](docs/tuning-playbook.md).

## How I read a case
As presents-->Each file has four sections:
1. **Scenario** — the business query and the symptom.
2. **Before** — the slow query + what the plan shows (scan, spool, key lookup, etc.).
3. **After** — the rewritten query + the structural index change.
4. **Why it's faster** — the plan difference and the measured timing.

## Headline techniques
- **Window functions** replace correlated subqueries and self-joins — one pass instead of N.
- **SARGability** — never wrap an indexed column in a function; rewrite so the optimizer can seek.
- **Join-grain discipline** — `DISTINCT` is usually a symptom of an accidental fan-out; fix the grain instead.
- **Covering indexes** — eliminate key lookups with `INCLUDE` columns.
- **Predicate shape** — split `OR` into `UNION ALL` of index-seekable branches.

> My real tuning work with : CTEs, recursive CTEs, window functions, execution-plan analysis, and indexing across Snowflake, SQL Server, Oracle, and Azure SQL — with documented 30–60% latency reductions on production reporting workloads.
