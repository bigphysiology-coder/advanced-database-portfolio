-- ============================================================================
-- Portfolio 3: Transactions
-- Single-session scenarios: COMMIT, ROLLBACK, SAVEPOINT.
--
-- Run against the seeded database:
--   docker compose exec -T postgres psql -U portfolio -d hospital \
--       -v ON_ERROR_STOP=0 -f portfolio-3-transactions-concurrency/transactions.sql
--
-- ON_ERROR_STOP is deliberately OFF: T2 and T3 must reach the expected
-- constraint errors and then continue to their verification queries.
-- The capture harness records the exit status separately.
--
-- Fixtures are removed at the end of the run, so the script is repeatable.
-- ============================================================================

\set ON_ERROR_STOP off
\pset pager off
\pset footer off
\set VERBOSITY verbose
\timing on
SET TIME ZONE 'UTC';

\echo ''
\echo '============================================================'
\echo 'Portfolio 3 - single-session transaction tests'
\echo 'Server time:'
SELECT clock_timestamp() AS server_time;
\echo 'Server:'
SELECT version();
\echo '============================================================'

-- Resolve stable business keys rather than hard-coding UUIDs, which change
-- when the database is rebuilt because they are generated with gen_random_uuid().
SELECT patient_id AS p3_patient
FROM patient WHERE mrn = 'MRN-0000001' \gset
SELECT staff_id AS p3_doctor
FROM doctor_profile WHERE license_no = 'KMPDC-000001' \gset
SELECT encounter_id AS p3_encounter
FROM encounter ORDER BY started_at, encounter_id LIMIT 1 \gset

\echo ''
\echo 'Fixture keys:'
\echo '  patient  = ' :p3_patient
\echo '  doctor   = ' :p3_doctor
\echo '  encounter= ' :p3_encounter

-- Remove rows left by an earlier interrupted run. The demo schema is created
-- by scripts/capture-p3.ps1; CREATE IF NOT EXISTS keeps this file runnable alone.
CREATE SCHEMA IF NOT EXISTS p3_demo;
CREATE TABLE IF NOT EXISTS p3_demo.lab_order_ids (
    lab_order_id uuid PRIMARY KEY
);
DELETE FROM lab_order
WHERE lab_order_id IN (SELECT lab_order_id FROM p3_demo.lab_order_ids);
DELETE FROM p3_demo.lab_order_ids;
DELETE FROM appointment WHERE reason LIKE 'P3 TEST%';


-- ----------------------------------------------------------------------------
-- T1. Successful multi-table write - appointment + trigger-written audit row
--
-- The appointment insert fires trg_appointment_audit, which writes audit_log.
-- Both rows must become visible at COMMIT and not before.
-- ----------------------------------------------------------------------------
\echo ''
\echo '------------------------------------------------------------'
\echo 'T1. COMMIT: appointment and audit row become visible together'
\echo '------------------------------------------------------------'

BEGIN;

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-02-03 09:00:00+00',
        TIMESTAMPTZ '2031-02-03 09:30:00+00',
        'BOOKED', 'P3 TEST T1 commit')
RETURNING appointment_id AS t1_appointment
\gset

\echo 'Inserted inside transaction: ' :t1_appointment

SELECT count(*) AS t1_appointment_rows_in_tx
FROM appointment WHERE appointment_id = :'t1_appointment';

SELECT count(*) AS t1_audit_rows_in_tx
FROM audit_log
WHERE table_name = 'appointment' AND record_id = :'t1_appointment';

SELECT audit_id, action, table_name, record_id
FROM audit_log
WHERE table_name = 'appointment' AND record_id = :'t1_appointment'
ORDER BY audit_id DESC
LIMIT 1;

COMMIT;

\echo 'After COMMIT:'
SELECT count(*) AS t1_appointment_rows_after_commit
FROM appointment WHERE appointment_id = :'t1_appointment';

SELECT count(*) AS t1_audit_rows_after_commit
FROM audit_log
WHERE table_name = 'appointment' AND record_id = :'t1_appointment';


-- ----------------------------------------------------------------------------
-- T2. ROLLBACK on a real constraint violation
--
-- The first insert succeeds. The second overlaps it for the same doctor, so
-- the no_double_booking exclusion constraint raises SQLSTATE 23P01. The whole
-- transaction must disappear, including the audit row written by the trigger.
-- ----------------------------------------------------------------------------
\echo ''
\echo '------------------------------------------------------------'
\echo 'T2. ROLLBACK: second insert violates no_double_booking (23P01)'
\echo '------------------------------------------------------------'

BEGIN;

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-02-03 10:00:00+00',
        TIMESTAMPTZ '2031-02-03 10:30:00+00',
        'BOOKED', 'P3 TEST T2 first')
RETURNING appointment_id AS t2_first
\gset

\echo 'First insert succeeded inside transaction: ' :t2_first
\echo 'The next statement is expected to fail:'

INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason)
VALUES (:'p3_patient', :'p3_doctor',
        TIMESTAMPTZ '2031-02-03 10:15:00+00',
        TIMESTAMPTZ '2031-02-03 10:45:00+00',
        'BOOKED', 'P3 TEST T2 conflicting');

\echo 'After the expected error the transaction is aborted; rolling back.'
ROLLBACK;

\echo 'After ROLLBACK:'
SELECT count(*) AS t2_first_rows_after_rollback
FROM appointment WHERE appointment_id = :'t2_first';

SELECT count(*) AS t2_audit_rows_after_rollback
FROM audit_log
WHERE table_name = 'appointment' AND record_id = :'t2_first';


-- ----------------------------------------------------------------------------
-- T3. SAVEPOINT - partial rollback
--
-- A lab order is created. One result is valid; a second result is invalid
-- because it supplies both a numeric and a text value (CHECK 23514). The
-- savepoint discards only the bad result and keeps the order; the corrected
-- result is then committed.
-- ----------------------------------------------------------------------------
\echo ''
\echo '------------------------------------------------------------'
\echo 'T3. SAVEPOINT: bad lab result rolled back, order survives'
\echo '------------------------------------------------------------'

BEGIN;

INSERT INTO lab_order (encounter_id, test_code, priority, status, ordered_by)
VALUES (:'p3_encounter', 'FBC', 'ROUTINE', 'ORDERED', :'p3_doctor')
RETURNING lab_order_id AS t3_order
\gset

INSERT INTO p3_demo.lab_order_ids (lab_order_id) VALUES (:'t3_order');

\echo 'Order created: ' :t3_order
\echo 'Inserting a valid result for analyte 1:'

INSERT INTO lab_result (lab_order_id, analyte_id, value_numeric, flag, resulted_by)
SELECT :'t3_order', a.analyte_id, 14.200, 'NORMAL', :'p3_doctor'
FROM (
    SELECT analyte_id, row_number() OVER (ORDER BY analyte_id) AS rn
    FROM analyte WHERE test_code = 'FBC'
) a
WHERE a.rn = 1;

-- The savepoint comes after the valid result: rolling back must discard only
-- the bad row, not the successful one.
SAVEPOINT after_valid_result;

\echo 'Inserting an invalid result for analyte 2 (both numeric and text):'

INSERT INTO lab_result (lab_order_id, analyte_id, value_numeric, value_text, flag, resulted_by)
SELECT :'t3_order', a.analyte_id, 5.000, 'invalid-both', 'NORMAL', :'p3_doctor'
FROM (
    SELECT analyte_id, row_number() OVER (ORDER BY analyte_id) AS rn
    FROM analyte WHERE test_code = 'FBC'
) a
WHERE a.rn = 2;

\echo 'Expected CHECK violation. Rolling back to the savepoint only:'
ROLLBACK TO SAVEPOINT after_valid_result;

SELECT count(*) AS t3_results_after_savepoint_rollback
FROM lab_result WHERE lab_order_id = :'t3_order';

\echo 'Re-inserting the corrected result for analyte 2:'

INSERT INTO lab_result (lab_order_id, analyte_id, value_numeric, flag, resulted_by)
SELECT :'t3_order', a.analyte_id, 6.100, 'NORMAL', :'p3_doctor'
FROM (
    SELECT analyte_id, row_number() OVER (ORDER BY analyte_id) AS rn
    FROM analyte WHERE test_code = 'FBC'
) a
WHERE a.rn = 2;

COMMIT;

\echo 'After COMMIT:'
SELECT count(*) AS t3_order_rows
FROM lab_order WHERE lab_order_id = :'t3_order';

SELECT count(*) AS t3_result_rows
FROM lab_result WHERE lab_order_id = :'t3_order';

SELECT count(*) AS t3_invalid_rows
FROM lab_result WHERE lab_order_id = :'t3_order' AND value_text = 'invalid-both';


-- ----------------------------------------------------------------------------
-- Cleanup: remove the two committed fixtures, keeping the dataset at its
-- seeded size. The audit rows are append-only and remain, by design.
-- ----------------------------------------------------------------------------
\echo ''
\echo '------------------------------------------------------------'
\echo 'Cleanup of committed fixtures'
\echo '------------------------------------------------------------'

DELETE FROM appointment WHERE appointment_id = :'t1_appointment';
DELETE FROM lab_order WHERE lab_order_id = :'t3_order';
DELETE FROM p3_demo.lab_order_ids WHERE lab_order_id = :'t3_order';

SELECT count(*) AS t1_rows_after_cleanup
FROM appointment WHERE appointment_id = :'t1_appointment';

SELECT count(*) AS t3_order_rows_after_cleanup
FROM lab_order WHERE lab_order_id = :'t3_order';

\echo 'Done.'
