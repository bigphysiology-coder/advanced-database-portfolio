# ER Diagram

Source of truth for the entity-relationship model. Written in Mermaid so it renders
directly on GitHub and changes are reviewable as diffs. The model matches
[`schema.sql`](schema.sql) exactly — if they diverge, this file is wrong.

A rendered PNG is committed as [`er-diagram.png`](er-diagram.png) for the LMS document.

## Diagram

```mermaid
erDiagram
    DEPARTMENT ||--o{ STAFF : "employs"
    DEPARTMENT ||--o{ WARD : "owns"
    DEPARTMENT ||--o{ TEST_CATALOGUE : "runs"
    STAFF ||--o| DOCTOR_PROFILE : "has clinical privileges"

    WARD ||--o{ BED : "contains"

    PATIENT ||--o{ NEXT_OF_KIN : "has"
    PATIENT ||--o{ APPOINTMENT : "books"
    PATIENT ||--o{ ENCOUNTER : "attends"
    PATIENT ||--o{ ADMISSION : "is admitted"

    DOCTOR_PROFILE ||--o{ DOCTOR_SCHEDULE : "publishes"
    DOCTOR_PROFILE ||--o{ APPOINTMENT : "sees"
    DOCTOR_PROFILE ||--o{ ENCOUNTER : "conducts"
    DOCTOR_PROFILE ||--o{ PRESCRIPTION : "writes"
    DOCTOR_PROFILE ||--o{ LAB_ORDER : "orders"
    DOCTOR_PROFILE ||--o{ ADMISSION : "admits"

    STAFF ||--o{ APPOINTMENT : "books on behalf of"
    STAFF ||--o{ VITALS : "records"
    STAFF ||--o{ LAB_RESULT : "verifies"
    STAFF ||--o{ AUDIT_LOG : "acts"

    APPOINTMENT |o--o| ENCOUNTER : "results in"
    ENCOUNTER ||--o{ VITALS : "records"
    ENCOUNTER ||--o{ DIAGNOSIS : "yields"
    ENCOUNTER ||--o{ PRESCRIPTION : "issues"
    ENCOUNTER ||--o{ LAB_ORDER : "requests"
    ENCOUNTER |o--o| ADMISSION : "leads to"

    WARD ||--o{ ADMISSION : "accommodates"
    BED  ||--o{ ADMISSION : "occupies"

    ICD_CODE ||--o{ DIAGNOSIS : "classifies"
    MEDICATION ||--o{ PRESCRIPTION : "prescribed as"

    TEST_CATALOGUE ||--o{ ANALYTE : "measures"
    TEST_CATALOGUE ||--o{ LAB_ORDER : "is requested as"
    LAB_ORDER ||--o{ LAB_RESULT : "produces"
    ANALYTE ||--o{ LAB_RESULT : "is reported as"

    DEPARTMENT {
        smallint department_id PK
        varchar  code UK
        varchar  name UK
        smallint floor
    }

    STAFF {
        uuid     staff_id PK
        varchar  employee_no UK
        varchar  first_name
        varchar  last_name
        enum     role
        smallint department_id FK
    }

    DOCTOR_PROFILE {
        uuid    staff_id PK
        varchar specialty
        varchar license_no UK
        date    license_expires_on
    }

    PATIENT {
        uuid    patient_id PK
        varchar mrn UK
        varchar first_name
        varchar last_name
        date    date_of_birth
        enum    sex
        varchar blood_group
        text    full_name "generated"
    }

    NEXT_OF_KIN {
        uuid    next_of_kin_id PK
        uuid    patient_id FK
        varchar full_name
        varchar relationship
        boolean is_primary
    }

    WARD {
        smallint ward_id PK
        varchar  code UK
        varchar  name UK
        varchar  ward_type
        smallint capacity
    }

    BED {
        uuid     bed_id PK
        smallint ward_id FK
        varchar  bed_number
        varchar  bed_type
    }

    DOCTOR_SCHEDULE {
        uuid     schedule_id PK
        uuid     doctor_id FK
        smallint day_of_week
        time     start_time
        time     end_time
        smallint slot_minutes
    }

    APPOINTMENT {
        uuid        appointment_id PK
        uuid        patient_id FK
        uuid        doctor_id FK
        timestamptz slot_start
        timestamptz slot_end
        enum        status
        uuid        booked_by FK
    }

    ENCOUNTER {
        uuid        encounter_id PK
        uuid        patient_id FK
        uuid        doctor_id FK
        uuid        appointment_id FK,UK
        enum        encounter_type
        timestamptz started_at
        timestamptz ended_at
    }

    ADMISSION {
        uuid        admission_id PK
        uuid        patient_id FK
        uuid        encounter_id FK,UK
        smallint    ward_id FK
        uuid        bed_id FK
        timestamptz admitted_at
        timestamptz discharged_at
    }

    VITALS {
        uuid        vitals_id PK
        uuid        encounter_id FK
        timestamptz recorded_at
        numeric     temperature_c
        smallint    systolic_mmhg
        smallint    diastolic_mmhg
        smallint    spo2_pct
    }

    ICD_CODE {
        varchar icd_code PK
        varchar description
        varchar chapter
    }

    DIAGNOSIS {
        uuid    diagnosis_id PK
        uuid    encounter_id FK
        varchar icd_code FK
        enum    diagnosis_type
        varchar note
    }

    MEDICATION {
        uuid    medication_id PK
        varchar name
        varchar form
        varchar strength
        varchar atc_code UK
    }

    PRESCRIPTION {
        uuid     prescription_id PK
        uuid     encounter_id FK
        uuid     medication_id FK
        varchar  dose
        varchar  frequency
        smallint duration_days
        uuid     prescribed_by FK
    }

    TEST_CATALOGUE {
        varchar  test_code PK
        varchar  test_name UK
        varchar  specimen_type
        smallint turnaround_hours
    }

    ANALYTE {
        smallint analyte_id PK
        varchar  test_code FK
        varchar  analyte_name
        varchar  unit
        numeric  ref_low
        numeric  ref_high
    }

    LAB_ORDER {
        uuid        lab_order_id PK
        uuid        encounter_id FK
        varchar     test_code FK
        enum        priority
        enum        status
        uuid        ordered_by FK
        timestamptz ordered_at
        timestamptz reported_at
    }

    LAB_RESULT {
        uuid     lab_result_id PK
        uuid     lab_order_id FK
        smallint analyte_id FK
        numeric  value_numeric
        varchar  value_text
        enum     flag
    }

    AUDIT_LOG {
        bigint      audit_id PK
        timestamptz occurred_at
        varchar     action
        varchar     table_name
        text        record_id
        jsonb       old_values
        jsonb       new_values
    }
```

## Reading the Notation

Crow's foot notation, ISO cardinalities:

| Symbol | Meaning |
|---|---|
| `\|\|` | exactly one (mandatory) |
| `\|o` | zero or one (optional) |
| `}o` | zero or many |
| `}\|` | one or many |

So `PATIENT ||--o{ APPOINTMENT` reads: a patient has zero or many appointments, and
every appointment belongs to exactly one patient.

## Three Relationships Worth Pointing At

**`APPOINTMENT |o--o| ENCOUNTER`** — optional on both sides, because a cancelled or
no-show appointment produces no encounter, and a walk-in encounter has no appointment.
An inner join between these two tables silently loses rows; that is a deliberate
modelling choice, not an oversight.

**`DOCTOR_PROFILE` as a 1:1 extension of `STAFF`** — employment attributes and clinical
privileges have different lifetimes and different access rules. Splitting them means a
nurse cannot accidentally acquire a licence number, and clinical attributes can be
audited separately from HR records.

**`ANALYTE` between `TEST_CATALOGUE` and `LAB_RESULT`** — a test is a panel of analytes.
This is what allows one result table to serve a one-analyte test and a four-analyte
panel without a sparse wide table. It is also the structure Portfolio 4 replaces with
an embedded array, which is the comparison that portfolio is built on.

## Generating the PNG

The committed image is produced reproducibly by `scripts/export-diagram.ps1`. It extracts
the Mermaid block above and renders it with Mermaid CLI v12, using the Chrome already
installed on the machine so no Chromium download is required.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export-diagram.ps1
```

Equivalent once the block is saved as a `.mmd` file:

```bash
npx @mermaid-js/mermaid-cli@12 -i er-diagram.mmd -o er-diagram.png --size 2400 -b white
```

Note that Mermaid CLI v12 renamed the width flag: it is `--size`, not the `-w` used in most
tutorials.

## Tools Acknowledged

| Tool | Version | Used for |
|---|---|---|
| Mermaid CLI | 12.0.0 | Rendering the diagram source to PNG |
| Google Chrome | headless | Rendering engine used by Mermaid CLI |
| PostgreSQL | 16 | Verifying the schema the diagram describes |

The diagram is authored by hand from `schema.sql`. If the two diverge, `schema.sql` wins.
