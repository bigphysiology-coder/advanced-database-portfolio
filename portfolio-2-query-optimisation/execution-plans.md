# Execution Plans and Performance Analysis

**Environment:** PostgreSQL _<version>_, Docker Desktop, _<CPU/RAM>_, dataset of
_<n>_ appointments and _<n>_ lab results.

> State the environment or the numbers mean nothing. A 12 ms query on 200 rows proves
> nothing about a 12 ms query on 2 million.

## Summary

| Query | Before (ms) | After (ms) | Change | Fix applied |
|---|---|---|---|---|
| Q1 | | | | |
| Q2 | | | | |
| Q3 | | | | |
| Q4 | | | | |
| Q5 | | | | |
| Q6 | | | | |

---

## Q1 — Patient clinical history

**Business requirement:** _<one line>_

### Before

```sql
-- query text
```

```text
-- paste raw EXPLAIN (ANALYZE, BUFFERS) output here, unedited
```

**Reading the plan:** _<the bottleneck, and the evidence for it — e.g. "the Seq Scan on
lab_results returns 20,000 rows to the hash join; the 3,180 KB of shared read confirms
it is coming from disk, not cache.">_

### After

```sql
-- index or rewritten query
```

```text
-- paste raw plan
```

**Why it worked:** _<which access method, why the planner chose it, what the row
estimates did>_

**Cost accepted:** _<storage, write amplification, maintenance>_

**At 10× volume:** _<what breaks next>_

---

## Q2 — Doctor workload

_(repeat the structure above)_

---

## Q3 — Lab turnaround

_(repeat)_

---

## Q4 — Dormant patients

_(repeat — this is the one where comparing `NOT EXISTS` vs `NOT IN` vs `LEFT JOIN`
is worth documenting)_

---

## Q5 — Top diagnoses

_(repeat)_

---

## Q6 — Double-booking detection

_(repeat)_

---

## Overall Observations

- Which index paid for itself and which did not?
- Where was the planner's row estimate wrong, and why?
- What does this tell you about the read/write balance of a hospital workload?
