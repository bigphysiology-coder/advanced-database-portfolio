# Case Study: Organisation Statement

> Required by the brief (p.2): "Each student must state the selected organisation clearly
> at the beginning of the portfolio documentation." This file satisfies that requirement.

## 1. Organisation / Scenario

_<Name and one-paragraph description. State clearly whether this is a real organisation,
a simulated organisation, or a constructed business scenario.>_

## 2. Nature of the Business or System

_<What the system does, who it serves, and why it needs a database.>_

## 3. Users of the Database

| User role | What they read | What they write |
|---|---|---|
| | | |
| | | |
| | | |

## 4. Major Data Stored

_<Entities and the business meaning of each. Group them: core entities, transactional
entities, reference data, audit data.>_

## 5. Key Operations the Database Must Support

1.
2.
3.
4.
5.

## 6. Scale and Workload Assumptions

These assumptions justify the design decisions and optimisation work that follow.

| Dimension | Assumption | Why it matters |
|---|---|---|
| Patients | | |
| Appointments per day | | |
| Concurrent users | | |
| Read/write ratio | | Drives indexing strategy (P2) |
| Growth rate | | Drives partitioning / sharding argument (P5) |
| Retention requirement | | Drives archival and compliance design |

## 7. Why This Case Study

_<Why this organisation suits all five portfolios. Be specific: where does the relational
model fit, where does a document model fit, where does contention occur, and what makes
distribution a real problem rather than a textbook exercise?>_

## 8. Scope Boundaries

_<What is explicitly out of scope, e.g. billing, insurance claims, payroll. Naming
boundaries is a design decision and shows judgement.>_
