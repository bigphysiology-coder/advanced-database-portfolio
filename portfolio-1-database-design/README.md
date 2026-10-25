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
| `schema.sql` | DDL — tables, types, keys, constraints, indexes |
| `seed-data.sql` | Realistic sample data. Everything downstream depends on this. |
| `er-diagram.md` | Mermaid ER diagram (renders on GitHub) |
| `er-diagram.png` | Exported image for the LMS document |
| `normalisation.md` | Step-by-step normalisation justification |

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
