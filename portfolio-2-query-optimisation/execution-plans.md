# Execution Plans and Performance Analysis

## Environment and dataset

| Item | Value |
|---|---|
| Database | PostgreSQL 16.15 (Debian 16.15-1.pgdg13+2), `postgres:16` Docker image |
| Host | Windows, Intel Core i5-6300U (2 cores / 4 threads), 7.9 GB RAM |
| Container | Docker Desktop 29.5.3, default memory limit (3.77 GiB visible to Postgres) |
| Settings | `work_mem = 4MB`, `shared_buffers = 128MB`, `max_parallel_workers_per_gather = 2` |
| Database size | 312 MB before the Portfolio 2 indexes |
| Data | 20,000 patients, 82,000 appointments, 62,588 encounters, 93,885 diagnoses, 93,885 lab orders, 163,387 lab results, 125,176 prescriptions |

All queries run with `SET TIME ZONE 'UTC'`. Their date windows are anchored to
`CURRENT_DATE`, matching `seed-data.sql`, which generates 100 days of history and
60 days of future bookings relative to the day the seed is loaded.

## Measurement method

Every number below comes from `EXPLAIN (ANALYZE, BUFFERS, TIMING)` run through
`scripts/capture-plans.ps1`. The script runs each query N times in one psql
session; `scripts/summarise-plans.ps1` discards the first run (cold cache) and
reports the median of the rest. The CSVs next to each capture contain the
run-by-run figures.

| Capture | Runs | File | What it measures |
|---|---:|---|---|
| Baseline | 5 | `results/baseline.txt` | Before any Portfolio 2 index. Q6 is still the original self-join. |
| Final | 21 | `results/after.txt` | All seven accepted indexes. Q6 is the window rewrite. |
| Variance control | 21 | `results/after-loaded.txt` | Repeat of the final capture while the host was at 68% CPU load; **not used** for any reported figure. |
| Q1 incremental | 5 each | `results/q1-after-*.txt` | One index added at a time |
| Q2-Q5 incremental | 5 each | `results/q2-after-index.txt` … `results/q5-after-index.txt` | Each index measured on its own |
| Q6 isolated | 5 | `results/q6-window-final.txt` | Rewrite without the rest of the session's load |

The final capture uses twenty-one runs instead of five because this host is noisy:
the same plan can differ by 20-50% between captures. The median of twenty measured
runs is much more stable than the median of four. The baseline was captured with
the standard five runs before the indexes existed; it is not possible to rebuild
that state without dropping the indexes, so it is reported as captured. The
comparison that matters — the access path and the buffer count — is identical in
both captures for every query.

The host noise is large enough to demonstrate directly. A repeat of the final
capture was taken while the laptop was at 68% CPU load; the plan shapes and buffer
counts were identical, but the medians were 20-50% higher. That capture is kept as
`results/after-loaded.txt` so the effect is visible, but every millisecond quoted
in this report comes from `results/after.txt`, which was taken with the database
and host otherwise idle.

A concrete example: Q2 measured 17.4 ms in the five-run capture taken immediately
after its index was built, 18.9 ms in the final 21-run capture, and 31.3 ms in the
loaded repeat. The plan in all three cases is the same Index Only Scan with 36
shared buffers. Q4 is sharper still: 122.3 ms in an earlier 11-run capture,
133.0 ms in the final capture, and 198.8 ms under load, with the same plan and 895
buffers every time. The difference is CPU scheduling on a 2-core Docker VM, not a
change in plan. For that reason the buffer counts are treated as the primary
evidence and the milliseconds as the user-visible outcome. The conclusions below
are based on changes that are far larger than the noise (access method, rows read,
disk spill), not on small millisecond differences.

## Summary

| Query | Before (ms) | After (ms) | Speed-up | Shared buffers before → after | Fix applied |
|---|---:|---:|---:|---|---|
| Q1 — patient history | 197.5 | 0.60 | 330× | 15,321 → 65 | 3 indexes: encounter, prescription, lab_order |
| Q2 — doctor workload | 76.5 | 18.9 | 4.1× | 1,481 → 36 | Covering index on `appointment (slot_start)` |
| Q3 — urgent lab turnaround | 135.4 | 48.7 | 2.8× | 1,339 → 66 | Partial covering index on urgent orders |
| Q4 — dormant patients | 193.3 | 133.0 | 1.5× | 1,969 → 895 | Index on `appointment (patient_id, slot_start)` |
| Q5 — top diagnoses | 1,018.2 | 303.4 | 3.4× | 1,012 + 736 temp → 627, 0 temp | Covering index on `diagnosis` |
| Q6 — double-booking audit | 646.2 | 55.9 | 11.6× | 57,300 → 294 | Window rewrite; **no index** |

The two largest wins are not the two largest indexes. Q1 is slow because a
correlated subquery re-scans two large tables once per encounter; three small
indexes remove that repeated work. Q6 is slow because a self-join performs 11,800
GiST probes to answer a question that a single ordered pass can answer; the fix
is a rewrite and adds no index at all. Q4 is the smallest win because its
predicate is not selective: 85% of appointments fall inside the twelve-month
window, so the index can only remove the other 15% and the heap access.

---

## Q1 — Patient clinical history

**Business requirement:** a clinician opens a patient's chart before a
consultation and needs every encounter, newest first, with the primary diagnosis
and counts of prescriptions and lab orders.

### Query

```sql
SELECT
    e.encounter_id,
    e.started_at,
    e.encounter_type,
    s.first_name || ' ' || s.last_name AS doctor,
    d.icd_code,
    ic.description AS primary_diagnosis,
    (SELECT count(*) FROM prescription p
      WHERE p.encounter_id = e.encounter_id) AS prescriptions,
    (SELECT count(*) FROM lab_order l
      WHERE l.encounter_id = e.encounter_id) AS lab_orders
FROM patient pt
JOIN encounter e ON e.patient_id = pt.patient_id
JOIN staff s ON s.staff_id = e.doctor_id
LEFT JOIN diagnosis d
       ON d.encounter_id = e.encounter_id
      AND d.diagnosis_type = 'PRIMARY'
LEFT JOIN icd_code ic ON ic.icd_code = d.icd_code
WHERE pt.mrn = 'MRN-0000002'
ORDER BY e.started_at DESC;
```

### Before

Abridged from `results/baseline.txt` (Q1 run 5; full plan in the file):

```text
Sort  (cost=20771.91..20771.91 rows=3 width=111) (actual time=207.615..207.626 rows=4 loops=1)
  Sort Key: e.started_at DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=15321
  ->  Nested Loop Left Join  (cost=8.73..20771.88 rows=3 width=111) (actual time=105.509..207.541 rows=4 loops=1)
        ...
        ->  Hash Join  (cost=8.32..1893.52 rows=3 width=44) (actual time=0.112..55.407 rows=4 loops=1)
              Hash Cond: (e.patient_id = pt.patient_id)
              ->  Seq Scan on encounter e  (cost=0.00..1720.88 rows=62588 width=60) (actual time=0.006..11.777 rows=62588 loops=1)
                    Buffers: shared hit=1095
              ->  Hash  (cost=8.30..8.30 rows=1 width=16) (actual time=0.050..0.052 rows=1 loops=1)
                    ->  Index Scan using patient_mrn_key on patient pt  (actual time=0.039..0.041 rows=1 loops=1)
                          Index Cond: ((mrn)::text = 'MRN-0000002'::text)
        SubPlan 1
          ->  Aggregate  (cost=3779.70..3779.72 rows=1 width=8) (actual time=22.541..22.541 rows=1 loops=4)
                Buffers: shared hit=8860
                ->  Seq Scan on prescription p  (cost=0.00..3779.70 rows=2 width=0) (actual time=0.005..22.524 rows=2 loops=4)
                      Filter: (encounter_id = e.encounter_id)
                      Rows Removed by Filter: 125174
                      Buffers: shared hit=8860
        SubPlan 2
          ->  Aggregate  (cost=2509.57..2509.58 rows=1 width=8) (actual time=15.353..15.353 rows=1 loops=4)
                Buffers: shared hit=5344
                ->  Seq Scan on lab_order l  (cost=0.00..2509.56 rows=2 width=0) (actual time=0.008..15.337 rows=1 loops=4)
                      Filter: (encounter_id = e.encounter_id)
                      Rows Removed by Filter: 93884
                      Buffers: shared hit=5344
Execution Time: 207.771 ms
```

**Reading the plan:** the patient lookup is already fast (3 buffers). The cost is
the two `SubPlan` nodes. Each is a correlated aggregate that has no index on
`encounter_id`, so it sequentially scans the whole table: 125,174 prescriptions
discarded to count 2, and 93,884 lab orders discarded to count 1. `loops=4`
means each scan happens once per encounter. That is roughly 500,000 prescription
rows and 375,000 lab-order rows read to return four result rows. The 15,321
shared buffers and 207 ms are the bill for those repeated scans. The `Seq Scan
on encounter` (62,588 rows, 1,095 buffers) is a secondary cost; the plan had to
read every encounter because there was no index on `patient_id`.

### After

Abridged from `results/after.txt` (Q1 run 21; median 0.60 ms):

```text
Sort  (cost=57.49..57.49 rows=3 width=111) (actual time=0.384..0.389 rows=4 loops=1)
  Sort Key: e.started_at DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=65
  ->  Nested Loop Left Join  (cost=5.43..57.46 rows=3 width=111) (actual time=0.264..0.375 rows=4 loops=1)
        ...
        ->  Bitmap Heap Scan on encounter e  (cost=4.45..19.77 rows=4 width=60) (actual time=0.026..0.029 rows=4 loops=1)
              Recheck Cond: (pt.patient_id = patient_id)
              Heap Blocks: exact=1
              Buffers: shared hit=4
              ->  Bitmap Index Scan on ix_encounter_patient_started  (cost=0.00..4.45 rows=4 width=0) (actual time=0.018..0.018 rows=4 loops=1)
                    Index Cond: (patient_id = pt.patient_id)
                    Buffers: shared hit=3
        SubPlan 1
          ->  Aggregate  (cost=4.46..4.47 rows=1 width=8) (actual time=0.014..0.015 rows=1 loops=4)
                Buffers: shared hit=13
                ->  Index Only Scan using ix_prescription_encounter on prescription p  (cost=0.42..4.45 rows=2 width=0) (actual time=0.011..0.011 rows=2 loops=4)
                      Index Cond: (encounter_id = e.encounter_id)
                      Heap Fetches: 0
                      Buffers: shared hit=13
        SubPlan 2
          ->  Aggregate  (cost=4.46..4.47 rows=1 width=8) (actual time=0.014..0.014 rows=1 loops=4)
                Buffers: shared hit=13
                ->  Index Only Scan using ix_lab_order_encounter on lab_order l  (cost=0.42..4.45 rows=2 width=0) (actual time=0.012..0.013 rows=1 loops=4)
                      Index Cond: (encounter_id = e.encounter_id)
                      Heap Fetches: 0
                      Buffers: shared hit=13
Execution Time: 0.592 ms
```

**Reading the plan:** the same four encounters are now found through a bitmap
index scan (3 buffers instead of 1,095), and each correlated aggregate becomes
an Index Only Scan with `Heap Fetches: 0`. Total shared buffers fall from 15,321
to 65, and execution from 207 ms to 0.59 ms. The `Sort` and `Nested Loop` nodes
are unchanged; only the access paths below them changed. That is the cleanest
possible demonstration of cause and effect: the plan shape is the same, the
work is not.

### Incremental effect

The three indexes were added one at a time. Each row in this table is a separate
five-run capture, so the delta is attributable to the index named:

| Stage | Median (ms) | Change from previous | Plan evidence |
|---|---:|---:|---|
| Baseline | 197.5 | — | Seq Scan on encounter; Seq Scan on prescription and lab_order per encounter; 15,321 buffers |
| + `ix_encounter_patient_started` | 178.2 | −9.8% | 4 encounters via bitmap index; subplans still seq scan |
| + `ix_prescription_encounter` | 82.0 | −54.0% | Prescription subplan becomes Index Only Scan |
| + `ix_lab_order_encounter` | 0.78 | −99.0% | Last sequential scan removed; 65 buffers |

The encounter index alone barely helps (197.5 → 178.2 ms) because the subplans
are the dominant cost. This is why the measurement was done one index at a time:
adding all three at once would have produced a 330× number with no explanation
of which index mattered. The prescription index removes about 96 ms; the
lab-order index removes the last 81 ms. The lab-order index looks more valuable
than it is — it is simply the last scan left, so removing it exposes the true
cost of the query, which is almost nothing.

**Why it worked:** `ix_encounter_patient_started` is `(patient_id, started_at
DESC)`. `patient_id` is the equality predicate and `started_at DESC` matches the
final sort, so the planner can use a bitmap index scan for four rows. The two
subplan indexes are simple B-trees on `encounter_id`; because the aggregate only
needs a count, PostgreSQL uses an Index Only Scan and never visits the heap. The
primary-diagnosis join already had a partial unique index from Portfolio 1
(`one_primary_diagnosis_per_encounter`), so no new index was needed there.

**Cost accepted:** about 8.1 MB across the three indexes (2.5 MB + 3.1 MB + 2.5
MB), plus insert/update maintenance on encounter, prescription and lab_order.
The patient chart is the most frequent clinical read in the system, so this is
the easiest write cost to justify. The indexes are narrow and the columns are
stable.

**At 10× volume:** 200,000 patients and 625,000 encounters. The query still
touches four encounters, so it remains effectively constant-time; the risk is a
single patient with thousands of encounters (for example, a dialysis or oncology
patient), where the result set and the sort grow. The fix would be pagination
(keyset on `started_at`) or a materialized "latest encounter summary", not a
different index. The same three indexes remain correct.

---

## Q2 — Doctor workload for the last complete week

**Business requirement:** operations wants to see, per doctor, how many
appointments were booked in the last seven days, how many completed, how many
were no-shows, and how many were cancelled.

### Query

```sql
SELECT
    s.employee_no,
    s.first_name || ' ' || s.last_name AS doctor,
    dp.specialty,
    count(*) AS appointments,
    count(*) FILTER (WHERE a.status = 'COMPLETED') AS completed,
    count(*) FILTER (WHERE a.status = 'NO_SHOW') AS no_shows,
    count(*) FILTER (WHERE a.status = 'CANCELLED') AS cancelled
FROM appointment a
JOIN doctor_profile dp ON dp.staff_id = a.doctor_id
JOIN staff s ON s.staff_id = dp.staff_id
WHERE a.slot_start >= CURRENT_DATE - 7
  AND a.slot_start < CURRENT_DATE
GROUP BY s.employee_no, s.first_name, s.last_name, dp.specialty
ORDER BY appointments DESC, s.last_name;
```

### Before

Abridged from `results/baseline.txt` (Q2 run 5; median 76.5 ms):

```text
Sort  (cost=3522.48..3523.98 rows=602 width=100) (actual time=99.426..99.447 rows=50 loops=1)
  Sort Key: (count(*)) DESC, s.last_name
  Sort Method: quicksort  Memory: 30kB
  Buffers: shared hit=1484
  ->  HashAggregate  (cost=3485.66..3494.69 rows=602 width=100) (actual time=99.214..99.288 rows=50 loops=1)
        ->  Hash Join  (cost=2.12..3341.34 rows=4640 width=50) (actual time=0.129..68.684 rows=4900 loops=1)
              ->  Seq Scan on appointment a  (cost=0.00..3326.00 rows=4640 width=20) (actual time=0.032..63.701 rows=4900 loops=1)
                    Filter: ((slot_start < CURRENT_DATE) AND (slot_start >= (CURRENT_DATE - 7)))
                    Rows Removed by Filter: 77100
                    Buffers: shared hit=1481
Execution Time: 99.604 ms
```

**Reading the plan:** the date range selects 4,900 rows out of 82,000 — 6% — but
there is no index on `slot_start`, so the executor reads all 82,000 rows and
discards 77,100. That scan is 63.7 ms and 1,481 buffers of the 76.5 ms median.
The hash joins and the 50-row aggregate are small by comparison. The planner's
row estimate (4,640) is within 5% of actual (4,900), so this is not a statistics
problem; it is a missing access path.

### After

Abridged from `results/after.txt` (Q2 run 3; median 18.9 ms):

```text
Sort  (cost=407.56..409.07 rows=602 width=100) (actual time=17.943..17.953 rows=50 loops=1)
  Sort Key: (count(*)) DESC, s.last_name
  Sort Method: quicksort  Memory: 30kB
  Buffers: shared hit=36
  ->  HashAggregate  (cost=370.74..379.77 rows=602 width=100) (actual time=17.756..17.805 rows=50 loops=1)
        ->  Hash Join  (cost=6.49..242.18 rows=4675 width=40) (actual time=0.329..8.428 rows=4900 loops=1)
              ->  Index Only Scan using ix_appointment_slot_start on appointment a  (cost=0.42..209.92 rows=4675 width=20) (actual time=0.063..2.521 rows=4900 loops=1)
                    Index Cond: ((slot_start >= (CURRENT_DATE - 7)) AND (slot_start < CURRENT_DATE))
                    Heap Fetches: 0
                    Buffers: shared hit=33
Execution Time: 18.103 ms
```

**Reading the plan:** the scan reads 4,900 index entries in 33 buffers and never
visits the heap, because `doctor_id` and `status` are `INCLUDE`d columns. No
`Rows Removed by Filter` line exists: the index condition seeks directly to the
week's range. Total buffers fall from 1,481 to 36. The remaining ~16 ms is the
hash aggregate and the final sort of 50 rows, which is CPU work that no index can
remove. The five-run isolated capture measured 17.4 ms; the final 21-run capture
measured 18.9 ms with the same plan and 36 buffers. The two agree. A repeat taken
under 68% host CPU load measured 31.3 ms, which is the host effect, not a
regression.

**Why it worked:** `slot_start` is the range predicate, so it must be the leading
column. `doctor_id` and `status` are not filtered or joined inside the index, but
including them makes the scan index-only: the executor can count status values
without fetching the heap row. The seed runs `VACUUM (ANALYZE)`, which sets the
visibility map; without that, an index-only scan still has to check the heap and
the gain would be smaller. This is a good example of why the maintenance step is
part of the index design, not an afterthought.

**Cost accepted:** 3,992 kB. Every appointment insert and status update maintains
it. `appointment` is the table Portfolio 3 will contend over, so adding an index
here is not free. This one earns its place because Q2 is a daily operational
report and the same index is reused by Q6's 60-day range scan. It is still only
one of two indexes added to `appointment`; the third candidate was rejected (see
Q6).

**At 10× volume:** 820,000 appointments and about 49,000 rows per week. The
index-only scan grows linearly and remains the right plan; the aggregate is still
50 doctors. The index will be about 40 MB, which is acceptable. If the report
were changed to a full year, the range would select a large fraction of the
table and a sequential scan might win again — the index is for the weekly
window, not for arbitrary history.

---

## Q3 — Urgent laboratory turnaround by department

**Business requirement:** operational reporting on urgent tests: how many were
ordered in the last 90 days, the average turnaround in hours, and the 90th
percentile, grouped by the department that ordered them.

### Query

```sql
SELECT
    d.name AS department,
    count(*) AS urgent_orders,
    round(avg(EXTRACT(EPOCH FROM (l.reported_at - l.collected_at)) / 3600)::numeric, 2)
        AS avg_hours,
    round(percentile_cont(0.9) WITHIN GROUP (
        ORDER BY EXTRACT(EPOCH FROM (l.reported_at - l.collected_at)) / 3600
    )::numeric, 2) AS p90_hours
FROM lab_order l
JOIN staff s ON s.staff_id = l.ordered_by
JOIN department d ON d.department_id = s.department_id
WHERE l.priority = 'URGENT'
  AND l.reported_at IS NOT NULL
  AND l.ordered_at >= CURRENT_DATE - 90
GROUP BY d.name
ORDER BY avg_hours DESC;
```

### Before

Abridged from `results/baseline.txt` (Q3 run 5; median 135.4 ms):

```text
Sort  (cost=3801.74..3801.77 rows=10 width=88) (actual time=125.357..125.362 rows=7 loops=1)
  Sort Key: (round(avg(...), 2)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=1339
  ->  GroupAggregate  (cost=3625.01..3801.58 rows=10 width=88) (actual time=107.374..125.329 rows=7 loops=1)
        ->  Sort  (cost=3625.01..3639.71 rows=5878 width=32) (actual time=99.803..102.218 rows=8314 loops=1)
              Sort Key: d.name
              Sort Method: quicksort  Memory: 884kB
              ->  Hash Join  (cost=5.16..3257.02 rows=5878 width=32) (actual time=0.146..87.559 rows=8314 loops=1)
                    ->  Seq Scan on lab_order l  (cost=0.00..3213.70 rows=5878 width=32) (actual time=0.012..61.012 rows=8314 loops=1)
                          Filter: ((reported_at IS NOT NULL) AND (priority = 'URGENT'::lab_priority) AND (ordered_at >= (CURRENT_DATE - 90)))
                          Rows Removed by Filter: 85571
                          Buffers: shared hit=1336
Execution Time: 125.580 ms
```

**Reading the plan:** the three predicates are selective — 8,314 rows (8.9%)
survive out of 93,885 — but without an index the executor reads all 93,885 rows
and discards 85,571. That is 61 ms and 1,336 buffers. The rest is the hash join
to staff/department and the sort of 8,314 rows by department for the group
aggregate. The estimate (5,878) is 29% below actual (8,314), a reminder that the
three predicates are correlated (an urgent order is more likely to be reported),
but the plan is still the right shape because the index-only scan is cheap
relative to the sort.

### After

Abridged from `results/after.txt` (Q3 run 2; median 48.7 ms):

```text
Sort  (cost=868.06..868.08 rows=10 width=88) (actual time=47.833..47.839 rows=7 loops=1)
  Sort Key: (round(avg(...), 2)) DESC
  Sort Method: quicksort  Memory: 25kB
  Buffers: shared hit=66
  ->  GroupAggregate  (cost=691.12..867.89 rows=10 width=88) (actual time=30.938..47.803 rows=7 loops=1)
        Group Key: d.name
        ->  Sort  (cost=691.12..705.83 rows=5885 width=32) (actual time=19.920..21.547 rows=8314 loops=1)
              Sort Key: d.name
              Sort Method: quicksort  Memory: 884kB
              ->  Hash Join  (cost=5.45..322.63 rows=5885 width=32) (actual time=0.218..14.135 rows=8314 loops=1)
                    ->  Index Only Scan using ix_lab_order_urgent_ordered_at on lab_order l  (cost=0.29..279.28 rows=5885 width=32) (actual time=0.079..2.855 rows=8314 loops=1)
                          Index Cond: (ordered_at >= (CURRENT_DATE - 90))
                          Heap Fetches: 0
                          Buffers: shared hit=63
Execution Time: 48.113 ms
```

**Reading the plan:** the `Seq Scan` becomes an Index Only Scan of exactly the
8,314 urgent, reported orders in 63 buffers. The scan drops from 61 ms to 2.9 ms.
The sort by department (8,314 rows, 884 kB) and the percentile calculation now
dominate at roughly 20-31 ms; total execution is 48.7 ms median. That is a 2.8×
speed-up and a 20× reduction in buffer traffic, but it is limited by the
aggregation, not the scan. This is the honest ceiling for an index on this query.

**Why it worked:** the partial predicate
`priority = 'URGENT' AND reported_at IS NOT NULL` matches the query exactly, so
the planner can prove the index applies and only store the 8,314 rows the report
can use. `ordered_at` is the range key. `collected_at`, `reported_at` and
`ordered_by` are included so the average, the percentile sort, and the join to
staff all read the index only. The index is 552 kB, the smallest one added,
because it indexes 9% of the table. A full index on the same columns would be
several megabytes and would still require the same filter.

**Cost accepted:** 552 kB, and only rows that are urgent and reported are
maintained. When a lab order changes from `PENDING` to `REPORTED`, it enters the
index; that is one index insertion per lab report, on a table that already
receives 164,000 result rows. The write cost is small compared with the read
benefit, and the partial predicate keeps the index from growing with routine
tests.

**At 10× volume:** 938,850 lab orders and about 83,000 urgent/reported orders per
90 days. The index-only scan is still the right access path (roughly 630
buffers). The `percentile_cont` sort of 83,000 rows will exceed `work_mem = 4MB`
and spill, so the report would need a larger `work_mem` for the analytics
session, or a nightly pre-aggregated table keyed by department and day. The
index itself does not need to change.

---

## Q4 — Patients with no appointment in the last 12 months

**Business requirement:** re-engagement. The hospital wants a callable list of
patients who have not been seen in the last year, with contact details, not just
a count.

### Query

```sql
SELECT
    p.mrn,
    p.full_name,
    p.phone,
    p.created_at
FROM patient p
WHERE NOT EXISTS (
    SELECT 1
    FROM appointment a
    WHERE a.patient_id = p.patient_id
      AND a.slot_start >= CURRENT_DATE - INTERVAL '12 months'
      AND a.slot_start < CURRENT_DATE
)
ORDER BY p.mrn;
```

### Before

Abridged from `results/baseline.txt` (Q4 run 5; median 193.3 ms):

```text
Sort  (cost=5284.27..5291.93 rows=3064 width=48) (actual time=223.229..226.394 rows=3000 loops=1)
  Sort Key: p.mrn
  Sort Method: quicksort  Memory: 314kB
  Buffers: shared hit=1969
  ->  Hash Right Anti Join  (cost=938.00..5106.84 rows=3064 width=48) (actual time=197.994..200.211 rows=3000 loops=1)
        Hash Cond: (a.patient_id = p.patient_id)
        ->  Seq Scan on appointment a  (cost=0.00..3326.00 rows=69971 width=16) (actual time=0.019..82.163 rows=70000 loops=1)
              Filter: ((slot_start < CURRENT_DATE) AND (slot_start >= (CURRENT_DATE - '1 year'::interval)))
              Rows Removed by Filter: 12000
              Buffers: shared hit=1481
        ->  Hash  (cost=688.00..688.00 rows=20000 width=64) (actual time=65.831..65.837 rows=20000 loops=1)
              ->  Seq Scan on patient p  (cost=0.00..688.00 rows=20000 width=64) (actual time=0.018..30.962 rows=20000 loops=1)
                    Buffers: shared hit=488
Execution Time: 227.352 ms
```

**Reading the plan:** the anti-join is the right shape: the planner has rewritten
`NOT EXISTS` into a `Hash Right Anti Join`, so it does not run a nested loop for
each patient. The cost is reading 82,000 appointments to keep the 70,000 inside
the year and discard 12,000 future bookings. That scan is 82 ms and 1,481
buffers; the patient scan is 31 ms and 488 buffers; the final sort of 3,000 rows
is small. The estimate (3,064 patients) is within 2% of actual (3,000), so the
plan is not a statistics failure. The predicate is simply not selective: 85% of
appointments are in the window, so most of the work is legitimate.

### After

Abridged from `results/after.txt` (Q4 run 6; median 133.0 ms):

```text
Sort  (cost=5108.50..5116.43 rows=3172 width=48) (actual time=131.621..132.010 rows=3000 loops=1)
  Sort Key: p.mrn
  Sort Method: quicksort  Memory: 314kB
  Buffers: shared hit=895
  ->  Hash Right Anti Join  (cost=938.42..4924.03 rows=3172 width=48) (actual time=102.973..108.266 rows=3000 loops=1)
        Hash Cond: (a.patient_id = p.patient_id)
        ->  Index Only Scan using ix_appointment_patient_start on appointment a  (cost=0.42..3152.15 rows=69573 width=16) (actual time=0.297..32.829 rows=70000 loops=1)
              Index Cond: ((slot_start >= (CURRENT_DATE - '1 year'::interval)) AND (slot_start < CURRENT_DATE))
              Heap Fetches: 0
              Buffers: shared hit=407
        ->  Hash  (cost=688.00..688.00 rows=20000 width=64) (actual time=40.344..40.345 rows=20000 loops=1)
              ->  Seq Scan on patient p  (cost=0.00..688.00 rows=20000 width=64) (actual time=0.015..14.745 rows=20000 loops=1)
                    Buffers: shared hit=488
Execution Time: 132.519 ms
```

**Reading the plan:** the appointment scan is now an Index Only Scan of 70,000
entries in 407 buffers, with no heap fetches. It no longer reads the 12,000
future appointments at all. Total buffers fall from 1,969 to 895 and execution
from 193 ms to 133 ms (1.5×). The anti-join and the 3,000-row sort are unchanged.
This is the smallest improvement in the portfolio, and that is the point: an
index cannot make an 85%-selective predicate cheap. The remaining cost is the
70,000 rows that genuinely have to be compared, plus the 20,000-row patient
hash. The 2.2× reduction in buffers is still worth having, but the headline
speed-up is modest.

The wall-clock number is also the one most affected by host noise. An earlier
11-run capture measured 122.3 ms, the final 21-run capture 133.0 ms, and the
loaded repeat 198.8 ms; all three use this same plan and 895 buffers. The
consistent result is the reduction in buffer traffic and the elimination of the
12,000 future-appointment reads, not the exact millisecond delta. On a quiet host
the gain is around 1.5×; under load it can disappear into the noise.

**Why it worked:** the anti-join probes appointments by `patient_id`, so the
index leads with `patient_id`. `slot_start` is second so the range predicate is
checked inside the index. The scan is index-only because the query needs only
`patient_id` and `slot_start` from appointment; the planner never fetches the
heap. Writing the predicate as `NOT EXISTS` matters: `NOT IN` would return no
rows if any `slot_start` were NULL (a single NULL poisons the whole comparison),
whereas `NOT EXISTS` is null-safe. The schema declares `slot_start NOT NULL`, so
both would work today, but the anti-join form is the one that stays correct if
the constraint is ever relaxed.

**Cost accepted:** 3,272 kB, plus maintenance on every appointment insert and
update. Unlike Q2's index, this one is not reused by another query in the
portfolio; it is a dedicated re-engagement report. At 133 ms for a monthly list
of 3,000 patients, it is acceptable, but it is the first index I would drop if
appointment write throughput became a problem.

**At 10× volume:** 200,000 patients and 820,000 appointments. The hash side of
the anti-join grows to about 21.8 MB (the current 20,000-row hash is 2,178 kB),
which exceeds `work_mem = 4MB`; the join will spill to disk. The better design at
that scale is a maintained `last_appointment_at` column on `patient` (updated by
a trigger or a nightly job), which turns the anti-join into a simple range scan,
or a materialized view refreshed nightly. The 30,000-row result also needs
pagination. The index on `appointment` remains useful for the trigger's lookup,
but the anti-join should not be the production mechanism at 10×.

---

## Q5 — Top 10 diagnoses by frequency this year

**Business requirement:** clinical reporting and service planning. Which
conditions consume the most consultation time this year?

### Query

```sql
SELECT
    d.icd_code,
    c.description,
    count(*) AS diagnoses,
    count(DISTINCT d.encounter_id) AS encounters
FROM diagnosis d
JOIN icd_code c ON c.icd_code = d.icd_code
WHERE d.diagnosed_at >= date_trunc('year', CURRENT_DATE)::timestamptz
GROUP BY d.icd_code, c.description
ORDER BY diagnoses DESC, d.icd_code
LIMIT 10;
```

### Before

Abridged from `results/baseline.txt` (Q5 run 5; median 1,018.2 ms):

```text
Limit  (cost=15337.83..15337.85 rows=10 width=51) (actual time=988.482..988.492 rows=10 loops=1)
  Buffers: shared hit=1012, temp read=736 written=738
  ->  Sort  (cost=15337.83..15338.83 rows=400 width=51) (actual time=988.479..988.486 rows=10 loops=1)
        Sort Key: (count(*)) DESC, d.icd_code
        Sort Method: quicksort  Memory: 27kB
        ->  GroupAggregate  (cost=14151.73..15329.18 rows=400 width=51) (actual time=796.747..988.405 rows=20 loops=1)
              ->  Sort  (cost=14151.73..14386.42 rows=93876 width=51) (actual time=789.260..907.951 rows=93885 loops=1)
                    Sort Key: d.icd_code, c.description, d.encounter_id
                    Sort Method: external merge  Disk: 5888kB
                    Buffers: shared hit=1012, temp read=736 written=738
                    ->  Hash Join  (cost=1.45..3188.80 rows=93876 width=51) (actual time=0.063..160.140 rows=93885 loops=1)
                          ->  Seq Scan on diagnosis d  (cost=0.00..2888.70 rows=93876 width=21) (actual time=0.029..92.241 rows=93885 loops=1)
                                Filter: (diagnosed_at >= date_trunc('year'::text, (CURRENT_DATE)::timestamp with time zone))
                                Buffers: shared hit=1011
Execution Time: 994.556 ms
```

**Reading the plan:** the diagnosis scan is not the problem: 93,885 rows in 92 ms,
and the `diagnosed_at` filter removes nothing in this capture because all 100 days
of seeded history fall inside 2026. The problem is the sort above it: 93,885 rows
do not fit in the 4 MB `work_mem`, so PostgreSQL spills 5,888 kB to disk
(`external merge Disk: 5888kB`) and reads/writes 736 temp blocks. The group
aggregate then sorts again by ICD code for the `count(DISTINCT encounter_id)`.
Total 1,018 ms. The estimate (93,876) is essentially exact, so this is a
memory/ordering problem, not a statistics problem.

### After

Abridged from `results/after.txt` (Q5 run 8; median 303.4 ms):

```text
Limit  (cost=12931.35..12931.38 rows=10 width=51) (actual time=325.597..325.602 rows=10 loops=1)
  Buffers: shared hit=627
  ->  Sort  (cost=12931.35..12932.35 rows=400 width=51) (actual time=325.595..325.598 rows=10 loops=1)
        Sort Key: (count(*)) DESC, d.icd_code
        Sort Method: quicksort  Memory: 27kB
        ->  GroupAggregate  (cost=540.83..12922.71 rows=400 width=51) (actual time=41.431..325.525 rows=20 loops=1)
              Group Key: d.icd_code, c.description
              ->  Incremental Sort  (cost=540.83..11979.95 rows=93876 width=51) (actual time=34.198..257.169 rows=93885 loops=1)
                    Sort Key: d.icd_code, c.description, d.encounter_id
                    Presorted Key: d.icd_code
                    Full-sort Groups: 20  Sort Method: quicksort  Average Memory: 30kB  Peak Memory: 30kB
                    Pre-sorted Groups: 20  Sort Method: quicksort  Average Memory: 1450kB  Peak Memory: 1663kB
                    ->  Nested Loop  (cost=0.55..5081.29 rows=93876 width=51) (actual time=0.075..144.925 rows=93885 loops=1)
                          ->  Index Only Scan using ix_diagnosis_icd_encounter on diagnosis d  (cost=0.42..206.50 rows=4694 width=21) (actual time=0.031..5.789 rows=4694 loops=20)
                                Index Cond: (icd_code = (c.icd_code)::text)
                                Filter: (diagnosed_at >= date_trunc('year'::text, (CURRENT_DATE)::timestamp with time zone))
                                Heap Fetches: 0
                                Buffers: shared hit=625
Execution Time: 325.760 ms
```

**Reading the plan:** the scan is now an Index Only Scan in ICD-code order
(627 buffers, no heap fetches). The `diagnosed_at` filter is applied inside the
index. The full external sort is replaced by an `Incremental Sort` that exploits
the index's `icd_code` order; its peak memory is 1,663 kB, so nothing spills
(`temp read/written` is absent). The median is 303.4 ms, a 3.4× speed-up. The
representative run shown here is 325.8 ms, within the host's normal spread. The
remaining cost is the `count(DISTINCT encounter_id)` over 93,885 rows: the
incremental sort still has to order each ICD group by `encounter_id`, and the
group aggregate reads all 93,885 rows. That is why this is not a 10× win like Q6;
the index removes the disk spill and the heap access, but not the aggregation.

**Why it worked:** the covering index is `(icd_code, encounter_id) INCLUDE
(diagnosed_at)`. `icd_code` provides the grouping order, `encounter_id` is needed
because `count(DISTINCT ...)` cannot be answered from a count of index entries
alone, and `diagnosed_at` is included so the year filter is evaluated in the
index. The index-only scan avoids the 92 ms heap scan and, more importantly,
gives the planner a presorted input, which turns the 5.9 MB external merge into
an in-memory incremental sort.

**Cost accepted:** 4,576 kB, the largest index in the portfolio. Diagnosis is
append-heavy (one or two rows per encounter), so the write cost is lower than an
index on appointment; there are no status updates to maintain. The index is
still 6.5× larger than Q3's partial index, which is the price of covering 93,885
rows instead of 8,314.

### Rewrite experiment: why the obvious `DISTINCT` rewrite lost

Before accepting the index, I tried rewriting the query to remove the
`count(DISTINCT ...)`:

```sql
SELECT x.icd_code, c.description, count(*) AS encounters
FROM (
    SELECT DISTINCT icd_code, encounter_id
    FROM diagnosis
    WHERE diagnosed_at >= date_trunc('year', CURRENT_DATE)::timestamptz
) x
JOIN icd_code c ON c.icd_code = x.icd_code
GROUP BY x.icd_code, c.description
ORDER BY encounters DESC, x.icd_code
LIMIT 10;
```

The results are a useful warning about optimising a query and an index
separately rather than together:

| Variant | Time | Plan |
|---|---:|---|
| Original, no index | 1,018 ms (median) | Seq Scan + external merge 5,888 kB |
| `DISTINCT` rewrite, no index | 377 ms (single run) | Seq Scan + hash aggregate, no spill |
| `DISTINCT` rewrite + covering index | 871 ms (single run) | Index scan + extra aggregation; the index order is lost |
| Original + covering index | 303.4 ms (median; 325.8 ms in the representative run) | Index Only Scan + incremental sort |

Without an index, the rewrite is excellent: `DISTINCT` turns the 93,885 rows into
about 62,588 distinct `(icd_code, encounter_id)` pairs and avoids the external
sort. But once the covering index exists, the rewrite is *worse*: the `DISTINCT`
step materialises and reorders the rows, so the final `GROUP BY` can no longer
use the index's `icd_code` order, and the plan loses the incremental sort. The
original query plus the index is the winner. The lesson is that a rewrite that
helps on unindexed data can block the best index plan; both variants have to be
measured against both physical designs.

**At 10× volume:** 938,850 diagnoses. The index-only scan is about 6,270 buffers,
which is fine, but the incremental sort's peak memory grows from 1,663 kB to
roughly 16.6 MB, well above `work_mem = 4MB`; it will spill. The options are a
larger `work_mem` for the reporting session, a materialized summary table
refreshed nightly, or a columnstore/OLAP engine for the analytics workload. The
top-10 query is a good candidate for a materialized view because it is read-only
and the result is small.

---

## Q6 — Appointments at risk of double-booking

**Business requirement:** a nightly data-quality audit of the live schedule. The
exclusion constraint from Portfolio 1 should make this return no rows; the query
is the independent check that proves it, and would catch rows loaded before the
constraint existed (for example, a restored backup).

### Before: the range self-join

```sql
SELECT
    a.appointment_id AS appointment_a,
    b.appointment_id AS appointment_b,
    a.doctor_id,
    a.slot_start AS a_start,
    a.slot_end   AS a_end,
    b.slot_start AS b_start,
    b.slot_end   AS b_end
FROM appointment a
JOIN appointment b
  ON b.doctor_id = a.doctor_id
 AND b.appointment_id > a.appointment_id
 AND tstzrange(b.slot_start, b.slot_end, '[)')
  && tstzrange(a.slot_start, a.slot_end, '[)')
WHERE a.status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
  AND b.status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
  AND a.slot_start >= CURRENT_DATE
  AND a.slot_start < CURRENT_DATE + 60
ORDER BY a.slot_start, b.slot_start;
```

Abridged from `results/baseline.txt` (Q6 run 5; median 646.2 ms):

```text
Gather Merge  (cost=7495.51..7541.51 rows=400 width=80) (actual time=666.135..675.529 rows=0 loops=1)
  Workers Planned: 1
  Workers Launched: 1
  Buffers: shared hit=57300
  ->  Nested Loop  (cost=648.28..6478.21 rows=400 width=80) (actual time=654.123..654.125 rows=0 loops=2)
        Buffers: shared hit=57291
        ->  Parallel Bitmap Heap Scan on appointment a  (cost=648.00..2312.14 rows=1011 width=48) (actual time=1.305..13.543 rows=5900 loops=2)
              Recheck Cond: (status = ANY ('{BOOKED,ARRIVED,IN_PROGRESS}'::appointment_status[]))
              Filter: ((slot_start >= CURRENT_DATE) AND (slot_start < (CURRENT_DATE + 60)))
              Rows Removed by Filter: 100
              Buffers: shared hit=367
              ->  Bitmap Index Scan on no_double_booking  (cost=0.00..647.57 rows=11860 width=0) (actual time=2.396..2.396 rows=12000 loops=1)
        ->  Index Scan using no_double_booking on appointment b  (cost=0.28..4.11 rows=1 width=48) (actual time=0.105..0.105 rows=0 loops=11800)
              Index Cond: ((doctor_id = a.doctor_id) AND (tstzrange(slot_start, slot_end, '[)'::text) && tstzrange(a.slot_start, a.slot_end, '[)'::text)))
              Filter: (appointment_id > a.appointment_id)
              Rows Removed by Filter: 1
              Buffers: shared hit=56895
Execution Time: 675.620 ms
```

**Reading the plan:** the GiST exclusion index `no_double_booking` is doing
exactly what it was designed to do — but it was designed for a different
question. It answers "does this one new appointment conflict with an existing
one?" with a single index probe. The audit asks "compare every live appointment
with every other appointment for the same doctor", so the nested loop probes the
GiST index once for each of the 11,800 live appointments, and each probe returns
about one row (the appointment itself), which the `appointment_id >` filter then
discards. That is 57,300 shared buffers and 646 ms to return zero rows. The plan
is not badly costed; the query is doing unnecessary work.

### After: one ordered pass with a window function

```sql
WITH live AS (
    SELECT appointment_id, doctor_id, slot_start, slot_end
    FROM appointment
    WHERE status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS')
      AND slot_start >= CURRENT_DATE
      AND slot_start < CURRENT_DATE + 60
),
flagged AS (
    SELECT l.*,
           max(l.slot_end) OVER w AS latest_previous_end,
           lag(l.appointment_id) OVER w AS previous_appointment
    FROM live l
    WINDOW w AS (
        PARTITION BY l.doctor_id
        ORDER BY l.slot_start, l.appointment_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING
    )
)
SELECT
    appointment_id       AS appointment_b,
    previous_appointment AS previous_appointment,
    doctor_id,
    latest_previous_end  AS a_end,
    slot_start           AS b_start,
    slot_end             AS b_end
FROM flagged
WHERE latest_previous_end > slot_start
ORDER BY doctor_id, slot_start;
```

Abridged from `results/after.txt` (Q6 run 14; median 55.9 ms; isolated median
43.9 ms):

```text
Subquery Scan on flagged  (cost=2325.79..2394.57 rows=611 width=72) (actual time=53.034..53.037 rows=0 loops=1)
  Filter: (flagged.latest_previous_end > flagged.slot_start)
  Rows Removed by Filter: 11800
  Buffers: shared hit=294
  ->  WindowAgg  (cost=2325.79..2371.64 rows=1834 width=72) (actual time=34.015..51.594 rows=11800 loops=1)
        ->  Sort  (cost=2325.79..2330.38 rows=1834 width=48) (actual time=34.000..36.241 rows=11800 loops=1)
              Sort Key: appointment.doctor_id, appointment.slot_start, appointment.appointment_id
              Sort Method: quicksort  Memory: 1214kB
              ->  Bitmap Heap Scan on appointment  (cost=423.50..2226.38 rows=1834 width=48) (actual time=3.788..14.118 rows=11800 loops=1)
                    Recheck Cond: ((slot_start >= CURRENT_DATE) AND (slot_start < (CURRENT_DATE + 60)))
                    Filter: (status = ANY ('{BOOKED,ARRIVED,IN_PROGRESS}'::appointment_status[]))
                    Heap Blocks: exact=220
                    ->  Bitmap Index Scan on ix_appointment_slot_start  (cost=0.00..423.05 rows=12262 width=0) (actual time=3.726..3.726 rows=11800 loops=1)
                          Index Cond: ((slot_start >= CURRENT_DATE) AND (slot_start < (CURRENT_DATE + 60)))
Execution Time: 53.295 ms
```

**Reading the plan:** the self-join is gone. The executor reads the 11,800 live
appointments once, sorts them by doctor and start time (1,214 kB, well inside
`work_mem`), and makes a single `WindowAgg` pass. The window computes two things
at once because both use the same window definition: `max(slot_end)` over all
earlier rows and `lag(appointment_id)` for the immediately preceding row. The
filter then compares each start with the latest end seen so far. Buffers fall
from 57,300 to 294 and the median from 646 ms to 55.9 ms — 11.6× — with **no new
index**. The 55.9 ms is the all-query capture; an isolated five-run capture of the
same query measured 43.9 ms. Both are far below the self-join.

**Why the running maximum matters:** `lag(slot_end)` alone is not sufficient. If
a doctor has A [09:00-12:00], B [09:15-09:30] and C [09:45-10:00], the rows sort
as A, B, C. Comparing C with its immediate predecessor B (end 09:30) would miss
that C overlaps A (end 12:00). The running maximum of all earlier ends is 12:00,
so C is correctly flagged. The immediate predecessor is still returned for
context, but the flag is based on the maximum. This is the difference between a
demo that works on the seed data (where no overlaps exist at all) and an audit
that would catch a real nested overlap in restored data.

**Why no index:** the rewrite is the fix. The sort of 11,800 rows is only 1,214
kB and fits in `work_mem`; a B-tree could avoid the sort, but it would add an
incremental sort because the window also orders by `appointment_id` as a
tiebreaker, and the WindowAgg itself would still have to process 11,800 rows. I
measured the candidate:

```sql
CREATE INDEX ... ON appointment (doctor_id, slot_start)
    INCLUDE (appointment_id, slot_end)
    WHERE status IN ('BOOKED', 'ARRIVED', 'IN_PROGRESS');
```

| Variant | Time | Plan |
|---|---:|---|
| Window rewrite, no new index | 43.9 ms (isolated median) | Bitmap Heap Scan + Sort + WindowAgg |
| Window rewrite + candidate index | 29-72 ms across six runs; median ~44 ms | Index Only Scan + Incremental Sort + WindowAgg |

The candidate is 808 kB and produces no measurable improvement: the median is
the same, and the WindowAgg dominates once the scan is cheap. It would also add
write maintenance to `appointment`, the table Portfolio 3 contends over, for a
query that runs once a night. It was rejected. The existing
`ix_appointment_slot_start` (added for Q2) already provides the 60-day range
scan; Q6 reuses it without paying for another index.

**Cost accepted:** no new storage or write cost. The query is more complex to
read than the self-join, which is why the comment in `queries.sql` explains the
running maximum and why `lag(slot_end)` is not enough. The window query also
returns one row per flagged appointment rather than one row per overlapping
pair; for an audit that is the useful shape, because each row identifies a
schedule entry that needs investigation.

**At 10× volume:** 118,000 live appointments over 60 days. The sort grows to
roughly 12 MB, which exceeds `work_mem = 4MB` and will spill. The audit does not
need a 60-day window every night; shortening it to 7 or 14 days keeps the sort
in memory and still catches recent data-quality problems. The other options are
partitioning `appointment` by month, or maintaining a materialized doctor
schedule. The exclusion constraint remains the primary guarantee; the audit is a
backstop, so a slower monthly deep check plus a fast nightly recent check is a
reasonable split. Note also that the planner estimates 1,834 rows in the `live`
CTE but gets 11,800 — see the estimate discussion below.

---

## Overall observations

### What actually paid

1. **Remove work before adding indexes.** Q1's correlated subqueries and Q6's
   self-join were both unnecessary work. Q6 took no index at all and became 11.6×
   faster; Q1 needed three indexes only because the subqueries were structurally
   correct but unindexed. The first question in every case was "what is the plan
   doing that it does not need to do?", not "which column should I index?".
2. **Selectivity determines the ceiling.** Q3's partial index covers 9% of the
   table, is 552 kB, and gives 2.8×. Q4's index covers 85% of the table, is 3.3 MB,
   and gives 1.5×. Both plans are correct; the difference is how much of the table
   the query genuinely needs. An index on a non-selective predicate is not a
   failure, but it should not be sold as a big win.
3. **Covering indexes need the visibility map.** Q2, Q3, Q4 and Q5 all show
   `Heap Fetches: 0`. That is only possible because `seed-data.sql` runs
   `VACUUM (ANALYZE)`; without the visibility map, an index-only scan still
   visits the heap and the gain shrinks. Index design and table maintenance are
   one topic, not two.

### Planner estimates

| Query | Estimated rows | Actual rows | Error |
|---|---:|---:|---:|
| Q1 | 3 | 4 | +33% (small absolute) |
| Q2 | 4,640 | 4,900 | −5% |
| Q3 | 5,878 | 8,314 | −29% |
| Q4 | 3,064 | 3,000 | +2% |
| Q5 | 93,876 | 93,885 | ≈0% |
| Q6 (live CTE) | 1,834 | 11,800 | −84% |

Q3's underestimate is explained by correlated predicates: urgent orders and
reported orders are not independent, so multiplying their selectivities
underestimates the result. It does not change the plan because the index-only
scan is cheap and the sort is the bottleneck anyway.

Q6 is the interesting one. The planner estimates 1,834 live appointments but
gets 11,800. The reason is the independence assumption: 12,000 of 82,000
appointments are `BOOKED` (14.6%), and 12,000 are in the 60-day future window
(14.6%), so the planner multiplies the two selectivities and expects about 2.1%
of 82,000 — roughly 1,700-1,800. In reality every future appointment is `BOOKED`;
the two predicates are perfectly correlated. This is a textbook correlated-column
estimate error, and it is why the `live` CTE estimate is 6.4× low even after
`ANALYZE`. At the current size the bitmap scan is cheap enough that the wrong
estimate does not hurt. At 10× it could: a 6.4× underestimate of the outer side is
exactly the kind of mistake that makes a nested loop look attractive. A
multivariate statistic would help:

```sql
CREATE STATISTICS appointment_status_start (dependencies, ndistinct)
    ON status, slot_start FROM appointment;
ANALYZE appointment;
```

That is a recommendation for the 10× design, not a change made here, because it
would alter the baseline and the portfolio is measuring the effect of the seven
indexes and the Q6 rewrite, one variable at a time.

### Read/write balance and index cost

The case study assumes an 85:15 read:write ratio, which is what makes seven read
indexes defensible. The total footprint is about 20.4 MB on a 312 MB database
(6.5%), small enough that storage is not the constraint. The real constraint is
write maintenance on `appointment`: it is the table Portfolio 3 will use for
concurrency, and it now has two new indexes (`slot_start` and
`patient_id, slot_start`). The third candidate for Q6 was rejected precisely
because it would add write cost without a measurable read benefit. The partial
index on `lab_order` is the best cost/benefit in the set: 552 kB, 9% of the
table, 2.8×. The diagnosis index is the largest at 4.6 MB, but diagnosis rows are
append-only in this workload, so its maintenance is cheaper than its size
suggests.

### At 10× volume

| Query | What breaks first | What I would change |
|---|---|---|
| Q1 | A patient with many encounters; result pagination | Keyset pagination, or a materialized latest-encounter summary |
| Q2 | Nothing significant; 49,000 rows/week | Keep the index; consider BRIN only if the table becomes append-only and huge |
| Q3 | `percentile_cont` over ~83,000 rows exceeds `work_mem` | Raise `work_mem` for the report, or pre-aggregate nightly |
| Q4 | 200,000-row hash exceeds `work_mem`; 30,000-row result | Maintained `last_appointment_at`; pagination |
| Q5 | Incremental sort ~16.6 MB spills | Raise `work_mem`, or materialized summary / OLAP engine |
| Q6 | 118,000-row sort ~12 MB spills | Shorten the audit window, partition by month, or materialise the schedule |

The common theme is that the indexes remain correct at 10×; what changes is the
memory available to sorts and hash joins. The portfolio's `work_mem` is 4 MB,
which is appropriate for an OLTP server but too small for the analytics queries.
A production design would separate the reporting workload from the transactional
one, either with a read replica and a larger `work_mem`, or with a nightly
materialized layer. Portfolio 4's move of lab results to MongoDB is a further
step in that direction for the lab workload; the PostgreSQL partial index in Q3
is the relational baseline it will be compared against.

### Reproducing the numbers

```powershell
# 1. Start with an empty volume (schema and seed run once, ~4.2 minutes).
docker compose down -v
docker compose up -d postgres
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/verify.ps1

# 2. Baseline, before indexes (five runs).
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
    -Output portfolio-2-query-optimisation/results/baseline.txt -Runs 5
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/summarise-plans.ps1 `
    -InputFile portfolio-2-query-optimisation/results/baseline.txt

# 3. Apply the indexes.
Get-Content portfolio-2-query-optimisation/indexes.sql -Raw |
    docker compose exec -T postgres psql -U portfolio -d hospital -v ON_ERROR_STOP=1

# 4. Final capture (21 runs; the summariser discards the first).
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
    -Output portfolio-2-query-optimisation/results/after.txt -Runs 21
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/summarise-plans.ps1 `
    -InputFile portfolio-2-query-optimisation/results/after.txt
```

Run the final capture on an otherwise idle host. `results/after-loaded.txt` is a
repeat of the same step taken at 68% CPU load; it is included only to show how
much the host affects absolute timings, not as a competing result.

`CREATE INDEX CONCURRENTLY` cannot run inside a transaction block, so
`indexes.sql` has no `BEGIN`/`COMMIT` and must be run with psql as above, not
inside a transaction. The file uses `IF NOT EXISTS` and is safe to re-run.

### Limitations

- **Single host, repeated runs.** All timings are from one Docker Desktop VM on a
  2-core laptop. The absolute milliseconds are not portable; the plan shapes,
  row counts and buffer counts are. The final capture uses 21 runs per query and
  reports the median of 20, but a repeat taken under 68% CPU load
  (`results/after-loaded.txt`) was 20-50% slower with identical plans. That is
  why the report compares buffer counts and access methods as primary evidence
  and treats small millisecond differences as noise.
- **Warm cache.** The first run of each capture is discarded, so the numbers
  describe a warm buffer cache, which is the right model for a repeatedly used
  clinical report but not for a cold-start benchmark.
- **Synthetic data.** The seed is deterministic in structure but uses UUID
  hashes for some tables, so row counts vary by a few per cent between rebuilds.
  The plans are stable because the volumes and distributions are stable.
- **No concurrency.** These measurements are single-session. Portfolio 3
  measures what happens when 150 sessions contend; an index that helps a
  single-session plan can still hurt under write contention, which is why the
  appointment indexes were kept to two.
