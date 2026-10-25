# Portfolio 1 — Database Design and Modelling

**Marks:** 7 / 40

## Required Evidence

- [ ] Case study description (see [`../docs/case-study.md`](../docs/case-study.md))
- [ ] ER diagram (source + exported image)
- [ ] Relational schema
- [ ] Keys: primary, foreign, candidate, alternate, composite
- [ ] Constraints: NOT NULL, UNIQUE, CHECK, FOREIGN KEY, defaults
- [ ] Normalisation explanation (1NF → 2NF → 3NF)

## Files

| File | Purpose |
|---|---|
| `schema.sql` | DDL — 21 relations, types, keys, constraints, indexes |
| `seed-data.sql` | Deterministic sample data. Everything downstream depends on this. |
| `er-diagram.md` | Mermaid ER diagram (renders on GitHub) |
| `er-diagram.png` | Exported image for the LMS document — _not yet produced_ |
| `normalisation.md` | Step-by-step normalisation justification and design decisions |
| `constraint-tests.sql` | Ten statements that must all fail, proving the constraints work |
| `constraint-tests-output.txt` | Raw output from the run above |

## Status

- [x] Case study description
- [x] Relational schema (21 relations)
- [x] Keys: primary, foreign, candidate, alternate, composite
- [x] Constraints: NOT NULL, UNIQUE, CHECK, FOREIGN KEY, EXCLUDE, triggers
- [x] Normalisation explanation (1NF → 3NF) with justified denormalisation
- [x] Seed data at a volume that makes query plans meaningful
- [x] Constraint verification with captured output
- [ ] ER diagram exported to PNG

## Verified Row Counts

```
patient 500 · staff 60 · doctor_profile 50 · appointment 5,700
encounter 4,470 · prescription 8,940 · vitals 4,470
diagnosis ~6,650 · lab_order ~6,650 · lab_result ~11,800 · audit_log ~15,000
```

Reference tables, appointments, encounters and prescriptions give identical counts on
every run. The four hash-selected tables vary by a few per cent, because primary keys are
random UUIDs and row selection hashes them.

Reproduce from scratch:

```bash
docker compose down -v && docker compose up -d
```

## Design Decisions to Record

The assessor is looking for judgement, not just correct syntax. As the schema is built,
record *why* each significant choice was made:

- Natural vs surrogate keys — which did you choose, and why?
- Which relationships are optional vs mandatory, and what business rule does that encode?
- Where was denormalisation considered and rejected (or accepted, with justification)?
- Which constraints belong in the database rather than the application layer?
- How is auditability handled — status columns, history tables, or triggers?

Put the answers in `normalisation.md` §5 or a `design-decisions.md` alongside it.

## Order of Work

1. Write `schema.sql` from the ER model.
2. Generate `seed-data.sql` — enough rows to make plans and indexes meaningful
   (target: hundreds of patients, thousands of appointments, tens of thousands of
   lab results; a 20-row table will not produce a measurable query plan).
3. Run `docker compose up -d` and confirm both scripts execute cleanly.
4. Verify constraints by attempting invalid inserts and capturing the errors.
5. Export the ER diagram.
