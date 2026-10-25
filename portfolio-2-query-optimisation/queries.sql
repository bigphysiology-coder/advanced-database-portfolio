-- ============================================================================
-- Portfolio 2: Query Processing and Optimisation
-- Business queries, written against schema.sql + seed-data.sql
--
-- Write these BEFORE adding any indexes, so the baseline plans are honest.
-- Add indexes afterwards in indexes.sql, one at a time.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Q1. Full clinical history for a patient, most recent first
-- Business use: doctor opens a patient record before a consultation.
-- Pressure point: join fan-out across encounters/diagnoses/prescriptions + sort.
-- ----------------------------------------------------------------------------
-- TODO


-- ----------------------------------------------------------------------------
-- Q2. Doctor workload for a date range
-- Business use: scheduling and capacity planning.
-- Pressure point: range predicate on a timestamp column.
-- ----------------------------------------------------------------------------
-- TODO


-- ----------------------------------------------------------------------------
-- Q3. Average lab turnaround time by department
-- Business use: operational performance reporting.
-- Pressure point: aggregation over the largest tables.
-- ----------------------------------------------------------------------------
-- TODO


-- ----------------------------------------------------------------------------
-- Q4. Patients with no appointment in the last 12 months
-- Business use: re-engagement / dormant patient list.
-- Pressure point: anti-join. Compare NOT EXISTS vs NOT IN vs LEFT JOIN ... IS NULL.
-- ----------------------------------------------------------------------------
-- TODO


-- ----------------------------------------------------------------------------
-- Q5. Top 10 diagnoses by frequency this year
-- Business use: clinical reporting.
-- Pressure point: group + sort + limit.
-- ----------------------------------------------------------------------------
-- TODO


-- ----------------------------------------------------------------------------
-- Q6. Appointments at risk of double-booking a doctor
-- Business use: data quality check.
-- Pressure point: self-join or window function over overlapping time ranges.
-- ----------------------------------------------------------------------------
-- TODO
