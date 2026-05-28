-- =====================================================================
-- CASE 5 — OR predicates defeating index seeks → UNION ALL
-- Scenario: "Find tickets that are high priority OR assigned to me."
-- Symptom: 6.8s; OR across two different indexed columns → scan.
-- =====================================================================

-- ---------------------------------------------------------------------
-- BEFORE  (6.8s)
-- An OR spanning two columns often can't use either index as a seek;
-- the optimizer falls back to a full scan + filter.
-- ---------------------------------------------------------------------
SELECT ticket_id, subject, priority, assigned_to
FROM   dbo.Tickets
WHERE  priority = 'High'
   OR  assigned_to = 'manoj.k';

-- ---------------------------------------------------------------------
-- AFTER  (0.4s)
-- Split into two seekable branches; UNION (not UNION ALL) dedupes rows
-- that satisfy both predicates. Each branch is a clean Index Seek.
-- ---------------------------------------------------------------------
SELECT ticket_id, subject, priority, assigned_to
FROM   dbo.Tickets WHERE priority = 'High'
UNION
SELECT ticket_id, subject, priority, assigned_to
FROM   dbo.Tickets WHERE assigned_to = 'manoj.k';

CREATE INDEX IX_Tickets_Priority ON dbo.Tickets(priority)     INCLUDE (subject, assigned_to);
CREATE INDEX IX_Tickets_Assignee ON dbo.Tickets(assigned_to)  INCLUDE (subject, priority);

-- =====================================================================
-- WHY IT'S FASTER
-- A multi-column OR can't be served by a single index seek, so the
-- engine scans. Rewriting as UNION lets each arm seek its own index;
-- UNION removes duplicates where both conditions hold. (Use UNION ALL
-- only when the branches are provably disjoint.)
-- 6.8s → 0.4s  (~17x).
-- =====================================================================
