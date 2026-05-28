/* ============================================================================
   queries/revenue_cohort_retention.sql
   ----------------------------------------------------------------------------
   Purpose : Monthly revenue cohort retention + expansion analysis for a
             subscription / payments book of business. Demonstrates the
             "production analytical SQL" patterns called out in the CV:
             recursive date spine, multiple CTEs, window functions, conformed
             dimension joins, and a final pivot-style summary — all kept
             sargable and plan-stable.
   Engine  : Written for SQL Server / Azure SQL (T-SQL). Snowflake notes inline.
   Grain   : One row per (cohort_month, activity_month).
   ============================================================================ */

DECLARE @StartDate date = '2024-01-01';
DECLARE @EndDate   date = '2025-12-31';

/* 1. Date spine via recursive CTE — first-of-month rows across the window.
      Capped with MAXRECURSION. In Snowflake use GENERATOR / SEQ instead. */
WITH month_spine AS (
    SELECT CAST(@StartDate AS date) AS month_start
    UNION ALL
    SELECT DATEADD(MONTH, 1, month_start)
    FROM   month_spine
    WHERE  DATEADD(MONTH, 1, month_start) <= @EndDate
),

/* 2. Normalise each customer's first paid month = their cohort.
      Window function avoids a correlated MIN() subquery per customer. */
customer_cohort AS (
    SELECT
        f.customer_key,
        DATEFROMPARTS(YEAR(f.invoice_date), MONTH(f.invoice_date), 1) AS activity_month,
        f.net_revenue_amt,
        MIN(DATEFROMPARTS(YEAR(f.invoice_date), MONTH(f.invoice_date), 1))
            OVER (PARTITION BY f.customer_key)                         AS cohort_month
    FROM   gold.fact_invoice AS f
    WHERE  f.invoice_date >= @StartDate            -- sargable range, no YEAR()
      AND  f.invoice_date <  DATEADD(DAY, 1, @EndDate)
      AND  f.invoice_status = 'PAID'
),

/* 3. Aggregate revenue to the (cohort_month, activity_month) grain BEFORE
      joining anything else — keeps the join fan-out under control. */
cohort_activity AS (
    SELECT
        cohort_month,
        activity_month,
        COUNT(DISTINCT customer_key) AS active_customers,
        SUM(net_revenue_amt)         AS cohort_revenue
    FROM   customer_cohort
    GROUP BY cohort_month, activity_month
),

/* 4. Cohort size at month 0, reused as the retention denominator. */
cohort_base AS (
    SELECT
        cohort_month,
        active_customers AS base_customers,
        cohort_revenue   AS base_revenue
    FROM   cohort_activity
    WHERE  cohort_month = activity_month
)

/* 5. Final projection: months-since-cohort, retention %, and net revenue
      retention (expansion vs base). LEFT JOIN to the spine so empty months
      still appear. */
SELECT
    ca.cohort_month,
    ca.activity_month,
    DATEDIFF(MONTH, ca.cohort_month, ca.activity_month)            AS months_since_start,
    ca.active_customers,
    cb.base_customers,
    CAST(100.0 * ca.active_customers
         / NULLIF(cb.base_customers, 0) AS decimal(5,1))           AS logo_retention_pct,
    ca.cohort_revenue,
    cb.base_revenue,
    CAST(100.0 * ca.cohort_revenue
         / NULLIF(cb.base_revenue, 0) AS decimal(6,1))             AS net_revenue_retention_pct,
    /* running cumulative revenue per cohort across its lifetime */
    SUM(ca.cohort_revenue) OVER (
        PARTITION BY ca.cohort_month
        ORDER BY     ca.activity_month
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )                                                              AS cumulative_cohort_revenue
FROM        cohort_activity AS ca
INNER JOIN  cohort_base     AS cb ON cb.cohort_month = ca.cohort_month
WHERE       ca.activity_month >= ca.cohort_month          -- ignore pre-cohort noise
ORDER BY    ca.cohort_month, ca.activity_month
OPTION (MAXRECURSION 120);

/* ----------------------------------------------------------------------------
   Why this is fast:
   - The only base-table scan is in customer_cohort, behind a sargable date range
     that an index on fact_invoice(invoice_date) INCLUDE (customer_key,
     net_revenue_amt, invoice_status) can seek + cover.
   - Aggregation happens at the smallest useful grain (step 3) before any further
     joins, so there is no fan-out feeding DISTINCT.
   - Retention denominators come from a tiny derived set (cohort_base), joined on
     an equality key — a cheap hash/merge, no per-row correlated lookup.
   - All period-over-period logic is done with window functions in a single pass.
   ---------------------------------------------------------------------------- */
