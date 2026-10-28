# NoSQL Model Design

## 1. Decision in One Paragraph

The laboratory report is the part of Riverbend Teaching Hospital that is modelled as a
document. One MongoDB document represents one laboratory order and owns its result
analytes: a lipid panel is one document with four result objects, a malaria screen is one
document with one textual result, and a pending order is one document with an empty
`results` array. Patient identity, encounters, staff, appointments, prescriptions and
the transactional laboratory order remain in PostgreSQL. MongoDB is therefore a
**laboratory report store/read model**, not a replacement for the hospital's relational
system of record. The boundary is deliberate: it keeps foreign keys and multi-row
transactions where they matter, and gives the report its natural unit of read and write.

The complete argument, including the cases where this boundary is the wrong choice, is
below.

---

## 2. What Was Modelled, and What Was Not

**Modelled in MongoDB:** one document per laboratory order, with its result analytes
embedded. The collection is `hospital_labs.lab_results`.

**Remained in PostgreSQL:** patients, next of kin, staff, doctors, departments, wards,
beds, appointments, encounters, admissions, diagnoses, prescriptions, medication
administrations, the laboratory order header, the analyte catalogue and the audit log.

The important question is not whether MongoDB *can* store the other entities — it can.
The question is what the system loses if it does. Moving patient demographics or
appointments into MongoDB would give up foreign keys, the exclusion constraint that
prevents double booking, and the multi-table transactions demonstrated in Portfolio 3.
Those are not decorative features; they are the reason the relational core exists.

### 2.1 Source data used

The MongoDB collection is derived from the same seeded PostgreSQL database used by
Portfolios 1–3, not from a separate toy dataset:

| Source fact | Count |
|---|---:|
| Patients | 20,000 |
| Encounters | 62,588 |
| Laboratory orders exported | 93,885 |
| Laboratory result rows embedded | 163,387 |
| Patients with at least one laboratory order | 15,200 |
| Test types | 10 |
| Analyte definitions | 25 |

Order status distribution in the source:

| Status | Orders | Embedded results |
|---|---:|---:|
| `ORDERED` | 9,494 | 0 |
| `COLLECTED` | 9,360 | 0 |
| `IN_PROGRESS` | 9,500 | 0 |
| `REPORTED` | 65,531 | 163,387 |
| `AMENDED` | 0 in this seed | 0 |

There are no `AMENDED` rows in the seed. The validator permits the status because the
case study has an amendment workflow, but the data does not exercise it. That is stated
rather than quietly ignored.

Result shape:

- Average results per reported order: **2.49**; maximum **4**.
- **156,794** numeric results and **6,593** textual results. Every textual result comes
  from the malaria parasite screen (`P. falciparum detected`, etc.); the numeric results
  cover the other nine test types.
- Flag counts across all result rows: `NORMAL` 121,513; `LOW` 26,145; `HIGH` 15,729;
  `CRITICAL` 0 in this seed.

The small, bounded result array is what makes embedding defensible. If a test could
produce thousands of analytes, or if results were appended indefinitely to one order,
embedding would become an unbounded-array problem and referencing would be safer.

---

## 3. Why This Subset Fits a Document Model

| Characteristic | Evidence from the case study | Consequence for the model |
|---|---|---|
| Heterogeneous structure | 10 test types and 25 analytes; numeric values with units and reference ranges coexist with qualitative text (`value_type: "text"`). | A single `results` array with a `value` union and a `value_type` tag handles both without sparse columns. |
| Read as a self-contained unit | The clinical read is "show me this order's report": test, specimen, priority, timestamps and all analytes together. Q1 returns 7 whole reports in one read. | One document fetch returns the report. There is no join from an order to its result rows at read time. |
| Bounded nesting | 1–4 results per order in this dataset, average 2.49. | Embedding is bounded; the document stays around **925 bytes** on average. |
| Append-only / immutable history | A reported result is corrected by a new amendment, not by silently editing history. The report must preserve the reference range and units used when it was produced. | The report owns a snapshot of test name, specimen type, unit and reference range. A later catalogue change must not rewrite old reports. |
| High write volume, low join need | 93,885 orders and 163,387 result rows; 65,531 reports already final. | One document insert/merge replaces an order header plus N result rows. The ETL and validator can enforce the shape once per order. |

### 3.1 Why not the obvious alternatives?

| Option | Why it was rejected for this slice |
|---|---|
| Wide table with many `NULL`s | With 25 analytes and more tests over time, most columns would be null for any given row. Adding a test means changing the table. It also makes the report read a row with dozens of irrelevant fields. |
| EAV (`order_id`, `analyte_id`, `value`) | Correct and flexible, but reconstructing one report needs a pivot or N joins, and validating "a reported order has at least one result" becomes an application rule spread across rows. Portfolio 1 already uses a normalized result table; P4 is specifically asking whether the document unit is a better fit for the read model. |
| Raw `jsonb` column in PostgreSQL | Genuinely reasonable, and it would keep foreign keys and transactions. It was rejected here because the laboratory reporting plane has a different read/write shape and scaling profile from the transactional core, and MongoDB gives native document validation plus multikey indexes over the embedded array. For a small single-node hospital, `jsonb` would be the simpler operational choice; this portfolio should say that rather than pretend otherwise. |
| Graph database | A patient–doctor–department referral graph is a secondary analytic workload, not the core laboratory report read. A graph store would optimise a peripheral query while making the report unit awkward. |
| Key-value store | Appropriate for session tokens or a last-viewed-patient cache; a laboratory report has queryable nested structure and needs secondary indexes, not an opaque blob. |
| Column-family store | A good fit for the append-heavy audit log or time-series observations, not for a report that is read as one bounded object. |

The document choice is therefore about the **shape of the report and its unit of
atomicity**, not about avoiding SQL for its own sake.

---

## 4. Embedding vs Referencing

The rule applied: **embed when the child is owned by the parent, bounded, and always
read with it; reference when the entity is shared, independently updated, unbounded, or
needed on its own.**

| Relationship | Decision | Justification |
|---|---|---|
| Order → result analytes | **Embed** | The analytes are owned by the order, there are 1–4 of them, and a report is never useful without them. One document write is atomic for the order and all its results. |
| Order → patient | **Reference** (`patient_id` string UUID) | The patient is a shared relational entity with demographics, encounters and appointments. Duplicating the patient master would create update anomalies. `patient_mrn` is embedded only as a display snapshot and is reconciled against `patient_refs`. |
| Order → encounter | **Reference** (`encounter_id` string UUID) | The encounter is the relational context; many orders can belong to it. Duplicating encounter data would duplicate a large, changing aggregate. |
| Order → ordering doctor | **Reference** (`ordered_by` string UUID) | Staff are shared and can change role or name; the report stores the stable ID, not a name snapshot. A display name is resolved by the application or a future projection. |
| Order → test/analyte metadata | **Embed snapshots** (`test_name`, `specimen_type`, `unit`, `ref_low`, `ref_high`) | The report must show the units and reference range that were in force when the result was produced. Referencing the live catalogue would silently rewrite history when a range changes. |
| Order → patient reference | **Reference to a derived projection** (`patient_refs`) | The projection contains only `_id` (patient UUID) and `mrn`. It is rebuilt from PostgreSQL, used to resolve an MRN through an index, and is not a second patient master. |

### 4.1 Why the identifiers are strings, not `ObjectId`

`order_id`, `encounter_id`, `patient_id` and `ordered_by` are UUID strings copied from
PostgreSQL. They are not converted to MongoDB `ObjectId`s. This is intentional:
cross-store references need one stable value that both systems can compare without a
mapping table. It also makes the ETL idempotent: `$merge` can match on `order_id`
directly. The MongoDB `_id` remains the internal document key and has no business
meaning.

The cost is 36 bytes per identifier and the loss of `ObjectId` generation. That is a
good trade for a store whose whole purpose is to reconcile with a relational source.

---

## 5. Document Schema

A representative document from the running collection
(`sample-documents.json`, first sample, abridged):

```json
{
  "order_id": "352ec38b-aebb-46f2-8534-33e904f72689",
  "encounter_id": "07846650-b4b7-4b8d-ba52-0b8d2318d57a",
  "patient_id": "4cd15ff3-dffc-438c-bf8e-514f6f6d6b91",
  "patient_mrn": "MRN-0000430",
  "test_code": "LIPID",
  "test_name": "Lipid Profile",
  "specimen_type": "Blood",
  "department": "Pathology and Laboratory",
  "priority": "URGENT",
  "status": "REPORTED",
  "ordered_at": { "$date": "2026-07-18T09:10:00Z" },
  "collected_at": { "$date": "2026-07-18T10:10:00Z" },
  "reported_at": { "$date": "2026-07-18T22:10:00Z" },
  "ordered_by": "3c2a986f-9221-43ce-9421-8dbea59a13a5",
  "results": [
    {
      "analyte_id": 5,
      "analyte": "Total cholesterol",
      "value": 0,
      "value_type": "numeric",
      "unit": "mmol/L",
      "ref_low": 0,
      "ref_high": 5,
      "flag": "NORMAL",
      "resulted_at": { "$date": "2026-07-18T22:10:00Z" },
      "resulted_by": "ffff91fd-02b8-46f3-9743-19b20e01f3f7"
    }
  ],
  "result_count": 4,
  "schema_version": 1
}
```

The real file contains all four analytes; one is shown here for readability. The dates
are MongoDB Extended JSON (`$date`) because the export uses relaxed EJSON.

| Field | Rationale |
|---|---|
| `order_id` | Cross-store natural key and `$merge` key; unique index makes reloads idempotent. |
| `encounter_id`, `patient_id`, `ordered_by` | Cross-store UUID references. No foreign key can cross the store boundary, so reconciliation matters (section 7). |
| `patient_mrn` | Human-readable business key for display and MRN→ID lookup; an immutable identifier in the case study, but still a snapshot that is checked against `patient_refs`. |
| `test_code`, `test_name`, `specimen_type`, `department` | Test identity and the report header. Names and specimen type are snapshots so old reports remain readable if the catalogue is edited. |
| `priority`, `status` | Closed enums. `status` drives which timestamps and result cardinality are valid. |
| `ordered_at`, `collected_at`, `reported_at` | BSON dates, nullable where the workflow has not reached that stage. Storing strings would break range queries and sort order. |
| `results` | The owned, bounded child array. `value` is `double`, `int` or `string`; `value_type` makes the intended interpretation explicit without inspecting BSON types. |
| `results.ref_low`, `results.ref_high` | Nullable because qualitative results such as malaria have no numeric range. The flag is still part of the result. |
| `result_count` | Denormalised count for dashboards and cheap checks. It must equal `size(results)`; the validator cannot express that, so the consistency script checks it. |
| `schema_version` | Gives a future migration a version to key on; currently `1`. |

---

## 6. Validation Strategy

`mongodb-setup.js` installs a `$jsonSchema` validator plus a query predicate:

- `validationLevel: "strict"`, `validationAction: "error"`.
- Required header fields: order, encounter, patient, test, specimen, department,
  priority, status, ordered date, ordering doctor, results, result count and schema
  version.
- Closed enums for `test_code`, `specimen_type`, `priority`, `status`, `value_type` and
  result `flag`.
- `patient_mrn` must match `^MRN-[0-9]{7}$`.
- Timestamps must be BSON dates, not ISO strings.
- Every result object requires `analyte_id`, `analyte`, `value`, `value_type`, `unit`,
  `flag` and `resulted_at`.
- `result_count` must be a non-negative integer; `schema_version` must be `1`.
- The `$and`/`$or` rule requires `results.0` to exist when the status is `REPORTED` or
  `AMENDED`. Pending orders are allowed to have an empty array.

`validation-tests.js` exercises both directions. The captured run in
`evidence/02-validator.txt` is **11 passed, 0 failed**:

| Case | Server response |
|---|---|
| Valid `REPORTED` document with one analyte | accepted |
| `IN_PROGRESS` document with empty results | accepted |
| Missing `test_code` | code **121** `DocumentValidationFailure` |
| `REPORTED` with empty results | code **121** |
| `ordered_at` supplied as a string | code **121** |
| Flag outside the closed enum (`ABNORMAL`) | code **121** |
| `patient_mrn` not matching the pattern | code **121** |
| Negative `result_count` | code **121** |
| Duplicate `order_id` | code **11000** `DuplicateKey` |
| `value_type` outside the enum | code **121** |
| Result without `resulted_at` | code **121** |

### 6.1 What the validator deliberately does not enforce

The validator is not a relational database. The following are handled elsewhere, and
the gap is named rather than hidden:

| Rule | Why the validator cannot enforce it | Control used |
|---|---|---|
| `result_count = size(results)` | `$jsonSchema` has no expression comparing two fields. | `consistency-checks.js` runs after every load: 0 mismatches in the captured run. |
| `patient_id` exists in PostgreSQL | MongoDB has no foreign keys across databases, let alone across engines. | `patient_refs` projection plus `$lookup` reconciliation (Q6) and consistency checks: 0 orphan patient IDs. |
| `patient_mrn` agrees with PostgreSQL | The MRN is an embedded snapshot. | Consistency check against `patient_refs`: 0 disagreements. |
| Result analyte belongs to its test | The validator does not know the PostgreSQL catalogue. | Consistency check: 0 violations. |
| `collected_at` after `ordered_at`; `reported_at` after `collected_at` | A JSON Schema cannot express temporal ordering. | Consistency checks: 0 violations. |
| Status/timestamp/result combinations | Requires cross-field logic. | The `$and`/`$or` rule covers the result cardinality part; the remaining rules are consistency checks. |
| Duplicate analyte within one order | No unique constraint inside an array. | Not present in this seed; would need an application rule or a consistency check if the write path allowed it. |

`consistency-checks.js` runs **27 checks** and the captured run passed all of them,
including document/status/result counts, 0 orphan patient references, 0 MRN
disagreements, 0 impossible timestamps, 0 flag/range disagreements, and the presence of
all six indexes. This is a reconciliation layer, not a substitute for a foreign key; a
production system would run it as a monitored job, not only at load time.

---

## 7. Index Design

Every index is tied to a named query in `queries.js`; none was added "just in case".
The compound order follows equality fields first, then the range/sort field (the ESR
guideline). Sizes are from `evidence/06-collection-stats.txt`.

| Index | Key | Query it serves | Access pattern observed | Size |
|---|---|---|---|---:|
| `ux_order_id` | `{ order_id: 1 }`, unique | ETL `$merge` on `order_id`; by-order lookup | Unique merge key; also rejects duplicate orders | 5.50 MB |
| `ix_patient_collected` | `{ patient_id: 1, collected_at: -1 }` | **Q1** patient history, newest first | `FETCH -> IXSCAN`, 7 keys / 7 docs returned | 1.79 MB |
| `ix_status_priority_collected` | `{ status: 1, priority: -1, collected_at: 1 }` | **Q3** work queue, urgent first, oldest first | `LIMIT -> FETCH -> IXSCAN`, 10 keys / 10 docs | 1.07 MB |
| `ix_result_flag_collected` | `{ "results.flag": 1, collected_at: -1 }` | **Q2** abnormal results across patients, last 30 days | `FETCH -> IXSCAN -> $unwind -> $match -> $project -> $sort`; 10,106 keys / 8,816 docs for 8,816 abnormal results | 1.41 MB |
| `ix_patient_analyte_collected` | `{ patient_id: 1, "results.analyte": 1, collected_at: -1 }` | **Q4** one analyte over time for one patient | `FETCH -> IXSCAN -> $unwind -> $match -> $project -> $sort`; 5 keys / 5 docs | 5.40 MB |
| `ix_collected` | `{ collected_at: -1 }` | **Q5** dashboard date range, `$facet` input | `FETCH -> IXSCAN -> $facet`; 75,061 keys / 75,061 docs | 1.02 MB |
| `ux_patient_mrn` | `{ mrn: 1 }`, unique, on `patient_refs` | Q1/Q6 MRN→ID resolution | Point lookup on 15,200 references | not in lab stats |

Total lab index size: **17,506,304 bytes (16.7 MiB)**. Collection logical size:
**86,845,355 bytes (82.8 MiB)**; storage size **40,128,512 bytes (38.3 MiB)**; average
document **925 bytes**. The logical collection is larger than the relational heap for
the same rows because it duplicates header fields and snapshots, but WiredTiger
compression keeps the on-disk collection to 38.3 MiB before its indexes.

### 7.1 What the plans show

The captured `explain("executionStats")` output in `evidence/04-queries.txt`:

- **Q1:** 7 returned, 7 keys, 7 docs, 4 ms. The index satisfies both the patient
  equality and the `collected_at DESC` sort; no collection scan and no sort stage.
- **Q2:** 8,816 returned at the cursor stage, 10,106 keys, 8,816 docs, 647 ms. This is
  a multikey index: a document with two abnormal flags contributes two keys. The
  `$unwind` is necessary because the filter is at result level, so the index cannot
  return "the matching result" without unwinding. The pipeline sorts 8,816 result rows
  and returns 20.
- **Q3:** 10 returned, 10 keys, 10 docs, 0 ms. The `status` equality and the
  `priority DESC, collected_at ASC` sort are both served by the compound index; the
  limit stops the scan.
- **Q4:** 5 returned, 5 keys, 5 docs, 1 ms. `patient_id` and `results.analyte` are
  equalities; `collected_at` is the sort field. This is the strongest per-patient read
  in the collection.
- **Q5:** 75,061 returned, 75,061 keys, 75,061 docs, 3,532 ms. The date range selects
  80% of the collection, so the index only bounds the scan; the `$facet` still has to
  fetch every selected document because it needs status, test, results and timestamps.
  This is the honest limit of the index: it is not a covering index for the dashboard.
- **Q6:** `$lookup` from `lab_results.patient_id` to `patient_refs._id` returns
  `mrn_matches: true` for all five sampled orders; the MRN point lookup uses
  `ux_patient_mrn`.

The before/after discipline from Portfolio 2 applies here too: the plan shape and
`docsExamined` are reported, not just the wall-clock time. Q1, Q3 and Q4 have
`docsExamined = nReturned`; Q2 is close (8,816/8,816 at the cursor); Q5 is deliberately
a broad scan because the dashboard genuinely needs most documents.

### 7.2 A note on Q5

`ix_collected` is useful for a narrow recent window, but the chosen 2026-07-29 window
selects 75,061 of 93,885 orders. At that selectivity the index does not avoid most of
the work. If the dashboard were a hot path, the next step would be a pre-aggregated
summary collection (or the PostgreSQL aggregate, which is already faster). The current
design keeps one source of truth and accepts a slower ad-hoc dashboard; it does not
pretend the index solves a problem it cannot.

---

## 8. Load and Transform

`scripts/load-p4.ps1` performs a one-way batch ETL:

1. `export-lab-results.sql` exports one NDJSON line per order. Results are aggregated
   with `json_agg` inside the order object. Captured size: **92.5 MB / 93,885 lines**.
2. `export-patient-refs.sql` exports **1.0 MB / 15,200** `{_id, mrn}` rows.
3. `mongodb-setup.js` creates the validated collection and indexes.
4. `load-ndjson.js` stages the raw lines in `lab_results_raw`. The local fallback
   MongoDB image does not ship `mongoimport`, so the loader uses `mongosh` and reports
   progress every 10,000 documents; the code path also supports `mongoimport` when the
   official image is used.
5. Before the `$merge`, the loader drops the five secondary indexes and keeps
   `ux_order_id` (the merge key must be unique). Building five indexes while inserting
   93,885 documents makes every write pay index maintenance; the indexes are recreated
   from `mongodb-setup.js` after the merge. This is an ETL optimisation, not a schema
   change: the final collection has exactly the six `lab_results` indexes in section 7.
6. `transform-lab-results.js` converts ISO strings to BSON dates with `$convert`,
   computes `result_count` with `$size`, sets `schema_version`, and `$merge`s on
   `order_id` with `whenMatched: "replace"` / `whenNotMatched: "insert"`.
7. The staging collection is dropped. The validator runs during the merge, so an
   invalid document fails the load rather than entering the store.

The captured load in `evidence/01-load.txt` is a **re-run against an existing 93,885
document target**: the transform clears the target and rebuilds it, and the counts after
the merge are exactly the PostgreSQL counts. That demonstrates idempotency rather than
a one-shot import.

The ETL is batch, not change data capture. A production integration would need an
outbox or CDC stream to propagate amendments and late-arriving results, plus a
reconciliation job. That limitation is stated in section 11.

---

## 9. Query Patterns and What They Demonstrate

| Query | Pattern | Why it matters for this model |
|---|---|---|
| **Q1** | `find({patient_id}).sort({collected_at: -1})` with a projection | The clinical read: whole reports for one patient, newest first, one indexed scan and no joins. |
| **Q2** | `$match` on `results.flag` + date, `$unwind`, `$match`, `$sort`, `$limit` | Cross-patient abnormal-results review. The multikey index finds candidate orders; unwinding makes the result-level filter explicit. |
| **Q3** | `find({status: "IN_PROGRESS"}).sort({priority: -1, collected_at: 1}).limit(10)` | Operational work queue. Compound index serves equality, sort and limit together. |
| **Q4** | `$match` patient + `results.analyte`, `$unwind`, project, sort | A single analyte trend, the classic multikey-array read. 5 keys and 5 docs. |
| **Q5** | `$match` date, `$facet` with status/test/flag/turnaround branches | One pass over the selected documents for four dashboard views. Convenient, but the broad scan is the cost. |
| **Q6** | `$lookup` to `patient_refs`, compare `patient_mrn` with the referenced MRN | Cross-store reconciliation. A document store cannot enforce the PostgreSQL FK, so the mismatch is made visible. |

Q6 is deliberately a **reference check**, not a claim that MongoDB enforces referential
integrity. It shows that the projection and the embedded MRN agree for the sampled
patient; `consistency-checks.js` runs the same idea across all 93,885 documents.

---

## 10. Comparison with the Relational Implementation

These are measurements from the same machine and the same seeded source. They are
**indicative, not a controlled benchmark**:

- PostgreSQL numbers are `psql` server timings from `evidence/05-compare-postgres.txt`.
- MongoDB numbers are client-observed `mongosh` timings from
  `evidence/07-benchmark.txt`; they include driver/BSON overhead.
- The first PostgreSQL execution after a restart includes buffer-cache warm-up. The warm
  numbers are the second and third runs.
- The MongoDB queries run against the document copy; the PostgreSQL queries use the
  Portfolio 2 indexes. Neither side was tuned specifically for this table beyond the
  indexes already justified.

| Operation | PostgreSQL (P1/P2) | MongoDB (P4) | Reading |
|---|---|---|---|
| One patient's laboratory history (Q1) | **2.07 ms** warm; 796 ms first run after restart; plan execution 1.01 ms, 58 buffers, 3 joins across 4 tables | **8 ms** median (6–10 ms), 7 keys / 7 docs | Both are fast. PostgreSQL wins warm, but needs a four-table join and a group/sort; MongoDB returns the report documents directly. |
| Work queue, top 10 (Q3) | **26–35 ms** warm; 912 ms first run; seq scan 93,885 rows, 1,336 buffers, top-N sort | **8 ms** median (6–12 ms), 10 keys / 10 docs | MongoDB's compound index serves the filter, sort and limit; PostgreSQL has no matching queue index, so it scans and sorts. |
| Analyte trend for one patient (Q4) | **2.78–2.91 ms** warm; 29.9 ms first run; 4 joins + analyte lookup, 59 buffers | **7 ms** median (6–8 ms), 5 keys / 5 docs | Both are sub-10 ms. PostgreSQL's nested-loop joins are very effective once warm. |
| Dashboard by test type (one `$facet` branch) | **95.6–98.6 ms** warm; one group-by branch | **3.24 s** median (2.68–3.75 s) for the full four-branch `$facet`; 3.53 s server explain | Not directly comparable: PostgreSQL computes one branch; MongoDB computes four. PostgreSQL is clearly better for set aggregation over narrow rows. |
| Write one reported order + 4 results | **122.9 ms** for the two inserts in a rolled-back transaction (98.5 ms order + 24.4 ms results); 5 rows, FK checks, multiple indexes | **16 ms** median (12–17 ms) for insert + cleanup delete of one 4-result document | The document is one atomic write; the relational transaction writes five rows with more index and constraint work. This is not a durability or concurrency benchmark. |
| Add a new analyte | The P1 catalogue is normalized: adding an analyte is an `INSERT` into `analyte`, not DDL. Adding a new *result metadata field* would be DDL. | Adding a new analyte or a new optional result field requires no migration; if it becomes required, the validator changes. | The document store does **not** automatically win here. It wins when the *shape* of a test's results varies, not merely when a new catalogue row is added. |

### 10.1 What this comparison actually says

At 93,885 orders and 163,387 results, warm PostgreSQL matches or beats MongoDB on the
patient history, analyte trend and dashboard reads. The document model's measured
advantages are the work queue (one compound index, 10 documents read, against a
sequential scan and top-N sort in PostgreSQL) and the write unit (one document instead
of an order plus four rows). It is not a general "NoSQL is faster" result, and the
portfolio should not claim one.

That is the correct conclusion for this case study: the document model is selected for
**shape, ownership and operational boundary**, not for raw single-node speed. If the
only requirement were the relational reports in Portfolio 2, PostgreSQL would remain the
better choice.

---

## 11. Suitability Conclusion and Boundary

**For this case study, the document model is the right choice for the laboratory report
slice, and the wrong choice as a replacement for the hospital database.**

The report is a bounded, self-contained object with a heterogeneous but small result
array. Embedding the analytes gives one atomic write and one read, preserves the units
and reference ranges used at report time, and removes the order→result join from the
clinical path. The validator enforces the shape at the database boundary, and the
reconciliation checks make the unavoidable cross-store gaps visible.

The boundary is:

- **PostgreSQL remains the system of record** for patient identity, encounters, staff,
  appointments, prescriptions, the laboratory order header and billing. It keeps the
  foreign keys, exclusion constraints and multi-row transactions that those entities
  need.
- **MongoDB stores the laboratory report projection**: one document per order with its
  results and snapshots. It is rebuilt from PostgreSQL by the batch ETL, and
  `patient_refs` is a derived identifier projection, not a second patient master.
- **The boundary would move the other way** if the requirement became a single
  relational reporting database with strict cross-entity transactions. In that case,
  keep the normalized tables or use `jsonb`; do not add a second store for its own sake.
- **The boundary would move further toward MongoDB** if report volume and result-shape
  variation grew, if reports were read far more often than the relational core, or if
  the laboratory reporting plane needed independent scaling. Even then, patient
  identity and orders would stay relational unless the whole transactional model moved.

### 11.1 Limitations and risks

1. **No cross-store foreign key.** A deleted or merged patient in PostgreSQL can leave a
   stale `patient_id` or `patient_mrn` in MongoDB until the next reconciliation. The
   consistency checks catch it; they do not prevent it. Production needs a monitored
   reconciliation job and a patient-merge procedure that updates the projection.
2. **Batch ETL lag.** Amendments, late results and corrections are not streamed. The
   current load is a full rebuild; production needs CDC/outbox and idempotent upserts.
3. **The validator is not the whole invariant.** `result_count = size(results)`,
   temporal ordering, analyte membership and duplicate analytes are checked by scripts,
   not by the database. A writer that bypasses the loader can still create a
   self-consistent but semantically invalid document unless the application applies the
   same rules.
4. **Q5 does not scale as a live dashboard.** A four-branch `$facet` over 75,061 wide
   documents costs seconds. A summary collection or a relational aggregate is the
   better answer for a hot dashboard.
5. **Operational overhead.** A second store means a second backup, restore, upgrade,
   monitoring and access-control surface. The portfolio demonstrates the model, not a
   production HA deployment.
6. **Sensitive data.** The seed is synthetic, but a real deployment would need
   encryption at rest and in transit, field-level access control, audit logging and
   retention rules. MongoDB's validators are not an access-control mechanism.

---

## 12. Reproduce

```powershell
# 1. Start PostgreSQL and MongoDB
docker compose up -d

# 2. Load P4 (exports from PostgreSQL, stages, transforms, validates)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/load-p4.ps1

# 3. Capture all evidence (00-07 plus sample-documents.json)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p4.ps1 `
  -Mongosh "C:\path\to\mongosh.exe"
```

`capture-p4.ps1` takes `-SkipLoad` when the collection is already loaded. The
`-Mongosh` parameter exists because the locally built fallback `mongo:7` image contains
the server but not the shell; the official image includes `mongosh`, so the default
`mongosh` works there. The loader has the same fallback logic.

The evidence files are the raw output of that run:

| File | Contents |
|---|---|
| `evidence/00-environment.txt` | Versions, container state, source counts |
| `evidence/01-load.txt` | Export, staging load, index drop/recreate, transform, idempotent counts |
| `evidence/02-validator.txt` | 11 accept/reject cases with server error codes |
| `evidence/03-consistency.txt` | 27 cross-document and cross-store checks |
| `evidence/04-queries.txt` | Q1–Q6 output and `explain("executionStats")` |
| `evidence/05-compare-postgres.txt` | PostgreSQL equivalents with `\timing` and plans |
| `evidence/06-collection-stats.txt` | BSON size, storage size, per-index sizes |
| `evidence/07-benchmark.txt` | Warm-up + five timed runs per MongoDB query/write |
| `sample-documents.json` | Four representative documents in Extended JSON |
