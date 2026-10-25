# Normalisation Analysis

The brief asks for a **normalisation explanation**, not a demonstration of 3NF by
assertion. Each stage must show what the relation looked like *before* and what changed.

## 1. Starting Point — Unnormalised Data

_<Show the raw form the design began from. A realistic source is a spreadsheet export or
a report the hospital already produces. Present it as a table with representative rows.>_

| appointment_id | patient_name | patient_phone | doctor | department | diagnoses | medications |
|---|---|---|---|---|---|---|
| | | | | | | |

Problems immediately visible:

- Repeating groups (multiple diagnoses / medications in one cell) — violates **1NF**
- Patient details repeated on every appointment row — redundancy
- Doctor and department names embedded rather than referenced

## 2. First Normal Form (1NF)

**Requirement:** atomic values, no repeating groups, each row uniquely identifiable.

**Changes made:**

- Split multi-valued `diagnoses` and `medications` into child tables.
- Established a primary key on every relation.

**Resulting relations:**

_<list them>_

## 3. Second Normal Form (2NF)

**Requirement:** 1NF **and** no partial dependency on part of a composite key.

**Partial dependencies found:**

| Relation | Composite key | Attribute | Depends on |
|---|---|---|---|
| | | | part of key only |

**Changes made:**

_<describe the decomposition>_

## 4. Third Normal Form (3NF)

**Requirement:** 2NF **and** no transitive dependency (non-key attribute depending on
another non-key attribute).

**Transitive dependencies found:**

| Relation | Non-key attribute | Depends on | Which depends on the key |
|---|---|---|---|
| | | | |

**Changes made:**

_<describe the decomposition>_

## 5. Deliberate Denormalisation

Not every departure from 3NF is a mistake — an unjustified one is. Document each:

| Where | What was denormalised | Justification | Cost accepted |
|---|---|---|---|
| | | | |

Typical candidates in this case study:

- A stored `total_cost` on an encounter, to avoid summing line items on every read.
- A denormalised `current_status` on appointments, to avoid reconstructing state from
  the audit log during scheduling checks.

## 6. Verification

State how normalisation was verified rather than assumed:

- Functional dependency list, derived from the business rules.
- Candidate key analysis for each relation.
- Confirmation that every non-key attribute depends on "the key, the whole key, and
  nothing but the key".

## 7. Design Decisions

Answers to the questions raised in `README.md`:

- **Natural vs surrogate keys:** _<which, where, why>_
- **Optional vs mandatory relationships:** _<what business rule each encodes>_
- **Constraints in the database vs the application:** _<and why>_
- **Auditability approach:** _<status columns / history table / triggers>_
