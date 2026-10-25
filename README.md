# Advanced Database Systems Portfolio

**Course:** MIT 8103 Advanced Database Systems
**Assessment:** First Semester Continuous Assessment (40 marks)
**Session:** 2026/2027 — September Cohort
**Student:** _<your name / student number>_

---

## Case Study

**Organisation / scenario:** Riverbend Teaching Hospital — a simulated 500-bed tertiary
teaching hospital operating outpatient, inpatient and laboratory services.

**Nature of the system:** A clinical records system supporting patient registration,
appointment scheduling, clinical encounters, prescriptions, admissions and laboratory
results.

**Users of the database:**

| User | Interaction |
|---|---|
| Receptionist | Registers patients, books/reschedules appointments |
| Triage nurse | Records vitals, updates appointment status |
| Doctor | Records encounters, diagnoses, prescriptions, lab orders |
| Lab technician | Records lab results against ordered tests |
| Pharmacist | Dispenses against active prescriptions |
| Ward clerk | Manages admissions, transfers and discharges |
| Records officer | Corrects records, handles merges |
| Administrator | Manages reference data |
| Auditor | Read-only access to the append-only audit log |

**Major data stored:** patients, next of kin, staff, doctors, departments, wards, beds,
appointments, encounters, admissions, vitals, diagnoses, prescriptions, laboratory tests
and results, and an append-only audit log.

**Key operations the database must support:**

1. Register a patient and issue a medical record number.
2. Book an appointment without double-booking a doctor, even under concurrent access.
3. Record an encounter — vitals, diagnosis and prescriptions — as one atomic unit.
4. Order a laboratory test and attach results with reference ranges and flags.
5. Retrieve a patient's full clinical history across all care settings.
6. Admit, transfer and discharge an inpatient.
7. Produce operational reports — doctor workload, lab turnaround, ward occupancy.
8. Audit all access to and changes of clinical records.

> Full description and design justification: [`docs/case-study.md`](docs/case-study.md)

---

## Portfolio Index

| # | Component | Marks | Directory | Status |
|---|---|---|---|---|
| 1 | Database Design and Modelling | 7 | [`portfolio-1-database-design/`](portfolio-1-database-design/) | complete |
| 2 | Query Processing and Optimisation | 7 | [`portfolio-2-query-optimisation/`](portfolio-2-query-optimisation/) | _pending_ |
| 3 | Transactions and Concurrency | 7 | [`portfolio-3-transactions-concurrency/`](portfolio-3-transactions-concurrency/) | _pending_ |
| 4 | NoSQL and Advanced Data Models | 7 | [`portfolio-4-nosql/`](portfolio-4-nosql/) | _pending_ |
| 5 | Distributed and Cloud Database | 6 | [`portfolio-5-distributed-cloud/`](portfolio-5-distributed-cloud/) | _pending_ |
| — | Final Documentation and Reflection | 6 | [`final-documentation/`](final-documentation/) | _pending_ |

---

## Repository Structure

```
advanced-database-portfolio/
├── README.md                  <- you are here
├── docker-compose.yml         <- reproducible PostgreSQL + MongoDB environment
├── docs/
│   ├── case-study.md          <- organisation statement (required by brief, p.2)
│   ├── ai-use-declaration.md  <- AI tool disclosure (required, p.7)
│   └── screenshots/
├── portfolio-1-database-design/
│   ├── schema.sql                     <- DDL: 21 relations, keys, constraints, triggers
│   ├── seed-data.sql                  <- deterministic sample data (drives P2, P3, P4)
│   ├── er-diagram.md                  <- Mermaid source, renders on GitHub
│   ├── er-diagram.png                 <- exported image for the LMS document
│   ├── normalisation.md               <- 1NF -> 3NF justification + design decisions
│   ├── constraint-tests.sql           <- 10 statements that must all fail
│   └── constraint-tests-output.txt    <- captured proof they do
├── portfolio-2-query-optimisation/
│   ├── queries.sql            <- the business queries
│   ├── indexes.sql            <- indexes added to improve them
│   ├── execution-plans.md     <- EXPLAIN ANALYZE before/after + timings
│   └── results/
├── portfolio-3-transactions-concurrency/
│   ├── transactions.sql       <- COMMIT / ROLLBACK examples
│   ├── session-a.sql          <- concurrent session 1
│   ├── session-b.sql          <- concurrent session 2
│   └── isolation-tests.md     <- anomaly demonstrated + fix
├── portfolio-4-nosql/
│   ├── mongodb-setup.js       <- collection, validator, indexes, queries
│   ├── model-design.md        <- suitability argument
│   └── sample-documents.json
├── portfolio-5-distributed-cloud/
│   ├── architecture.md        <- replication / sharding / consistency reasoning
│   ├── replication-setup.sh   <- deployment evidence
│   └── config/
└── final-documentation/
    ├── portfolio-summary.md   <- the 2-3 page LMS submission
    └── reflection.md          <- individual technical reflection
```

---

## Running the Environment

Requires Docker Desktop.

```bash
docker compose up -d
```

| Service | Port | Credentials |
|---|---|---|
| PostgreSQL 16 | 5432 | `portfolio` / `portfolio` |
| MongoDB 7 | 27017 | `portfolio` / `portfolio` |

On first boot PostgreSQL executes `schema.sql` then `seed-data.sql` automatically.
To rebuild from scratch after changing either file:

```bash
docker compose down -v && docker compose up -d
```

Connect with `psql -h localhost -U portfolio -d hospital` or `mongosh`.

---

## Evidence Standard

Every claim in this repository must be backed by output that was actually produced:

- Query timings: raw `EXPLAIN (ANALYZE, BUFFERS)` output, not a paraphrased summary.
- Concurrency: two live sessions with visible interleaving, not a theoretical description.
- Screenshots: committed under the relevant portfolio folder, with the command visible.
- No screenshot appears in the documentation unless the command that produced it is in the repo.

---

## AI Use Declaration

See [`docs/ai-use-declaration.md`](docs/ai-use-declaration.md). This file is updated as
the portfolio develops, not reconstructed at the end.

---

## Development Log

Work is committed progressively rather than in a single final upload.

| Date | Portfolio | What was done |
|---|---|---|
| | | |
