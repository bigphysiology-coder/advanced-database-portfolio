-- ============================================================================
-- Portfolio 3: concurrency baseline - SESSION B
--
-- Scenario 01: the double-booking anomaly with no database control.
-- Start about 1.2 s after Session A, while A is still inside its transaction.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION B - unprotected booking ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS b_started;

BEGIN;

\echo 'B checks availability while A is uncommitted:'
SELECT count(*) AS b_sees_at_slot
FROM p3_demo.booking_unprotected
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-01 09:00:00+00';

\echo 'B keeps its transaction open for 3 s as well:'
SELECT pg_sleep(3);

INSERT INTO p3_demo.booking_unprotected
    (booking_id, doctor_id, patient_id, slot_start, slot_end)
VALUES
    (gen_random_uuid(), :'p3_doctor', :'p3_patient',
     TIMESTAMPTZ '2031-03-01 09:00:00+00',
     TIMESTAMPTZ '2031-03-01 09:30:00+00')
RETURNING booking_id AS b_booking
\gset

\echo 'B inserted booking: ' :b_booking
SELECT clock_timestamp() AS b_inserted_at;

\echo 'B waits 2 s before committing:'
SELECT pg_sleep(2);

COMMIT;

SELECT clock_timestamp() AS b_committed_at;

\echo 'B sees after its own commit:'
SELECT count(*) AS b_rows_for_slot
FROM p3_demo.booking_unprotected
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-01 09:00:00+00';

\echo 'B finished. Two rows now occupy one slot.'
