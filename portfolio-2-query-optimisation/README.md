# Portfolio 2 — Query Processing and Optimisation

**Marks:** 7 / 40

## Required Evidence

- [x] SQL queries
- [x] Query results
- [x] Execution plans
- [x] Indexing / optimisation evidence
- [x] Brief performance analysis

## Files

| File | Purpose |
|---|---|
| `queries.sql` | The six business queries, written independently of indexes. Includes the rejected Q5 rewrite and Q6 self-join for the record. |
| `indexes.sql` | The seven accepted indexes, each tied to a query and a measured plan, plus the rejected Q6 index. |
| `execution-plans.md` | Full before/after analysis: environment, plans, buffer counts, incremental effects, costs and 10× risks. |
| `results/baseline.txt` | Five-run baseline before any Portfolio 2 index (old Q6 self-join). |
| `results/after.txt` | **Final** 21-run capture with all accepted indexes (Q6 window rewrite). |
| `results/after-loaded.txt` | Repeat of the final capture at 68% host CPU load. Same plans and buffers, 20-50% slower. Kept as a variance control; not used for reported numbers. |
| `results/q1-after-*.txt` | Q1 measured after each of its three indexes, one at a time. |
| `results/q2-after-index.txt` … `results/q5-after-index.txt` | Per-query captures after each index was added. |
| `results/q6-window-final.txt` | Isolated five-run capture of the Q6 rewrite. |
| `results/*.csv` | Machine-readable medians from each capture. |

## Method

Each query follows the same loop, so the cause and effect are visible:

1. Write the query from the business requirement.
2. Capture `EXPLAIN (ANALYZE, BUFFERS, TIMING)` on unindexed data — five runs,
   first run discarded, median reported.
3. Identify the bottleneck from the plan: sequential scan, repeated subplan,
   nested loop, disk sort, bad row estimate.
4. Change one variable: add one index, or rewrite the query, never both at once.
5. Capture again: five runs for the baseline and incremental captures, 21 for
   the final capture.
6. Explain the delta.

The final capture uses 21 runs because the 2-core Docker host showed 20-50%
run-to-run variance; the median of 20 measured runs is much more stable than the
median of four. The buffer counts and access methods are the primary evidence,
not small millisecond differences. A repeat capture under 68% CPU load is kept in
`results/after-loaded.txt` to show the size of the host effect. See
`execution-plans.md` for the full discussion.

## Results

| Query | Before (ms) | After (ms) | Speed-up | Fix |
|---|---:|---:|---:|---|
| Q1 — patient history | 197.5 | 0.60 | 330× | Three indexes; correlated subplans become index-only counts |
| Q2 — doctor workload | 76.5 | 18.9 | 4.1× | Covering index on `appointment (slot_start)` |
| Q3 — urgent lab turnaround | 135.4 | 48.7 | 2.8× | Partial covering index on urgent, reported orders |
| Q4 — dormant patients | 193.3 | 133.0 | 1.5× | Index on `appointment (patient_id, slot_start)` |
| Q5 — top diagnoses | 1,018.2 | 303.4 | 3.4× | Covering index on `diagnosis`; avoids a 5.9 MB disk sort |
| Q6 — double-booking audit | 646.2 | 55.9 | 11.6× | Window rewrite; **no index added** |

Total index footprint: about 20.4 MB on a 312 MB database (6.5%).

## Key Findings

- **Q1 is a repeated-work problem, not a missing-index problem.** One patient
  lookup was fine; the two correlated subqueries re-scanned 125,176
  prescriptions and 93,885 lab orders once per encounter. Adding the encounter
  index alone changed 197.5 → 178.2 ms. The prescription index took it to 82.0 ms
  and the lab-order index to 0.78 ms. Measuring one index at a time is what makes
  that story visible.
- **Q5: the obvious rewrite lost.** `SELECT DISTINCT` was faster without an index
  (377 ms single run vs 1,018 ms median) but blocked the covering-index plan
  (871 ms single run vs 303.4 ms median for the original query plus the index),
  because the `DISTINCT` step loses the index's `icd_code` order.
- **Q6: the best fix added no index.** The range self-join probed the GiST
  exclusion index 11,800 times (57,300 buffers). A window function over one
  ordered pass reduced that to 294 buffers. A candidate B-tree measured 29-72 ms
  (median ~44 ms) against 43.9 ms for the rewrite alone — no measurable benefit,
  808 kB of write overhead on the busiest table, rejected.
- **Q4 is the honest counter-example.** The predicate selects 85% of the table,
  so the index can only remove the other 15%; 1.5× is the ceiling on a quiet
  host, and the wall-clock gain can disappear into host noise even though the
  buffer traffic falls 2.2×. Not every index is a 10× win, and the report says so.
- **Q6's plan estimate is 6.4× low** (1,834 vs 11,800) because the planner assumes
  `status` and `slot_start` are independent, but every future appointment is
  `BOOKED`. At 10× that is the kind of error that could flip a nested loop;
  multivariate statistics are the recommended fix.

## Reproduce

```powershell
# Baseline before indexes (5 runs)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
    -Output portfolio-2-query-optimisation/results/baseline.txt -Runs 5

# Apply indexes (not inside a transaction: CREATE INDEX CONCURRENTLY)
Get-Content portfolio-2-query-optimisation/indexes.sql -Raw |
    docker compose exec -T postgres psql -U portfolio -d hospital -v ON_ERROR_STOP=1

# Final capture (21 runs; first run discarded)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
    -Output portfolio-2-query-optimisation/results/after.txt -Runs 21

powershell -NoProfile -ExecutionPolicy Bypass -File scripts/summarise-plans.ps1 `
    -InputFile portfolio-2-query-optimisation/results/after.txt
```

Run the final capture on an otherwise idle host. The seed must be loaded first
(`scripts/verify.ps1` checks 20,000 patients, 82,000 appointments and 163,387 lab
results). See the root README for the full environment setup.
