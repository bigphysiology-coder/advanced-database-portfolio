// ============================================================================
// MIT 8103 Advanced Database Systems
// Portfolio 4: NoSQL - MongoDB implementation
//
// Case study: the same hospital system as Portfolio 1. This file creates the
// validated lab_results collection and the indexes that serve the queries in
// queries.js. The data itself is loaded by scripts/load-p4.ps1.
//
// Run:
//   docker exec -it portfolio-mongodb mongosh -u portfolio -p portfolio \
//     --authenticationDatabase admin hospital_labs mongodb-setup.js
//
// The script is re-runnable: it updates the validator on an existing
// collection and leaves existing indexes in place.
// ============================================================================

// ----------------------------------------------------------------------------
// 1. Validator
//
// The validator is deliberately stricter than "the field exists":
//   * status, priority, test code, specimen type and flag are closed enums;
//   * timestamps must be BSON dates, not strings;
//   * a REPORTED/AMENDED order must carry at least one result, while a pending
//     order may legitimately have an empty results array;
//   * result_count and schema_version make the denormalised data explicit.
//
// The one rule MongoDB cannot express here is result_count = size(results).
// That is checked by consistency-checks.js after every load.
// ----------------------------------------------------------------------------

const schema = {
    $jsonSchema: {
        bsonType: "object",
        required: [
            "order_id", "encounter_id", "patient_id", "patient_mrn",
            "test_code", "test_name", "specimen_type", "department",
            "priority", "status", "ordered_at", "ordered_by",
            "results", "result_count", "schema_version"
        ],
        properties: {
            _id:          { bsonType: "objectId" },
            order_id:     { bsonType: "string", minLength: 36, maxLength: 36,
                            description: "P1 lab_order UUID; cross-store natural key" },
            encounter_id: { bsonType: "string", minLength: 36, maxLength: 36,
                            description: "P1 encounter UUID" },
            patient_id:   { bsonType: "string", minLength: 36, maxLength: 36,
                            description: "P1 patient UUID; string, not ObjectId" },
            patient_mrn:  { bsonType: "string", pattern: "^MRN-[0-9]{7}$",
                            description: "Immutable business key for display" },
            test_code:    { enum: ["FBC", "LIPID", "LFT", "UEC", "TFT",
                                   "CRP", "MP", "URIN", "COAG", "HBA1C"] },
            test_name:    { bsonType: "string", minLength: 1 },
            specimen_type:{ enum: ["Blood", "Urine"] },
            department:   { bsonType: "string", minLength: 1 },
            priority:     { enum: ["ROUTINE", "URGENT"] },
            status:       { enum: ["ORDERED", "COLLECTED", "IN_PROGRESS",
                                   "REPORTED", "AMENDED"] },
            ordered_at:   { bsonType: "date" },
            collected_at: { bsonType: ["date", "null"] },
            reported_at:  { bsonType: ["date", "null"] },
            ordered_by:   { bsonType: "string", minLength: 36, maxLength: 36,
                            description: "P1 doctor/staff UUID" },
            results: {
                bsonType: "array",
                items: {
                    bsonType: "object",
                    required: ["analyte_id", "analyte", "value", "value_type",
                               "unit", "flag", "resulted_at"],
                    properties: {
                        analyte_id:  { bsonType: "int", minimum: 1 },
                        analyte:     { bsonType: "string", minLength: 1 },
                        value:       { bsonType: ["double", "int", "string"] },
                        value_type:  { enum: ["numeric", "text"] },
                        unit:        { bsonType: "string", minLength: 1 },
                        ref_low:     { bsonType: ["double", "int", "null"] },
                        ref_high:    { bsonType: ["double", "int", "null"] },
                        flag:        { enum: ["NORMAL", "LOW", "HIGH", "CRITICAL"] },
                        resulted_at: { bsonType: "date" },
                        resulted_by: { bsonType: ["string", "null"],
                                       minLength: 36, maxLength: 36 }
                    }
                }
            },
            result_count:  { bsonType: "int", minimum: 0 },
            schema_version:{ bsonType: "int", enum: [1] }
        }
    }
};

// MongoDB's $jsonSchema cannot express "results.0 must exist when status is
// REPORTED". Combining $jsonSchema with a query predicate can.
const validator = {
    $and: [
        schema,
        {
            $or: [
                { status: { $in: ["ORDERED", "COLLECTED", "IN_PROGRESS"] } },
                { "results.0": { $exists: true } }
            ]
        }
    ]
};

// ----------------------------------------------------------------------------
// 2. Collections
// ----------------------------------------------------------------------------

if (db.getCollectionInfos({ name: "lab_results" }).length === 0) {
    db.createCollection("lab_results", {
        validator: validator,
        validationLevel: "strict",
        validationAction: "error"
    });
    print("created collection lab_results");
} else {
    db.runCommand({
        collMod: "lab_results",
        validator: validator,
        validationLevel: "strict",
        validationAction: "error"
    });
    print("updated validator on lab_results");
}

if (db.getCollectionInfos({ name: "patient_refs" }).length === 0) {
    db.createCollection("patient_refs", {
        validator: {
            $jsonSchema: {
                bsonType: "object",
                required: ["_id", "mrn"],
                properties: {
                    _id: { bsonType: "string", minLength: 36, maxLength: 36 },
                    mrn: { bsonType: "string", pattern: "^MRN-[0-9]{7}$" }
                }
            }
        },
        validationLevel: "strict",
        validationAction: "error"
    });
    print("created collection patient_refs");
}

// ----------------------------------------------------------------------------
// 3. Indexes
//
// Each index is tied to a named query in queries.js. The compound indexes put
// equality fields first and the range/sort field last (the ESR guideline).
// ----------------------------------------------------------------------------

// Idempotent load and by-order lookup.
db.lab_results.createIndex(
    { order_id: 1 },
    { name: "ux_order_id", unique: true }
);

// Q1: one patient's results, newest first.
db.lab_results.createIndex(
    { patient_id: 1, collected_at: -1 },
    { name: "ix_patient_collected" }
);

// Q3: the laboratory work queue, urgent first and oldest first.
db.lab_results.createIndex(
    { status: 1, priority: -1, collected_at: 1 },
    { name: "ix_status_priority_collected" }
);

// Q2: abnormal results across patients, newest first.
// "results.flag" is a multikey field; the index is still a single-array index.
db.lab_results.createIndex(
    { "results.flag": 1, collected_at: -1 },
    { name: "ix_result_flag_collected" }
);

// Q4: one analyte over time for one patient.
db.lab_results.createIndex(
    { patient_id: 1, "results.analyte": 1, collected_at: -1 },
    { name: "ix_patient_analyte_collected" }
);

// Q5: date-range dashboard and $facet input.
db.lab_results.createIndex(
    { collected_at: -1 },
    { name: "ix_collected" }
);

// Reconciliation lookup from lab_results.patient_id to patient_refs._id.
db.patient_refs.createIndex(
    { mrn: 1 },
    { name: "ux_patient_mrn", unique: true }
);

printjson({
    collections: db.getCollectionNames().sort(),
    lab_results_documents: db.lab_results.countDocuments({}),
    patient_refs_documents: db.patient_refs.countDocuments({}),
    indexes: db.lab_results.getIndexes().map(i => i.name).sort()
});
