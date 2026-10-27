-- ============================================================================
-- Portfolio 3: write skew - SESSION A
--
-- Scenario 05: two doctors cover each other. Each transaction checks that
-- both are on duty, then takes its own doctor off duty. The invariant is
-- "at least one doctor remains on duty".
--
-- Run with -v iso=READ COMMITTED to show the anomaly, and with
-- -v iso=SERIALIZABLE to show SSI aborting one transaction with 40001.
-- Start 05-write-skew-b.sql about 1.2 s after this session.
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

\echo '=== SESSION A - write skew under' :iso '==='

SELECT staff_id AS p3_doctor_a
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset
SELECT staff_id AS p3_doctor_b
FROM doctor_profile WHERE license_no = 'KMPDC-000002' \gset

SELECT clock_timestamp() AS a_started;

BEGIN;
SET TRANSACTION ISOLATION LEVEL :iso;

\echo 'A checks the on-call roster:'
SELECT count(*) AS a_on_duty_seen
FROM p3_demo.on_call WHERE on_duty \gset
\echo 'A sees on duty=' :a_on_duty_seen

\echo 'A holds the transaction open for 4 s:'
SELECT pg_sleep(4);

\echo 'A takes doctor A off duty:'
UPDATE p3_demo.on_call
SET on_duty = false
WHERE doctor_id = :'p3_doctor_a';

\echo 'A commits (under SERIALIZABLE this may be the transaction that aborts):'
COMMIT;

SELECT clock_timestamp() AS a_committed_at;

\echo 'On-duty count after A commit:'
SELECT count(*) AS a_on_duty_after_commit
FROM p3_demo.on_call WHERE on_duty;

\echo 'A finished.'
