# Portfolio 4 — NoSQL and Advanced Data Models

**Marks:** 7 / 40

## Required Evidence

- [ ] A NoSQL model for **the same case study**
- [ ] A document / key-value / column / graph example
- [ ] Implementation evidence
- [ ] Explanation of suitability

## The Trap

The easiest way to lose marks here is to model something unrelated. The brief says
"based on the same case study" — so the lab data must be the *same* lab data that
Portfolio 1 stores relationally. The interesting question is then not "what does a
document look like" but **"why does this subset belong in a document store rather than
in PostgreSQL?"** Answer that and P4 is straightforward.

## Files

| File | Purpose |
|---|---|
| `mongodb-setup.js` | Collection creation, JSON Schema validator, indexes, queries |
| `model-design.md` | The modelling argument, including what stayed relational and why |
| `sample-documents.json` | Representative documents from the running database |
| `evidence/` | Screenshots of `mongosh` output |

## Candidate Model: Lab Results

A lab result is a natural document, and the reason is structural rather than fashion:

| Property | Why it fits a document model |
|---|---|
| Heterogeneous shape | A lipid panel, a blood culture and a PCR test share almost no fields |
| Self-contained | A result is read as a whole; it is rarely joined across results |
| Append-only | Results are written once, corrected by superseding, never patched in place |
| Nested by nature | One order → many analytes, each with value, unit, reference range, flag |

In a relational schema that heterogeneity becomes either a wide sparse table (many
`NULL`s), an EAV table (correct, but painful to query), or a `jsonb` column. It is worth
naming all three and explaining which you rejected and why — that is exactly the
"advanced data model" reasoning the rubric rewards.

## Implementation Checklist

- [ ] Collection created with a `$jsonSchema` validator (`validationLevel`, `validationAction`)
- [ ] Indexes designed against the actual query patterns, not guessed
- [ ] Insert via `mongosh`, proving the validator accepts valid and rejects invalid documents
- [ ] At least one aggregation pipeline with `$lookup` or `$facet`
- [ ] A read that demonstrates the access pattern the model was designed for
- [ ] Explanation of embedding vs referencing for each relationship

## Model Comparison to Write

| Concern | PostgreSQL (P1) | MongoDB (P4) | Which was chosen, and why |
|---|---|---|---|
| Result heterogeneity | | | |
| Read pattern | | | |
| Write pattern | | | |
| Referential integrity | | | |
| Schema evolution | | | |
| Reporting / joins | | | |

## Polyglot Persistence Statement

State the boundary explicitly. Something like:

> Patient demographics, appointments, prescriptions and billing remain in PostgreSQL
> because they are highly relational and require multi-row transactional integrity.
> Laboratory results are stored in MongoDB because their structure varies by test type,
> they are read as self-contained documents, and they are append-only.

Then justify the boundary: what breaks if you move it the other way?

## If You Choose a Different Model Type

The brief allows document, key-value, column or graph. This case study also supports:

- **Graph** — patient–doctor–department referral networks, or diagnosis co-occurrence,
  for clinical decision support. A real fit if you want to argue for one.
- **Key-value** — session tokens, or a cache of the last-viewed patient summary.
  Weaker, because it is peripheral rather than core to the domain.
- **Column-family** — the audit log, which is append-heavy and time-ordered.
  Defensible, but Cassandra setup cost is high for 7 marks.

Whatever you pick, the marks come from the **suitability argument**, not the tool.
