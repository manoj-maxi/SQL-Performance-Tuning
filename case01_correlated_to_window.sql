-- =====================================================================
-- CASE 1 — Correlated subquery → Window function
-- Scenario: "For each order line, show the line amount and that
-- customer's running total of all order lines up to this order date."
-- Symptom: query ran 18s on ~12M order lines; CPU-bound.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (18.0s)
-- The correlated subquery re-scans Orders for every outer row → O(N^2).
-- Plan: outer Index Scan + per-row inner aggregate (Nested Loops + Stream Aggregate),
--       millions of executions of the inner branch.
-- ---------------------------------------------------------------------
SELECT
    o.order_line_id,
    o.customer_id,
    o.order_date,
    o.line_amount,
    (   SELECT SUM(o2.line_amount)
        FROM   dbo.OrderLines o2
        WHERE  o2.customer_id = o.customer_id
          AND  o2.order_date <= o.order_date
    ) AS running_total
FROM dbo.OrderLines o;

-- ---------------------------------------------------------------------
-- AFTER  (1.2s)
-- Single pass with a windowed running total. The frame
-- ROWS UNBOUNDED PRECEDING computes the cumulative sum in order.
-- Plan: one Index Scan + Window Aggregate (Segment + Window Spool),
--       no per-row re-scan.
-- ---------------------------------------------------------------------
SELECT
    o.order_line_id,
    o.customer_id,
    o.order_date,
    o.line_amount,
    SUM(o.line_amount) OVER (
        PARTITION BY o.customer_id
        ORDER BY     o.order_date, o.order_line_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS running_total
FROM dbo.OrderLines o;

-- Supporting index so the window's PARTITION/ORDER is pre-sorted:
CREATE INDEX IX_OrderLines_Cust_Date
    ON dbo.OrderLines (customer_id, order_date, order_line_id)
    INCLUDE (line_amount);

-- =====================================================================
-- WHY IT'S FASTER
-- The correlated subquery executes the inner aggregate once per outer
-- row (~12M times). The window function reads the data once and
-- streams a cumulative aggregate. With the covering index the input is
-- already ordered, so the Window Aggregate avoids an explicit Sort.
-- 18.0s → 1.2s  (~15x), CPU dropped ~90%.
-- =====================================================================
