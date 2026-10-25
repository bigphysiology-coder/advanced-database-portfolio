# Portfolio 2 — Query Processing and Optimisation

**Marks:** 7 / 40

## Required Evidence

- [ ] SQL queries
- [ ] Query results
- [ ] Execution plans
- [ ] Indexing / optimisation evidence
- [ ] Brief performance analysis

## Files

| File | Purpose |
|---|---|
| `queries.sql` | The business queries, written independently of indexes |
| `indexes.sql` | Indexes added, each tied to a query and a plan |
| `execution-plans.md` | Before/after `EXPLAIN (ANALYZE, BUFFERS)` output |
| `results/` | Raw output, screenshots, CSV timing runs |

## Method

The mark comes from showing **cause and effect**, so each query follows the same loop:

1. Write the query from the business requirement.
2. Capture the plan and timing on unindexed data.
3. Identify the bottleneck from the plan — seq scan, nested loop, sort spill, bad row estimate.
4. Add one index (or rewrite the query).
5. Capture the plan and timing again.
6. Explain the delta in one paragraph.

Only change one variable per iteration, or the result proves nothing.

## Queries to Cover

Cover a spread of plan shapes rather than five variations of the same lookup:

| # | Business question | Expected pressure point |
|---|---|---|
| 1 | Patient's full history in chronological order | Sort + join fan-out |
| 2 | Doctor workload for a date range | Range scan on a date column |
| 3 | Average lab turnaround by department | Aggregation over large tables |
| 4 | Patients with no appointment in 12 months | Anti-join / NOT EXISTS |
| 5 | Top 10 diagnoses by frequency this year | Group + sort + limit |
| 6 | Appointments at risk of double-booking | Self-join / window function |

## Capturing Plans

```sql
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT ...;
```

Record the numbers, not just the shape:

- Planning time vs execution time
- Actual rows vs estimated rows (large divergence means stale stats — try `ANALYZE`)
- Buffers: `shared hit` vs `shared read` (proves cache behaviour)
- Any `Sort Method: external merge Disk:` — a spill worth fixing

## Timing Runs

A single run is noise. For each query:

```sql
\timing on
-- run 5 times, discard the first (cold cache), report the median of the rest
```

State the PostgreSQL version, machine specs and dataset size alongside the numbers,
otherwise the timings are not interpretable.

## Analysis to Write

For each query, answer:

- What was the bottleneck, and what in the plan told you that?
- Why did the chosen index help — which access method, and why that one?
- What did it cost? (write amplification, storage, slower inserts)
- Was a query rewrite more effective than an index? If so, why?
- What would you do at 10× the data volume?
