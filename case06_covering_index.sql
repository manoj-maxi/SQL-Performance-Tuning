-- =====================================================================
-- CASE 6 — Key lookups → covering index with INCLUDE
-- Scenario: "List recent orders for a status, with amount and customer."
-- Symptom: 4.1s; index seek BUT thousands of key lookups.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (4.1s)
-- Index on (status, order_date) seeks fine, but the SELECT needs columns
-- not in the index → one Key Lookup per row into the clustered index.
-- Plan: Index Seek + Key Lookup (Nested Loops), high logical reads.
-- ---------------------------------------------------------------------
SELECT order_id, order_date, customer_id, amount
FROM   dbo.Orders
WHERE  status = 'SHIPPED'
  AND  order_date >= '2025-01-01'
ORDER BY order_date DESC;

-- existing: CREATE INDEX IX_Orders_Status_Date ON dbo.Orders(status, order_date);

-- ---------------------------------------------------------------------
-- AFTER  (0.2s)
-- Make the index covering: add the SELECT columns as INCLUDE so the
-- query is answered entirely from the index — no lookups.
-- ---------------------------------------------------------------------
CREATE INDEX IX_Orders_Status_Date_Covering
    ON dbo.Orders (status, order_date DESC)
    INCLUDE (customer_id, amount);

-- (same query, now Index Seek only)
SELECT order_id, order_date, customer_id, amount
FROM   dbo.Orders
WHERE  status = 'SHIPPED'
  AND  order_date >= '2025-01-01'
ORDER BY order_date DESC;

-- =====================================================================
-- WHY IT'S FASTER
-- Each key lookup is a random read into the clustered index; thousands
-- of them dominate the cost. INCLUDE-ing the needed columns makes the
-- nonclustered index "covering", so the seek alone returns everything.
-- Ordering the key as order_date DESC also satisfies the ORDER BY
-- without a Sort.
-- 4.1s → 0.2s  (~20x), logical reads down ~95%.
-- =====================================================================
