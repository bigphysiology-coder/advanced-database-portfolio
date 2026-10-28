# Portfolio 4 — NoSQL and Advanced Data Models

**Marks:** 7 / 40

**Status:** complete

## Required Evidence

- [x] A NoSQL model for **the same case study** — one document per laboratory order,
      built from the P1 seeded PostgreSQL database
- [x] A document-model example with real implementation, not a slide
- [x] Implementation evidence — raw `mongosh`, `psql` and Docker output in
      [`evidence/`](evidence/)
- [x] Explanation of suitability — including where the document model is the **wrong**
      choice

The evidence is raw terminal output rather than cropped screenshots. Each file records
the command and its exit status, so the numbers can be re-run and diffed. The four
representative documents are in [`sample-documents.json`](sample-documents.json)
(Extended JSON).

---

## The Model in One Page

A laboratory report is the document:

```text
one lab order
├── order_id, encounter_id, patient_id, patient_mrn
├── test_code, test_name, specimen_type, department
├── priority, status
├── ordered_at, collected_at, reported_at
└── results[]  (1–4 analytes; empty while pending)
    ├── analyte_id, analyte, value, value_type, unit
    ├── ref_low, ref_high, flag
    └── resulted_at, resulted_by
```

From the captured load (`evidence/00-environment.txt`, `evidence/01-load.txt`):

| Fact | Count |
|---|---:|
| Laboratory orders / MongoDB documents | 93,885 |
| Embedded result rows | 163,387 |
| Patients with laboratory orders | 15,200 |
| `REPORTED` orders | 65,531 |
| `ORDERED` / `COLLECTED` / `IN_PROGRESS` orders | 9,494 / 9,360 / 9,500 |
| Test types / analyte definitions | 10 / 25 |
| Numeric / textual result rows | 156,794 / 6,593 |
| Average document size | 925 bytes |

The average is **2.49 results per reported order**, maximum **4**. That bound is what
makes embedding safe. A report is read as a whole, written as a whole, and carries the
units and reference ranges that were in force when it was produced.

**Not in MongoDB:** patients, encounters, staff, appointments, prescriptions, the
laboratory order header, the analyte catalogue and the audit log. Those remain in
PostgreSQL. MongoDB is a laboratory report store/read model, not a replacement for the
hospital's relational system of record. The full boundary and the cases where it would
move are in [`model-design.md`](model-design.md).

---

## Files

| File | Purpose |
|---|---|
| `mongodb-setup.js` | Creates `lab_results` and `patient_refs`, installs the `$jsonSchema` validator and six indexes. |
| `export-lab-results.sql` | One NDJSON line per order, with `json_agg` results. |
| `export-patient-refs.sql` | 15,200 `{_id, mrn}` reference projections. |
| `load-ndjson.js` | Stages NDJSON when `mongoimport` is unavailable. |
| `transform-lab-results.js` | Converts ISO strings to BSON dates, computes `result_count`, `$merge`s, drops staging. |
| `queries.js` | Q1–Q6 with `explain("executionStats")` summaries. |
| `validation-tests.js` | 11 valid/invalid insert cases with server error codes. |
| `consistency-checks.js` | 27 cross-document and cross-store checks. |
| `benchmark.js` | Warm-up + five timed runs per query/write; median reported. |
| `compare-postgres.sql` | Relational equivalents with `\timing` and plans. |
| `export-samples.js` | Four representative documents in Extended JSON. |
| `model-design.md` | Full modelling argument, embedding/referencing decisions, comparison and limitations. |
| `evidence/00-environment.txt` … `07-benchmark.txt` | Raw captured evidence. |
| `sample-documents.json` | Real documents exported from the running collection. |

---

## Method

1. Export the same PostgreSQL laboratory data used by Portfolios 1–3. The export is one
   line per order, so a document is never assembled by a client-side N+1 loop.
2. Create the validated collection and indexes. The validator is strict: closed enums,
   BSON dates, required fields, and `results.0` required for `REPORTED`/`AMENDED`.
3. Stage the raw JSON, convert the timestamp strings to BSON dates, `$merge` on
   `order_id`, then drop the staging collection.
4. Drop the five secondary indexes before the bulk merge and recreate them afterwards.
   The merge key `ux_order_id` stays because `$merge` requires a unique match key. This
   keeps index maintenance off the 93,885 inserts without changing the final schema.
5. Run the validator and consistency tests, then Q1–Q6 with `executionStats`.
6. Run the PostgreSQL equivalents and the warm-run benchmark on the same host.

The load is idempotent. The captured run starts with an existing 93,885-document
collection, clears it in the transform and rebuilds exactly the same counts. That is
why `evidence/01-load.txt` shows `target documents before transform: 93885` followed by
the same total after the merge.

---

## Results

### Validator: 11 / 11

`evidence/02-validator.txt` contains real inserts against `lab_results`. Two documents
are accepted (a `REPORTED` lipid panel and an empty `IN_PROGRESS` order); nine are
rejected with the server's error code:

| Rejected case | Error |
|---|---|
| Missing `test_code` | `121 DocumentValidationFailure` |
| `REPORTED` with empty `results` | `121 DocumentValidationFailure` |
| `ordered_at` as a string | `121 DocumentValidationFailure` |
| Flag `ABNORMAL` outside the enum | `121 DocumentValidationFailure` |
| MRN not matching `^MRN-[0-9]{7}$` | `121 DocumentValidationFailure` |
| Negative `result_count` | `121 DocumentValidationFailure` |
| Duplicate `order_id` | `11000 DuplicateKey` |
| `value_type: "number"` | `121 DocumentValidationFailure` |
| Result without `resulted_at` | `121 DocumentValidationFailure` |

The validator cannot express `result_count = size(results)`, cross-store foreign keys,
temporal ordering or analyte membership. Those are checked by
`consistency-checks.js`: **27 / 27 passed**, including 0 count mismatches, 0 orphan
patient IDs, 0 MRN disagreements, 0 impossible timestamps, 0 flag/range disagreements
and all six lab indexes present (`evidence/03-consistency.txt`).

### Query patterns and plans

From `evidence/04-queries.txt`:

| Query | Result | Keys / docs examined | Plan | Server time |
|---|---|---|---:|---|---:|
| **Q1** patient history, newest first | 7 orders | 7 / 7 | `FETCH -> IXSCAN[ix_patient_collected]` | 4 ms |
| **Q2** abnormal results, last 30 days | 8,816 abnormal results (20 shown) | 10,106 / 8,816 | `FETCH -> IXSCAN[ix_result_flag_collected] -> $unwind -> $match -> $project -> $sort` | 647 ms |
| **Q3** work queue, top 10 | 10 orders | 10 / 10 | `LIMIT -> FETCH -> IXSCAN[ix_status_priority_collected]` | 0 ms |
| **Q4** one analyte over time | 5 results | 5 / 5 | `FETCH -> IXSCAN[ix_patient_analyte_collected] -> $unwind -> $match -> $project -> $sort` | 1 ms |
| **Q5** dashboard `$facet` | 4 branches | 75,061 / 75,061 | `FETCH -> IXSCAN[ix_collected] -> $facet` | 3,532 ms |
| **Q6** `$lookup` reconciliation | 5 orders | — | `$lookup` against `patient_refs._id` | — |

Q1, Q3 and Q4 read exactly as many documents as they return. Q2 is a multikey result
filter: a document with two abnormal flags contributes two keys, hence 10,106 keys for
8,816 documents. Q5 is deliberately a broad scan: the chosen date window selects 80% of
the collection, and the `$facet` needs the wide document fields. The index bounds the
scan; it does not make the dashboard cheap.

### Warm-run timings

`evidence/07-benchmark.txt` runs each query twice as a warm-up, then five times. The
median and full run list are in the evidence; the host is a 2-core Docker Desktop
machine and shows run-to-run variance, so the range is reported rather than a single
best number.

| Operation | MongoDB median (range) |
|---|---:|
| W1 insert + cleanup delete, one reported order | 16 ms (12–17) |
| Q1 patient history | 8 ms (6–10) |
| Q2 abnormal results, last 30 days | 508 ms (399–646) |
| Q3 work queue | 8 ms (6–12) |
| Q4 analyte trend | 7 ms (6–8) |
| Q5 dashboard `$facet` | 3,236 ms (2,684–3,750) |

### PostgreSQL comparison

`evidence/05-compare-postgres.txt` runs the closest relational equivalents on the same
seeded database. PostgreSQL timings are `psql` server timings; MongoDB timings include
the `mongosh` client. The first PostgreSQL execution after a restart includes buffer
warm-up, so the warm figures are the second/third runs.

| Operation | PostgreSQL warm | MongoDB | Reading |
|---|---:|---:|---|
| One patient's history | **2.07 ms** (796 ms first run; 3 joins, 58 buffers) | **8 ms** (7 keys/docs) | Both fast; PostgreSQL wins warm, MongoDB avoids the join and group/sort. |
| Work queue, top 10 | **26–35 ms** (912 ms first run; seq scan 93,885 rows) | **8 ms** (10 keys/docs) | MongoDB's compound index serves filter + sort + limit; PostgreSQL has no matching queue index. |
| Analyte trend | **2.78–2.91 ms** (29.9 ms first run; 4 joins) | **7 ms** (5 keys/docs) | Both sub-10 ms; PostgreSQL's nested loops are very effective warm. |
| Dashboard by test type | **95.6–98.6 ms** (one `$facet` branch) | **3.24 s** (four branches) | Not directly comparable; PostgreSQL is better for set aggregation over narrow rows. |
| Write order + 4 results | **122.9 ms** (98.5 ms order + 24.4 ms results, rolled back) | **16 ms** insert + cleanup delete | One document write versus five rows with FK/index work; not a durability benchmark. |
| New analyte | `INSERT` into the normalized `analyte` catalogue, not DDL | No migration for a new analyte; validator change only if a field becomes required | The document model wins on **shape variation**, not on adding a catalogue row. |

The honest conclusion: warm PostgreSQL matches or beats MongoDB on the patient history,
analyte trend and dashboard reads; MongoDB wins the work queue and the single-document
write. The document model is selected for the report's shape, ownership and write unit,
not for a claim that NoSQL is universally faster. This is argued in full in
[`model-design.md`](model-design.md).

---

## Embedding vs Referencing

| Relationship | Decision | Why |
|---|---|---|
| Order → results | **Embed** | Owned, bounded (1–4), read as a whole, written atomically. |
| Order → patient | **Reference** (`patient_id` string UUID) + MRN snapshot | Patient is a shared relational entity; duplicating the master creates update anomalies. |
| Order → encounter | **Reference** (`encounter_id`) | Shared relational context; many orders per encounter. |
| Order → ordering doctor | **Reference** (`ordered_by`) | Staff are shared and can change; no stale name snapshot. |
| Order → test/analyte metadata | **Embed snapshots** | Units and reference ranges must reflect the report time, not the current catalogue. |
| Order → patient reference | **Reference to derived `patient_refs`** | Small, indexed projection for MRN→ID lookup and reconciliation; not a second patient master. |

The cross-store identifiers are UUID strings, not `ObjectId`s. That gives both systems
one stable value to compare and lets `$merge` be idempotent on `order_id`. `_id` is only
MongoDB's internal document key.

---

## Polyglot Persistence Boundary

> Patient demographics, encounters, staff, appointments, prescriptions, billing and the
> laboratory order header remain in PostgreSQL because they are highly relational and
> require foreign keys, exclusion constraints and multi-row transactions. Laboratory
> reports live in MongoDB because one order and its 1–4 results form a bounded,
> self-contained document that is read and written as a unit, and because the result
> shape varies by test type.

What breaks if the boundary moves the other way?

- **Move patients/appointments to MongoDB:** lose the `no_double_booking` exclusion
  constraint and the two-session guarantees demonstrated in Portfolio 3; duplicate
  patient data across documents; make a patient merge a multi-document repair job.
- **Move laboratory reports back to PostgreSQL:** possible with the normalized tables or
  `jsonb`; it restores one store and foreign keys, but gives up the document read unit,
  native multikey indexes and independent scaling of the reporting plane. For a small
  hospital, `jsonb` would be simpler operationally; that trade-off is stated rather
  than hidden.

`patient_refs` is a **derived projection**, not a second source of truth. It is rebuilt
from PostgreSQL and checked by Q6/consistency checks. A patient merge or MRN correction
must update it; until then, reconciliation should flag the drift.

---

## Limitations

1. No cross-store foreign key: a deleted/merged patient can leave stale references until
   reconciliation. The checks detect drift; they do not prevent it.
2. Batch ETL, not CDC: amendments and late results need an outbox/CDC path in production.
3. The validator is not the whole invariant: `result_count = size(results)`, temporal
   ordering, analyte membership and duplicate analytes are script/application rules.
4. Q5 is not a hot-dashboard design: four facets over 75,061 wide documents cost
   seconds. A summary collection or the PostgreSQL aggregate is the better answer.
5. A second store means a second backup, restore, upgrade, monitoring and access-control
   surface.
6. Synthetic data only. A real deployment needs encryption, field-level access control,
   audit logging and retention rules.

---

## Reproduce

```powershell
# 1. Start both stores
docker compose up -d

# 2. Load MongoDB from the seeded PostgreSQL source
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/load-p4.ps1

# 3. Regenerate evidence/00-07 and sample-documents.json
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p4.ps1 `
  -Mongosh "C:\path\to\mongosh.exe"
```

`capture-p4.ps1 -SkipLoad` reuses an existing collection. `-Mongosh` is needed when the
MongoDB image contains the server but not the shell (the locally built fallback image);
the official `mongo:7` image includes `mongosh`, so the default works there.

Raw files:

| File | Contents |
|---|---|
| [`evidence/00-environment.txt`](evidence/00-environment.txt) | Versions, container state, source counts |
| [`evidence/01-load.txt`](evidence/01-load.txt) | Export → staging → index drop/recreate → transform → idempotent counts |
| [`evidence/02-validator.txt`](evidence/02-validator.txt) | 11 accept/reject cases |
| [`evidence/03-consistency.txt`](evidence/03-consistency.txt) | 27 checks |
| [`evidence/04-queries.txt`](evidence/04-queries.txt) | Q1–Q6 + `executionStats` |
| [`evidence/05-compare-postgres.txt`](evidence/05-compare-postgres.txt) | PostgreSQL timings and plans |
| [`evidence/06-collection-stats.txt`](evidence/06-collection-stats.txt) | Collection/index sizes |
| [`evidence/07-benchmark.txt`](evidence/07-benchmark.txt) | Five-run medians |

---

## Data and AI Declaration

All patients, staff, appointments and results are **synthetic**, generated by
`seed-data.sql`. No real patient data is used. See the repository
[data disclaimer](../README.md#data-disclaimer).

The AI-use declaration is maintained in
[`docs/ai-use-declaration.md`](../docs/ai-use-declaration.md); Entry 5 covers the P4
model, ETL, validator, query work and the corrections made while producing the
evidence.
