-- ============================================================================
-- Portfolio 4: export the P1 laboratory data as newline-delimited JSON.
--
-- One line per lab order. Results are embedded as an array. Timestamps are
-- emitted as ISO-8601 strings; transform-lab-results.js converts them to BSON
-- dates before the documents enter the validated collection.
--
-- Run with:
--   psql -U portfolio -d hospital -X -q -A -t -f export-lab-results.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
\pset footer off

WITH orders AS (
    SELECT
        lo.lab_order_id,
        lo.encounter_id,
        e.patient_id,
        p.mrn AS patient_mrn,
        lo.test_code,
        tc.test_name,
        tc.specimen_type,
        d.name AS department,
        lo.priority,
        lo.status,
        lo.ordered_at,
        lo.collected_at,
        lo.reported_at,
        lo.ordered_by
    FROM lab_order lo
    JOIN encounter e       ON e.encounter_id = lo.encounter_id
    JOIN patient p         ON p.patient_id = e.patient_id
    JOIN test_catalogue tc ON tc.test_code = lo.test_code
    LEFT JOIN department d ON d.department_id = tc.department_id
),
results AS (
    SELECT
        lr.lab_order_id,
        json_agg(
            json_build_object(
                'analyte_id',  a.analyte_id,
                'analyte',     a.analyte_name,
                'value',       CASE
                                   WHEN lr.value_numeric IS NOT NULL
                                   THEN to_jsonb(lr.value_numeric)
                                   ELSE to_jsonb(lr.value_text)
                               END,
                'value_type',  CASE
                                   WHEN lr.value_numeric IS NOT NULL
                                   THEN 'numeric'
                                   ELSE 'text'
                               END,
                'unit',        a.unit,
                'ref_low',     a.ref_low,
                'ref_high',    a.ref_high,
                'flag',        lr.flag,
                'resulted_at', lr.resulted_at,
                'resulted_by', lr.resulted_by
            )
            ORDER BY a.analyte_id
        ) AS results
    FROM lab_result lr
    JOIN analyte a ON a.analyte_id = lr.analyte_id
    GROUP BY lr.lab_order_id
)
SELECT json_build_object(
    'order_id',      o.lab_order_id,
    'encounter_id',  o.encounter_id,
    'patient_id',    o.patient_id,
    'patient_mrn',   o.patient_mrn,
    'test_code',     o.test_code,
    'test_name',     o.test_name,
    'specimen_type', o.specimen_type,
    'department',    o.department,
    'priority',      o.priority,
    'status',        o.status,
    'ordered_at',    o.ordered_at,
    'collected_at',  o.collected_at,
    'reported_at',   o.reported_at,
    'ordered_by',    o.ordered_by,
    'results',       COALESCE(r.results, '[]'::json)
)::text
FROM orders o
LEFT JOIN results r USING (lab_order_id)
ORDER BY o.lab_order_id;
