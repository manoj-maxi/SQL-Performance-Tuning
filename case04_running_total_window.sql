-- =====================================================================
-- CASE 4 — Running total via self-join → window frame
-- Scenario: "Daily cumulative sales by store, year to date."
-- Symptom: 31s; classic triangular self-join.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (31.0s)
-- The self-join matches every row to all prior rows (triangular join),
-- producing ~N^2/2 intermediate rows before aggregation.
-- ---------------------------------------------------------------------
SELECT
    a.store_id,
    a.sales_date,
    a.daily_sales,
    SUM(b.daily_sales) AS running_total
FROM dbo.DailySales a
JOIN dbo.DailySales b
      ON b.store_id = a.store_id
     AND b.sales_date <= a.sales_date
GROUP BY a.store_id, a.sales_date, a.daily_sales;

-- ---------------------------------------------------------------------
-- AFTER  (0.9s)
-- Window running total — one ordered pass per partition.
-- ---------------------------------------------------------------------
SELECT
    store_id,
    sales_date,
    daily_sales,
    SUM(daily_sales) OVER (
        PARTITION BY store_id
        ORDER BY     sales_date
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM dbo.DailySales;

CREATE INDEX IX_DailySales_Store_Date
    ON dbo.DailySales (store_id, sales_date) INCLUDE (daily_sales);

-- =====================================================================
-- WHY IT'S FASTER
-- The self-join's cost grows quadratically with rows per store. The
-- window frame computes the cumulative sum in a single ordered scan.
-- Explicitly stating ROWS (not the default RANGE) also avoids the
-- slower RANGE window-spool behavior.
-- 31.0s → 0.9s  (~34x).
-- =====================================================================
