# Transactions and Concurrency — Test Record

Environment: PostgreSQL _<version>_, isolation level default `READ COMMITTED`.
Two `psql` sessions against the same database, side by side.

---

## Test 1 — Atomic COMMIT

**Transaction:** booking an appointment, which writes `appointment` and `audit_log`.

| Step | Session | Statement | Result |
|---|---|---|---|
| 1 | A | `BEGIN` | |
| 2 | A | `INSERT INTO appointment ...` | |
| 3 | A | `INSERT INTO audit_log ...` | |
| 4 | A | `COMMIT` | |

**Verification:** `SELECT count(*)` on both tables before and after.

**Evidence:** _<screenshot filename>_

---

## Test 2 — ROLLBACK on constraint violation

**Transaction:** same unit, second statement violates _<which constraint>_.

```text
ERROR:  <paste the exact error message here>
```

**Verification:** row counts unchanged after `ROLLBACK`.

**Observation:** _<what this proves — e.g. "the appointment insert was not left behind
even though it succeeded, because the transaction never committed.">_

**Evidence:** _<screenshot filename>_

---

## Test 3 — SAVEPOINT partial rollback

_(order created, one result rolled back, corrected result committed)_

**Verification:** the order and exactly one result exist.

---

## Test 4 — The anomaly: double-booking

**Setup:** `doctor_id = '<id>'`, `slot_start = '<time>'`, zero existing appointments.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | check availability | 0 rows |
| 2 | B | check availability | 0 rows |
| 3 | A | insert appointment | success |
| 4 | B | insert appointment | success |
| 5 | A | `COMMIT` | |
| 6 | B | `COMMIT` | |

**Result:** `SELECT count(*)` returns **2** for the same doctor and slot.

**Analysis:** Both transactions read a snapshot in which the slot was free. Neither
write conflicted at the storage level, because they inserted different rows. `READ
COMMITTED` permits this — it prevents dirty reads, not phantom writes.

**Evidence:** _<two-window screenshot>_

---

## Test 5 — Pessimistic control: `SELECT ... FOR UPDATE`

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | `SELECT * FROM doctor WHERE ... FOR UPDATE` | lock acquired |
| 2 | B | same `SELECT ... FOR UPDATE` | **blocked** |
| 3 | A | insert + `COMMIT` | |
| 4 | B | unblocks, re-checks, sees 1 row | `ROLLBACK` |

**Blocking evidence:** from a third session,

```sql
SELECT pid, wait_event_type, wait_event, state
FROM pg_stat_activity WHERE datname = 'hospital';
```

```text
-- paste output showing wait_event = 'transactionid'
```

**Measured wait:** _<seconds>_

**Assessment:** correct outcome, but the second booking waited for the first to finish
and then had to fail at the application layer. Serialisation reduces throughput on
exactly the hot rows that matter (popular doctors, peak slots).

**Evidence:** _<screenshot>_

---

## Test 6 — Optimistic control

Chosen mechanism: _<version column with conditional UPDATE | EXCLUDE USING gist>_

```sql
-- the constraint or conditional update
```

**Result under contention:** _<e.g. second transaction affects 0 rows and retries;
or the exclusion constraint raises 23P01>_

```text
-- paste the error or the 0-row update
```

**Comparison:**

| Mechanism | Throughput under contention | Failure mode | Best suited to |
|---|---|---|---|
| None | Highest | Silent data corruption | never |
| `FOR UPDATE` | Lowest | Blocking, then application-level retry | short, predictable contention |
| Version column | High | Lost update returns 0 rows, caller retries | low-contention writes |
| `EXCLUDE` constraint | High | `23P01` at commit | invariants that must never break |

**Conclusion:** _<which mechanism was adopted for this case study and why>_

---

## Test 7 — Isolation levels

Same read performed twice inside one transaction, with a concurrent committed write in
between.

| Isolation level | First read | Second read | Anomaly observed |
|---|---|---|---|
| READ COMMITTED | | | non-repeatable read |
| REPEATABLE READ | | | none |
| SERIALIZABLE | | | none, plus possible `40001` on write skew |

**Conclusion:** _<the trade-off between isolation and retry handling, in your own words>_
