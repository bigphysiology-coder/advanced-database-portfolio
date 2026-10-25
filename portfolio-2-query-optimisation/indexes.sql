-- ============================================================================
-- Portfolio 2: Indexes
--
-- Rule: each index below must be justified by a plan captured in
-- execution-plans.md BEFORE the index existed. An index with no measured
-- before/after is decoration, not optimisation.
--
-- Template for every index:
--
--   -- Q<n> | <what the plan showed> | <expected effect>
--   CREATE INDEX CONCURRENTLY idx_<table>_<columns>
--       ON <table> (<columns>);
--
--   Justification:
--   Before: Seq Scan, 4,812 ms, 20,000 rows filtered
--   After:  Index Scan, 12 ms
--   Cost:   ~2 MB, slight insert overhead on lab_results
-- ============================================================================

-- TODO: indexes


-- ----------------------------------------------------------------------------
-- Queries worth running during analysis (not part of the final schema)
-- ----------------------------------------------------------------------------

-- List indexes on a table and their size
-- SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass))
-- FROM pg_indexes WHERE tablename = 'lab_results';

-- Per-index usage — after the timing runs, an index with idx_scan = 0 is dead weight
-- SELECT relname, indexrelname, idx_scan, idx_tup_read
-- FROM pg_stat_user_indexes ORDER BY idx_scan;

-- Table sizes, to put timings in context
-- SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total
-- FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC;

-- Refresh planner statistics after bulk seed load — stale stats produce bad plans
-- ANALYZE;
