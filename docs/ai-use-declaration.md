# AI Use Declaration

Required by the brief (p.7): where AI tools are used, the declaration must state
**(I)** the AI tool used, **(II)** what it was used for, and **(III)** how the output was
reviewed, corrected, tested or verified by the student.

This file is maintained as work progresses. It is not reconstructed at submission time.

---

## Tools Used

| Tool | Version / model | Period of use |
|---|---|---|
| OpenCode (AI coding agent) | DeepSeek V4.1 Flash Free | 25-27 October 2026 |

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

## Declaration

I confirm that the database implementations, scripts, analysis and conclusions submitted
in this portfolio represent my own work. Where AI tools were used, the use is recorded
above and I can explain and defend every part of the submitted work.

**Name:**
**Student number:**
**Signature / date:**
