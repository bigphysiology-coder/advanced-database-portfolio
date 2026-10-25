-- ============================================================================
-- MIT 8103 Advanced Database Systems
-- Portfolio 1: Seed data
-- Case study: Riverbend Teaching Hospital
--
-- Purpose: populate the schema with enough realistic data that Portfolio 2
-- (execution plans) and Portfolio 3 (concurrency) produce meaningful results.
-- A 20-row table produces an identical plan with or without an index, which
-- makes the optimisation work in P2 impossible to demonstrate.
--
-- Volumes produced (verified by running the script):
--   departments   10        patients        500
--   staff         60        doctor_profile   50
--   wards          6        beds             60
--   schedules    250        appointments   5,700
--   encounters   4,470     vitals         4,470
--   diagnoses    6,652     prescriptions  8,940
--   lab_orders   6,652     lab_results   11,877
--   admissions      72     audit_log     15,140
--
-- Deterministic: every row is derived from a series index, so re-running against
-- a fresh database produces identical data. No random() is used.
--
-- Execution order: schema.sql, then seed-data.sql, against an EMPTY database.
-- ============================================================================

-- Helper: stable, readable hash. Dropped at the end so it does not become part
-- of the assessed schema.
CREATE OR REPLACE FUNCTION seed_hash(text) RETURNS bigint
LANGUAGE sql IMMUTABLE STRICT AS $$
    SELECT abs(hashtext($1)::bigint)
$$;


-- ============================================================================
-- 1. Reference data
-- ============================================================================

INSERT INTO department (code, name, floor, phone) VALUES
    ('MED',   'Internal Medicine',            2, '+254700000101'),
    ('SURG',  'General Surgery',              3, '+254700000102'),
    ('PAED',  'Paediatrics',                  4, '+254700000103'),
    ('OBGYN', 'Obstetrics and Gynaecology',   4, '+254700000104'),
    ('CARD',  'Cardiology',                   2, '+254700000105'),
    ('ONCO',  'Oncology',                     5, '+254700000106'),
    ('PATH',  'Pathology and Laboratory',     1, '+254700000107'),
    ('RAD',   'Radiology',                    1, '+254700000108'),
    ('EMED',  'Emergency Medicine',           0, '+254700000109'),
    ('ADMIN', 'Administration',               6, '+254700000110');


INSERT INTO icd_code (icd_code, description, chapter) VALUES
    ('J06.9', 'Acute upper respiratory infection, unspecified', 'Respiratory'),
    ('I10',   'Essential (primary) hypertension',               'Circulatory'),
    ('A09',   'Infectious gastroenteritis and colitis',         'Infectious'),
    ('M54.5', 'Low back pain',                                  'Musculoskeletal'),
    ('J18.9', 'Pneumonia, unspecified organism',                'Respiratory'),
    ('E11.9', 'Type 2 diabetes mellitus without complications', 'Endocrine'),
    ('K30',   'Functional dyspepsia',                           'Digestive'),
    ('R51',   'Headache',                                       'Symptoms'),
    ('L30.9', 'Dermatitis, unspecified',                        'Skin'),
    ('I25.9', 'Chronic ischaemic heart disease, unspecified',   'Circulatory'),
    ('N39.0', 'Urinary tract infection, site not specified',    'Genitourinary'),
    ('J45.9', 'Asthma, unspecified',                            'Respiratory'),
    ('K21.9', 'Gastro-oesophageal reflux disease',              'Digestive'),
    ('F41.9', 'Anxiety disorder, unspecified',                  'Mental'),
    ('B54',   'Unspecified malaria',                            'Infectious'),
    ('O80',   'Encounter for full-term uncomplicated delivery', 'Pregnancy'),
    ('S52.5', 'Fracture of lower end of radius',                'Injury'),
    ('H10.9', 'Unspecified conjunctivitis',                     'Eye'),
    ('A15.0', 'Tuberculosis of lung',                           'Infectious'),
    ('E78.5', 'Hyperlipidaemia, unspecified',                   'Endocrine');


INSERT INTO medication (name, form, strength, atc_code) VALUES
    ('Paracetamol',        'Tablet',    '500 mg',    'N02BE01'),
    ('Amoxicillin',        'Capsule',   '500 mg',    'J01CA04'),
    ('Ibuprofen',          'Tablet',    '400 mg',    'M01AE01'),
    ('Metformin',          'Tablet',    '500 mg',    'A10BA02'),
    ('Amlodipine',         'Tablet',    '5 mg',      'C08CA01'),
    ('Atorvastatin',       'Tablet',    '20 mg',     'C10AA05'),
    ('Omeprazole',         'Capsule',   '20 mg',     'A02BC01'),
    ('Salbutamol',         'Inhaler',   '100 mcg',   'R03AC02'),
    ('Ceftriaxone',        'Injection', '1 g',       'J01DD04'),
    ('Artemether/Lumefantrine', 'Tablet', '20/120 mg','P01BF01'),
    ('Ferrous sulphate',   'Tablet',    '200 mg',    'B03AA07'),
    ('Hydrocortisone',     'Cream',     '1%',        'D07AA02'),
    ('Lisinopril',         'Tablet',    '10 mg',     'C09AA03'),
    ('Furosemide',         'Tablet',    '40 mg',     'C03CA01'),
    ('Insulin glargine',   'Injection', '100 IU/mL', 'A10AE04');


INSERT INTO test_catalogue (test_code, test_name, department_id, specimen_type, turnaround_hours) VALUES
    ('FBC',  'Full Blood Count',            (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 4),
    ('LIPID','Lipid Profile',               (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 12),
    ('HBA1C','Glycated Haemoglobin',        (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 12),
    ('UEC',  'Urea and Electrolytes',       (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 6),
    ('LFT',  'Liver Function Tests',        (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 12),
    ('TFT',  'Thyroid Function Tests',      (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 24),
    ('CRP',  'C-Reactive Protein',          (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 4),
    ('MP',   'Malaria Parasite Screen',     (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 2),
    ('URIN', 'Urinalysis',                  (SELECT department_id FROM department WHERE code = 'PATH'), 'Urine', 2),
    ('COAG', 'Coagulation Screen',          (SELECT department_id FROM department WHERE code = 'PATH'), 'Blood', 6);


INSERT INTO analyte (test_code, analyte_name, unit, ref_low, ref_high) VALUES
    ('FBC',  'Haemoglobin',        'g/L',     130,  175),
    ('FBC',  'White cell count',   '10^9/L',    4,   11),
    ('FBC',  'Platelets',          '10^9/L',  150,  400),
    ('FBC',  'MCV',                'fL',       80,  100),
    ('LIPID','Total cholesterol',  'mmol/L',    0,  5.0),
    ('LIPID','HDL cholesterol',    'mmol/L',    1.0,2.0),
    ('LIPID','LDL cholesterol',    'mmol/L',    0,  3.0),
    ('LIPID','Triglycerides',      'mmol/L',    0,  1.7),
    ('HBA1C','HbA1c',              '%',         4.0,5.6),
    ('UEC',  'Sodium',             'mmol/L',  135,  145),
    ('UEC',  'Potassium',          'mmol/L',    3.5,5.1),
    ('UEC',  'Urea',               'mmol/L',    2.5,7.1),
    ('UEC',  'Creatinine',         'umol/L',   60,  110),
    ('LFT',  'ALT',                'U/L',      10,   40),
    ('LFT',  'AST',                'U/L',      10,   40),
    ('LFT',  'ALP',                'U/L',      40,  120),
    ('LFT',  'Total bilirubin',    'umol/L',    3,   20),
    ('TFT',  'TSH',                'mIU/L',     0.4, 4.0),
    ('TFT',  'Free T4',            'pmol/L',   10,   22),
    ('CRP',  'C-reactive protein', 'mg/L',      0,    5),
    ('MP',   'Malaria parasites',  'qualitative', NULL, NULL),
    ('URIN', 'pH',                 'pH units',  4.5, 8.0),
    ('URIN', 'Specific gravity',   'ratio',     1.005, 1.030),
    ('COAG', 'Prothrombin time',   'seconds',  11,   14),
    ('COAG', 'INR',                'ratio',     0.8, 1.2);


-- ============================================================================
-- 2. Staff and doctors
-- ============================================================================

INSERT INTO staff (employee_no, first_name, last_name, role, department_id, email, phone, hired_on)
SELECT
    'EMP-' || lpad(g::text, 5, '0'),
    (ARRAY['Amina','Brian','Chloe','Daniel','Esther','Farouk','Grace','Hassan','Irene','James',
           'Kelvin','Lydia','Moses','Nancy','Omar','Peter','Rachel','Samuel','Teresa','Victor'])[1 + (g % 20)],
    (ARRAY['Otieno','Mwangi','Kariuki','Njoroge','Odhiambo','Chebet','Kiptoo','Mutua','Waweru','Auma',
           'Barasa','Cheruiyot','Gitau','Kamau','Langat','Maina','Njeri','Omondi','Rotich','Wafula'])[1 + ((g * 7) % 20)],
    CASE WHEN g <= 50 THEN 'DOCTOR'::staff_role
         WHEN g <= 56 THEN 'NURSE'::staff_role
         WHEN g <= 58 THEN 'RECEPTIONIST'::staff_role
         WHEN g <= 59 THEN 'LAB_TECH'::staff_role
         ELSE 'PHARMACIST'::staff_role END,
    (SELECT d.department_id
       FROM department d
      WHERE d.code = (ARRAY['MED','SURG','PAED','OBGYN','CARD','ONCO','PATH'])[1 + (g % 7)]),
    'staff' || g::text || '@riverbend.example',
    '+254711' || lpad(((g * 7919) % 1000000)::text, 6, '0'),
    DATE '2005-01-01' + ((g * 173) % 7000)
FROM generate_series(1, 60) AS g;


INSERT INTO doctor_profile (staff_id, specialty, license_no, license_expires_on)
SELECT
    s.staff_id,
    (ARRAY['Internal Medicine','General Surgery','Paediatrics','Obstetrics and Gynaecology',
           'Cardiology','Oncology','Pathology'])[1 + (rn % 7)],
    'KMPDC-' || lpad(rn::text, 6, '0'),
    DATE '2027-12-31'
FROM (SELECT staff_id, row_number() OVER (ORDER BY employee_no) AS rn
        FROM staff WHERE role = 'DOCTOR') AS s;


-- ============================================================================
-- 3. Wards and beds
-- ============================================================================

INSERT INTO ward (code, name, ward_type, department_id, capacity) VALUES
    ('MED-A',  'Medical Ward A',      'GENERAL',  (SELECT department_id FROM department WHERE code = 'MED'),   20),
    ('MED-B',  'Medical Ward B',      'GENERAL',  (SELECT department_id FROM department WHERE code = 'MED'),   20),
    ('SURG-A', 'Surgical Ward A',     'SURGICAL', (SELECT department_id FROM department WHERE code = 'SURG'),  20),
    ('PAED-A', 'Paediatric Ward',     'GENERAL',  (SELECT department_id FROM department WHERE code = 'PAED'),  20),
    ('OBGY-A', 'Maternity Ward',      'MATERNITY',(SELECT department_id FROM department WHERE code = 'OBGYN'),20),
    ('ICU',    'Intensive Care Unit', 'ICU',      (SELECT department_id FROM department WHERE code = 'MED'),   10);


INSERT INTO bed (ward_id, bed_number, bed_type)
SELECT w.ward_id,
       lpad(b::text, 2, '0'),
       CASE WHEN w.code = 'ICU' THEN 'ICU' ELSE 'STANDARD' END
FROM ward w
CROSS JOIN generate_series(1, 10) AS b;


-- ============================================================================
-- 4. Schedules
-- ============================================================================

INSERT INTO doctor_schedule (doctor_id, day_of_week, start_time, end_time, slot_minutes, effective_from)
SELECT dp.staff_id, d.day, TIME '09:00', TIME '17:00', 30, DATE '2025-01-01'
FROM doctor_profile dp
CROSS JOIN generate_series(1, 5) AS d(day);


-- ============================================================================
-- 5. Patients
-- ============================================================================

INSERT INTO patient (mrn, first_name, middle_name, last_name, date_of_birth, sex, phone,
                     email, national_id, address_line, city, blood_group, created_at)
SELECT
    'MRN-' || lpad(g::text, 7, '0'),
    (ARRAY['Amina','Brian','Chloe','Daniel','Esther','Farouk','Grace','Hassan','Irene','James',
           'Kelvin','Lydia','Moses','Nancy','Omar','Peter','Rachel','Samuel','Teresa','Victor'])[1 + (g % 20)],
    CASE WHEN g % 5 = 0
         THEN (ARRAY['Wanjiku','Ochieng','Achieng','Kimani'])[1 + (g % 4)] END,
    (ARRAY['Otieno','Mwangi','Kariuki','Njoroge','Odhiambo','Chebet','Kiptoo','Mutua','Waweru','Auma',
           'Barasa','Cheruiyot','Gitau','Kamau','Langat','Maina','Njeri','Omondi','Rotich','Wafula'])[1 + ((g * 3) % 20)],
    DATE '1940-01-01' + ((g * 7919) % 28000),
    (ARRAY['F','M','F','M','O','U'])[1 + (g % 6)]::sex_type,
    '+2547' || lpad(((g * 1234567) % 100000000)::text, 8, '0'),
    lower((ARRAY['amina','brian','chloe','daniel','esther','farouk','grace','hassan','irene','james',
                 'kelvin','lydia','moses','nancy','omar','peter','rachel','samuel','teresa','victor'])[1 + (g % 20)])
        || '.' || g::text || '@example.com',
    CASE WHEN g % 10 = 0 THEN NULL ELSE 'ID' || lpad(g::text, 8, '0') END,
    ((g * 13) % 400)::text || ' Riverside Drive',
    (ARRAY['Nairobi','Mombasa','Kisumu','Nakuru','Eldoret'])[1 + (g % 5)],
    (ARRAY['A+','A-','B+','B-','AB+','AB-','O+','O-'])[1 + (g % 8)],
    timestamptz '2020-01-01 08:00:00+03' + ((g % 2000) * interval '1 day')
FROM generate_series(1, 500) AS g;


INSERT INTO next_of_kin (patient_id, full_name, relationship, phone, is_primary)
SELECT p.patient_id,
       (ARRAY['Mary','Joseph','Ann','David','Susan','Michael'])[1 + (seed_hash(p.patient_id::text) % 6)]
         || ' ' || (ARRAY['Otieno','Mwangi','Kariuki','Njoroge'])[1 + (seed_hash(p.patient_id::text) % 4)],
       (ARRAY['Spouse','Parent','Sibling','Child','Guardian'])[1 + (seed_hash(p.patient_id::text) % 5)],
       '+2547' || lpad((seed_hash(p.patient_id::text || 'kin') % 100000000)::text, 8, '0'),
       true
FROM patient p
WHERE seed_hash(p.patient_id::text) % 10 < 6;


-- ============================================================================
-- 6. Appointments
--
-- Constructed so that (doctor, day) is unique: 50 doctors x 100 days = 5,000.
-- Guaranteed injective, therefore no accidental exclusion-constraint failure.
-- ============================================================================

WITH docs AS (
    SELECT dp.staff_id, row_number() OVER (ORDER BY s.employee_no) - 1 AS rn
    FROM doctor_profile dp
    JOIN staff s ON s.staff_id = dp.staff_id
),
pts AS (
    SELECT patient_id, row_number() OVER (ORDER BY mrn) - 1 AS rn
    FROM patient
)
INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason,
                         booked_by, created_at, cancelled_at)
SELECT
    p.patient_id,
    d.staff_id,
    ts,
    ts + interval '30 minutes',
    st.status,
    (ARRAY['Fever and headache','Chest pain','Persistent cough','Abdominal pain',
           'Lower back pain','Shortness of breath','Fatigue','Routine review'])[1 + (n % 8)],
    (SELECT staff_id FROM staff WHERE role = 'RECEPTIONIST' ORDER BY employee_no LIMIT 1),
    ts - interval '3 days',
    CASE WHEN st.status = 'CANCELLED' THEN ts - interval '1 day' END
FROM generate_series(1, 5000) AS n
JOIN docs d ON d.rn = (n - 1) % 50
JOIN pts  p ON p.rn = (n * 13) % 500
CROSS JOIN LATERAL (
    SELECT (CURRENT_DATE - 100 + ((n - 1) / 50))::date AS day
) AS dd
CROSS JOIN LATERAL (
    SELECT (dd.day + TIME '09:00' + (((n - 1) / 50) % 8) * interval '30 minutes')::timestamptz AS ts
) AS tt
CROSS JOIN LATERAL (
    SELECT CASE WHEN n % 20 = 0 THEN 'CANCELLED'::appointment_status
                WHEN n % 17 = 0 THEN 'NO_SHOW'::appointment_status
                ELSE 'COMPLETED'::appointment_status END AS status
) AS st;


-- Upcoming appointments: 50 doctors x 14 days, one slot each. These are the
-- rows Portfolio 3 contends over.
WITH docs AS (
    SELECT dp.staff_id, row_number() OVER (ORDER BY s.employee_no) - 1 AS rn
    FROM doctor_profile dp
    JOIN staff s ON s.staff_id = dp.staff_id
),
pts AS (
    SELECT patient_id, row_number() OVER (ORDER BY mrn) - 1 AS rn
    FROM patient
)
INSERT INTO appointment (patient_id, doctor_id, slot_start, slot_end, status, reason,
                         booked_by, created_at)
SELECT
    p.patient_id,
    d.staff_id,
    (CURRENT_DATE + 1 + k) + TIME '10:00' + (d.rn % 8) * interval '30 minutes',
    (CURRENT_DATE + 1 + k) + TIME '10:30' + (d.rn % 8) * interval '30 minutes',
    'BOOKED',
    'Follow-up review',
    (SELECT staff_id FROM staff WHERE role = 'RECEPTIONIST' ORDER BY employee_no LIMIT 1),
    now() - interval '2 days'
FROM generate_series(0, 13) AS k
CROSS JOIN docs d
JOIN pts p ON p.rn = ((k * 37) + d.rn) % 500;


-- ============================================================================
-- 7. Clinical encounters
-- ============================================================================

INSERT INTO encounter (patient_id, doctor_id, appointment_id, encounter_type,
                       started_at, ended_at, chief_complaint)
SELECT a.patient_id, a.doctor_id, a.appointment_id, 'OPD',
       a.slot_start,
       a.slot_start + interval '20 minutes',
       (ARRAY['Fever and headache','Chest pain','Persistent cough','Abdominal pain',
              'Lower back pain','Shortness of breath','Fatigue','Joint pain',
              'Skin rash','Routine review'])[1 + (seed_hash(a.appointment_id::text) % 10)]
FROM appointment a
WHERE a.status = 'COMPLETED';


INSERT INTO vitals (encounter_id, recorded_at, recorded_by, temperature_c,
                    systolic_mmhg, diastolic_mmhg, pulse_bpm, resp_rate, spo2_pct,
                    weight_kg, height_cm)
SELECT e.encounter_id,
       e.started_at,
       (SELECT s.staff_id FROM staff s
         WHERE s.role = 'NURSE'
         ORDER BY seed_hash(e.encounter_id::text || s.staff_id::text) LIMIT 1),
       round((36.2 + (seed_hash(e.encounter_id::text || 't') % 30)::numeric / 10)::numeric, 1),
       100 + (seed_hash(e.encounter_id::text || 's') % 60)::int,
        60 + (seed_hash(e.encounter_id::text || 'd') % 30)::int,
        60 + (seed_hash(e.encounter_id::text || 'p') % 60)::int,
        12 + (seed_hash(e.encounter_id::text || 'r') % 12)::int,
        90 + (seed_hash(e.encounter_id::text || 'o') % 10)::int,
        45 + (seed_hash(e.encounter_id::text || 'w') % 70)::numeric,
       140 + (seed_hash(e.encounter_id::text || 'h') % 60)::numeric
FROM encounter e;


INSERT INTO diagnosis (encounter_id, icd_code, diagnosis_type, note, diagnosed_at)
SELECT e.encounter_id,
       (SELECT c.icd_code FROM icd_code c
         ORDER BY seed_hash(e.encounter_id::text || c.icd_code) LIMIT 1),
       'PRIMARY',
       NULL,
       e.started_at + interval '15 minutes'
FROM encounter e;


INSERT INTO diagnosis (encounter_id, icd_code, diagnosis_type, note, diagnosed_at)
SELECT e.encounter_id,
       (SELECT c.icd_code FROM icd_code c
         ORDER BY seed_hash(e.encounter_id::text || 'sec' || c.icd_code) LIMIT 1),
       'SECONDARY',
       'Noted during review',
       e.started_at + interval '16 minutes'
FROM encounter e
WHERE seed_hash(e.encounter_id::text) % 2 = 0;


-- ============================================================================
-- 8. Admissions (all discharged, so no active-bed conflict is possible)
-- ============================================================================

INSERT INTO admission (patient_id, encounter_id, ward_id, bed_id, admitting_doctor_id,
                       admitted_at, discharged_at, status, discharge_reason)
SELECT e.patient_id, e.encounter_id, b.ward_id, b.bed_id, e.doctor_id,
       e.started_at,
       e.started_at + ((3 + (seed_hash(e.encounter_id::text) % 5)) * interval '1 day'),
       'DISCHARGED',
       (ARRAY['Recovered','Improved','Transferred to another facility','Stable on discharge'])[1 + (seed_hash(e.encounter_id::text) % 4)]
FROM encounter e
JOIN LATERAL (
    SELECT bd.bed_id, bd.ward_id
    FROM bed bd
    ORDER BY seed_hash(e.encounter_id::text || bd.bed_id::text)
    LIMIT 1
) AS b ON true
WHERE seed_hash(e.encounter_id::text) % 70 = 0;


-- ============================================================================
-- 9. Prescriptions
-- ============================================================================

INSERT INTO prescription (encounter_id, medication_id, dose, frequency, route,
                          duration_days, quantity, prescribed_by, prescribed_at, status)
SELECT e.encounter_id,
       m.medication_id,
       (ARRAY['1 tablet','1 capsule','5 mL','1 puff','2 tablets'])[1 + (seed_hash(e.encounter_id::text) % 5)],
       (ARRAY['Once daily','Twice daily','Three times daily','As required','At bedtime'])[1 + (seed_hash(e.encounter_id::text || 'f') % 5)],
       (ARRAY['Oral','Oral','Oral','Topical','Inhalation'])[1 + (seed_hash(e.encounter_id::text || 'r') % 5)],
       3 + (seed_hash(e.encounter_id::text || 'd') % 12)::int,
       6 + (seed_hash(e.encounter_id::text || 'q') % 30)::int,
       e.doctor_id,
       e.started_at,
       'ACTIVE'
FROM encounter e
CROSS JOIN LATERAL (
    SELECT md.medication_id
    FROM medication md
    ORDER BY seed_hash(e.encounter_id::text || md.medication_id::text)
    LIMIT 2
) AS m;


-- ============================================================================
-- 10. Laboratory orders and results
-- ============================================================================

WITH src AS (
    SELECT e.encounter_id, e.doctor_id, e.started_at, k,
           (SELECT tc.test_code
              FROM test_catalogue tc
             ORDER BY seed_hash(e.encounter_id::text || k::text || tc.test_code)
             LIMIT 1) AS test_code
    FROM encounter e
    CROSS JOIN generate_series(1, 2) AS k
    WHERE k = 1 OR seed_hash(e.encounter_id::text) % 2 = 0
),
calc AS (
    SELECT s.*,
           (SELECT tc.turnaround_hours FROM test_catalogue tc WHERE tc.test_code = s.test_code) AS tat_hours,
           seed_hash(s.encounter_id::text || s.k::text) % 10 AS bucket
    FROM src s
)
INSERT INTO lab_order (encounter_id, test_code, priority, status, ordered_by,
                       ordered_at, collected_at, reported_at)
SELECT
    c.encounter_id,
    c.test_code,
    CASE WHEN c.bucket = 0 THEN 'URGENT'::lab_priority ELSE 'ROUTINE'::lab_priority END,
    CASE WHEN c.bucket <= 6 THEN 'REPORTED'::lab_status
         WHEN c.bucket = 7 THEN 'IN_PROGRESS'::lab_status
         WHEN c.bucket = 8 THEN 'COLLECTED'::lab_status
         ELSE 'ORDERED'::lab_status END,
    c.doctor_id,
    c.started_at + interval '10 minutes',
    CASE WHEN c.bucket <= 8 THEN c.started_at + interval '70 minutes' END,
    CASE WHEN c.bucket <= 6
         THEN c.started_at + interval '70 minutes' + (c.tat_hours * interval '1 hour') END
FROM calc c;


INSERT INTO lab_result (lab_order_id, analyte_id, value_numeric, value_text, flag,
                        resulted_at, resulted_by)
SELECT
    lo.lab_order_id,
    an.analyte_id,
    CASE WHEN an.ref_low IS NOT NULL OR an.ref_high IS NOT NULL THEN
        CASE
            -- 70% of values land inside the reference range, 30% outside, so the
            -- flag column is exercised rather than uniformly NORMAL.
            WHEN seed_hash(lo.lab_order_id::text || an.analyte_id::text) % 10 < 7
                THEN round((COALESCE(an.ref_low, 0)
                            + (COALESCE(an.ref_high, COALESCE(an.ref_low, 0) + 10)
                               - COALESCE(an.ref_low, 0))
                              * (0.10 + (seed_hash(lo.lab_order_id::text || an.analyte_id::text || 'v') % 80)::numeric / 100))::numeric, 3)
            WHEN seed_hash(lo.lab_order_id::text || an.analyte_id::text) % 2 = 0
                THEN round((COALESCE(an.ref_high, 10) * 1.25)::numeric, 3)
            ELSE round((COALESCE(an.ref_low, 0) * 0.75)::numeric, 3)
        END
    END,
    CASE WHEN an.ref_low IS NULL AND an.ref_high IS NULL
         THEN (ARRAY['Not detected','P. falciparum detected','P. malariae detected'])[1 + (seed_hash(lo.lab_order_id::text || an.analyte_id::text) % 3)]
    END,
    'NORMAL',   -- corrected below
    lo.reported_at,
    (SELECT s.staff_id FROM staff s WHERE s.role = 'LAB_TECH'
      ORDER BY seed_hash(lo.lab_order_id::text || s.staff_id::text) LIMIT 1)
FROM lab_order lo
JOIN analyte an ON an.test_code = lo.test_code
WHERE lo.status = 'REPORTED';


-- Now set the flag from the value actually stored, so the data is internally
-- consistent rather than carrying a placeholder.
UPDATE lab_result r
SET flag = CASE
    WHEN r.value_numeric IS NULL THEN 'NORMAL'::result_flag
    WHEN a.ref_low IS NOT NULL AND r.value_numeric < a.ref_low  THEN 'LOW'::result_flag
    WHEN a.ref_high IS NOT NULL AND r.value_numeric > a.ref_high THEN 'HIGH'::result_flag
    ELSE 'NORMAL'::result_flag
END
FROM analyte a
WHERE a.analyte_id = r.analyte_id;


-- ============================================================================
-- 11. Refresh statistics
-- ============================================================================

ANALYZE;


-- ============================================================================
-- 12. Verification
-- ============================================================================

SELECT 'department' AS table_name, count(*) FROM department
UNION ALL SELECT 'staff',          count(*) FROM staff
UNION ALL SELECT 'doctor_profile', count(*) FROM doctor_profile
UNION ALL SELECT 'patient',        count(*) FROM patient
UNION ALL SELECT 'next_of_kin',    count(*) FROM next_of_kin
UNION ALL SELECT 'ward',           count(*) FROM ward
UNION ALL SELECT 'bed',            count(*) FROM bed
UNION ALL SELECT 'doctor_schedule',count(*) FROM doctor_schedule
UNION ALL SELECT 'appointment',    count(*) FROM appointment
UNION ALL SELECT 'encounter',      count(*) FROM encounter
UNION ALL SELECT 'admission',      count(*) FROM admission
UNION ALL SELECT 'vitals',         count(*) FROM vitals
UNION ALL SELECT 'diagnosis',      count(*) FROM diagnosis
UNION ALL SELECT 'prescription',   count(*) FROM prescription
UNION ALL SELECT 'lab_order',      count(*) FROM lab_order
UNION ALL SELECT 'lab_result',     count(*) FROM lab_result
UNION ALL SELECT 'audit_log',      count(*) FROM audit_log
ORDER BY table_name;


DROP FUNCTION seed_hash(text);
