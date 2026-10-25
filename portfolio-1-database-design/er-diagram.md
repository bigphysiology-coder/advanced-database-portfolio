# ER Diagram

Source of truth for the entity-relationship model. Written in Mermaid so it renders
directly on GitHub and changes are reviewable as diffs.

Export to `er-diagram.png` for the LMS document.

## Diagram

```mermaid
erDiagram
    PATIENT ||--o{ APPOINTMENT : "books"
    PATIENT ||--o{ ENCOUNTER : "attends"
    PATIENT ||--o{ NEXT_OF_KIN : "has"
    PATIENT }o--o| NEXT_OF_KIN : "primary contact"

    DEPARTMENT ||--o{ DOCTOR : "employs"
    DOCTOR ||--o{ APPOINTMENT : "attends"
    DOCTOR ||--o{ ENCOUNTER : "conducts"

    APPOINTMENT |o--o| ENCOUNTER : "results in"
    ENCOUNTER ||--o{ DIAGNOSIS : "records"
    ENCOUNTER ||--o{ PRESCRIPTION : "issues"
    ENCOUNTER ||--o{ LAB_ORDER : "orders"

    MEDICATION ||--o{ PRESCRIPTION : "prescribed as"
    DIAGNOSIS_CODE ||--o{ DIAGNOSIS : "classifies"

    LAB_ORDER ||--o{ LAB_RESULT : "produces"
    TEST_CATALOGUE ||--o{ LAB_ORDER : "defines"

    PATIENT {
        uuid   patient_id PK
        string medical_record_no UK
        string first_name
        string last_name
        date   date_of_birth
        string sex
        string phone
        timestamp created_at
    }

    NEXT_OF_KIN {
        uuid   next_of_kin_id PK
        uuid   patient_id FK
        string full_name
        string relationship
        string phone
    }
```

> The block above is a **starting skeleton** — replace it as the model develops.
> Mermaid does not support composite attributes cleanly, so keep the diagram at entity
> and relationship level and put attribute detail in `schema.sql`.

## Rendering the PNG

Any of these work:

- **dbdiagram.io** — paste equivalent DBML, export PNG. Free tier prints a watermark.
- **Mermaid Live Editor** (mermaid.live) — paste the block, export PNG/SVG.
- **DBeaver / DataGrip** — reverse-engineer the live schema from the database and
  export. Best option, because the diagram is then guaranteed to match `schema.sql`.

Record which tool was used in `normalisation.md`, since the brief requires external
tools to be acknowledged.

## Notation

State the notation used (crow's foot / Chen) and what the cardinalities mean, e.g.
`||--o{` is one-to-many with mandatory-one on the left and zero-or-many on the right.
