// ============================================================================
// Portfolio 4: cross-document consistency checks.
//
// The validator guards one document at a time. These checks cover the rules a
// document store cannot express in $jsonSchema:
//
//   * result_count equals the number of embedded results;
//   * every patient_id resolves to a patient_refs row with the same MRN;
//   * every analyte belongs to the test that produced it;
//   * status, timestamps and results agree;
//   * numeric flags agree with the reference range;
//   * the collection totals match the PostgreSQL source.
//
// Run:
//   mongosh ... hospital_labs consistency-checks.js
// ============================================================================

const EXPECTED = {
    orders: 93885,
    reported: 65531,
    result_rows: 163387,
    status: { ORDERED: 9494, COLLECTED: 9360, IN_PROGRESS: 9500, REPORTED: 65531 },
    flags: { NORMAL: 121513, LOW: 26145, HIGH: 15729 }
};

const ANALYTES = {
    COAG: ["Prothrombin time", "INR"],
    CRP: ["C-reactive protein"],
    FBC: ["Haemoglobin", "White cell count", "Platelets", "MCV"],
    HBA1C: ["HbA1c"],
    LFT: ["ALT", "AST", "ALP", "Total bilirubin"],
    LIPID: ["Total cholesterol", "HDL cholesterol", "LDL cholesterol", "Triglycerides"],
    MP: ["Malaria parasites"],
    TFT: ["TSH", "Free T4"],
    UEC: ["Sodium", "Potassium", "Urea", "Creatinine"],
    URIN: ["pH", "Specific gravity"]
};

let failed = 0;

function check(name, actual, expected) {
    const ok = actual === expected;
    if (!ok) { failed++; }
    print((ok ? "PASS  " : "FAIL  ") + name
        + ": " + actual + (expected !== undefined ? " (expected " + expected + ")" : ""));
}

function count(pipeline) {
    const rows = db.lab_results.aggregate(pipeline).toArray();
    return rows.length ? rows[0].n : 0;
}

print("=== Cross-document consistency: lab_results ===");

// ---------------------------------------------------------------------------
// 1. Counts
// ---------------------------------------------------------------------------
check("documents", db.lab_results.countDocuments({}), EXPECTED.orders);

const statusCounts = {};
db.lab_results.aggregate([
    { $group: { _id: "$status", n: { $sum: 1 } } }
]).forEach(function (row) { statusCounts[row._id] = row.n; });

Object.keys(EXPECTED.status).forEach(function (status) {
    check("status " + status, statusCounts[status] || 0, EXPECTED.status[status]);
});

const resultRows = db.lab_results.aggregate([
    { $group: { _id: null, n: { $sum: "$result_count" } } }
]).toArray()[0].n;
check("embedded result rows", resultRows, EXPECTED.result_rows);

// ---------------------------------------------------------------------------
// 2. result_count
// ---------------------------------------------------------------------------
check("result_count != size(results)", count([
    { $match: { $expr: { $ne: ["$result_count", { $size: "$results" }] } } },
    { $count: "n" }
]), 0);

// ---------------------------------------------------------------------------
// 3. Cross-store patient reference
// ---------------------------------------------------------------------------
check("patient_id with no patient_refs match", count([
    {
        $lookup: {
            from: "patient_refs",
            localField: "patient_id",
            foreignField: "_id",
            as: "ref"
        }
    },
    { $match: { ref: { $size: 0 } } },
    { $count: "n" }
]), 0);

check("patient_mrn disagreeing with patient_refs", count([
    {
        $lookup: {
            from: "patient_refs",
            localField: "patient_id",
            foreignField: "_id",
            as: "ref"
        }
    },
    {
        $match: {
            $expr: { $ne: ["$patient_mrn", { $arrayElemAt: ["$ref.mrn", 0] }] }
        }
    },
    { $count: "n" }
]), 0);

check("duplicate patient IDs in patient_refs", db.patient_refs.aggregate([
    { $group: { _id: "$_id", n: { $sum: 1 } } },
    { $match: { n: { $gt: 1 } } },
    { $count: "n" }
]).toArray().length ? 1 : 0, 0);

// ---------------------------------------------------------------------------
// 4. Analyte belongs to the test
// ---------------------------------------------------------------------------
let wrongAnalyte = 0;
db.lab_results.find(
    {},
    { _id: 0, test_code: 1, results: 1 }
).forEach(function (doc) {
    const allowed = ANALYTES[doc.test_code] || [];
    doc.results.forEach(function (r) {
        if (allowed.indexOf(r.analyte) === -1) {
            wrongAnalyte++;
        }
    });
});
check("result analyte not belonging to its test", wrongAnalyte, 0);

// ---------------------------------------------------------------------------
// 5. Timestamp and status invariants
// ---------------------------------------------------------------------------
check("collected_at before ordered_at", count([
    {
        $match: {
            $expr: {
                $and: [
                    { $ne: ["$collected_at", null] },
                    { $lt: ["$collected_at", "$ordered_at"] }
                ]
            }
        }
    },
    { $count: "n" }
]), 0);

check("reported_at before collected_at", count([
    {
        $match: {
            $expr: {
                $and: [
                    { $ne: ["$reported_at", null] },
                    { $ne: ["$collected_at", null] },
                    { $lt: ["$reported_at", "$collected_at"] }
                ]
            }
        }
    },
    { $count: "n" }
]), 0);

check("ORDERED with collection or results", count([
    {
        $match: {
            status: "ORDERED",
            $or: [{ collected_at: { $ne: null } }, { "results.0": { $exists: true } }]
        }
    },
    { $count: "n" }
]), 0);

check("COLLECTED/IN_PROGRESS with missing collection, report or results", count([
    {
        $match: {
            status: { $in: ["COLLECTED", "IN_PROGRESS"] },
            $or: [
                { collected_at: null },
                { reported_at: { $ne: null } },
                { "results.0": { $exists: true } }
            ]
        }
    },
    { $count: "n" }
]), 0);

check("REPORTED with missing timestamps or results", count([
    {
        $match: {
            status: "REPORTED",
            $or: [
                { collected_at: null },
                { reported_at: null },
                { "results.0": { $exists: false } }
            ]
        }
    },
    { $count: "n" }
]), 0);

// ---------------------------------------------------------------------------
// 6. Numeric flags match the reference range
// ---------------------------------------------------------------------------
check("numeric flag disagrees with reference range", count([
    { $unwind: "$results" },
    { $match: { "results.value_type": "numeric" } },
    {
        $match: {
            $expr: {
                $or: [
                    {
                        $and: [
                            { $gt: ["$results.value", "$results.ref_high"] },
                            { $ne: ["$results.flag", "HIGH"] }
                        ]
                    },
                    {
                        $and: [
                            { $lt: ["$results.value", "$results.ref_low"] },
                            { $ne: ["$results.flag", "LOW"] }
                        ]
                    },
                    {
                        $and: [
                            { $gte: ["$results.value", "$results.ref_low"] },
                            { $lte: ["$results.value", "$results.ref_high"] },
                            { $ne: ["$results.flag", "NORMAL"] }
                        ]
                    }
                ]
            }
        }
    },
    { $count: "n" }
]), 0);

const flagCounts = {};
db.lab_results.aggregate([
    { $unwind: "$results" },
    { $group: { _id: "$results.flag", n: { $sum: 1 } } }
]).forEach(function (row) { flagCounts[row._id] = row.n; });

Object.keys(EXPECTED.flags).forEach(function (flag) {
    check("flag " + flag, flagCounts[flag] || 0, EXPECTED.flags[flag]);
});

// ---------------------------------------------------------------------------
// 7. Indexes
// ---------------------------------------------------------------------------
const indexes = db.lab_results.getIndexes().map(function (i) { return i.name; }).sort();
const required = [
    "_id_", "ix_collected", "ix_patient_analyte_collected", "ix_patient_collected",
    "ix_result_flag_collected", "ix_status_priority_collected", "ux_order_id"
];
required.forEach(function (name) {
    check("index " + name, indexes.indexOf(name) >= 0 ? "present" : "missing", "present");
});

print("");
if (failed > 0) {
    print("consistency checks: " + failed + " FAILED");
    throw new Error("consistency checks failed");
}
print("consistency checks: all passed");
