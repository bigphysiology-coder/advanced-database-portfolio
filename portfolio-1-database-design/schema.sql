-- ============================================================================
-- MIT 8103 Advanced Database Systems
-- Portfolio 1: Database Design and Modelling
-- Case study: Riverbend Teaching Hospital — Clinical Records System
-- Target: PostgreSQL 16+ (validated on PostgreSQL 18)
--
-- Design decisions encoded here (justified in normalisation.md):
--   * Surrogate UUID primary keys for clinical entities, MRN as the business key
--   * Diagnoses coded (icd_code FK) plus a free-text note
--   * Laboratory results normalised into order/result/analyte tables, so that
--     Portfolio 4 can move the same data to a document store and compare
--   * Double-booking prevented declaratively by an exclusion constraint
--
-- Execution order: schema.sql, then seed-data.sql, against an EMPTY database.
-- To rebuild:  docker compose down -v && docker compose up -d
-- ============================================================================


-- ============================================================================
-- 0. Extensions
-- ============================================================================

-- btree_gist provides the equality operator classes that allow a GiST exclusion
-- constraint to combine "doctor_id =" with "time range &&". Without it, the
-- no-double-booking constraint cannot be declared.
CREATE EXTENSION IF NOT EXISTS btree_gist;


-- ============================================================================
-- 1. Enumerated domains
--
-- Enums are used where the value set is small, stable and owned by the schema.
-- Trade-off: adding a value later needs ALTER TYPE (fast since PG12, but it is
-- still a migration). Where values change often, a lookup table is used instead.
-- ============================================================================

CREATE TYPE sex_type AS ENUM ('F', 'M', 'O', 'U');

CREATE TYPE staff_role AS ENUM (
    'RECEPTIONIST', 'NURSE', 'DOCTOR', 'LAB_TECH',
    'PHARMACIST', 'WARD_CLERK', 'RECORDS_OFFICER', 'ADMIN', 'AUDITOR'
);

CREATE TYPE appointment_status AS ENUM (
    'BOOKED', 'ARRIVED', 'IN_PROGRESS', 'COMPLETED', 'CANCELLED', 'NO_SHOW'
);

CREATE TYPE encounter_type AS ENUM ('OPD', 'INPATIENT', 'FOLLOW_UP');

CREATE TYPE diagnosis_type AS ENUM ('PRIMARY', 'SECONDARY', 'DIFFERENTIAL');

CREATE TYPE admission_status AS ENUM ('ADMITTED', 'TRANSFERRED', 'DISCHARGED');

CREATE TYPE lab_priority AS ENUM ('ROUTINE', 'URGENT', 'STAT');

CREATE TYPE lab_status AS ENUM (
    'ORDERED', 'COLLECTED', 'IN_PROGRESS', 'REPORTED', 'AMENDED', 'CANCELLED'
);

CREATE TYPE result_flag AS ENUM ('NORMAL', 'LOW', 'HIGH', 'CRITICAL_LOW', 'CRITICAL_HIGH');


-- ============================================================================
-- 2. Organisation
-- ============================================================================

CREATE TABLE department (
    department_id   smallint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            varchar(10)   NOT NULL UNIQUE,
    name            varchar(80)   NOT NULL UNIQUE,
    floor           smallint,
    phone           varchar(20),
    created_at      timestamptz   NOT NULL DEFAULT now()
);

COMMENT ON TABLE department IS
    'Clinical and administrative departments. Referenced by staff, wards and the test catalogue.';


CREATE TABLE staff (
    staff_id        uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_no     varchar(12)   NOT NULL UNIQUE,
    first_name      varchar(60)   NOT NULL,
    last_name       varchar(60)   NOT NULL,
    role            staff_role    NOT NULL,
    department_id   smallint      REFERENCES department(department_id) ON DELETE SET NULL,
    email           varchar(120)  UNIQUE,
    phone           varchar(20),
    hired_on        date          NOT NULL,
    is_active       boolean       NOT NULL DEFAULT true,
    created_at      timestamptz   NOT NULL DEFAULT now(),

    CONSTRAINT staff_hired_on_sane CHECK (hired_on > DATE '1950-01-01')
);

COMMENT ON TABLE staff IS
    'All employees. Doctors have a 1:1 doctor_profile row carrying clinical attributes, '
    'which keeps employment data and clinical privileges separable.';


-- Only doctors have clinical privileges. A plain CHECK cannot reference another
-- table, so this cross-table invariant is enforced with a trigger.
CREATE TABLE doctor_profile (
    staff_id                uuid          PRIMARY KEY
                                          REFERENCES staff(staff_id) ON DELETE CASCADE,
    specialty               varchar(60)   NOT NULL,
    license_no              varchar(30)   NOT NULL UNIQUE,
    license_expires_on      date,

    CONSTRAINT doctor_license_sane CHECK (license_expires_on IS NULL OR license_expires_on > DATE '2000-01-01')
);

CREATE OR REPLACE FUNCTION enforce_doctor_role() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF (SELECT role FROM staff WHERE staff_id = NEW.staff_id) <> 'DOCTOR' THEN
        RAISE EXCEPTION 'staff % does not have the DOCTOR role', NEW.staff_id
            USING ERRCODE = 'check_violation';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_doctor_profile_role
    BEFORE INSERT OR UPDATE ON doctor_profile
    FOR EACH ROW EXECUTE FUNCTION enforce_doctor_role();


-- ============================================================================
-- 3. Patients
-- ============================================================================

CREATE TABLE patient (
    patient_id      uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    mrn             varchar(12)   NOT NULL UNIQUE,
    first_name      varchar(60)   NOT NULL,
    middle_name     varchar(60),
    last_name       varchar(60)   NOT NULL,
    date_of_birth   date          NOT NULL,
    sex             sex_type      NOT NULL,
    phone           varchar(20),
    email           varchar(120),
    national_id     varchar(20)   UNIQUE,
    address_line    varchar(150),
    city            varchar(60),
    blood_group     varchar(3),
    created_at      timestamptz   NOT NULL DEFAULT now(),
    is_active       boolean       NOT NULL DEFAULT true,

    -- Derived, stored: the display name is written far more often than the parts
    -- change, so materialising it is cheaper than concatenating on every read.
    full_name       text          GENERATED ALWAYS AS (
                                      first_name || ' ' ||
                                      COALESCE(middle_name || ' ', '') ||
                                      last_name
                                  ) STORED,

    CONSTRAINT patient_mrn_format
        CHECK (mrn ~ '^MRN-[0-9]{7}$'),
    CONSTRAINT patient_dob_sane
        CHECK (date_of_birth > DATE '1900-01-01'),
    CONSTRAINT patient_blood_group_valid
        CHECK (blood_group IS NULL OR blood_group IN
               ('A+','A-','B+','B-','AB+','AB-','O+','O-'))
);

COMMENT ON COLUMN patient.mrn IS
    'Medical record number. Stable, human-quotable business key. The surrogate '
    'patient_id is the primary key so that a corrected or merged MRN does not '
    'cascade through every child table.';

COMMENT ON COLUMN patient.national_id IS
    'Nullable: not every patient presents identification, and requiring it would '
    'block emergency registration.';


CREATE TABLE next_of_kin (
    next_of_kin_id  uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid          NOT NULL
                                  REFERENCES patient(patient_id) ON DELETE CASCADE,
    full_name       varchar(120)  NOT NULL,
    relationship    varchar(40)   NOT NULL,
    phone           varchar(20)   NOT NULL,
    is_primary      boolean       NOT NULL DEFAULT false
);

-- At most one primary contact per patient. A partial unique index expresses
-- "unique among the rows that matter" — impossible with a table constraint.
CREATE UNIQUE INDEX one_primary_contact_per_patient
    ON next_of_kin (patient_id)
    WHERE is_primary;


-- ============================================================================
-- 4. Inpatient facilities
-- ============================================================================

CREATE TABLE ward (
    ward_id         smallint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code            varchar(10)   NOT NULL UNIQUE,
    name            varchar(60)   NOT NULL UNIQUE,
    ward_type       varchar(30)   NOT NULL,
    department_id   smallint      REFERENCES department(department_id) ON DELETE SET NULL,
    capacity        smallint      NOT NULL,

    CONSTRAINT ward_capacity_positive CHECK (capacity > 0)
);

CREATE TABLE bed (
    bed_id          uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    ward_id         smallint      NOT NULL REFERENCES ward(ward_id) ON DELETE CASCADE,
    bed_number      varchar(10)   NOT NULL,
    bed_type        varchar(20)   NOT NULL DEFAULT 'STANDARD',

    CONSTRAINT bed_unique_in_ward UNIQUE (ward_id, bed_number)
);


-- ============================================================================
-- 5. Scheduling
-- ============================================================================

CREATE TABLE doctor_schedule (
    schedule_id     uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    doctor_id       uuid          NOT NULL
                                  REFERENCES doctor_profile(staff_id) ON DELETE CASCADE,
    day_of_week     smallint      NOT NULL,   -- ISO: 1 = Monday, 7 = Sunday
    start_time      time          NOT NULL,
    end_time        time          NOT NULL,
    slot_minutes    smallint      NOT NULL DEFAULT 30,
    effective_from  date          NOT NULL DEFAULT CURRENT_DATE,
    effective_to    date,

    CONSTRAINT schedule_day_valid   CHECK (day_of_week BETWEEN 1 AND 7),
    CONSTRAINT schedule_time_order  CHECK (end_time > start_time),
    CONSTRAINT schedule_slot_valid  CHECK (slot_minutes BETWEEN 5 AND 120),
    CONSTRAINT schedule_dates_valid CHECK (effective_to IS NULL OR effective_to >= effective_from),
    CONSTRAINT schedule_no_overlap  UNIQUE (doctor_id, day_of_week, start_time, effective_from)
);


CREATE TABLE appointment (
    appointment_id  uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid              NOT NULL
                                      REFERENCES patient(patient_id) ON DELETE RESTRICT,
    doctor_id       uuid              NOT NULL
                                      REFERENCES doctor_profile(staff_id) ON DELETE RESTRICT,
    slot_start      timestamptz       NOT NULL,
    slot_end        timestamptz       NOT NULL,
    status          appointment_status NOT NULL DEFAULT 'BOOKED',
    reason          varchar(200),
    booked_by       uuid              REFERENCES staff(staff_id) ON DELETE SET NULL,
    created_at      timestamptz       NOT NULL DEFAULT now(),
    cancelled_at    timestamptz,

    CONSTRAINT appointment_time_order CHECK (slot_end > slot_start),
    CONSTRAINT appointment_cancelled_consistency
        CHECK ((status = 'CANCELLED') = (cancelled_at IS NOT NULL)),

    -- ------------------------------------------------------------------
    -- The centrepiece constraint for Portfolio 3.
    --
    -- A doctor cannot hold two live appointments whose time ranges overlap.
    -- This is enforced by the database, not by application code, so it holds
    -- even when two receptionists act at the same instant.
    --
    -- '[)' means the range includes the start and excludes the end, so a
    -- 09:00-09:30 and a 09:30-10:00 appointment do not collide.
    -- ------------------------------------------------------------------
    CONSTRAINT no_double_booking
        EXCLUDE USING gist (
            doctor_id WITH =,
            tstzrange(slot_start, slot_end, '[)') WITH &&
        )
        WHERE (status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS'))
);

COMMENT ON CONSTRAINT no_double_booking ON appointment IS
    'Declarative double-booking prevention. Compared with SELECT ... FOR UPDATE '
    'and with an application-level check, this is the only option that cannot be '
    'bypassed by a second concurrent session.';


-- ============================================================================
-- 6. Clinical activity
-- ============================================================================

CREATE TABLE encounter (
    encounter_id    uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id      uuid            NOT NULL
                                    REFERENCES patient(patient_id) ON DELETE RESTRICT,
    doctor_id       uuid            NOT NULL
                                    REFERENCES doctor_profile(staff_id) ON DELETE RESTRICT,
    appointment_id  uuid            UNIQUE
                                    REFERENCES appointment(appointment_id) ON DELETE SET NULL,
    encounter_type  encounter_type  NOT NULL,
    started_at      timestamptz     NOT NULL,
    ended_at        timestamptz,
    chief_complaint varchar(300),
    clinical_notes  text,

    CONSTRAINT encounter_time_order CHECK (ended_at IS NULL OR ended_at >= started_at)
);

COMMENT ON TABLE encounter IS
    'A single clinical contact. Outpatient visits, inpatient reviews and follow-ups '
    'all share this table because they share the same attributes; encounter_type '
    'distinguishes them without a subtype table.';


CREATE TABLE admission (
    admission_id        uuid              PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_id          uuid              NOT NULL
                                          REFERENCES patient(patient_id) ON DELETE RESTRICT,
    encounter_id        uuid              UNIQUE
                                          REFERENCES encounter(encounter_id) ON DELETE SET NULL,
    ward_id             smallint          NOT NULL REFERENCES ward(ward_id) ON DELETE RESTRICT,
    bed_id              uuid              NOT NULL REFERENCES bed(bed_id) ON DELETE RESTRICT,
    admitting_doctor_id uuid              NOT NULL
                                          REFERENCES doctor_profile(staff_id) ON DELETE RESTRICT,
    admitted_at         timestamptz       NOT NULL,
    discharged_at       timestamptz,
    status              admission_status  NOT NULL DEFAULT 'ADMITTED',
    discharge_reason    varchar(200),

    CONSTRAINT admission_time_order
        CHECK (discharged_at IS NULL OR discharged_at >= admitted_at),
    CONSTRAINT admission_discharge_consistency
        CHECK ((status = 'DISCHARGED') = (discharged_at IS NOT NULL))
);

-- A bed can hold at most one patient who has not been discharged.
CREATE UNIQUE INDEX one_active_admission_per_bed
    ON admission (bed_id)
    WHERE discharged_at IS NULL;


CREATE TABLE vitals (
    vitals_id       uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id    uuid          NOT NULL
                                  REFERENCES encounter(encounter_id) ON DELETE CASCADE,
    recorded_at     timestamptz   NOT NULL DEFAULT now(),
    recorded_by     uuid          REFERENCES staff(staff_id) ON DELETE SET NULL,
    temperature_c   numeric(4,1),
    systolic_mmhg   smallint,
    diastolic_mmhg  smallint,
    pulse_bpm       smallint,
    resp_rate       smallint,
    spo2_pct        smallint,
    weight_kg       numeric(5,2),
    height_cm       numeric(5,2),

    CONSTRAINT vitals_temperature  CHECK (temperature_c IS NULL OR temperature_c BETWEEN 25.0 AND 45.0),
    CONSTRAINT vitals_systolic     CHECK (systolic_mmhg  IS NULL OR systolic_mmhg  BETWEEN 40 AND 300),
    CONSTRAINT vitals_diastolic    CHECK (diastolic_mmhg IS NULL OR diastolic_mmhg BETWEEN 20 AND 200),
    CONSTRAINT vitals_pulse        CHECK (pulse_bpm      IS NULL OR pulse_bpm      BETWEEN 20 AND 250),
    CONSTRAINT vitals_resp_rate    CHECK (resp_rate      IS NULL OR resp_rate      BETWEEN 5 AND 60),
    CONSTRAINT vitals_spo2         CHECK (spo2_pct       IS NULL OR spo2_pct       BETWEEN 50 AND 100),
    CONSTRAINT vitals_weight       CHECK (weight_kg      IS NULL OR weight_kg      BETWEEN 0.5 AND 400),
    CONSTRAINT vitals_height       CHECK (height_cm      IS NULL OR height_cm      BETWEEN 20 AND 260),
    CONSTRAINT vitals_bp_order
        CHECK (systolic_mmhg IS NULL OR diastolic_mmhg IS NULL
               OR systolic_mmhg > diastolic_mmhg)
);


CREATE TABLE icd_code (
    icd_code        varchar(10)   PRIMARY KEY,
    description     varchar(200)  NOT NULL,
    chapter         varchar(80)
);

COMMENT ON TABLE icd_code IS
    'Coded diagnoses. A reference table rather than an enum because the code set is '
    'large, externally governed and versioned independently of this schema.';


CREATE TABLE diagnosis (
    diagnosis_id    uuid            PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id    uuid            NOT NULL
                                    REFERENCES encounter(encounter_id) ON DELETE CASCADE,
    icd_code        varchar(10)     NOT NULL
                                    REFERENCES icd_code(icd_code) ON DELETE RESTRICT,
    diagnosis_type  diagnosis_type  NOT NULL DEFAULT 'PRIMARY',
    note            varchar(500),
    diagnosed_at    timestamptz     NOT NULL DEFAULT now()
);

-- Exactly one primary diagnosis per encounter; any number of secondary ones.
CREATE UNIQUE INDEX one_primary_diagnosis_per_encounter
    ON diagnosis (encounter_id)
    WHERE diagnosis_type = 'PRIMARY';


CREATE TABLE medication (
    medication_id   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    name            varchar(120)  NOT NULL,
    form            varchar(30)   NOT NULL,
    strength        varchar(30)   NOT NULL,
    atc_code        varchar(10)   UNIQUE,

    CONSTRAINT medication_unique_presentation UNIQUE (name, form, strength)
);


CREATE TABLE prescription (
    prescription_id uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id    uuid          NOT NULL
                                  REFERENCES encounter(encounter_id) ON DELETE CASCADE,
    medication_id   uuid          NOT NULL
                                  REFERENCES medication(medication_id) ON DELETE RESTRICT,
    dose            varchar(40)   NOT NULL,
    frequency       varchar(40)   NOT NULL,
    route           varchar(20)   NOT NULL,
    duration_days   smallint      NOT NULL,
    quantity        smallint      NOT NULL,
    prescribed_by   uuid          NOT NULL
                                  REFERENCES doctor_profile(staff_id) ON DELETE RESTRICT,
    prescribed_at   timestamptz   NOT NULL DEFAULT now(),
    status          varchar(20)   NOT NULL DEFAULT 'ACTIVE',

    CONSTRAINT prescription_duration_valid CHECK (duration_days BETWEEN 1 AND 365),
    CONSTRAINT prescription_quantity_valid CHECK (quantity > 0),
    CONSTRAINT prescription_status_valid
        CHECK (status IN ('ACTIVE', 'COMPLETED', 'STOPPED'))
);


-- ============================================================================
-- 7. Laboratory
--
-- Deliberately normalised. The same data is re-modelled as documents in
-- Portfolio 4, so the two designs can be compared on evidence rather than opinion.
-- ============================================================================

CREATE TABLE test_catalogue (
    test_code       varchar(10)   PRIMARY KEY,
    test_name       varchar(120)  NOT NULL UNIQUE,
    department_id   smallint      REFERENCES department(department_id) ON DELETE SET NULL,
    specimen_type   varchar(40)   NOT NULL,
    turnaround_hours smallint     NOT NULL,

    CONSTRAINT test_turnaround_positive CHECK (turnaround_hours > 0)
);


CREATE TABLE analyte (
    analyte_id      smallint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    test_code       varchar(10)   NOT NULL
                                  REFERENCES test_catalogue(test_code) ON DELETE CASCADE,
    analyte_name    varchar(80)   NOT NULL,
    unit            varchar(20)   NOT NULL,
    ref_low         numeric(10,3),
    ref_high        numeric(10,3),

    CONSTRAINT analyte_unique_per_test UNIQUE (test_code, analyte_name),
    CONSTRAINT analyte_range_order
        CHECK (ref_low IS NULL OR ref_high IS NULL OR ref_high > ref_low)
);


CREATE TABLE lab_order (
    lab_order_id    uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    encounter_id    uuid          NOT NULL
                                  REFERENCES encounter(encounter_id) ON DELETE RESTRICT,
    test_code       varchar(10)   NOT NULL
                                  REFERENCES test_catalogue(test_code) ON DELETE RESTRICT,
    priority        lab_priority  NOT NULL DEFAULT 'ROUTINE',
    status          lab_status    NOT NULL DEFAULT 'ORDERED',
    ordered_by      uuid          NOT NULL
                                  REFERENCES doctor_profile(staff_id) ON DELETE RESTRICT,
    ordered_at      timestamptz   NOT NULL DEFAULT now(),
    collected_at    timestamptz,
    reported_at     timestamptz,

    CONSTRAINT lab_order_time_order
        CHECK (reported_at IS NULL OR collected_at IS NULL OR reported_at >= collected_at),
    CONSTRAINT lab_order_reported_has_timestamp
        CHECK (status NOT IN ('REPORTED', 'AMENDED') OR reported_at IS NOT NULL),
    CONSTRAINT lab_order_collected_has_timestamp
        CHECK (status NOT IN ('COLLECTED', 'IN_PROGRESS', 'REPORTED', 'AMENDED')
               OR collected_at IS NOT NULL)
);


CREATE TABLE lab_result (
    lab_result_id   uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    lab_order_id    uuid          NOT NULL
                                  REFERENCES lab_order(lab_order_id) ON DELETE CASCADE,
    analyte_id      smallint      NOT NULL
                                  REFERENCES analyte(analyte_id) ON DELETE RESTRICT,
    value_numeric   numeric(10,3),
    value_text      varchar(60),
    flag            result_flag   NOT NULL DEFAULT 'NORMAL',
    resulted_at     timestamptz   NOT NULL DEFAULT now(),
    resulted_by     uuid          REFERENCES staff(staff_id) ON DELETE SET NULL,

    CONSTRAINT lab_result_one_per_analyte UNIQUE (lab_order_id, analyte_id),
    -- A result is either numeric or textual, never both, never neither.
    CONSTRAINT lab_result_value_present CHECK (num_nonnulls(value_numeric, value_text) = 1)
);


-- ============================================================================
-- 8. Audit
-- ============================================================================

CREATE TABLE audit_log (
    audit_id        bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    occurred_at     timestamptz   NOT NULL DEFAULT now(),
    actor_staff_id  uuid          REFERENCES staff(staff_id) ON DELETE SET NULL,
    action          varchar(10)   NOT NULL,
    table_name      varchar(60)   NOT NULL,
    record_id       text,
    old_values      jsonb,
    new_values      jsonb,
    client_addr     inet,

    CONSTRAINT audit_action_valid
        CHECK (action IN ('INSERT', 'UPDATE', 'DELETE', 'READ', 'LOGIN'))
);

CREATE INDEX ix_audit_record ON audit_log (table_name, record_id, occurred_at DESC);
CREATE INDEX ix_audit_time   ON audit_log (occurred_at DESC);


-- Append-only: the log is evidence, so mutation is refused rather than merely
-- discouraged. No UPDATE or DELETE statement can succeed against this table.
CREATE OR REPLACE FUNCTION deny_audit_mutation() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'audit_log is append-only; % is not permitted', TG_OP
        USING ERRCODE = 'insufficient_privilege';
END;
$$;

CREATE TRIGGER trg_audit_append_only
    BEFORE UPDATE OR DELETE ON audit_log
    FOR EACH ROW EXECUTE FUNCTION deny_audit_mutation();


-- Generic row-change audit. The key column name is passed as a trigger argument
-- so one function serves every audited table.
CREATE OR REPLACE FUNCTION audit_row_change() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    v_key text := TG_ARGV[0];
BEGIN
    INSERT INTO audit_log (action, table_name, record_id, old_values, new_values)
    VALUES (
        TG_OP,
        TG_TABLE_NAME,
        CASE WHEN TG_OP = 'DELETE' THEN to_jsonb(OLD) ->> v_key
             ELSE to_jsonb(NEW) ->> v_key END,
        CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END,
        CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END
    );
    RETURN NULL;   -- AFTER trigger; return value is ignored
END;
$$;

CREATE TRIGGER trg_patient_audit
    AFTER INSERT OR UPDATE OR DELETE ON patient
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('patient_id');

CREATE TRIGGER trg_appointment_audit
    AFTER INSERT OR UPDATE OR DELETE ON appointment
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('appointment_id');

CREATE TRIGGER trg_prescription_audit
    AFTER INSERT OR UPDATE OR DELETE ON prescription
    FOR EACH ROW EXECUTE FUNCTION audit_row_change('prescription_id');


-- ============================================================================
-- 9. Deliberately deferred indexes
--
-- PostgreSQL does not automatically index the referencing side of a foreign key.
-- Those indexes are NOT created here on purpose: Portfolio 2 measures the
-- unindexed baseline first, then adds each index against a captured plan. An
-- index added before the measurement proves nothing.
--
-- Only correctness-critical indexes appear above (partial uniques, exclusion).
-- ============================================================================


-- ============================================================================
-- 10. Post-load verification
-- ============================================================================

-- Uncomment and run after seed-data.sql to confirm the model behaves.
--
--   -- Reject a double booking
--   INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end)
--   SELECT patient_id, doctor_id, slot_start + interval '15 min',
--          slot_end + interval '15 min'
--   FROM appointment WHERE status = 'BOOKED' LIMIT 1;
--   -- Expected: ERROR 23P01 conflicting key value violates exclusion constraint
--
--   -- Reject a second primary diagnosis
--   UPDATE diagnosis SET diagnosis_type = 'PRIMARY'
--   WHERE diagnosis_type = 'SECONDARY';
--   -- Expected: ERROR 23505 duplicate key value violates unique constraint
--
--   -- Reject a malformed MRN
--   UPDATE patient SET mrn = 'ABC123' WHERE patient_id = (SELECT min(patient_id) FROM patient);
--   -- Expected: ERROR 23514 new row violates check constraint "patient_mrn_format"
