-- ============================================================================
-- Portfolio 3: Transactions
-- Single-session scenarios: COMMIT, ROLLBACK, SAVEPOINT.
-- Run with psql so you can see the output:
--   docker exec -it portfolio-postgres psql -U portfolio -d hospital -f /path/to/file
-- ============================================================================

-- ----------------------------------------------------------------------------
-- T1. Successful multi-table write — appointment + audit row
-- Demonstrates atomicity: either both rows exist or neither does.
-- ----------------------------------------------------------------------------
BEGIN;

--   INSERT INTO appointment (...) VALUES (...);
--   INSERT INTO audit_log (...) VALUES (...);

-- Confirm within the transaction, then commit
--   SELECT ...;

COMMIT;


-- ----------------------------------------------------------------------------
-- T2. Failed write — constraint violation, full rollback
-- The second statement must violate a real constraint (FK, CHECK or EXCLUDE).
-- Capture the exact error message: it is part of the evidence.
-- ----------------------------------------------------------------------------
BEGIN;

--   INSERT INTO appointment (...) VALUES (...);
--   INSERT INTO appointment (...) VALUES (...);   -- violates a constraint

-- After the error:
ROLLBACK;

-- Prove nothing survived:
--   SELECT count(*) FROM appointment WHERE ...;


-- ----------------------------------------------------------------------------
-- T3. Savepoint — partial rollback
-- A lab order is created; one result row is bad; the order survives, the row does not.
-- ----------------------------------------------------------------------------
BEGIN;

--   INSERT INTO lab_order (...) VALUES (...);
--   SAVEPOINT after_order;

--   INSERT INTO lab_result (...) VALUES (...);        -- good
--   INSERT INTO lab_result (...) VALUES (...);        -- bad: violates CHECK

--   ROLLBACK TO SAVEPOINT after_order;
--   INSERT INTO lab_result (...) VALUES (...);        -- corrected version

COMMIT;

-- Show that the order and one result exist, and the bad row never did.


-- ----------------------------------------------------------------------------
-- Useful inspection queries during these tests
-- ----------------------------------------------------------------------------

-- Am I inside a transaction, and at what isolation level?
-- SHOW transaction_isolation;
-- SELECT txid_current();

-- What is blocking what, right now? (run from a third session)
-- SELECT pid, wait_event_type, wait_event, state, left(query, 60)
-- FROM pg_stat_activity WHERE datname = 'hospital';

-- Locks held on a specific table
-- SELECT * FROM pg_locks WHERE relation = 'appointment'::regclass;
