-- ============================================================================
-- Portfolio 2: Query Processing and Optimisation
-- Case study: Riverbend Teaching Hospital
--
-- Six business queries written against schema.sql + seed-data.sql. They are
-- written and measured BEFORE any index from indexes.sql exists, so the
-- baseline plans in results/ are honest.
--
-- Measurement windows are anchored to CURRENT_DATE, matching seed-data.sql,
-- which generates 100 days of history and 60 days of future bookings relative
-- to the date the seed is loaded. Timestamps are UTC.
-- ============================================================================

SET TIME ZONE 'UTC';


-- ----------------------------------------------------------------------------
-- Q1. Full clinical history for one patient, most recent first
--
-- Business use: a clinician opens the chart before a consultation. The
-- medical record number is the identifier the clinician has in hand.
--
-- Pressure point: one patient's few encounters are buried in 62,588; the
-- prescription and laboratory counts are correlated subqueries, so a missing
-- index is paid once per encounter rather than once per query.
-- ----------------------------------------------------------------------------
-- >>> Q1
SELECT
    e.encounter_id,
    e.started_at,
    e.encounter_type,
    s.first_name || ' ' || s.last_name AS doctor,
    d.icd_code,
    ic.description AS primary_diagnosis,
    (SELECT count(*) FROM prescription p
      WHERE p.encounter_id = e.encounter_id) AS prescriptions,
    (SELECT count(*) FROM lab_order l
      WHERE l.encounter_id = e.encounter_id) AS lab_orders
FROM patient pt
JOIN encounter e ON e.patient_id = pt.patient_id
JOIN staff s ON s.staff_id = e.doctor_id
LEFT JOIN diagnosis d
       ON d.encounter_id = e.encounter_id
      AND d.diagnosis_type = 'PRIMARY'
LEFT JOIN icd_code ic ON ic.icd_code = d.icd_code
WHERE pt.mrn = 'MRN-0000002'
ORDER BY e.started_at DESC;
-- <<< Q1


-- ----------------------------------------------------------------------------
-- Q2. Appointment load per doctor for the last complete week
--
-- Business use: scheduling and capacity planning. Operations wants to see
-- who is overbooked, who is idle, and how much of the booked time actually
-- turned into a consultation.
--
-- Pressure point: a range predicate on a timestamp column over 82,000 rows,
-- followed by a group-by. The date range selects about 6% of the table.
-- ----------------------------------------------------------------------------
-- >>> Q2
SELECT
    s.employee_no,
    s.first_name || ' ' || s.last_name AS doctor,
    dp.specialty,
    count(*) AS appointments,
    count(*) FILTER (WHERE a.status = 'COMPLETED') AS completed,
    count(*) FILTER (WHERE a.status = 'NO_SHOW') AS no_shows,
    count(*) FILTER (WHERE a.status = 'CANCELLED') AS cancelled
FROM appointment a
JOIN doctor_profile dp ON dp.staff_id = a.doctor_id
JOIN staff s ON s.staff_id = dp.staff_id
WHERE a.slot_start >= CURRENT_DATE - 7
  AND a.slot_start < CURRENT_DATE
GROUP BY s.employee_no, s.first_name, s.last_name, dp.specialty
ORDER BY appointments DESC, s.last_name;
-- <<< Q2


-- ----------------------------------------------------------------------------
-- Q3. Urgent laboratory turnaround by ordering department, last 90 days
--
-- Business use: operational performance reporting. Clinicians care about the
-- urgent tests, not the routine ones, and the report is grouped by the
-- department that ordered the test rather than the laboratory that ran it.
--
-- Pressure point: aggregation over the largest table. Only 10% of orders are
-- urgent, and only 70% of those have been reported, so a partial index has a
-- much smaller working set than the table.
-- ----------------------------------------------------------------------------
-- >>> Q3
SELECT
    d.name AS department,
    count(*) AS urgent_orders,
    round(avg(EXTRACT(EPOCH FROM (l.reported_at - l.collected_at)) / 3600)::numeric, 2)
        AS avg_hours,
    round(percentile_cont(0.9) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (l.reported_at - l.collected_at)) / 3600
    )::numeric, 2) AS p90_hours
FROM lab_order l
JOIN staff s ON s.staff_id = l.ordered_by
JOIN department d ON d.department_id = s.department_id
WHERE l.priority = 'URGENT'
  AND l.reported_at IS NOT NULL
  AND l.ordered_at >= CURRENT_DATE - 90
GROUP BY d.name
ORDER BY avg_hours DESC;
-- <<< Q3


-- ----------------------------------------------------------------------------
-- Q4. Patients with no appointment in the last 12 months
--
-- Business use: re-engagement. The hospital wants a list it can call, not a
-- count, so the query returns patient contact details.
--
-- Pressure point: anti-join over 20,000 patients and 82,000 appointments.
-- Written as NOT EXISTS so a NULL appointment date cannot silently change the
-- result, which is the classic NOT IN trap.
-- ----------------------------------------------------------------------------
-- >>> Q4
SELECT
    p.mrn,
    p.full_name,
    p.phone,
    p.created_at
FROM patient p
WHERE NOT EXISTS (
    SELECT 1
    FROM appointment a
    WHERE a.patient_id = p.patient_id
      AND a.slot_start >= CURRENT_DATE - INTERVAL '12 months'
      AND a.slot_start < CURRENT_DATE
)
ORDER BY p.mrn;
-- <<< Q4


-- ----------------------------------------------------------------------------
-- Q5. Top 10 diagnoses by frequency this year
--
-- Business use: clinical reporting and service planning. Which conditions
-- consume the most consultation time?
--
-- Pressure point: group + sort + limit over 93,846 diagnosis rows. The sort
-- itself is small (20 ICD codes) but the aggregate must read every row.
-- ----------------------------------------------------------------------------
-- >>> Q5
SELECT
    d.icd_code,
    c.description,
    count(*) AS diagnoses,
    count(DISTINCT d.encounter_id) AS encounters
FROM diagnosis d
JOIN icd_code c ON c.icd_code = d.icd_code
WHERE d.diagnosed_at >= date_trunc('year', CURRENT_DATE)::timestamptz
GROUP BY d.icd_code, c.description
ORDER BY diagnoses DESC, d.icd_code
LIMIT 10;
-- <<< Q5


-- ----------------------------------------------------------------------------
-- Q6. Appointments at risk of double-booking a doctor
--
-- Business use: a nightly data-quality audit of the live schedule. The
-- exclusion constraint introduced in Portfolio 1 should make this return no
-- rows; the query is the independent check that proves it, and would catch
-- rows loaded before the constraint existed.
--
-- Pressure point: the obvious self-join on overlapping ranges costs 646 ms
-- because every appointment probes the GiST index and then discards its own
-- row. A window function orders each doctor's appointments once and scans
-- that ordered list, which is O(n log n) instead of O(n * index probes).
--
-- The comparison uses the maximum end of ALL earlier appointments, not just
-- the immediately preceding end. With only lag(slot_end), a long appointment
-- A [09:00-12:00], B [09:15-09:30], C [09:45-10:00] would compare C with B
-- and miss that C overlaps A. The running maximum catches it. The immediate
-- predecessor is still returned for context.
-- ----------------------------------------------------------------------------
-- >>> Q6
WITH live AS (
    SELECT appointment_id, doctor_id, slot_start, slot_end
    FROM appointment
    WHERE status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
      AND slot_start >= CURRENT_DATE
      AND slot_start < CURRENT_DATE + 60
),
flagged AS (
    SELECT l.*,
           max(l.slot_end) OVER w AS latest_previous_end,
           lag(l.appointment_id) OVER w AS previous_appointment
    FROM live l
    WINDOW w AS (
        PARTITION BY l.doctor_id
        ORDER BY l.slot_start, l.appointment_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    )
)
SELECT
    appointment_id       AS appointment_b,
    previous_appointment AS previous_appointment,
    doctor_id,
    latest_previous_end  AS a_end,
    slot_start           AS b_start,
    slot_end             AS b_end
FROM flagged
WHERE latest_previous_end > slot_start
ORDER BY doctor_id, slot_start;
-- <<< Q6


-- ============================================================================
-- Rejected formulations (kept for the before/after record; not executed)
-- ============================================================================

-- Q5 alternative: replace count(DISTINCT encounter_id) with a DISTINCT
-- subquery. This was faster without an index (377 ms vs 1,018 ms) but blocked
-- the covering-index plan (871 ms vs 224 ms) because the DISTINCT step loses
-- the index's icd_code order. The original query + covering index won.
--
-- SELECT x.icd_code, c.description, count(*) AS encounters
-- FROM (
--     SELECT DISTINCT icd_code, encounter_id
--     FROM diagnosis
--     WHERE diagnosed_at >= date_trunc('year', CURRENT_DATE)::timestamptz
-- ) x
-- JOIN icd_code c ON c.icd_code = x.icd_code
-- GROUP BY x.icd_code, c.description
-- ORDER BY encounters DESC, x.icd_code
-- LIMIT 10;

-- Q6 original: range self-join. Correct, but it performs one GiST probe per
-- live appointment (57,300 shared buffers, 646 ms) and returns the same zero
-- rows as the window rewrite. The window version is the final query above.
--
-- SELECT
--     a.appointment_id AS appointment_a,
--     b.appointment_id AS appointment_b,
--     a.doctor_id,
--     a.slot_start AS a_start,
--     a.slot_end   AS a_end,
--     b.slot_start AS b_start,
--     b.slot_end   AS b_end
-- FROM appointment a
-- JOIN appointment b
--   ON b.doctor_id = a.doctor_id
--  AND b.appointment_id > a.appointment_id
--  AND tstzrange(b.slot_start, b.slot_end, '[)') && tstzrange(a.slot_start, a.slot_end, '[)')
-- WHERE a.status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
--   AND b.status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
--   AND a.slot_start >= CURRENT_DATE
--   AND a.slot_start < CURRENT_DATE + 60
-- ORDER BY a.slot_start, b.slot_start;
