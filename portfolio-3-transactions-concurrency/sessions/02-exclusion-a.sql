-- ============================================================================
-- Portfolio 3: protected booking - SESSION A
--
-- Scenario 02: the real appointment table with the no_double_booking
-- EXCLUDE USING gist constraint. The availability check still races, but the
-- database refuses the second overlapping row.
--
-- Run alongside 02-exclusion-b.sql; B starts about 1.2 s after A.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION A - exclusion constraint, protected booking ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS a_started;

BEGIN;

\echo 'A checks availability:'
SELECT count(*) AS a_sees_at_slot
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';

\echo 'A keeps its transaction open for 3 s so B can race it:'
SELECT pg_sleep(3);

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-03-04 09:00:00+00',
        TIMESTAMPTZ '2031-03-04 09:30:00+00',
        'BOOKED', 'P3 TEST exclusion A')
RETURNING appointment_id AS a_appointment
\gset

\echo 'A booked appointment: ' :a_appointment
SELECT clock_timestamp() AS a_inserted_at;

\echo 'A waits 3 s before committing; B is blocked on the exclusion index:'
SELECT pg_sleep(3);

COMMIT;

SELECT clock_timestamp() AS a_committed_at;

\echo 'A sees after commit:'
SELECT appointment_id, reason, status
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';

\echo 'A finished.'
