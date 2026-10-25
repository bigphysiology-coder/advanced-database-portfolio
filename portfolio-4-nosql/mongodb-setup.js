// ============================================================================
// MIT 8103 Advanced Database Systems
// Portfolio 4: NoSQL — MongoDB implementation
//
// Case study: same hospital system as Portfolio 1. This file models the
// laboratory results subset, which is stored relationally in P1 and here as
// documents, so the two models can be compared directly.
//
// Run:  docker exec -it portfolio-mongodb mongosh -u portfolio -p portfolio \
//         --authenticationDatabase admin hospital_labs mongodb-setup.js
//
// Every statement is written to be re-runnable.
// ============================================================================

// ----------------------------------------------------------------------------
// 1. Collection with schema validation
//    Validation is the closest document-store equivalent to a relational CHECK,
//    and choosing validationLevel/validationAction is a design decision worth
//    explaining in model-design.md.
// ----------------------------------------------------------------------------

db.createCollection("lab_results", {
  validator: {
    $jsonSchema: {
      bsonType: "object",
      required: ["order_id", "patient_id", "test_code", "collected_at", "status", "results"],
      properties: {
        order_id:     { bsonType: "string", description: "FK to PostgreSQL lab_order" },
        patient_id:   { bsonType: "string", description: "FK to PostgreSQL patient" },
        test_code:    { bsonType: "string", description: "e.g. FBC, LIPID, HBA1C" },
        collected_at: { bsonType: "date" },
        reported_at:  { bsonType: ["date", "null"] },
        status:       { enum: ["COLLECTED", "IN_PROGRESS", "REPORTED", "AMENDED"] },
        results: {
          bsonType: "array",
          minItems: 1,
          items: {
            bsonType: "object",
            required: ["analyte", "value", "unit"],
            properties: {
              analyte: { bsonType: "string" },
              value:   { bsonType: ["double", "int", "string"] },
              unit:    { bsonType: "string" },
              ref_low: { bsonType: ["double", "int", "null"] },
              ref_high:{ bsonType: ["double", "int", "null"] },
              flag:    { enum: ["NORMAL", "HIGH", "LOW", "CRITICAL", null] }
            }
          }
        }
      }
    }
  },
  validationLevel: "strict",
  validationAction: "error"
});

// TODO: extend the schema above as the model develops.

// ----------------------------------------------------------------------------
// 2. Indexes — each must answer a named query in model-design.md
// ----------------------------------------------------------------------------

// Patient history: results for one patient, newest first
db.lab_results.createIndex({ patient_id: 1, collected_at: -1 }, { name: "ix_patient_collected" });

// Turnaround reporting: unreported orders by test type
db.lab_results.createIndex({ status: 1, test_code: 1 }, { name: "ix_status_test" });

// TODO: understanding what makes an index usable in MongoDB (prefix rule,
//       ESR guideline, covered queries) and apply it here.

// ----------------------------------------------------------------------------
// 3. Sample documents
// ----------------------------------------------------------------------------

// Insert one valid lipid panel and one valid full blood count — deliberately
// different shapes, which is the point of the model.
db.lab_results.insertOne({
  order_id: "LAB-000001",
  patient_id: "PAT-00042",
  test_code: "LIPID",
  collected_at: new Date("2026-03-14T08:15:00Z"),
  reported_at: new Date("2026-03-14T15:40:00Z"),
  status: "REPORTED",
  results: [
    { analyte: "Total cholesterol", value: 5.8, unit: "mmol/L", ref_low: 0, ref_high: 5.0, flag: "HIGH" },
    { analyte: "HDL", value: 1.1, unit: "mmol/L", ref_low: 1.0, ref_high: 2.0, flag: "NORMAL" },
    { analyte: "LDL", value: 3.9, unit: "mmol/L", ref_low: 0, ref_high: 3.0, flag: "HIGH" }
  ]
});

db.lab_results.insertOne({
  order_id: "LAB-000002",
  patient_id: "PAT-00042",
  test_code: "FBC",
  collected_at: new Date("2026-03-14T08:20:00Z"),
  reported_at: null,
  status: "IN_PROGRESS",
  results: [
    { analyte: "Haemoglobin", value: 134, unit: "g/L", ref_low: 130, ref_high: 175, flag: "NORMAL" },
    { analyte: "WBC", value: 11.2, unit: "10^9/L", ref_low: 4.0, ref_high: 11.0, flag: "HIGH" },
    { analyte: "Platelets", value: 250, unit: "10^9/L", ref_low: 150, ref_high: 400, flag: "NORMAL" }
  ]
});

// TODO: prove the validator works — attempt an invalid document and capture the
//       rejection message. That error output is the implementation evidence.

// ----------------------------------------------------------------------------
// 4. Queries that justify the model
// ----------------------------------------------------------------------------

// Q1. A patient's full lab history, newest first
//     Baseline access pattern for the clinical UI.
db.lab_results.find({ patient_id: "PAT-00042" }).sort({ collected_at: -1 });

// Q2. Every critical analyte across all patients in the last 7 days
//     Hard to express relationally without a join through the analyte table.
db.lab_results.aggregate([
  { $match: { collected_at: { $gte: new Date(Date.now() - 7 * 864e5) } } },
  { $unwind: "$results" },
  { $match: { "results.flag": "CRITICAL" } },
  { $project: { _id: 0, patient_id: 1, test_code: 1, analyte: "$results.analyte", value: "$results.value" } }
]);

// Q3. Average turnaround time per test type, in hours
db.lab_results.aggregate([
  { $match: { status: "REPORTED", reported_at: { $ne: null } } },
  { $project: { test_code: 1, hours: { $divide: [{ $subtract: ["$reported_at", "$collected_at"] }, 3600000] } } },
  { $group: { _id: "$test_code", avg_hours: { $avg: "$hours" }, n: { $sum: 1 } } },
  { $sort: { avg_hours: -1 } }
]);

// TODO: add an aggregation using $facet (e.g. abnormal vs normal counts per test
//       in one pass) and, if you keep a separate patients collection, a $lookup.

// ----------------------------------------------------------------------------
// 5. Explain a query plan — the MongoDB equivalent of EXPLAIN ANALYZE,
//    which lets you compare directly with Portfolio 2.
// ----------------------------------------------------------------------------

// db.lab_results.find({ patient_id: "PAT-00042" }).explain("executionStats");
// Look for: totalDocsExamined vs nReturned (should be close), and IXSCAN vs COLLSCAN.
