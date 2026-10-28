-- ============================================================================
-- Portfolio 4: export the patient IDs that own laboratory orders.
--
-- MongoDB cannot enforce the foreign key from lab_results.patient_id to
-- PostgreSQL patient.patient_id. This small projection is used by the
-- reconciliation check ($lookup) to prove that every document still points at
-- a real patient. It is a cache of identifiers, not a second patient master.
--
-- Run with:
--   psql -U portfolio -d hospital -X -q -A -t -f export-patient-refs.sql
-- ============================================================================

\set ON_ERROR_STOP on
\pset tuples_only on
\pset format unaligned
\pset footer off

SELECT json_build_object(
    '_id', p.patient_id,
    'mrn', p.mrn
)::text
FROM patient p
WHERE EXISTS (
    SELECT 1
    FROM encounter e
    JOIN lab_order lo ON lo.encounter_id = e.encounter_id
    WHERE e.patient_id = p.patient_id
)
ORDER BY p.patient_id;
