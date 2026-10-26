-- ============================================================================
-- Portfolio 2: Indexes
-- Case study: Riverbend Teaching Hospital
--
-- Rule: each index below is justified by a plan captured before it existed.
-- The raw before/after output is in results/baseline.txt and results/after.txt;
-- the analysis is in execution-plans.md.
--
-- Apply with psql, not inside a transaction:
--   docker compose exec -T postgres psql -U portfolio -d hospital \
--       -v ON_ERROR_STOP=1 -f /path/to/indexes.sql
--
-- CREATE INDEX CONCURRENTLY cannot run inside a transaction block, so this
-- file has no BEGIN/COMMIT. IF NOT EXISTS makes it safe to re-run.
--
-- Measurement method: capture-plans.ps1 runs each query N times (21 for the
-- final capture, 5 for the incremental captures); summarise-plans.ps1 discards
-- the first (cold) run and reports the median of the rest. The times quoted
-- below are those medians.
--
-- Index footprint at 82,000 appointments / 163,000 lab results:
--   ix_encounter_patient_started      2,504 kB
--   ix_prescription_encounter         3,056 kB
--   ix_lab_order_encounter            2,496 kB
--   ix_appointment_slot_start         3,992 kB
--   ix_lab_order_urgent_ordered_at      552 kB
--   ix_appointment_patient_start      3,272 kB
--   ix_diagnosis_icd_encounter        4,576 kB
--   ------------------------------------------
--   total                            ~20.4 MB on a 312 MB database (~6.5%)
-- ============================================================================


-- ----------------------------------------------------------------------------
-- Q1. Patient clinical history
--
-- The plan showed: one patient is found by mrn, but the two correlated
-- subqueries below then re-scan prescription and lab_order once per encounter.
-- With four encounters that is four sequential scans of 125,176 prescriptions
-- and 93,885 lab orders: 15,321 shared buffers and 197.5 ms to return 4 rows.
--
-- Three indexes are needed because the query touches three different tables.
-- They were added one at a time so the effect of each is visible; the medians
-- below are from separate five-run captures in results/q1-after-*.txt.
-- ----------------------------------------------------------------------------

-- Step 1 of 3: find one patient's encounters without scanning 62,588 rows.
-- Before: Seq Scan on encounter, 62,588 rows, 197.5 ms overall.
-- After:  Bitmap Index Scan, 4 rows; overall 178.2 ms. The modest gain proves
--         the encounter scan was not the dominant cost.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_encounter_patient_started
    ON encounter (patient_id, started_at DESC);

-- Step 2 of 3: count prescriptions per encounter from the index, not the heap.
-- Before: four Seq Scans on prescription (125,176 rows each).
-- After:  Index Only Scan, 2 rows per encounter; overall 178.2 -> 82.0 ms.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_prescription_encounter
    ON prescription (encounter_id);

-- Step 3 of 3: the same for lab orders. This is the last sequential scan in
-- the query, so removing it is what finally collapses the runtime.
-- Before: four Seq Scans on lab_order (93,885 rows each).
-- After:  Index Only Scan, 1-2 rows per encounter; overall 82.0 -> 0.78 ms
--         in the incremental capture, 0.60 ms in the final all-query capture.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_lab_order_encounter
    ON lab_order (encounter_id);


-- ----------------------------------------------------------------------------
-- Q2. Appointment load per doctor, last complete week
--
-- The plan showed: Seq Scan on appointment, 82,000 rows read, 77,100 removed
-- by the date filter, 63.7 ms of the 76.5 ms total and 1,481 shared buffers.
-- Only 4,900 rows (6%) survive.
--
-- A range scan on slot_start fixes the access path. doctor_id and status are
-- included so the aggregation never visits the heap: the plan becomes an
-- Index Only Scan with Heap Fetches: 0 (the seed runs VACUUM, which sets the
-- visibility map that an index-only scan depends on).
--
-- Before: 76.5 ms, 1,481 buffers, Seq Scan.
-- After:  18.9 ms in the final 21-run capture; 17.4 ms when measured alone.
--         The two agree. A repeat capture under 68% host CPU load measured
--         31.3 ms with the same plan and buffer count, which shows how much
--         the 2-core Docker host moves. The I/O fell from 1,481 buffers to 36.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_appointment_slot_start
    ON appointment (slot_start) INCLUDE (doctor_id, status);


-- ----------------------------------------------------------------------------
-- Q3. Urgent laboratory turnaround by ordering department
--
-- The plan showed: Seq Scan on lab_order, 93,885 rows read, 85,571 removed by
-- the three predicates, 61 ms and 1,336 buffers. Only 8,314 rows (8.9%) are
-- both urgent and reported.
--
-- A partial index stores only the rows the report can ever use. ordered_at is
-- the range key; collected_at, reported_at and ordered_by are included so the
-- aggregate, the percentile_cont sort and the join to staff all read the index
-- only. The predicate is written exactly as the query writes it
-- (priority = 'URGENT' AND reported_at IS NOT NULL) so the planner can prove
-- the index applies.
--
-- Before: 135.4 ms, 1,336 buffers, Seq Scan.
-- After:  48.7 ms, 66 buffers, Index Only Scan, Heap Fetches: 0. What remains
--         is the sort by department plus percentile_cont over 8,314 groups.
--         The index is 552 kB, the smallest one added, because it indexes 9%
--         of the table.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_lab_order_urgent_ordered_at
    ON lab_order (ordered_at) INCLUDE (collected_at, reported_at, ordered_by)
    WHERE priority = 'URGENT' AND reported_at IS NOT NULL;


-- ----------------------------------------------------------------------------
-- Q4. Patients with no appointment in the last 12 months
--
-- The plan showed: Seq Scan on appointment, 82,000 rows read, 12,000 removed
-- by the date filter, 82 ms of the 193 ms total. The anti-join itself is not
-- the problem; reading and discarding the future appointments is.
--
-- The index is (patient_id, slot_start) rather than (slot_start, patient_id)
-- because the anti-join probes by patient_id. slot_start is the second column
-- so the range predicate is still checked inside the index and the scan stays
-- index-only.
--
-- Before: 193.3 ms, 1,969 buffers.
-- After:  133.0 ms, 895 buffers, Index Only Scan, Heap Fetches: 0.
--         This is the smallest relative improvement (1.5x) because 70,000 of
--         the 82,000 appointments are inside the 12-month window: the index
--         removes the 12,000-row filter and the heap reads, but the hash
--         anti-join and the final sort still process 70,000 rows. The buffer
--         traffic falls by 2.2x; the wall-clock gain is smaller and is the
--         measurement most affected by host noise (122-199 ms across captures
--         with this same plan).
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_appointment_patient_start
    ON appointment (patient_id, slot_start);


-- ----------------------------------------------------------------------------
-- Q5. Top 10 diagnoses by frequency this year
--
-- The plan showed: Seq Scan on diagnosis, 93,885 rows, then a Sort of 93,885
-- rows that spilled 5,888 kB to disk ("external merge Disk: 5888kB"), with
-- 736 temp blocks read. Total 1,018 ms. The heap scan alone was only about
-- 92 ms; the disk sort and the count(DISTINCT encounter_id) were the cost.
--
-- The covering index (icd_code, encounter_id) INCLUDE (diagnosed_at) lets the
-- planner walk the data already ordered by icd_code, so the group aggregate
-- uses an Incremental Sort instead of a full external merge. count(DISTINCT)
-- is still required because one encounter can carry the same code twice, so
-- the encounter_id must be in the index, not just counted from the heap.
--
-- Before: 1,018.2 ms, 5,888 kB spilled to disk, 1,012 buffers.
-- After:  303.4 ms, no temp blocks, 627 buffers, Index Only Scan with
--         Heap Fetches: 0. The sort now peaks at 1,663 kB in memory.
--
-- Note: rewriting the query with SELECT DISTINCT was tried first. Without an
-- index it ran at 377 ms, but it then blocked the covering-index plan and was
-- slower than the original query plus this index. See execution-plans.md.
CREATE INDEX CONCURRENTLY IF NOT EXISTS ix_diagnosis_icd_encounter
    ON diagnosis (icd_code, encounter_id) INCLUDE (diagnosed_at);


-- ----------------------------------------------------------------------------
-- Q6. Double-booking audit
--
-- No index is added. This is deliberate, and it is the most useful negative
-- result in the portfolio.
--
-- The original query was a range self-join:
--
--   JOIN appointment b
--     ON b.doctor_id = a.doctor_id
--    AND tstzrange(b.slot_start, b.slot_end, '[)')
--     && tstzrange(a.slot_start, a.slot_end, '[)')
--
-- It returned no rows, but cost 646 ms: the GiST exclusion index was probed
-- once for each of the 11,800 live appointments (57,300 shared buffers).
--
-- Rewriting it as a window function that compares each appointment with the
-- maximum end of all earlier appointments for the same doctor reduced it to
-- 55.9 ms in the 21-run final capture (43.9 ms when run alone), with no new
-- index. The rewrite changes the complexity from O(n * index probes) to
-- O(n log n) for one sort. An index cannot make a self-join cheaper when the
-- join itself is unnecessary.
--
-- A candidate B-tree WAS measured and rejected:
--
--   CREATE INDEX ... ON appointment (doctor_id, slot_start)
--       INCLUDE (appointment_id, slot_end)
--       WHERE status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS');
--
-- It produced an Index Only Scan plus an Incremental Sort at 29-72 ms across
-- six runs (median ~44 ms), against 43.9 ms for the rewrite alone in an
-- isolated five-run capture. There is no measurable benefit: the WindowAgg over
-- 11,800 rows dominates once the scan is cheap. The index is also 808 kB of
-- extra write maintenance on the busiest table in the system, for a query that
-- runs once a night. Rejected on cost/benefit, not on a failed plan.
--
-- The Q2 index (ix_appointment_slot_start) is sufficient for Q6: the planner
-- uses it to fetch the 60-day window, then sorts 11,800 rows once. Q6's final
-- median is 55.9 ms in the all-query capture and 43.9 ms when run alone; both
-- are within the host's variance and far below the 646 ms self-join.
-- ----------------------------------------------------------------------------


-- Refresh planner statistics after the bulk index builds. CREATE INDEX does
-- not update column statistics; ANALYZE makes the new indexes visible to the
-- planner with accurate estimates on the next query.
ANALYZE encounter;
ANALYZE prescription;
ANALYZE lab_order;
ANALYZE appointment;
ANALYZE diagnosis;


-- ----------------------------------------------------------------------------
-- Diagnostic queries used during the analysis (not part of the schema)
-- ----------------------------------------------------------------------------

-- List indexes on a table and their size.
-- SELECT indexname, pg_size_pretty(pg_relation_size(indexname::regclass)) AS size
-- FROM pg_indexes WHERE schemaname = 'public' AND tablename = 'appointment';

-- Per-index usage. An index with idx_scan = 0 after the timing runs is dead
-- weight; check this again after a week of production traffic, not after a
-- benchmark that deliberately runs the queries it was built for.
-- SELECT relname, indexrelname, idx_scan, idx_tup_read
-- FROM pg_stat_user_indexes ORDER BY idx_scan;

-- Table and index sizes, to put timings in context.
-- SELECT relname, pg_size_pretty(pg_total_relation_size(relid)) AS total
-- FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC;

-- Confirm the partial index is actually smaller than the full column would be.
-- SELECT pg_size_pretty(pg_relation_size('ix_lab_order_urgent_ordered_at'));
