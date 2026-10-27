-- ============================================================================
-- Portfolio 3: protected booking - SESSION B
--
-- Scenario 02: the same availability check, followed by an insert that
-- overlaps A's uncommitted row. The exclusion constraint must block this
-- statement until A commits, then raise SQLSTATE 23P01.
--
-- Start about 1.2 s after Session A.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo '=== SESSION B - exclusion constraint, conflicting booking ==='

SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset

SELECT clock_timestamp() AS b_started;

BEGIN;

\echo 'B checks availability while A is uncommitted:'
SELECT count(*) AS b_sees_at_slot
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';

\echo 'B waits 2 s, then attempts the race:'
SELECT pg_sleep(2);

\echo 'B attempts the overlapping insert; this should block, then fail with 23P01:'
SELECT clock_timestamp() AS b_insert_attempt_at;

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-03-04 09:00:00+00',
        TIMESTAMPTZ '2031-03-04 09:30:00+00',
        'BOOKED', 'P3 TEST exclusion B')
RETURNING appointment_id AS b_appointment
\gset

\echo 'If the constraint worked, the line above is an error and no id was stored.'
SELECT clock_timestamp() AS b_after_insert_statement;

ROLLBACK;

\echo 'B rolled back its failed transaction. Rows for the slot now:'
SELECT appointment_id, reason, status
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';

SELECT count(*) AS b_rows_for_slot
FROM appointment
WHERE doctor_id = :'p3_doctor'
  AND slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';

\echo 'B finished. The database, not the application, enforced the invariant.'
