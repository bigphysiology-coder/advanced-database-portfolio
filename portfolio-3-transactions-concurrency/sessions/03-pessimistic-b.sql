-- ============================================================================
-- Portfolio 3: pessimistic locking - SESSION B
--
-- Scenario 03: B asks for the same doctor row with FOR UPDATE. It must block
-- until A commits, then see A's booking and roll back its own attempt.
--
-- Start about 1.2 s after Session A.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION B - pessimistic lock waiter ==='

SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS b_started;

BEGIN;

\echo 'B tries to lock the same doctor row; it should block here:'
SELECT clock_timestamp() AS b_lock_before \gset

SELECT staff_id FROM doctor_profile
WHERE staff_id = :'p3_doctor'
FOR UPDATE;

SELECT clock_timestamp() AS b_lock_after \gset

\echo 'B acquired the lock after A committed.'
SELECT round(
    extract(epoch FROM (:'b_lock_after'::timestamptz - :'b_lock_before'::timestamptz))::numeric,
    3
) AS b_lock_wait_seconds;

\echo 'B re-checks availability and sees A booking:'
SELECT count(*) AS b_sees_booked_rows
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 11:00:00+00';

SELECT appointment_id, reason
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 11:00:00+00';

\echo 'B abandons its booking attempt:'
ROLLBACK;

SELECT clock_timestamp() AS b_finished_at;

\echo 'B finished.'
