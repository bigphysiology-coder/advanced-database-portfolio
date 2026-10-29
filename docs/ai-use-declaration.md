# AI Use Declaration

Required by the brief (p.7): where AI tools are used, the declaration must state
**(I)** the AI tool used, **(II)** what it was used for, and **(III)** how the output was
reviewed, corrected, tested or verified by the student.

This file is maintained as work progresses. It is not reconstructed at submission time.

---

## Tools Used

| Tool | Version / model | Period of use |
|---|---|---|
| OpenCode (AI coding agent) | DeepSeek V4.1 Flash Free | 25-29 October 2026 |

---

## Log

### Entry 1 — 25-26 October 2026 — Database design, schema and seed data

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** draft the PostgreSQL schema for the Riverbend Teaching Hospital case
study, the normalisation notes, the ER diagram source, the constraint tests and a
seed-data generator large enough for query plans to be meaningful.

**Prompt (summarised):** "Design a 21-relation PostgreSQL schema for a 500-bed
teaching hospital covering outpatients, inpatients, prescriptions and laboratory
results. Include primary, foreign, candidate and composite keys, CHECK/UNIQUE/
EXCLUDE constraints, audit triggers, and a deterministic seed script. Explain the
normalisation to 3NF."

**Output used:** `portfolio-1-database-design/schema.sql`, `seed-data.sql`,
`normalisation.md`, `er-diagram.md`, `er-diagram.png`, `constraint-tests.sql` and
the exported test output.

**Verification performed:** the schema and seed were executed against PostgreSQL
16.15 in Docker from an empty volume. `scripts/verify.ps1` confirmed 21 base
tables, the exclusion constraint and the expected row counts. All ten negative
constraint tests failed as intended (10/10 PASS). The ER diagram was rendered and
inspected. Query plans were run against the seeded database before accepting the
data volume.

**Corrections made:** the first seed produced only 500 patients and 5,700
appointments; plans for indexed and unindexed queries were indistinguishable at
that size, so the generator was rescaled to 20,000 patients, 82,000 appointments
and 163,387 lab results. Diagnosis selection was changed from a uniform hash to
weighted ICD-10 frequencies so the top-10 report has a realistic distribution.
Stale row-count claims in the README and the initialisation-wait logic in the
verification scripts were corrected after the rebuild.

**Rejected / not used:** a natural-key-only patient identifier (the design keeps a
surrogate UUID primary key plus a unique MRN); emergency, theatre, imaging and
billing modules (out of scope for the 21-relation model).

---

### Entry 2 — 25-26 October 2026 — Query processing and optimisation

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** write the six Portfolio 2 business queries, build reproducible plan
capture and summary scripts, propose index candidates, measure them, and draft the
performance analysis.

**Prompt (summarised):** "Write six SQL queries covering patient history, doctor
workload, lab turnaround, dormant patients, top diagnoses and double-booking.
Capture EXPLAIN (ANALYZE, BUFFERS) before and after indexing, add one index at a
time, and explain the plan changes with measured numbers."

**Output used:** `portfolio-2-query-optimisation/queries.sql`, `indexes.sql`,
`execution-plans.md`, `results/` (raw plans and CSVs), and
`scripts/capture-plans.ps1` / `scripts/summarise-plans.ps1`.

**Verification performed:** every query was executed against the 312 MB seeded
database. The baseline was captured with five runs per query; the final capture
used twenty-one runs because the 2-core Docker host showed 20-50% run-to-run
variance. The summariser discards the first run and reports the median of the
rest. Each accepted index was applied with `CREATE INDEX CONCURRENTLY` and
measured before the next one was added. The buffer counts and plan shapes were
checked as well as the timings. The Q6 query was re-run end-to-end and returns
zero rows, matching the exclusion constraint. A repeat final capture taken under
68% CPU load was kept as `results/after-loaded.txt`; its plans and buffers were
identical but its timings were 20-50% higher, so it was not used for the reported
figures.

**Corrections made:** Q6's first window rewrite used `lag(slot_end)`, which misses
a long appointment that overlaps a later one across an intermediate row; it was
changed to a running maximum over all earlier rows. Q5's `SELECT DISTINCT`
rewrite was rejected after it blocked the covering-index plan. The Q6 candidate
B-tree was rejected after six runs showed no median improvement. The final
capture was extended from five runs to twenty-one after successive captures
showed large host variance, and all quoted numbers were reconciled to the single
committed `after.txt`. A PowerShell bug caused by the reserved `$Input` variable
in the summary script was fixed by renaming the parameter to `-InputFile`.

**Rejected / not used:** the Q5 `DISTINCT` rewrite (faster unindexed, slower with
the covering index); the Q6 `(doctor_id, slot_start)` partial B-tree (29-72 ms,
median ~44 ms, against 43.9 ms for the rewrite alone); adding an index to the Q6
self-join instead of rewriting it.

---

### Entry 3 — 26 October 2026 — Documentation

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** draft the portfolio READMEs, the execution-plan analysis and the
reproduction instructions.

**Output used:** `README.md`, `portfolio-2-query-optimisation/README.md` and
`portfolio-2-query-optimisation/execution-plans.md`.

**Verification performed:** every number in the summary tables was cross-checked
against the CSVs in `results/`; the before/after plan excerpts were copied from
`baseline.txt` and `after.txt`; the reproduction commands were run against the
live database; and both SQL files were executed end-to-end with
`ON_ERROR_STOP=1`.

**Corrections made:** corrected a transcription error in the Q6 plan excerpt and
aligned the index comments with the final 21-run medians. Added the note that
the 20,000-patient seed is a working sample of the 250,000-patient case study,
not a full replica.

**Rejected / not used:** presenting the isolated per-query timings as the headline
numbers. The all-query medians are more conservative and are the ones reported in
the summary; the isolated figures are disclosed in the analysis where they differ
materially.

---

### Entry 4 — 27 October 2026 — Transactions and concurrency

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** write and execute the Portfolio 3 transaction and concurrency tests, build a
reproducible two-session capture harness, and document the observed behaviour.

**Output used:** `transactions.sql`; five paired scenarios under
`portfolio-3-transactions-concurrency/sessions/`; `sessions/monitor.sql`;
`scripts/capture-p3.ps1`; the raw captures in `evidence/`; and the P3 `README.md` and
`isolation-tests.md`.

**Prompt (summarised):** "Using the existing Riverbend schema and seeded database, build
real `COMMIT`, `ROLLBACK` and `SAVEPOINT` examples; demonstrate a concurrency anomaly and
two control mechanisms; show an isolation-level difference; capture actual output from two
simultaneous sessions rather than describing it; keep the production constraints intact."

**Verification performed:** every scenario was executed against the live PostgreSQL 16.15
container, not written from theory. The final evidence is the output of a complete re-run
of `scripts/capture-p3.ps1`. Each claim in the README was checked against the raw files
with `Select-String` before it was written: the `23P01`, `23514` and `40001` SQLSTATE
codes, both session exit codes in `summary.csv`, the lock waits, and the pre/post row
counts. After the run, the database was queried independently and matched the seeded
counts of 20,000 patients, 82,000 appointments, 93,885 lab orders and 163,387 lab results,
with no P3 test rows and no `p3_demo` schema left. The reproduction command was also run
end-to-end more than once to confirm the harness is repeatable.

**Corrections made:** the first pessimistic-lock script selected `doctor_id` from
`doctor_profile`, but that table's primary key is `staff_id`; the failing run exposed it
and the statement was corrected to `staff_id`. The savepoint was initially placed before
the valid lab result, so `ROLLBACK TO SAVEPOINT` removed both results; it was moved after
the valid row, which is the behaviour the test is meant to show. Windows PowerShell 5.1
treated PostgreSQL `NOTICE` output on stderr as a terminating error; the capture functions
now relax `ErrorActionPreference` for native calls and judge success by exit code. The
`pg_stat_activity` sampler originally ran through `docker compose exec` from PowerShell,
which took about 1.6 s per sample and delayed Session B past the interleaving; sampling now
runs inside the container every ~300 ms. The exclusion scenario was lengthened to a 3 s
hold so the block is visible in the monitor. A comment in the serializable write-skew
script said B "commits" when PostgreSQL actually aborts the `UPDATE` and the `COMMIT`
prints `ROLLBACK`; the narration was corrected to match the output.

**Rejected / not used:** dropping `no_double_booking` from the production `appointment`
table to demonstrate the anomaly — the baseline uses a separate structurally identical
table that is dropped afterwards; cropped screenshots — raw logs include commands,
timestamps, monitor samples and exit codes and can be diffed; the application-only
availability check, which the anomaly test shows is insufficient; and `SELECT ... FOR
UPDATE` as the adopted booking control, because it serialises every booking for the
doctor. The exclusion constraint is adopted for appointments; `SERIALIZABLE` is retained
for the multi-row on-call invariant, where an exclusion key does not exist.

---

### Entry 5 — 28 October 2026 — NoSQL and advanced data models

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** design and implement the Portfolio 4 document model for the same Riverbend
laboratory data, build the PostgreSQL→MongoDB ETL, prove the validator and indexes with
real inserts and query plans, benchmark the document store against the relational
implementation, and produce traceable evidence.

**Prompt (summarised):** "Model a subset of the existing case study as a document store,
not a toy dataset. Justify what stays relational and why. Implement a `$jsonSchema`
validator, query-driven indexes, valid and invalid inserts, `$lookup`/`$facet`, a
read-pattern demonstration and an honest PostgreSQL comparison. Capture raw terminal
output and state where the document model is the wrong choice."

**Output used:** `portfolio-4-nosql/mongodb-setup.js`, `export-lab-results.sql`,
`export-patient-refs.sql`, `load-ndjson.js`, `transform-lab-results.js`, `queries.js`,
`validation-tests.js`, `consistency-checks.js`, `benchmark.js`, `compare-postgres.sql`,
`export-samples.js`, `model-design.md`, `README.md`, `sample-documents.json` and
`evidence/00`–`07`; plus `scripts/load-p4.ps1`, `scripts/capture-p4.ps1`,
`scripts/verify.ps1` and `scripts/verify.sh`.

**Verification performed:** the final evidence is the output of one complete
`scripts/capture-p4.ps1` run (exit 0) against the live containers, after a full reload.
Every figure quoted in the P4 README and model design was checked against those files with
`Select-String`/`Get-Content` before it was written. The captured run shows 93,885
documents, 163,387 embedded results, 15,200 patient references, 11/11 validator cases with
the server's error codes, 27/27 consistency checks, six `explain("executionStats")`
summaries, the PostgreSQL `\timing` output and five timed MongoDB runs per query. The
PostgreSQL and MongoDB insert equivalents were executed and rolled back or deleted
afterwards; the collection was then recounted to confirm no test rows remained. The final
`scripts/verify.ps1 -Mongosh <host path>` run passed every container, schema, seed-data,
MongoDB count/index and P4-artefact check. `scripts/verify.sh` was brought to the same
coverage and syntax-checked with `bash -n` inside the PostgreSQL container, because this
Windows host has no usable Bash shell.

**Corrections made:** the first `queries.js` assumed `find()`'s top-level
`executionStats`, but `db.collection.explain("executionStats").aggregate()` nests it under
`stages[0].$cursor`; the summary function was rewritten to handle both shapes and to print
the pipeline stages. `validation-tests.js` relied on `e.codeName`, which mongosh 2.2.12 did
not populate for these inserts; an explicit `121 → DocumentValidationFailure` /
`11000 → DuplicateKey` map now prints the server's documented names. `capture-p4.ps1`
originally passed JavaScript to `mongosh --eval` from PowerShell, which stripped the
inner quotes and produced invalid JS; evaluations now go through a temporary `.js` file.
The PostgreSQL write comparison initially spread `\gset` across separate `psql -c` calls,
which cannot share psql variables; it was rewritten as one SQL file inside a transaction.
The sample export filtered for `ORDERED` + `URGENT`, but the seed contains no urgent
orders that have not already been reported; it now selects a real pending `ORDERED` order
with zero results. The PostgreSQL order-insert sample was also corrected to insert a
`REPORTED` order with collected/reported timestamps, because an `ORDERED` row with
`collected_at` set violates the schema's check constraint.

The first full evidence capture failed with `MongoNetworkError: connection ... closed`.
The cause was host disk exhaustion (under 1 GB free), which took Docker Desktop/WSL down,
not a database or script fault. Stale temporary files, including five 1.65 GB duplicate
video directories and old MongoDB image-build/extraction directories, were removed
(~8.5 GB freed), Docker Desktop was restarted, and the load and capture were re-run from
scratch. The report quotes only that final clean run, not the earlier partial one.

**Rejected / not used:** claiming MongoDB was faster in general — the warm PostgreSQL
timings match or beat it on most reads, and the report says so; using `ObjectId` for
cross-store IDs — UUID strings preserve the PostgreSQL identity and make `$merge`
idempotent; duplicating the patient master in MongoDB — `patient_refs` is a derived
identifier projection only; hiding validator gaps behind application code — the gaps and
the reconciliation checks are named in `model-design.md`; and cropped screenshots — the
evidence is raw command output with exit codes, so it can be re-run and diffed.

---

### Entry 6 — 29 October 2026 — Distributed replication and evidence capture

**Tool:** OpenCode, model DeepSeek V4.1 Flash Free.

**Task:** build and document the Portfolio 5 distributed-database exercise on the
existing Riverbend case study: a PostgreSQL primary and hot-standby replica, a
reproducible setup/failover harness, a lag measurement, a read-your-writes stale-read
demonstration with a mitigation, config fragments and a single-run evidence capture.

**Prompt (summarised):** "Deploy one PostgreSQL primary and one streaming replica with
Docker. Show `pg_stat_replication` streaming, a write on the primary visible on the replica,
measured commit-to-visible lag under a burst insert, a stale read with a working lag-aware
mitigation, synchronous versus asynchronous commit, and a manual promotion that accepts
writes. Keep it isolated from the P1-P4 database, capture raw terminal output, and be explicit
about RPO/RTO and what the single-host demo does not prove."

**Output used:** `portfolio-5-distributed-cloud/replication-setup.ps1`,
`config/primary.conf`, `config/replica.conf`, `config/pg_hba-replication.conf`,
`config/README.md`, `README.md`, `architecture.md`, `evidence/00`-`07` and
`scripts/capture-p5.ps1`; plus the P5 checks and root README updates.

**Verification performed:** the final evidence is one complete
`scripts/capture-p5.ps1` run (exit 0) captured on 29 October 2026 at 07:55 +01:00,
after a clean `up -Force` rebuild. Every number quoted in the P5 README and
architecture document was checked against those files before it was written:
`state=streaming`, `sync_state=async`, identical sent/replay LSNs, a
6.173 ms primary insert and 5.015 ms replica read with the same timestamp,
525.469 ms commit-to-visible lag for 50,000 rows, synchronous/async medians of
16.913/6.971 ms, a 0-row stale read with 296 unapplied bytes, the router returning
1 row from the primary, a 2,946.7 ms promotion, a post-failover insert, and 0 rows
lost after catch-up. The live `SHOW` values and `postgresql.auto.conf` were compared
with the committed config fragments. The final P5 database contained 20,000 patients
and 93,889 lab orders, and the P5 containers were separate from `portfolio-postgres`
throughout; the P1-P4 data was not modified. `scripts/verify.ps1` and `verify.sh`
were extended to check the P5 report, config and evidence files; `verify.sh` was
syntax-checked with `bash -n` inside the PostgreSQL container because this Windows
host has no usable Bash.

**Corrections made:** the first harness run failed because the PostgreSQL Docker
entrypoint answers `pg_isready` during its temporary init server and then shuts it
down; readiness now requires three consecutive successful `SELECT 1` checks over
four seconds. The first evidence capture failed at the log step because Windows
PowerShell 5.1 treated `docker logs` output on stderr as a terminating error; the
capture now merges Docker's streams through `cmd /c` and records partial output
before a failure. The config fragments were initially UTF-8 without a BOM, so
PowerShell 5.1's default `Get-Content` rendered em dashes and a section sign as
mojibake in `06-configs.txt`; the fragments were made ASCII-only and the reader now
specifies UTF-8. Promotion timing originally included `Invoke-Sql`'s temp-file copy;
the failover step now calls `psql -c "SELECT pg_promote(...)"` directly. The sync
comparison was increased from five to ten commits per mode after the first five-sample
run was too noisy to support a median claim. The capture's config listing originally
printed PowerShell formatting objects (`FormatStartData` etc.), which were replaced
with plain file lines and file contents. The TODO `replication-setup.sh` skeleton was
removed rather than shipped unimplemented; the tested path is the PowerShell harness.
An early assumption that `synchronous_commit=on` alone made replication synchronous was
wrong and is corrected in the report: `synchronous_standby_names` is what creates
`sync_state=quorum`.

**Rejected / not used:** using synchronous replication as the default for every write
(the primary would stall when the standby is unavailable); claiming the controlled
0-row loss proves async RPO is zero (it does not: the failover waited for catch-up);
automatic failover with Patroni or a managed multi-AZ service (useful production
recommendation, not demonstrated here); sharding at 317 MB and 20,000 patients
(premature without a measured bottleneck); a replication slot (bounded `wal_keep_size`
is safer for this demo); and cropped screenshots (the evidence is raw command output
that can be re-run and diffed). Exploratory runs used to debug the harness are not
quoted; the report uses only the final clean capture.

---

## Declaration

I confirm that the database implementations, scripts, analysis and conclusions submitted
in this portfolio represent my own work. Where AI tools were used, the use is recorded
above and I can explain and defend every part of the submitted work.

**Name:**
**Student number:**
**Signature / date:**
