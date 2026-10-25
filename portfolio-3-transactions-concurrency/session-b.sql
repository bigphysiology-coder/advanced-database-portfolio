-- ============================================================================
-- Portfolio 3: Concurrency — SESSION B
--
-- Run in terminal 2, alongside session-a.sql in terminal 1.
-- The value of this file is its TIMING: it must run while Session A is
-- mid-transaction. Wait for the ">>> PAUSE" marker in Session A before acting.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Scenario 1: The anomaly — both sessions book the same slot
-- ----------------------------------------------------------------------------

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- Both sessions see the slot as free, because neither has committed yet.
--   SELECT appointment_id FROM appointment
--   WHERE doctor_id = '<doctor>' AND slot_start = '<time>';
-- Expected: 0 rows.

-- >>> Perform this AFTER Session A has done its availability check <<<

--   INSERT INTO appointment (appointment_id, doctor_id, slot_start, slot_end, status)
--   VALUES (gen_random_uuid(), '<doctor>', '<time>', '<end>', 'BOOKED');

COMMIT;

-- >>> Now both rows exist. Neither transaction could see the other's write.
--     This is the double-booking anomaly: correct under READ COMMITTED,
--     catastrophic for the business rule. <<<


-- ----------------------------------------------------------------------------
-- Scenario 2: Pessimistic control — B should block on A's lock
-- ----------------------------------------------------------------------------

BEGIN;

-- This will hang while Session A holds SELECT ... FOR UPDATE on the doctor row.
-- >>> Confirm the block in a third window via pg_stat_activity, screenshot it,
--     then let Session A commit. <<<

--   SELECT * FROM doctor WHERE doctor_id = '<doctor>' FOR UPDATE;

-- Once unblocked, the correct behaviour is to re-check availability and fail:
--   SELECT count(*) FROM appointment
--   WHERE doctor_id = '<doctor>' AND slot_start = '<time>';
-- Expected now: 1 row — A's booking is visible.
--   ROLLBACK;   -- abandon this booking attempt, surface the conflict to the user

ROLLBACK;

-- >>> Record the elapsed wait time. That number is the cost of pessimistic locking. <<<


-- ----------------------------------------------------------------------------
-- Scenario 3: Isolation level demonstration — commit a change mid-transaction
-- ----------------------------------------------------------------------------

BEGIN;

--   INSERT INTO appointment (appointment_id, patient_id, doctor_id, slot_start, slot_end, status)
--   VALUES (gen_random_uuid(), '<patient>', '<doctor>', '<time>', '<end>', 'BOOKED');

COMMIT;

-- >>> Session A's second read now returns a different count under
--     READ COMMITTED, and the original count under REPEATABLE READ. <<<


-- ----------------------------------------------------------------------------
-- Scenario 4 (optional, strong): write skew under SERIALIZABLE
-- Two doctors each go off-duty because the other is covering.
-- Each transaction reads the other's status as ON_DUTY, both write.
-- ----------------------------------------------------------------------------

-- BEGIN;
-- SET TRANSACTION ISOLATION LEVEL SERIALIZABLE;
--   SELECT status FROM doctor WHERE doctor_id IN ('<a>', '<b>');
--   UPDATE doctor SET status = 'OFF_DUTY' WHERE doctor_id = '<a>';
-- COMMIT;
-- Expect: ERROR: could not serialize access due to read/write dependencies
-- Capture the SQLSTATE (40001) verbatim.
