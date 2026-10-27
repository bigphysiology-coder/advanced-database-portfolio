-- ============================================================================
-- Portfolio 3: write skew - SESSION B
--
-- Scenario 05: B reads the same roster, then takes the other doctor off duty.
-- Under READ COMMITTED both transactions commit and the invariant breaks.
-- Under SERIALIZABLE one transaction must abort with SQLSTATE 40001.
--
-- Start about 1.2 s after Session A.
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

\echo '=== SESSION B - write skew under' :iso '==='

SELECT staff_id AS p3_doctor_a
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset
SELECT staff_id AS p3_doctor_b
FROM doctor_profile WHERE license_no = 'KMPDC-000002' \gset

SELECT clock_timestamp() AS b_started;

BEGIN;
SET TRANSACTION ISOLATION LEVEL :iso;

\echo 'B checks the on-call roster:'
SELECT count(*) AS b_on_duty_seen
FROM p3_demo.on_call WHERE on_duty \gset
\echo 'B sees on duty=' :b_on_duty_seen

\echo 'B holds the transaction open for 4 s:'
SELECT pg_sleep(4);

\echo 'B takes doctor B off duty:'
UPDATE p3_demo.on_call
SET on_duty = false
WHERE doctor_id = :'p3_doctor_b';

\echo 'B attempts COMMIT (the UPDATE already aborted this transaction):'
COMMIT;

SELECT clock_timestamp() AS b_committed_at;

\echo 'Under SERIALIZABLE, the error above is the expected 40001.'
\echo 'On-duty count after B commit attempt:'
SELECT count(*) AS b_on_duty_after_commit
FROM p3_demo.on_call WHERE on_duty;

\echo 'B finished.'
