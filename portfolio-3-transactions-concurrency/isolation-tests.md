# Transactions and Concurrency — Test Record

**Environment:** PostgreSQL 16.15 (Debian) in Docker Desktop on Windows; database
`hospital`; default isolation `READ COMMITTED`; `psql` with `\timing on` and
`VERBOSITY verbose` so SQLSTATE codes appear in the raw output.

**Method:** two independent `psql` connections for every concurrency test, never
one script run sequentially. Session B is launched 1.2 s after A. A monitor
inside the container samples `pg_stat_activity` every ~300 ms. The timestamps in
the logs are server time in UTC. The production `appointment` constraint is never
dropped; the unprotected baseline uses a separate table with the same shape.

Every claim below is backed by a file in [`evidence/`](evidence/). The exact
commands are in each evidence header.

---

## Test 1 — Atomic `COMMIT`

**Transaction:** book an appointment; the `trg_appointment_audit` trigger writes
the audit row in the same transaction.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | `BEGIN` | transaction open |
| 2 | A | `INSERT INTO appointment ...` | 1 row; `audit_log` trigger fires |
| 3 | A | count appointment / audit inside transaction | **1 / 1** |
| 4 | A | `COMMIT` | both rows visible |
| 5 | A | count after commit | **1 / 1** |

**Why it matters:** the audit row is not written by the application. If the
transaction rolls back, the trigger's row must disappear with it — which T2
proves.

Evidence: [`evidence/transactions.txt`](evidence/transactions.txt), T1 section.

---

## Test 2 — `ROLLBACK` on a real constraint violation

**Transaction:** two overlapping appointments for the same doctor. The first
insert succeeds; the second must violate `no_double_booking`.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | `BEGIN`; insert 10:00–10:30 | success |
| 2 | A | insert 10:15–10:45 | **ERROR 23P01** |
| 3 | A | `ROLLBACK` | transaction ends |
| 4 | A | count first appointment | **0** |
| 5 | A | count audit rows for first appointment | **0** |

Exact error:

```text
ERROR:  23P01: conflicting key value violates exclusion constraint "no_double_booking"
DETAIL:  Key (doctor_id, tstzrange(slot_start, slot_end, '[)'::text))=(..., ["2031-02-03 10:15:00+00","2031-02-03 10:45:00+00"))
         conflicts with existing key (doctor_id, tstzrange(...))=(..., ["2031-02-03 10:00:00+00","2031-02-03 10:30:00+00")).
```

**Observation:** the first appointment insert was valid, but it never committed.
The rollback removed it and the trigger-written audit row. Nothing partial
survived.

Evidence: [`evidence/transactions.txt`](evidence/transactions.txt), T2 section.

---

## Test 3 — `SAVEPOINT` partial rollback

**Transaction:** create a lab order, insert one valid result, take a savepoint,
then attempt a bad result.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | `BEGIN`; insert `lab_order` (FBC) | order created |
| 2 | A | insert result for analyte 1 | success |
| 3 | A | `SAVEPOINT after_valid_result` | savepoint set |
| 4 | A | insert result 2 with both numeric and text values | **ERROR 23514** |
| 5 | A | `ROLLBACK TO SAVEPOINT after_valid_result` | only the bad row is undone |
| 6 | A | count results for order | **1** |
| 7 | A | insert corrected result 2 | success |
| 8 | A | `COMMIT` | order + **2** results |
| 9 | A | count invalid rows | **0** |

Exact error:

```text
ERROR:  23514: new row for relation "lab_result" violates check constraint "lab_result_value_present"
DETAIL:  Failing row contains (..., 5.000, invalid-both, NORMAL, ...).
```

**Observation:** the order and the first result survived; the bad row never
existed after the savepoint rollback. A savepoint is not a retry mechanism — it
only undoes work after the marker, so the marker has to be placed after the work
that must survive.

Evidence: [`evidence/transactions.txt`](evidence/transactions.txt), T3 section.

---

## Test 4 — The anomaly: double-booking with no database control

**Setup:** `p3_demo.booking_unprotected`, structurally the appointment table
without `no_double_booking`. Doctor `KMPDC-000001`, patient `MRN-0000001`, slot
`2031-03-01 09:00–09:30+00`. Both sessions run the same check-then-insert logic.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | check availability | **0 rows** |
| 2 | B | check availability | **0 rows** |
| 3 | A | insert booking | success |
| 4 | A | `COMMIT` | at 09:21:36.048 |
| 5 | B | insert booking | success at 09:21:36.393 |
| 6 | B | `COMMIT` | at 09:21:38.433 |
| 7 | check | count rows for the slot | **2** |

**Analysis:** this is a check-then-act race (TOCTOU). Both transactions read a
snapshot in which the slot was free. B's insert happened just after A's commit,
but B's *decision* was made from the earlier read. `READ COMMITTED` prevents
dirty reads; it does not make a prior check remain true. Without a constraint
that sees the conflicting key, both rows commit and the receptionist has
double-booked the doctor.

Evidence: [`evidence/01-unprotected.txt`](evidence/01-unprotected.txt).

---

## Test 5 — The control: `EXCLUDE USING gist`

**Setup:** the real `appointment` table, same doctor/patient/slot
(`2031-03-04 09:00–09:30+00`). The exclusion constraint is
`(doctor_id WITH =, tstzrange(slot_start, slot_end, '[)') WITH &&)` for live
statuses.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | check availability | **0 rows** |
| 2 | B | check availability | **0 rows** |
| 3 | A | insert booking | success at 09:21:51.061 |
| 4 | B | overlapping insert at 09:21:52.250 | **blocks** |
| 5 | A | `COMMIT` at 09:21:54.094 | releases the conflict |
| 6 | B | insert returns | **ERROR 23P01** |
| 7 | B | `ROLLBACK`; count rows | **1** |

Measured block: **1.844 s**, from B's attempt at 09:21:52.250 to A's commit at
09:21:54.094. The monitor shows the wait while it is happening:

```text
sampled_at | pid | state | wait_type | wait_event | xact_age_s | query
09:21:52.692 | 32731 | active | Lock | transactionid | 2.45 | INSERT INTO appointment ...
09:21:53.230 | 32731 | active | Lock | transactionid | 2.99 | INSERT INTO appointment ...
09:21:53.669 | 32731 | active | Lock | transactionid | 3.43 | INSERT INTO appointment ...
```

Exact error:

```text
ERROR:  23P01: conflicting key value violates exclusion constraint "no_double_booking"
DETAIL:  Key (doctor_id, tstzrange(slot_start, slot_end, '[)'::text))=(..., ["2031-03-04 09:00:00+00","2031-03-04 09:30:00+00"))
         conflicts with existing key (doctor_id, tstzrange(...))=(..., ["2031-03-04 09:00:00+00","2031-03-04 09:30:00+00")).
```

**Analysis:** the second check was just as stale as in Test 4. The difference is
that the database evaluates the exclusion predicate at insert time. It waits for
A's transaction to resolve; when A commits, the conflict is real and B gets
`23P01`. The constraint enforces the invariant for every writer, including a
writer that never runs the application's check. The application must still catch
`23P01` and translate it into a user-facing "slot no longer available" message.

Evidence: [`evidence/02-exclusion.txt`](evidence/02-exclusion.txt).

---

## Test 6 — Pessimistic control: `SELECT ... FOR UPDATE`

**Setup:** same doctor and slot `2031-03-04 11:00–11:30+00`. A locks the
`doctor_profile` row before inserting. B requests the same row.

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | `BEGIN`; `SELECT ... FOR UPDATE` on doctor | lock acquired at 09:22:05.923 |
| 2 | B | `BEGIN`; same `SELECT ... FOR UPDATE` at 09:22:08.039 | **blocks** |
| 3 | A | insert booking; `COMMIT` at 09:22:09.963 | lock released |
| 4 | B | lock returns | **wait 1.913 s** |
| 5 | B | re-check availability | **1 row** (A's booking) |
| 6 | B | `ROLLBACK` | abandons its attempt |
| 7 | check | count rows for slot | **1** |

Monitor excerpt:

```text
sampled_at | pid | state | wait_type | wait_event | xact_age_s | query
09:22:08.495 | 32965 | active | Lock | transactionid | 0.45 | SELECT staff_id FROM doctor_profile ...
09:22:08.904 | 32965 | active | Lock | transactionid | 0.86 | SELECT staff_id FROM doctor_profile ...
09:22:09.413 | 32965 | active | Lock | transactionid | 1.37 | SELECT staff_id FROM doctor_profile ...
09:22:09.937 | 32965 | active | Lock | transactionid | 1.89 | SELECT staff_id FROM doctor_profile ...
```

**Analysis:** the outcome is correct, but it is correct only because B re-checks
after acquiring the lock. The lock serialises every booking for that doctor:
throughput is bounded by the slowest holder, and a session that stalls delays
the queue. The wait shown here is deliberately held for three seconds; it is not
a benchmark. This mechanism is suitable for short critical sections where the
application wants to control the order of operations, not for a high-volume
booking path.

Evidence: [`evidence/03-pessimistic.txt`](evidence/03-pessimistic.txt).

---

## Test 7 — Isolation levels: the same two reads

**Setup:** A reads the appointment count for patient `MRN-0000001`, sleeps four
seconds, and reads again. B inserts and commits one appointment for the same
patient in between. The slot differs between the two runs so they are
independent.

| Isolation level | First read | Second read | Delta | After A commits |
|---|---:|---:|---:|---:|
| `READ COMMITTED` | 5 | **6** | **+1** | 6 |
| `REPEATABLE READ` | 5 | **5** | **0** | 6 |

**Analysis:** under `READ COMMITTED`, each statement takes a fresh snapshot, so
the second read sees B's committed insert. Under `REPEATABLE READ`, the snapshot
is fixed at the first read, so the second read is stable — but A's transaction
still sees the old world until it ends. The after-commit count of 6 shows that
B's row was committed all along; the isolation level only controls what A is
allowed to see while its transaction is open.

This is consistency of reads, not correctness of decisions. A transaction can
read a stable snapshot and still make a decision that invalidates another
transaction's invariant; that is the write-skew test next.

Evidence: [`evidence/04-read-committed.txt`](evidence/04-read-committed.txt),
[`evidence/05-repeatable-read.txt`](evidence/05-repeatable-read.txt).

---

## Test 8 — Write skew: `READ COMMITTED` versus `SERIALIZABLE`

**Setup:** `p3_demo.on_call` holds two doctors, both `on_duty = true`. The
business invariant is "at least one doctor remains on duty." Each transaction
reads both rows, then takes only its own doctor off duty.

### 8a. `READ COMMITTED` — both commit

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | read on-duty count | **2** |
| 2 | B | read on-duty count | **2** |
| 3 | A | update doctor A off duty; `COMMIT` | success |
| 4 | B | update doctor B off duty; `COMMIT` | success |
| 5 | check | on-duty count | **0** |

Both transactions read a snapshot in which two doctors were on duty. They wrote
different rows, so there was no row-level write conflict and no reason for
`READ COMMITTED` to stop either one. The invariant spans rows; no single row
violates it, but the final state does.

### 8b. `SERIALIZABLE` — one transaction aborts

The same scripts with `-v iso=SERIALIZABLE`:

| Step | Session | Statement | Observed |
|---|---|---|---|
| 1 | A | read on-duty count | **2** |
| 2 | B | read on-duty count | **2** |
| 3 | A | update doctor A off duty; `COMMIT` | success |
| 4 | B | update doctor B off duty | **ERROR 40001** |
| 5 | B | `COMMIT` after the error | prints `ROLLBACK` |
| 6 | check | on-duty count | **1** |

Exact error:

```text
ERROR:  40001: could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
```

**Analysis:** SSI tracks the read/write dependency between the two transactions
and aborts one instead of allowing a serialisation anomaly. The abort surfaced at
B's `UPDATE`, not at `COMMIT`; the subsequent `COMMIT` therefore returns
`ROLLBACK`. Retry logic must treat `40001` as a retryable failure at any
statement, with backoff, and must not assume the transaction reached commit.

Evidence: [`evidence/06-write-skew-read-committed.txt`](evidence/06-write-skew-read-committed.txt),
[`evidence/07-write-skew-serializable.txt`](evidence/07-write-skew-serializable.txt).

---

## Mechanism Comparison

| Mechanism | Test result | Blocking | Failure mode | Use in this case study |
|---|---|---|---|---|
| Application check only | 2 rows in one slot | none | silent duplicate | never for a hard invariant |
| `SELECT ... FOR UPDATE` | correct, but waits 1.9 s | serialises the doctor | waiting, then app re-check | short critical sections |
| `EXCLUDE USING gist` | 1 row, `23P01` | only conflicting keys | deterministic conflict | **adopted for appointments** |
| `SERIALIZABLE` | 1 doctor on duty, `40001` | SSI may abort either side | serialisation failure + retry | multi-row invariants, e.g. on-call roster |

**Conclusion.** The appointment invariant has a natural key — doctor plus time
range — so the exclusion constraint is the simplest mechanism that cannot be
bypassed. It turns the race into a deterministic `23P01` and leaves the database
consistent even if the application check is stale. Pessimistic locking is a
valid alternative but serialises the doctor's whole booking path and depends on
the application re-checking after the lock. `SERIALIZABLE` is necessary when the
invariant spans rows, as the on-call roster shows; it requires retry handling and
can abort work that would have been valid, so it is not the default for the
single-row booking rule.

The price of the chosen design is explicit: the application must catch `23P01`
and return a useful conflict response. The database prevents corruption; it does
not replace the user-facing workflow.

---

## Evidence Map

| Test | Raw capture |
|---|---|
| T1–T3 | [`evidence/transactions.txt`](evidence/transactions.txt) |
| Double-booking anomaly | [`evidence/01-unprotected.txt`](evidence/01-unprotected.txt) |
| Exclusion constraint | [`evidence/02-exclusion.txt`](evidence/02-exclusion.txt) |
| Pessimistic lock | [`evidence/03-pessimistic.txt`](evidence/03-pessimistic.txt) |
| `READ COMMITTED` | [`evidence/04-read-committed.txt`](evidence/04-read-committed.txt) |
| `REPEATABLE READ` | [`evidence/05-repeatable-read.txt`](evidence/05-repeatable-read.txt) |
| Write skew, `READ COMMITTED` | [`evidence/06-write-skew-read-committed.txt`](evidence/06-write-skew-read-committed.txt) |
| Write skew, `SERIALIZABLE` | [`evidence/07-write-skew-serializable.txt`](evidence/07-write-skew-serializable.txt) |
| Cleanup | [`evidence/08-cleanup.txt`](evidence/08-cleanup.txt) |
| Machine-readable checks | [`evidence/summary.csv`](evidence/summary.csv) |

All captures were produced by
[`scripts/capture-p3.ps1`](../scripts/capture-p3.ps1) against the seeded
database. The script removes its own fixtures and drops `p3_demo` at the end.
