# NoSQL Model Design

## 1. What Was Modelled, and What Was Not

**Modelled in MongoDB:** _<e.g. laboratory results>_

**Remained in PostgreSQL:** patients, staff, appointments, encounters, prescriptions.

The important question is not whether MongoDB *can* store the other entities — it can.
The question is what the system loses if it does.

## 2. Why This Subset Fits a Document Model

| Characteristic | Evidence from the case study |
|---|---|
| Heterogeneous structure | |
| Read as a self-contained unit | |
| Append-only / immutable history | |
| Nested data | |
| High write volume, low join need | |

## 3. Why Not the Obvious Alternative

For each rejected option, say what it would have cost:

| Option | Rejected because |
|---|---|
| Wide table with many `NULL`s | |
| EAV (entity-attribute-value) table | |
| Raw `jsonb` column in PostgreSQL | |

That third one deserves care — `jsonb` is genuinely a reasonable answer. If you reject
it, have a specific reason (document size limits, cross-document aggregation, separate
scaling, operational separation). "Because it's NoSQL" is not a reason.

## 4. Embedding vs Referencing

| Relationship | Decision | Justification |
|---|---|---|
| Order → result analytes | embed | |
| Result → patient | reference | |
| Result → ordering doctor | reference | |

State the rule you applied: embed when the child is owned by the parent, bounded in
size, and always read with it; reference when it is shared, unbounded, or accessed
independently.

## 5. Document Schema

```json
{
  "order_id": "LAB-000001",
  "patient_id": "PAT-00042",
  "test_code": "LIPID",
  "collected_at": "2026-03-14T08:15:00Z",
  "status": "REPORTED",
  "results": [ { "analyte": "...", "value": 5.8, "unit": "mmol/L", "flag": "HIGH" } ]
}
```

Field-by-field rationale, including why `patient_id` is a string rather than an
`ObjectId` (it references a PostgreSQL row — cross-store references are a real design
concern worth naming).

## 6. Validation Strategy

What the `$jsonSchema` validator enforces, and what it deliberately does not.

Be honest about the gap: MongoDB cannot enforce the foreign key to `patient`. Explain
how that is handled instead — application-level check, periodic reconciliation job, or
accepted risk — and what the consequence of a violation is.

## 7. Index Design

| Index | Query it serves | Access pattern | Why this prefix order |
|---|---|---|---|
| | | | |

Include `explain("executionStats")` output for at least one query, showing
`totalDocsExamined` close to `nReturned` — the same before/after discipline as P2.

## 8. Suitability Conclusion

One paragraph answering directly: **for this case study, is the document model the right
choice, and for which part?** A well-argued "partly, and here is the boundary" scores
better than an unqualified endorsement.

## 9. Comparison with the Relational Implementation

Pull the actual numbers from Portfolio 2 where you can:

| Operation | PostgreSQL | MongoDB | Comment |
|---|---|---|---|
| Read one patient's results | | | |
| Insert one result | | | |
| Aggregate by test type | | | |
| Schema change (new analyte) | | | |

The last row is where document stores genuinely win — a new analyte type requires no
migration. If your design captures that, say so with evidence.
