-- ============================================================================
-- Portfolio 3: isolation level read - SESSION A
--
-- Scenario 04: the same count is read twice inside one transaction, while
-- Session B commits an insert in between.
--
-- Run with -v iso=READ COMMITTED and again with -v iso=REPEATABLE READ.
-- 04-isolation-b.sql inserts one appointment for the same patient.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\if :{?iso}
\else
  \set iso 'READ COMMITTED'
\endif

\echo '=== SESSION A - repeated read under' :iso '==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset

SELECT clock_timestamp() AS a_started;

BEGIN;
SET TRANSACTION ISOLATION LEVEL :iso;

\echo 'A first read:'
SELECT clock_timestamp() AS a_first_read_at;
SELECT count(*) AS a_first_count
FROM appointment
WHERE patient_id = :'p3_patient' \gset

\echo 'A holds the transaction open for 4 s while B inserts and commits:'
SELECT pg_sleep(4);

\echo 'A second read:'
SELECT clock_timestamp() AS a_second_read_at;
SELECT count(*) AS a_second_count
FROM appointment
WHERE patient_id = :'p3_patient' \gset

\echo 'A RESULT isolation=' :iso ' first=' :a_first_count ' second=' :a_second_count
SELECT (:a_second_count::int - :a_first_count::int) AS a_delta;

COMMIT;

\echo 'A after commit:'
SELECT count(*) AS a_count_after_commit
FROM appointment
WHERE patient_id = :'p3_patient';

\echo 'A finished.'
