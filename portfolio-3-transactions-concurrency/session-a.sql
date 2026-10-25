-- ============================================================================
-- Portfolio 3: Concurrency — SESSION A
--
-- Run this in terminal 1, session-b.sql in terminal 2, side by side.
-- Two windows:
--   docker exec -it portfolio-postgres psql -U portfolio -d hospital
-- Then paste or \i this file, stepping through with pauses.
--
-- Do NOT run both scripts in one psql session — that is sequential execution
-- and demonstrates nothing about concurrency.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- Scenario 1: The anomaly — double-booking with no control
-- ----------------------------------------------------------------------------

BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

-- Check the slot is free
--   SELECT appointment_id, doctor_id, slot_start, slot_end
--   FROM appointment
--   WHERE doctor_id = '<doctor>' AND slot_start = '<time>';

-- >>> PAUSE: let Session B also see the slot as free <<<

-- Both sessions now book it.
--   INSERT INTO appointment (appointment_id, doctor_id, slot_start, slot_end, status)
--   VALUES (gen_random_uuid(), '<doctor>', '<time>', '<end>', 'BOOKED');

COMMIT;

-- >>> Observe: two appointments now occupy the same slot <<<
--   SELECT count(*) FROM appointment
--   WHERE doctor_id = '<doctor>' AND slot_start = '<time>';
-- Expected: 2. This is the bug.


-- ----------------------------------------------------------------------------
-- Scenario 2: Pessimistic control — SELECT ... FOR UPDATE
-- Reset the data first (see isolation-tests.md), then:
-- ----------------------------------------------------------------------------

BEGIN;

-- Lock the doctor's row so a competing booking must wait.
--   SELECT * FROM doctor WHERE doctor_id = '<doctor>' FOR UPDATE;

-- >>> PAUSE: start Session B now. It should BLOCK here. <<<
-- >>> In a third window, confirm the wait:
--   SELECT pid, wait_event_type, wait_event FROM pg_stat_activity
--   WHERE datname = 'hospital' AND wait_event IS NOT NULL;

--   INSERT INTO appointment (...) VALUES (...);

COMMIT;

-- >>> Session B unblocks and must now detect the conflict and fail cleanly. <<<


-- ----------------------------------------------------------------------------
-- Scenario 3: Isolation level demonstration
-- ----------------------------------------------------------------------------

-- Non-repeatable read under READ COMMITTED:
BEGIN;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

--   SELECT count(*) FROM appointment WHERE patient_id = '<patient>';

-- >>> PAUSE: Session B inserts and commits a new appointment for this patient <<<

-- Re-read: the number changes inside the same transaction.
--   SELECT count(*) FROM appointment WHERE patient_id = '<patient>';

COMMIT;

-- Repeat the whole scenario under REPEATABLE READ and record that the second
-- read returns the original value. That delta is the evidence.
