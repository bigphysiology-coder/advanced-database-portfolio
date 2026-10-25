# Portfolio 3 — Transactions and Concurrency

**Marks:** 7 / 40

## Required Evidence

- [ ] Transaction examples showing `COMMIT`
- [ ] Transaction examples showing `ROLLBACK`
- [ ] Isolation level demonstration
- [ ] A concurrency issue **or** a concurrency control mechanism
- [ ] Screenshots / output evidence

## Files

| File | Purpose |
|---|---|
| `transactions.sql` | Single-session COMMIT and ROLLBACK scenarios |
| `session-a.sql` | Concurrent session 1 (run in one terminal) |
| `session-b.sql` | Concurrent session 2 (run in a second terminal) |
| `isolation-tests.md` | The anomaly demonstrated, and the fix |

## Why Two Sessions

A concurrency anomaly cannot be shown by one script. It requires two connections whose
statements interleave. The scripts are written with **explicit pauses**, so the
interleaving is visible in the terminal and capturable in a screenshot:

```
Session A                          Session B
---------                          ---------
BEGIN;
UPDATE appointments ...
                                   BEGIN;
                                   UPDATE appointments ...
                                   -- blocks
COMMIT;                            -- unblocks, then reads stale/new value
```

Run them in two windows side by side and screenshot the pair. A single cropped window
proves nothing.

## Scenarios to Cover

### A. Commit and rollback

| # | Scenario | What it demonstrates |
|---|---|---|
| 1 | Book an appointment: insert appointment + audit row, `COMMIT` | Atomicity of a multi-table unit |
| 2 | Same, but the second insert violates a constraint → `ROLLBACK` | Nothing partial survives |
| 3 | Savepoint: partial rollback inside a longer transaction | `SAVEPOINT` / `ROLLBACK TO` |

### B. Isolation levels

PostgreSQL uses MVCC; the standard anomalies to demonstrate are:

| Level | Anomaly to attempt | Expected result in PostgreSQL |
|---|---|---|
| READ COMMITTED (default) | Non-repeatable read | Second read sees the committed change |
| REPEATABLE READ | Non-repeatable read | Same row returned both times |
| SERIALIZABLE | Write skew | One transaction aborts with a serialisation failure |

### C. The concurrency issue and its control

The natural one for this case study is **double-booking**: two receptionists book the
same doctor into the same slot simultaneously.

Demonstrate all three, in order, and state the trade-off of each:

1. **The anomaly** — no constraint, both transactions commit, two appointments exist.
2. **Pessimistic control** — `SELECT ... FOR UPDATE` on the doctor's availability row.
   Show Session B blocking, then failing cleanly.
3. **Optimistic control** — a version column with a conditional update, or an exclusion
   constraint (`EXCLUDE USING gist` on a doctor + time range). Show the retry.

The `EXCLUDE` constraint is the strongest answer here because it enforces the invariant
in the database rather than trusting the application. If you use it, explain
`btree_gist` in the write-up.

## Evidence Checklist

- [ ] Two-window screenshots with timestamps or a visible prompt distinguishing A from B
- [ ] The blocking state visible (`pg_stat_activity` showing `wait_event = 'transactionid'`)
- [ ] `ROLLBACK` output proving no orphan rows (`SELECT count(*)` before and after)
- [ ] Isolation test logs showing the actual anomaly, not a description of it
- [ ] The deadlock or serialisation error captured verbatim
