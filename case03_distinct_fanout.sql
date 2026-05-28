-- =====================================================================
-- CASE 3 — DISTINCT masking a join fan-out → pre-aggregate CTE
-- Scenario: "Customer revenue and number of distinct products bought."
-- Symptom: 22s; someone added DISTINCT to "fix" duplicated rows.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (22.0s)
-- Joining Orders to OrderLines fans out the order header, so SUM double
-- counts; DISTINCT was bolted on to dedupe. DISTINCT over a huge,
-- already-exploded result is expensive (big Hash/Sort Distinct) AND the
-- SUM is still wrong-grain before dedupe.
-- ---------------------------------------------------------------------
SELECT DISTINCT
    c.customer_id,
    c.customer_name,
    SUM(ol.line_amount) OVER (PARTITION BY c.customer_id)  AS total_revenue,
    COUNT(ol.product_id) OVER (PARTITION BY c.customer_id) AS product_count
FROM dbo.Customers  c
JOIN dbo.Orders     o  ON o.customer_id = c.customer_id
JOIN dbo.OrderLines ol ON ol.order_id  = o.order_id;

-- ---------------------------------------------------------------------
-- AFTER  (2.1s)
-- Aggregate at the correct grain FIRST in a CTE, then join 1:1.
-- No fan-out, no DISTINCT. Plan: aggregate then a clean hash join.
-- ---------------------------------------------------------------------
WITH cust_rollup AS (
    SELECT
        o.customer_id,
        SUM(ol.line_amount)            AS total_revenue,
        COUNT(DISTINCT ol.product_id)  AS product_count
    FROM dbo.Orders     o
    JOIN dbo.OrderLines ol ON ol.order_id = o.order_id
    GROUP BY o.customer_id
)
SELECT
    c.customer_id,
    c.customer_name,
    r.total_revenue,
    r.product_count
FROM dbo.Customers c
JOIN cust_rollup   r ON r.customer_id = c.customer_id;

-- =====================================================================
-- WHY IT'S FASTER
-- The original explodes to (orders × lines) rows, then forces a global
-- DISTINCT to undo it — paying twice. Pre-aggregating in the CTE
-- collapses to one row per customer BEFORE joining the dimension, so
-- the final join is 1:1 and DISTINCT disappears. COUNT(DISTINCT) is now
-- computed at the right grain instead of via window over duplicates.
-- 22.0s → 2.1s  (~10x). Rule: DISTINCT in an aggregate query is usually
-- a fan-out smell — fix the grain, don't dedupe the symptom.
-- =====================================================================
