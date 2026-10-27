# Portfolio 3 — Transactions and Concurrency

**Marks:** 7 / 40

**Status:** complete

## Required Evidence

- [x] Transaction examples showing `COMMIT`
- [x] Transaction examples showing `ROLLBACK`
- [x] Isolation level demonstration
- [x] A concurrency issue **and** two concurrency control mechanisms
- [x] Screenshots / output evidence — raw two-session terminal captures in [`evidence/`](evidence/)

The evidence is raw `psql` output rather than cropped screenshots. Every capture
includes the command, both session outputs with server timestamps, the
`pg_stat_activity` samples taken during the overlap, the post-run check, and the
session exit codes. That is deliberately stronger than a screenshot: it can be
re-run, diffed, and checked without trusting the person who cropped the image.

---

## Files

| File | Purpose |
|---|---|
| `transactions.sql` | T1 `COMMIT`, T2 `ROLLBACK`, T3 `SAVEPOINT` with real constraints. |
| `sessions/01-unprotected-a.sql`, `-b.sql` | The double-booking anomaly on a structurally identical table without the exclusion constraint. |
| `sessions/02-exclusion-a.sql`, `-b.sql` | The same race on the real `appointment` table; `no_double_booking` rejects the second row with `23P01`. |
| `sessions/03-pessimistic-a.sql`, `-b.sql` | `SELECT ... FOR UPDATE` on the doctor row; the second session blocks, re-checks, and abandons its booking. |
| `sessions/04-isolation-a.sql`, `-b.sql` | Same count read twice with a committed insert in between. Parameterised by `-v iso=...`. |
| `sessions/05-write-skew-a.sql`, `-b.sql` | Two doctors each take themselves off duty after seeing the other on duty. Parameterised by `-v iso=...`. |
| `sessions/monitor.sql` | One `pg_stat_activity` sample, run in a loop during each concurrent test. |
| `evidence/transactions.txt` | Raw T1–T3 output. |
| `evidence/01-unprotected.txt` … `07-write-skew-serializable.txt` | Raw two-session captures and monitor logs. |
| `evidence/08-cleanup.txt` | Fixtures removed, demo schema dropped, zero test rows left. |
| `evidence/summary.csv` | Machine-readable scenario/exit/post-run-check summary. |
| `scripts/capture-p3.ps1` | Reproduces every capture, including the in-container monitor. |
| `isolation-tests.md` | Detailed test record with step tables, error text, and analysis. |

---

## Method

**Single-session tests.** `transactions.sql` runs with `ON_ERROR_STOP=0` on purpose:
T2 and T3 must reach the expected constraint errors and then continue to their
verification queries. The exit code is checked by the harness, not by the number
of red lines in the output.

**Two-session tests.** Each scenario is two independent `psql` connections against
the same database. Session A starts first; Session B is launched 1.2 s later. A
monitor loop runs inside the container and samples `pg_stat_activity` every
~300 ms. The timestamps printed by each session are the authoritative ordering;
process startup adds roughly a second, which is visible in the logs.

**The unprotected baseline.** The production `appointment` table already has the
`no_double_booking` `EXCLUDE USING gist` constraint. Dropping it to demonstrate
the bug would put the real schema at risk, so the baseline uses
`p3_demo.booking_unprotected`: the same columns and the same application logic,
without the constraint. It is created for the test and dropped afterwards. This
isolates the variable being tested — the presence of the constraint — instead of
pretending the production table is unprotected.

**Fixtures.** Every test resolves the patient and doctors by stable business keys
(`MRN-0000001`, `KMPDC-000001`, `KMPDC-000002`) rather than hard-coded UUIDs,
which change when the database is rebuilt. Test appointments, lab orders and the
`p3_demo` schema are removed at the end. The seed is back to 20,000 patients,
82,000 appointments, 93,885 lab orders and 163,387 lab results.

---

## Results

| # | Test | Isolation / control | Observed result |
|---|---|---|---|
| T1 | Multi-table `COMMIT` | READ COMMITTED | 1 appointment + 1 trigger-written audit row both visible after commit |
| T2 | `ROLLBACK` after a real conflict | READ COMMITTED | `23P01` on the second insert; **0** appointment rows and **0** audit rows survive |
| T3 | `SAVEPOINT` partial rollback | READ COMMITTED | **1** result survives the rollback, **2** after the correction, **0** invalid rows |
| 01 | Double-booking anomaly | Application check only | Both sessions read **0** rows; both commit; **2** rows occupy one slot |
| 02 | Same race, real table | `EXCLUDE USING gist` | Both read **0**; B blocks **1.844 s** on `Lock / transactionid`; `23P01`; **1** row |
| 03 | Pessimistic locking | `SELECT ... FOR UPDATE` | B waits **1.913 s**; sees A's booking; rolls back; **1** row |
| 04 | Non-repeatable read | `READ COMMITTED` | Count **5 → 6**, delta **1**; after commit 6 |
| 05 | Same read again | `REPEATABLE READ` | Count **5 → 5**, delta **0**; after commit 6 |
| 06 | Write skew | `READ COMMITTED` | Both read 2 doctors on duty; both commit; **0** remain on duty |
| 07 | Same write skew | `SERIALIZABLE` | Both read 2; B aborts with **`40001`**; **1** remains on duty |

The lock waits in 02 and 03 are deliberately held open by the scripts. They show
that blocking occurs and that the monitor can see it; they are **not** a
throughput benchmark.

---

## What the Evidence Shows

### Atomicity includes trigger-written rows

T1 inserts an appointment. The `trg_appointment_audit` trigger writes the
`audit_log` row in the same transaction. Both rows are visible inside the
transaction and after `COMMIT`.

T2 proves the other half: the first appointment insert succeeds, the second
overlapping insert raises `23P01`, and `ROLLBACK` removes **both** the
appointment and the audit row written by the trigger — even though the audit
insert was never explicitly issued. Atomicity is a property of the transaction,
not of the application remembering to clean up.

### A savepoint is a partial rollback, not a retry

T3 creates a lab order, inserts one valid result, takes a savepoint, then tries a
result that supplies both a numeric and a text value. The `lab_result_value_present`
CHECK raises `23514`. `ROLLBACK TO SAVEPOINT` removes only the bad result:
the count is **1** immediately after the rollback and **2** after the corrected
row is inserted and committed. The order survives throughout.

### Isolation level is not concurrency control

The same two reads produce different results purely because of the isolation
level:

- `READ COMMITTED` takes a fresh snapshot for each statement, so A's second
  read sees B's committed row: **5 → 6**.
- `REPEATABLE READ` fixes the snapshot at the first read, so A still sees
  **5 → 5**, while a new transaction after commit sees 6.

That protects A's read consistency, but it does not stop two transactions from
making a decision based on the same stale snapshot. The write-skew test is the
proof: under `READ COMMITTED` both transactions read two doctors on duty, each
takes only its own row off duty, and both commit — leaving **zero** doctors on
duty. The invariant "at least one doctor stays on duty" is not a row-level
constraint, so no amount of row locking on the updated rows would catch it.

Under `SERIALIZABLE`, PostgreSQL's SSI detects the read/write dependency. B
aborts with the exact error:

```text
ERROR:  40001: could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
```

The abort happens at B's `UPDATE`, before its `COMMIT`; the subsequent `COMMIT`
therefore prints `ROLLBACK`. That detail matters when writing retry logic: a
serialisation failure can surface at any statement, not only at commit.

### The database, not the application, enforces the booking invariant

The contrast between 01 and 02 is the core of this portfolio. Both scenarios use
the same check-then-insert logic and both sessions read the slot as free. In 01
the two checks are stale and both rows commit. In 02 the second insert blocks on
the GiST exclusion index until A commits, then fails with:

```text
ERROR:  23P01: conflicting key value violates exclusion constraint "no_double_booking"
DETAIL:  Key (doctor_id, tstzrange(slot_start, slot_end, '[)'::text))=...
         conflicts with existing key (doctor_id, tstzrange(...))=...
```

The `pg_stat_activity` monitor records the block while it is happening:

```text
sampled_at | pid | state | wait_type | wait_event | xact_age_s | query
09:21:52.692 | 32731 | active | Lock | transactionid | 2.45 | INSERT INTO appointment ...
09:21:53.230 | 32731 | active | Lock | transactionid | 2.99 | INSERT INTO appointment ...
09:21:53.669 | 32731 | active | Lock | transactionid | 3.43 | INSERT INTO appointment ...
```

This is the mechanism adopted for the case study. It is declarative, cannot be
bypassed by a second connection, and its failure mode is deterministic: the
loser gets `23P01` and the application maps that to "slot already taken". The
application still needs to handle the error and show a useful message; the
constraint prevents the duplicate, it does not improve the user experience by
itself.

### Pessimistic locking works, but serialises the hot row

`SELECT ... FOR UPDATE` on the doctor row produces the expected outcome: B waits
**1.913 s**, then sees A's booking and abandons its own. The monitor captures
`Lock / transactionid` for the duration.

The cost is that every booking for that doctor is serialised while the lock is
held. The measured wait is the deliberately held lock, but the structure is the
point: throughput on the busiest doctor is limited by the slowest transaction,
and a session that dies while holding the lock delays everyone behind it until
the connection is cleaned up. This is a reasonable choice for short,
predictable critical sections, not for a high-throughput booking path.

### Why the exclusion constraint is the adopted control

| Mechanism | Failure mode | Blocking | Best suited to |
|---|---|---|---|
| Application check only | Silent duplicate booking | None | Never for a hard invariant |
| `SELECT ... FOR UPDATE` | Waits, then application must re-check | Serialises the locked doctor | Short, predictable critical sections |
| `EXCLUDE USING gist` | `23P01` at the conflicting insert | Only colliding keys | Invariants that must never break |
| `SERIALIZABLE` | `40001`, caller must retry | SSI can abort either transaction | Multi-row invariants with no natural unique key |

For appointments, the invariant has a natural key: `(doctor_id, time range)`. The
exclusion constraint expresses exactly that key, enforces it for every writer,
and fails only the conflicting booking. `SERIALIZABLE` is the right tool for the
on-call roster because "at least one doctor remains on duty" spans rows and does
not map to a single unique key; it would be the fallback if a booking rule ever
needed to span multiple rows. `FOR UPDATE` is kept as a comparison, not adopted
for booking.

---

## Reproduce

```powershell
# 1. Confirm the seeded database is ready
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1

# 2. Re-run every test and regenerate evidence/
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p3.ps1
```

The harness copies the SQL into the container, runs the monitor, launches the
two sessions, and cleans up. It takes about 90 seconds on the 2-core Docker host
used for this portfolio. The individual SQL files can also be run manually in
two terminals:

```bash
docker cp portfolio-3-transactions-concurrency/sessions/02-exclusion-a.sql \
    portfolio-postgres:/tmp/02-a.sql
docker exec -it portfolio-postgres psql -U portfolio -d hospital \
    -v ON_ERROR_STOP=0 -f /tmp/02-a.sql
# in a second terminal, 1-2 s later:
docker cp portfolio-3-transactions-concurrency/sessions/02-exclusion-b.sql \
    portfolio-postgres:/tmp/02-b.sql
docker exec -it portfolio-postgres psql -U portfolio -d hospital \
    -v ON_ERROR_STOP=0 -f /tmp/02-b.sql
```

`transactions.sql` creates `p3_demo.lab_order_ids` if it does not exist, so it can
be run on its own. The two-session tests expect `p3_demo.booking_unprotected` and
`p3_demo.on_call`; use `capture-p3.ps1`, which creates and drops them.

---

## Limitations

- **One PostgreSQL instance.** There is no network partition, replica lag or
  failover here; those are Portfolio 5. This portfolio tests transaction and
  lock behaviour on a single primary.
- **Timing is illustrative, not a benchmark.** The host is a 2-core Docker
  Desktop environment. The lock waits are deliberately held for seconds so the
  monitor can capture them. The invariant and the error codes are the evidence;
  the millisecond figures are not a capacity claim.
- **The unprotected table is a test fixture.** `p3_demo.booking_unprotected` is
  structurally the appointment table without the exclusion constraint. It exists
  only long enough to demonstrate the anomaly and is dropped by the harness.
- **The on-call roster is a test fixture.** The schema has no on-call table, so
  the write-skew test uses `p3_demo.on_call`. That is deliberate: it isolates
  the isolation-level behaviour without adding an unrelated production table.
- **Audit rows accumulate.** `audit_log` is append-only, so deleting a test
  appointment writes a DELETE audit row. That is the intended design; the audit
  trail is evidence, not disposable test data.
