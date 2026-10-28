-- ============================================================================
-- Portfolio 4: the relational side of the comparison.
--
-- These are the PostgreSQL equivalents of selected MongoDB queries in
-- queries.js. They run against the same seeded database and the indexes added
-- in Portfolio 2. Timings are printed by psql's \timing; the EXPLAIN output is
-- there to show why the relational reads need joins.
--
-- The first execution of each block pays for reading the tables into shared
-- buffers. Later executions are the warm numbers quoted in model-design.md.
--
-- Run:
--   psql -U portfolio -d hospital -f compare-postgres.sql
-- ============================================================================

\pset pager off
\pset footer off
\timing on

\echo ''
\echo '=== PG-Q1. One patient''s lab history (MRN-0003927), three runs ==='
SELECT lo.lab_order_id,
       lo.test_code,
       lo.status,
       lo.collected_at,
       lo.reported_at,
       count(lr.lab_result_id) AS result_count
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
LEFT JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
WHERE p.mrn = 'MRN-0003927'
GROUP BY lo.lab_order_id, lo.test_code, lo.status, lo.collected_at, lo.reported_at
ORDER BY lo.collected_at DESC;
SELECT lo.lab_order_id,
       lo.test_code,
       lo.status,
       lo.collected_at,
       lo.reported_at,
       count(lr.lab_result_id) AS result_count
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
LEFT JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
WHERE p.mrn = 'MRN-0003927'
GROUP BY lo.lab_order_id, lo.test_code, lo.status, lo.collected_at, lo.reported_at
ORDER BY lo.collected_at DESC;
SELECT lo.lab_order_id,
       lo.test_code,
       lo.status,
       lo.collected_at,
       lo.reported_at,
       count(lr.lab_result_id) AS result_count
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
LEFT JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
WHERE p.mrn = 'MRN-0003927'
GROUP BY lo.lab_order_id, lo.test_code, lo.status, lo.collected_at, lo.reported_at
ORDER BY lo.collected_at DESC;

\echo ''
\echo '=== PG-Q1 plan (one run) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT lo.lab_order_id,
       lo.test_code,
       lo.status,
       lo.collected_at,
       lo.reported_at,
       count(lr.lab_result_id) AS result_count
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
LEFT JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
WHERE p.mrn = 'MRN-0003927'
GROUP BY lo.lab_order_id, lo.test_code, lo.status, lo.collected_at, lo.reported_at
ORDER BY lo.collected_at DESC;

\echo ''
\echo '=== PG-Q3. Work queue: IN_PROGRESS, urgent first, oldest first, three runs ==='
SELECT lo.lab_order_id, lo.test_code, lo.priority, lo.status, lo.collected_at
FROM lab_order lo
WHERE lo.status = 'IN_PROGRESS'
ORDER BY lo.priority DESC, lo.collected_at ASC
LIMIT 10;
SELECT lo.lab_order_id, lo.test_code, lo.priority, lo.status, lo.collected_at
FROM lab_order lo
WHERE lo.status = 'IN_PROGRESS'
ORDER BY lo.priority DESC, lo.collected_at ASC
LIMIT 10;
SELECT lo.lab_order_id, lo.test_code, lo.priority, lo.status, lo.collected_at
FROM lab_order lo
WHERE lo.status = 'IN_PROGRESS'
ORDER BY lo.priority DESC, lo.collected_at ASC
LIMIT 10;

\echo ''
\echo '=== PG-Q3 plan (one run) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT lo.lab_order_id, lo.test_code, lo.priority, lo.status, lo.collected_at
FROM lab_order lo
WHERE lo.status = 'IN_PROGRESS'
ORDER BY lo.priority DESC, lo.collected_at ASC
LIMIT 10;

\echo ''
\echo '=== PG-Q4. Total cholesterol trend for MRN-0003927, three runs ==='
SELECT lo.collected_at, lr.value_numeric, lr.flag
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
JOIN analyte a    ON a.analyte_id = lr.analyte_id
WHERE p.mrn = 'MRN-0003927'
  AND a.analyte_name = 'Total cholesterol'
ORDER BY lo.collected_at;
SELECT lo.collected_at, lr.value_numeric, lr.flag
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
JOIN analyte a    ON a.analyte_id = lr.analyte_id
WHERE p.mrn = 'MRN-0003927'
  AND a.analyte_name = 'Total cholesterol'
ORDER BY lo.collected_at;
SELECT lo.collected_at, lr.value_numeric, lr.flag
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
JOIN analyte a    ON a.analyte_id = lr.analyte_id
WHERE p.mrn = 'MRN-0003927'
  AND a.analyte_name = 'Total cholesterol'
ORDER BY lo.collected_at;

\echo ''
\echo '=== PG-Q4 plan (one run) ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT lo.collected_at, lr.value_numeric, lr.flag
FROM patient p
JOIN encounter e  ON e.patient_id = p.patient_id
JOIN lab_order lo ON lo.encounter_id = e.encounter_id
JOIN lab_result lr ON lr.lab_order_id = lo.lab_order_id
JOIN analyte a    ON a.analyte_id = lr.analyte_id
WHERE p.mrn = 'MRN-0003927'
  AND a.analyte_name = 'Total cholesterol'
ORDER BY lo.collected_at;

\echo ''
\echo '=== PG-Q5. Orders by test type since 2026-07-29, three runs ==='
-- This is the by_test branch of the MongoDB $facet, not the whole dashboard.
-- The other three branches add per-status, per-flag and turnaround aggregates.
SELECT tc.test_code, count(*) AS orders
FROM lab_order lo
JOIN test_catalogue tc ON tc.test_code = lo.test_code
WHERE lo.collected_at >= '2026-07-29'
GROUP BY tc.test_code
ORDER BY orders DESC;
SELECT tc.test_code, count(*) AS orders
FROM lab_order lo
JOIN test_catalogue tc ON tc.test_code = lo.test_code
WHERE lo.collected_at >= '2026-07-29'
GROUP BY tc.test_code
ORDER BY orders DESC;
SELECT tc.test_code, count(*) AS orders
FROM lab_order lo
JOIN test_catalogue tc ON tc.test_code = lo.test_code
WHERE lo.collected_at >= '2026-07-29'
GROUP BY tc.test_code
ORDER BY orders DESC;

\echo ''
\echo '=== PG insert. One lab_order plus four result rows, rolled back ==='
-- The MongoDB write unit is one order document containing its result array.
-- This is the closest relational equivalent: an order header plus four rows.
BEGIN;
INSERT INTO lab_order (encounter_id, test_code, priority, status,
                       ordered_at, collected_at, reported_at, ordered_by)
SELECT lo.encounter_id, 'LIPID', 'ROUTINE', 'REPORTED',
       now() - interval '3 hours', now() - interval '2 hours', now(), lo.ordered_by
FROM lab_order lo
LIMIT 1
RETURNING lab_order_id \gset
INSERT INTO lab_result (lab_order_id, analyte_id, value_numeric, flag, resulted_at, resulted_by)
SELECT :'lab_order_id', analyte_id, 4.2, 'NORMAL', now(), NULL
FROM analyte
WHERE test_code = 'LIPID'
LIMIT 4;
ROLLBACK;

\timing off
