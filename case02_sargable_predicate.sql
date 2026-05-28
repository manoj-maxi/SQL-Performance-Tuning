-- =====================================================================
-- CASE 2 — Non-SARGable predicate → SARGable + index
-- Scenario: "All invoices from a given month."
-- Symptom: 9.4s; full index scan despite an index on invoice_date.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (9.4s)
-- Wrapping the column in functions makes the predicate non-SARGable:
-- the optimizer cannot seek and must scan + compute the function on
-- every row. Plan: Index Scan (all rows) + Filter.
-- ---------------------------------------------------------------------
SELECT invoice_id, customer_id, amount
FROM   dbo.Invoices
WHERE  YEAR(invoice_date) = 2025
  AND  MONTH(invoice_date) = 3;

-- Also non-SARGable (function/implicit conversion on the column):
-- WHERE CONVERT(varchar(7), invoice_date, 126) = '2025-03'

-- ---------------------------------------------------------------------
-- AFTER  (0.3s)
-- Rewrite as a half-open date range so the column is bare → seekable.
-- Plan: Index Seek on a narrow range.
-- ---------------------------------------------------------------------
SELECT invoice_id, customer_id, amount
FROM   dbo.Invoices
WHERE  invoice_date >= '2025-03-01'
  AND  invoice_date <  '2025-04-01';   -- half-open avoids time-of-day edge cases

CREATE INDEX IX_Invoices_Date
    ON dbo.Invoices (invoice_date)
    INCLUDE (customer_id, amount);      -- covering → no key lookups

-- =====================================================================
-- WHY IT'S FASTER
-- YEAR()/MONTH() on the column force a scan because the optimizer can't
-- map the function result to index key order. A bare-column range
-- predicate is SARGable, enabling an Index Seek that touches only the
-- qualifying rows. The covering INCLUDE removes key lookups.
-- 9.4s → 0.3s  (~31x).  Rule: never put a function on the column you
-- want to seek — transform the constant side instead.
-- =====================================================================
