-- ============================================================================
-- Portfolio 1: Constraint verification
--
-- Every test below MUST fail for the schema to be correct. A test that succeeds
-- is a defect, and the report says so explicitly.
--
-- Each test runs inside a subtransaction that is rolled back on error, so this
-- script can be run repeatedly against a live database without side effects.
--
--   psql -U portfolio -d hospital -f constraint-tests.sql
--
-- Expected outcome: 10 rows, all beginning with 'PASS'.
-- ============================================================================

CREATE OR REPLACE FUNCTION expect_failure(p_label text, p_sql text, p_expected_state text)
RETURNS text
LANGUAGE plpgsql AS $fn$
DECLARE
    v_state text;
    v_msg   text;
BEGIN
    BEGIN
        EXECUTE p_sql;
        -- Reaching this line means the statement was accepted: a schema defect.
        RETURN format('FAIL  %s -- statement succeeded but should have failed',
                      rpad(p_label, 34));
    EXCEPTION WHEN OTHERS THEN
        GET STACKED DIAGNOSTICS v_state = RETURNED_SQLSTATE, v_msg = MESSAGE_TEXT;
    END;

    IF v_state = p_expected_state THEN
        RETURN format('PASS  %s [%s] %s', rpad(p_label, 34), v_state, v_msg);
    END IF;

    RETURN format('FAIL  %s expected %s, got %s -- %s',
                  rpad(p_label, 34), p_expected_state, v_state, v_msg);
END;
$fn$;


\echo ''
\echo 'Portfolio 1 — constraint verification'
\echo '====================================='

SELECT expect_failure(
    'T01 double booking',
    $stmt$
        INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status)
        SELECT patient_id, doctor_id, slot_start + interval '10 minutes',
               slot_end + interval '10 minutes', 'BOOKED'
        FROM appointment
        WHERE status = 'BOOKED'
        ORDER BY slot_start
        LIMIT 1
    $stmt$,
    '23P01'
) AS t01;


SELECT expect_failure(
    'T02 second primary diagnosis',
    $stmt$
        UPDATE diagnosis
        SET diagnosis_type = 'PRIMARY'
        WHERE diagnosis_id = (
            SELECT d.diagnosis_id
            FROM diagnosis d
            JOIN diagnosis p ON p.encounter_id = d.encounter_id
                            AND p.diagnosis_type = 'PRIMARY'
            WHERE d.diagnosis_type = 'SECONDARY'
            LIMIT 1)
    $stmt$,
    '23505'
) AS t02;


SELECT expect_failure(
    'T03 malformed MRN',
    $stmt$
        UPDATE patient SET mrn = 'ABC123' WHERE mrn = (SELECT min(mrn) FROM patient)
    $stmt$,
    '23514'
) AS t03;


SELECT expect_failure(
    'T04 delete from audit log',
    $stmt$
        DELETE FROM audit_log WHERE audit_id = (SELECT min(audit_id) FROM audit_log)
    $stmt$,
    '42501'
) AS t04;


SELECT expect_failure(
    'T05 update audit log',
    $stmt$
        UPDATE audit_log SET action = 'LOGIN'
        WHERE audit_id = (SELECT min(audit_id) FROM audit_log)
    $stmt$,
    '42501'
) AS t05;


SELECT expect_failure(
    'T06 doctor profile for a nurse',
    $stmt$
        INSERT INTO doctor_profile (staff_id, specialty, license_no)
        SELECT staff_id, 'Testing', 'TEST-0001'
        FROM staff WHERE role = 'NURSE' LIMIT 1
    $stmt$,
    '23514'
) AS t06;


SELECT expect_failure(
    'T07 impossible temperature',
    $stmt$
        INSERT INTO vitals (encounter_id, temperature_c)
        SELECT encounter_id, 99.0 FROM encounter LIMIT 1
    $stmt$,
    '23514'
) AS t07;


SELECT expect_failure(
    'T08 lab result with no value',
    $stmt$
        INSERT INTO lab_result (lab_order_id, analyte_id)
        SELECT lo.lab_order_id, a.analyte_id
        FROM lab_order lo
        JOIN analyte a ON a.test_code = lo.test_code
        LIMIT 1
    $stmt$,
    '23514'
) AS t08;


SELECT expect_failure(
    'T09 cancel without timestamp',
    $stmt$
        UPDATE appointment SET status = 'CANCELLED'
        WHERE appointment_id = (SELECT appointment_id FROM appointment
                                WHERE status = 'BOOKED' LIMIT 1)
    $stmt$,
    '23514'
) AS t09;


-- Two rows, one bed, neither discharged: the second must collide with the
-- partial unique index one_active_admission_per_bed.
SELECT expect_failure(
    'T10 two active admissions',
    $stmt$
        INSERT INTO admission (patient_id, encounter_id, ward_id, bed_id,
                               admitting_doctor_id, admitted_at, status)
        SELECT e.patient_id, e.encounter_id, b.ward_id, b.bed_id,
               e.doctor_id, now(), 'ADMITTED'
        FROM (SELECT patient_id, encounter_id, doctor_id FROM encounter LIMIT 2) e
        CROSS JOIN (SELECT bed_id, ward_id FROM bed
                    ORDER BY ward_id, bed_number LIMIT 1) b
    $stmt$,
    '23505'
) AS t10;


DROP FUNCTION expect_failure(text, text, text);

\echo ''
