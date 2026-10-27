-- ============================================================================
-- Portfolio 3: concurrency baseline - SESSION A
--
-- Scenario 01: the double-booking anomaly with no database control.
--
-- p3_demo.booking_unprotected is structurally the appointment table without
-- the no_double_booking exclusion constraint. It represents an application
-- that checks availability and then inserts, trusting the check.
--
-- Run alongside 01-unprotected-b.sql; B starts about 1.2 s after A.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION A - unprotected booking ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS a_started;

BEGIN;

\echo 'A checks availability:'
SELECT count(*) AS a_sees_at_slot
FROM p3_demo.booking_unprotected
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-01 09:00:00+00';

\echo 'A keeps its transaction open for 3 s so B can check the same slot:'
SELECT pg_sleep(3);

INSERT INTO p3_demo.booking_unprotected
    (booking_id, doctor_id, patient_id, slot_start, slot_end)
VALUES
    (gen_random_uuid(), :'p3_doctor', :'p3_patient',
     TIMESTAMPTZ '2031-03-01 09:00:00+00',
     TIMESTAMPTZ '2031-03-01 09:30:00+00')
RETURNING booking_id AS a_booking
\gset

\echo 'A inserted booking: ' :a_booking
SELECT clock_timestamp() AS a_inserted_at;

\echo 'A waits 2 s before committing:'
SELECT pg_sleep(2);

COMMIT;

SELECT clock_timestamp() AS a_committed_at;

\echo 'A sees after its own commit:'
SELECT count(*) AS a_rows_for_slot
FROM p3_demo.booking_unprotected
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-01 09:00:00+00';

\echo 'A finished.'
