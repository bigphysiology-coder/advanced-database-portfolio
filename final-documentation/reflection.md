# Individual Technical Reflection

**Abdulrasheed Abdulrazak**<br>
Matriculation number: 2026/A/MIT/0734<br>
Student ID: 301926758<br>
MIT 8103 Advanced Database Systems<br>
30 October 2026

## 1. What I Built

I built a five-part portfolio around Riverbend Teaching Hospital, a simulated
500-bed hospital. It contains a 21-relation PostgreSQL schema for patient records,
appointments, encounters, prescriptions and laboratory work; six business queries
with measured plans; two-session transaction tests; a MongoDB laboratory-report
store populated from the relational data; and a PostgreSQL primary/standby
replication deployment. All five parts share one schema and one seed, so the work
is a single case study rather than five disconnected exercises.

## 2. Design Decisions I Would Defend

**PostgreSQL as the system of record, MongoDB only for laboratory reports.** The
alternatives were to put everything in MongoDB, or to keep everything relational
and use a `jsonb` column for results. I chose a polyglot boundary because a
laboratory report is a bounded document: one order owns one to four analytes, the
report is read and written as a unit, and the units and reference ranges must be
preserved as they were at report time. The relational core still needs foreign
keys, the `no_double_booking` exclusion constraint and multi-row transactions. The
cost is an ETL pipeline, eventual consistency and no cross-store foreign key. For a
small single-node hospital I would test the `jsonb` option first, because it avoids
that operational cost; I would still defend the document model for a separate
reporting plane.

**Asynchronous replication as the default.** The alternative was synchronous
commit for every write. Asynchronous replication keeps bookings available when the
standby is down; synchronous commit would make every booking wait for a remote
acknowledgement and would stop clinical writes during a standby outage. The cost
is a non-zero recovery point objective, which I state in the report. I demonstrated
synchronous mode separately with `synchronous_standby_names`, producing
`sync_state=quorum` and a median commit of 16.913 ms against 6.971 ms asynchronous.
I would use synchronous commit for a small set of booking-critical writes, not as
a global default.

**The exclusion constraint for appointments, `SERIALIZABLE` for the on-call
invariant.** The alternatives were an application check, `SELECT ... FOR UPDATE`,
or serializable isolation for both. The application check failed the two-session
test: both sessions read zero rows and both committed, producing two appointments
in one slot. `FOR UPDATE` prevented the race but serialised every booking for that
doctor, and the second session waited 1.913 s. The exclusion constraint rejects the
second writer with `23P01` without locking the doctor for every booking. The
on-call rule constrains a multi-row invariant, not an overlap, so no exclusion key
exists; under `SERIALIZABLE` the second transaction aborted with `40001` and one
doctor stayed on duty. The cost is that the application must handle `23P01` and
`40001` as normal outcomes.

## 3. What Surprised Me

The slow patient-history query was not a missing-index problem. I expected one
index on `encounter` to fix it. The plan showed two correlated subqueries
re-scanning 125,176 prescriptions and 93,885 laboratory orders once per encounter.
The encounter index alone moved 197.5 ms to 178.2 ms; the prescription index took
it to 82.0 ms; the laboratory-order index took it to 0.78 ms. Measuring one index
at a time was the only way to see that. If I had added all three at once, I would
have known the query was faster but not why.

The obvious Q5 rewrite also lost. `SELECT DISTINCT` was faster than the original
query without an index, but it blocked the covering-index plan and produced 871 ms
against 303.4 ms for the original query with the index. I had assumed a simpler
query shape would always help; it helped only in the environment I was not trying
to optimise.

The MongoDB benchmark was the third surprise. Warm PostgreSQL matched or beat
MongoDB on patient history (2.07 ms vs 8 ms) and analyte trend (2.8 ms vs 7 ms);
the dashboard is not like-for-like (96 ms for one PostgreSQL branch, 3.24 s for
MongoDB's four-branch `$facet`). MongoDB won the work queue (8 ms vs 26–35 ms)
and the single-document write (16 ms vs 122.9 ms). That changed how I
write about NoSQL: the document model is a choice about shape and ownership, not a
claim that it is universally faster.

## 4. The Hardest Problem

**What it was:** making the Portfolio 5 evidence capture reliable enough to
commit. The first harness run failed because PostgreSQL's Docker entrypoint
answers `pg_isready` during its temporary initialisation server and then shuts it
down. The script connected too early and failed partway through the rebuild. A
later capture failed at the log step because Windows PowerShell 5.1 treated
`docker logs` output on stderr as a terminating error.

**Why it was hard:** the failure looked like a database problem, not a readiness
problem. The container logs showed a healthy server; the script saw a connection
refusal a few seconds later. I had to separate the entrypoint's temporary server
from the final server, and Docker's stream handling from the actual exit status.

**How I got unstuck:** readiness now requires three consecutive successful
`SELECT 1` checks over four seconds, and Docker's output streams are merged through
`cmd /c` so stderr is recorded rather than treated as a failure. I rebuilt from an
empty volume and captured the whole run again. The final evidence is one clean
capture from 29 October 2026 at 07:55 +01:00, not a collection of partial runs.

**What I would do differently:** build the harness in Bash under WSL from the
start. Most of the friction was PowerShell 5.1's handling of native stderr,
temporary files and quoting, not PostgreSQL. A shell script would have been
shorter and easier to test on Linux CI.

## 5. Mistakes and Corrections

I assumed that setting `synchronous_commit=on` made replication synchronous. It
does not. `synchronous_commit` controls when a commit returns;
`synchronous_standby_names` is what makes a standby synchronous. The primary still
reported `sync_state=async` after my first configuration. I noticed because I
checked `pg_stat_replication` instead of trusting the setting name. I added
`synchronous_standby_names = 'ANY 1 ("portfolio-p5-replica")'`, rebuilt the
cluster and captured `sync_state=quorum` in `04-sync-vs-async.txt`. The report now
explains the distinction instead of repeating my assumption.

My first Q6 window rewrite used `lag(slot_end)`. That only compares an appointment
with the immediately preceding row, so a long appointment that overlaps a later
one across an intermediate row is missed. I noticed when I constructed an overlap
that the query returned zero rows even though the intervals collided. I replaced
`lag` with a running maximum over all earlier rows. The final query returns zero
rows on the seeded data because the exclusion constraint is doing its job; the
difference is that it now returns zero for the right reason.

My first five-run performance capture was also too noisy to support the claims I
wanted to make. The 2-core Docker host showed 20–50% run-to-run variance, and
successive captures disagreed. I extended the final capture to 21 runs, discarded
the first as warm-up, reported medians, and kept a repeat capture under 68% CPU
load as a variance control. I reconciled every quoted number to the single
committed `after.txt` rather than mixing captures. That changed how I present
performance evidence: plan shape and buffer counts are the evidence; the
milliseconds are context.

## 6. Where the Design Is Weak

The seed is 20,000 patients, not the 250,000 described in the case study. It is
large enough for the planner to choose between a sequential scan and an index, but
not large enough to prove behaviour at ten times the volume. At 10×, `lab_result`
and `audit_log` would be the first tables to hurt; I would partition them by time
before adding more indexes. Q4 would not improve much because its predicate
selects 85% of the table, and Q6's plan estimate is already 6.4× low because the
planner assumes `status` and `slot_start` are independent. Multivariate statistics
are the next fix there, not another B-tree.

The MongoDB design has no cross-store foreign key. A patient merge or MRN
correction in PostgreSQL can leave a stale reference in MongoDB until the next
reconciliation. The 27 consistency checks make drift visible, but they do not
prevent it. If I rebuilt this, I would add an outbox or change-stream
reconciliation job and test a patient merge end to end.

The P5 deployment is a single-host demonstration, not production high
availability. Failover is manual, there is no PITR or backup in the exercise, and
the same replica serves both read scaling and failover. A reporting query that
pins the replica also delays the failover target. Asynchronous replication has a
non-zero RPO; the controlled promotion lost zero rows only because I waited for
the replica to catch up before stopping the primary. I would not present that as
evidence that async RPO is zero.

## 7. What I Would Do Next

1. Add continuous archiving and point-in-time recovery, then test a restore. A
   replica is not a backup.
2. Replace manual promotion with an orchestrator such as Patroni, and add a
   fencing step so the old primary cannot accept writes after a split-brain.
3. Load a 10× dataset, partition `lab_result` and `audit_log` by time, and add
   multivariate statistics for the appointment status/date correlation. Measure
   whether the Q6 plan flips before changing the query again.
4. Replace the demonstration router with a service-level read policy and test
   read-your-writes during promotion, not only during normal streaming.

## 8. On AI Assistance

I used OpenCode (DeepSeek V4.1 Flash Free) as a pair programmer and editor between
25 and 30 October 2026. It drafted SQL, PowerShell, JavaScript and documentation,
and suggested several tests. I ran every script against the live containers, read
the raw output, and corrected the work where it was wrong. I found the errors in
section 5 myself: the synchronous-replication mistake by checking
`pg_stat_replication`, and the Q6 mistake by constructing an overlap the query
failed to detect. I implemented and re-ran the fixes. The full declaration is in
`docs/ai-use-declaration.md`. I did not use AI to invent evidence or to write
results I had not reproduced.

## 9. Skills Carried Forward

I can now read an `EXPLAIN (ANALYZE, BUFFERS)` plan and explain a query's cost
from its access methods and buffer counts, not just its elapsed time. I can design
a constraint that enforces a business invariant at the storage layer, and test it
with two real sessions instead of assuming the application check is enough. I can
build a reproducible evidence harness and reason about replication lag, RPO and
RTO from measured output. Most importantly, I can choose a persistence boundary
from the shape of the data and the transaction, rather than from the label on the
database.
