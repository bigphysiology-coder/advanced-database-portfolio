# Portfolio 1 — Database Design and Modelling

**Marks:** 7 / 40

## Required Evidence

- [x] Case study description (see [`../docs/case-study.md`](../docs/case-study.md))
- [x] ER diagram (source + exported image)
- [x] Relational schema
- [x] Keys: primary, foreign, candidate, alternate, composite
- [x] Constraints: NOT NULL, UNIQUE, CHECK, FOREIGN KEY, defaults
- [x] Normalisation explanation (1NF → 2NF → 3NF)

## Files

| File | Purpose |
|---|---|
| `schema.sql` | DDL — 21 relations, types, keys, constraints, indexes |
| `seed-data.sql` | Synthetic sample data at a volume that makes query plans meaningful. Everything downstream depends on this. |
| `er-diagram.md` | Mermaid ER diagram (renders on GitHub) |
| `er-diagram.png` | Exported image for the LMS document (2400 px, generated from the source above) |
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
- [x] ER diagram exported to PNG

## Reproducing the Diagram

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export-diagram.ps1
```

Uses the Chrome already installed on the machine; Mermaid CLI does not download Chromium.

## Verified Row Counts

```
patient 20,000 · staff 86 · doctor_profile 50 · appointment 82,000
encounter 62,588 · prescription 125,176 · vitals 62,588
diagnosis ~93,850 · lab_order ~93,850 · lab_result ~164,000 · audit_log ~227,000
```

Reference tables, appointments, encounters and prescriptions give identical counts on
every run. The hash-selected tables (`next_of_kin`, `diagnosis`, `lab_order`,
`lab_result`, `admission`) vary by a few per cent, because primary keys are random UUIDs
and row selection hashes them.

This is a **working sample**, not a full replica of the case-study hospital's ten-year
history. The case study describes 250,000 patients; the seed loads 20,000, which is
enough for the planner to choose between a sequential scan and an index. Loading the
full figure would add several minutes to every rebuild without changing any plan
conclusion. The per-day rates and distributions (700 appointments/day, 10% urgent lab
orders, weighted ICD-10 frequencies) follow the case study; the row count is scaled to
the Docker environment.

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
   (20,000 patients, 82,000 appointments, 164,000 lab results; a 20-row table will not
   produce a measurable query plan).
3. Run `docker compose up -d` and confirm both scripts execute cleanly.
4. Verify constraints by attempting invalid inserts and capturing the errors.
5. Export the ER diagram.
