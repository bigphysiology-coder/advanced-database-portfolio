# Case Study: Organisation Statement

> Required by the brief (p.2): "Each student must state the selected organisation clearly
> at the beginning of the portfolio documentation." This file satisfies that requirement.

## 1. Organisation / Scenario

**Riverbend Teaching Hospital** — a simulated 500-bed tertiary teaching hospital.
The scenario is constructed rather than drawn from a real institution, but the data
volumes and workflows are modelled on published figures for hospitals of this size.

The hospital operates three connected care settings that this database must serve:

- **Outpatient department (OPD)** — scheduled consultations, the highest-volume setting.
- **Inpatient wards** — admissions, daily clinical review, discharge.
- **Laboratory** — pathology and haematology testing ordered from both settings.

The database under design is the **Clinical Records System**: the system of record for
who was seen, by whom, for what, and with what result.

## 2. Nature of the Business or System

A hospital is a data-intensive, safety-critical organisation. Three properties shape every
design decision that follows:

1. **Records outlive the people who create them.** A patient's history must remain
   readable and legally defensible for years after the treating clinician has left.
2. **Writes are consequential.** A lost appointment is an inconvenience; a lost
   prescription or a misattributed lab result is a clinical safety event. This raises
   the bar for transactional integrity well above a typical business application.
3. **Reads vastly outnumber writes, and they are shaped differently.** Clinicians read
   one patient's complete history; managers read aggregates across thousands of patients.
   These two workloads want different physical designs.

## 3. Users of the Database

| User role | What they read | What they write |
|---|---|---|
| Receptionist | Patient register, doctor schedules, appointment slots | Registrations, appointments, reschedules |
| Triage nurse | Today's appointment list, patient vitals history | Vitals, triage notes, appointment status |
| Doctor | Full patient history, prior results, current medications | Encounters, diagnoses, prescriptions, lab orders |
| Laboratory technician | Work queue of pending orders | Results, result status, amendments |
| Pharmacist | Active prescriptions | Dispensing records, interaction notes |
| Ward clerk | Bed occupancy, admission list | Admissions, transfers, discharges |
| Records officer | Complete record for a patient, audit trail | Corrections (with audit), merges |
| Hospital administrator | Department workload, turnaround, utilisation | Reference data only |
| Auditor | Append-only audit log, access history | Nothing — read-only by design |

Nine roles with materially different access needs means role separation is a real design
concern, not a footnote. It directly informs the concurrency and access work in P3.

## 4. Major Data Stored

| Group | Entities | Notes |
|---|---|---|
| **Identity** | `patient`, `next_of_kin`, `staff`, `department` | Patient identity is durable and must survive name changes |
| **Scheduling** | `appointment`, `doctor_schedule`, `room` | Contention point: one doctor, one time slot |
| **Clinical** | `encounter`, `vitals`, `diagnosis`, `prescription` | The transactional core; written together or not at all |
| **Laboratory** | `lab_order`, `lab_result`, `test_catalogue`, `analyte` | Heterogeneous by test type — see P4 |
| **Reference** | `icd_code`, `medication`, `test_catalogue`, `analyte` | Slow-changing; versioned |
| **Audit** | `audit_log`, `record_access_log` | Append-only; never updated, never deleted |

The laboratory group is the deliberate outlier: a lipid panel, a full blood count and a
PCR test share almost no attributes. That structural heterogeneity is why the same data
is modelled twice — relationally in P1, as documents in P4.

## 5. Key Operations the Database Must Support

1. **Register a patient** and issue a unique medical record number (MRN).
2. **Book an appointment** for a doctor and time slot, preventing double-booking even
   when two receptionists act simultaneously.
3. **Record an encounter** — vitals, diagnosis and prescriptions — as one atomic unit.
4. **Order a laboratory test** and later attach results with reference ranges and flags.
5. **Retrieve a patient's complete chronological history** across all care settings.
6. **Admit, transfer and discharge** an inpatient, tracking ward and bed.
7. **Produce operational reports** — doctor workload, lab turnaround, ward occupancy.
8. **Audit access** to any patient record, for compliance review.

Operations 2 and 3 are the concurrency hotspots. Operations 5 and 7 are the read
workload that dominates the system.

## 6. Scale and Workload Assumptions

These numbers drive the indexing strategy in P2, the contention scenarios in P3, and the
distribution argument in P5. They are stated here so that every later claim can be traced
back to an assumption.

| Dimension | Assumption | Basis |
|---|---|---|
| Registered patients | 250,000 | 500-bed tertiary hospital, ~10 years of operation |
| New registrations | ~120 / day | |
| Outpatient consultations | ~700 / day | ~1.4 per bed per day |
| Inpatient admissions | ~55 / day | Average stay 4.2 days, ~230 occupied beds |
| Doctors | 180 | |
| Nursing and support staff | 600 | |
| Laboratory orders | ~1,800 / day | ~2.6 per OPD visit plus inpatient review |
| Laboratory result rows | ~7,000 / day | ~4 analytes per order |
| Concurrent sessions at peak | 150 | Morning ward round + OPD overlap, 08:00–11:00 |
| Read : write ratio | 85 : 15 | Clinical reads dominate |
| Transactional data growth | ~2.5 GB / year | Excludes imaging |
| Clinical record retention | 7 years minimum | Legal/regulatory |
| Audit log retention | 10 years, append-only | Compliance |

**Peak concurrency is the number that matters most.** At 08:00 the ward round, the OPD
queue and the lab all open simultaneously, and they contend for the same rows: the same
doctor's schedule, the same patient's encounter. A design that is fine at 10 sessions
per second will show lock waits at 150.

## 7. Why This Case Study

Each portfolio needs something different from the domain, and a hospital supplies all
five without contrivance:

| Portfolio | What the domain provides |
|---|---|
| **P1 Design** | Genuine normalisation pressure: repeating groups in clinical notes, transitive dependencies through department and specialty |
| **P2 Optimisation** | Two clearly different read shapes — single-patient history vs cross-population aggregation — so index strategies can be compared honestly |
| **P3 Concurrency** | Real, safety-relevant contention: double-booking, and two clerks updating the same patient record |
| **P4 NoSQL** | Lab results are structurally heterogeneous and append-only — a defensible document-store boundary rather than an arbitrary one |
| **P5 Distribution** | Read-heavy with geographically separated sites, and a hard consistency requirement on booking and prescribing |

The strongest feature of this choice is that P4 has an honest answer. In many case studies
moving data to MongoDB is decoration; here there is a real argument on both sides, which
is exactly what the rubric rewards.

## 8. Scope Boundaries

Explicitly **out of scope**, to keep the work proportionate to 40 marks:

- **Billing, insurance claims and payments** — a separate financial system.
- **Pharmacy stock and inventory** — prescriptions are recorded; dispensing logistics are not.
- **HR, payroll and rostering** — staff records exist only to attribute clinical work.
- **Imaging and PACS** — radiology orders may be recorded; image storage is out of scope.
- **Theatre scheduling and surgical notes.**
- **Patient-facing portal and mobile app.**
- **HL7/FHIR interoperability interfaces.**

Recording these boundaries is itself a design decision: it prevents scope creep and makes
the boundary of the assessment defensible if challenged.
