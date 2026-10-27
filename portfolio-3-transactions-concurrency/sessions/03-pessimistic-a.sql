-- ============================================================================
-- Portfolio 3: pessimistic locking - SESSION A
--
-- Scenario 03: SELECT ... FOR UPDATE on the doctor row. B must block until A
-- commits, then re-check availability and abandon its booking.
--
-- Run alongside 03-pessimistic-b.sql; B starts about 1.2 s after A.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION A - pessimistic lock holder ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS a_started;

BEGIN;

\echo 'A locks the doctor row:'
SELECT staff_id FROM doctor_profile
WHERE staff_id = :'p3_doctor'
FOR UPDATE;

SELECT clock_timestamp() AS a_lock_acquired;

\echo 'A holds the lock for 3 s:'
SELECT pg_sleep(3);

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-03-04 11:00:00+00',
        TIMESTAMPTZ '2031-03-04 11:30:00+00',
        'BOOKED', 'P3 TEST pessimistic A')
RETURNING appointment_id AS a_appointment
\gset

\echo 'A booked appointment: ' :a_appointment
SELECT clock_timestamp() AS a_inserted_at;

\echo 'A waits 1 s, then commits and releases the lock:'
SELECT pg_sleep(1);

COMMIT;

SELECT clock_timestamp() AS a_committed_at;

\echo 'A finished.'
