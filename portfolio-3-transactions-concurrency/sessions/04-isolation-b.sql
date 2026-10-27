-- ============================================================================
-- Portfolio 3: isolation level read - SESSION B
--
-- Scenario 04: insert and commit one appointment for the patient Session A is
-- counting. Start about 1.2 s after A, while A is sleeping between its reads.
--
-- Run with -v p3_slot='2031-03-05 09:00:00+00' for READ COMMITTED and a
-- different slot for REPEATABLE READ so the two runs are independent.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\if :{?p3_slot}
\else
  \set p3_slot '2031-03-05 09:00:00+00'
\endif

\echo '=== SESSION B - concurrent insert ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS b_started;

BEGIN;

\echo 'B inserts one appointment and commits:'
INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        :'p3_slot'::timestamptz,
        :'p3_slot'::timestamptz + INTERVAL '30 minutes',
        'BOOKED', 'P3 TEST isolation')
RETURNING appointment_id AS b_appointment
\gset

COMMIT;

SELECT clock_timestamp() AS b_committed_at;
\echo 'B inserted appointment: ' :b_appointment

\echo 'B count for the patient:'
SELECT count(*) AS b_count_for_patient
FROM appointment
WHERE patient_id = :'p3_patient';

\echo 'B finished.'
