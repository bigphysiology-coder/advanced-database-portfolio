// ============================================================================
// Portfolio 4: steady-state query timings for the PostgreSQL comparison.
//
// The explain output in queries.js reports the server's own executionStats.
// This script adds repeated client-side measurements so the comparison table
// can quote a median rather than a single cold run. Each query is executed
// twice as a warm-up and then five times; the median of the five is reported.
//
// Run:
//   mongosh ... hospital_labs benchmark.js
//
// Client-observed time includes mongosh's BSON conversion and transport. The
// PostgreSQL figures in compare-postgres.sql are psql server timings, so the
// table in model-design.md quotes both raw values and says which is which.
// ============================================================================

const PATIENT_MRN = "MRN-0003927";
const TREND_ANALYTE = "Total cholesterol";
const ABNORMAL_SINCE = new Date("2026-09-27T00:00:00Z");
const DASHBOARD_SINCE = new Date("2026-07-29T00:00:00Z");
const RUNS = 5;

const patientRef = db.patient_refs.findOne({ mrn: PATIENT_MRN });
if (!patientRef) {
    throw new Error("No patient_refs row for " + PATIENT_MRN + "; run scripts/load-p4.ps1 first");
}
const patientId = patientRef._id;

function median(values) {
    const sorted = values.slice().sort(function (a, b) { return a - b; });
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2
        ? sorted[mid]
        : (sorted[mid - 1] + sorted[mid]) / 2;
}

function bench(name, fn) {
    fn();
    fn();
    const times = [];
    let rows = 0;
    for (let i = 0; i < RUNS; i++) {
        const started = Date.now();
        rows = fn();
        times.push(Date.now() - started);
    }
    print(name
        + ": rows=" + rows
        + " runs=" + times.join(",")
        + " medianMs=" + median(times)
        + " minMs=" + Math.min.apply(null, times)
        + " maxMs=" + Math.max.apply(null, times));
}

print("=== MongoDB steady-state timings (warm-up 2, measured " + RUNS + ") ===");

// One order document is the write unit. Clone a real reported lipid panel,
// give it a new UUID, insert it through the validator, then remove it. This is
// the document-store equivalent of the PostgreSQL order + four result rows
// measured in compare-postgres.sql.
const writeTemplate = db.lab_results.findOne(
    { status: "REPORTED", test_code: "LIPID", result_count: 4 },
    { _id: 0 }
);
const crypto = require("crypto");

bench("W1 insert + cleanup delete, one reported order", function () {
    const doc = EJSON.parse(EJSON.stringify(writeTemplate));
    doc.order_id = crypto.randomUUID();
    db.lab_results.insertOne(doc);
    db.lab_results.deleteOne({ order_id: doc.order_id });
    return 1;
});


bench("Q1 patient history", function () {
    return db.lab_results.find(
        { patient_id: patientId },
        { _id: 0, order_id: 1, test_code: 1, test_name: 1, status: 1,
          collected_at: 1, reported_at: 1, result_count: 1 }
    ).sort({ collected_at: -1 }).toArray().length;
});

bench("Q2 abnormal results, last 30 days", function () {
    return db.lab_results.aggregate([
        { $match: {
            collected_at: { $gte: ABNORMAL_SINCE },
            "results.flag": { $in: ["HIGH", "LOW", "CRITICAL"] }
        } },
        { $unwind: "$results" },
        { $match: { "results.flag": { $in: ["HIGH", "LOW", "CRITICAL"] } } },
        { $project: {
            _id: 0, patient_mrn: 1, test_code: 1, collected_at: 1,
            analyte: "$results.analyte", value: "$results.value",
            unit: "$results.unit", flag: "$results.flag"
        } },
        { $sort: { collected_at: -1 } },
        { $limit: 20 }
    ]).toArray().length;
});

bench("Q3 work queue", function () {
    return db.lab_results.find(
        { status: "IN_PROGRESS" },
        { _id: 0, order_id: 1, patient_mrn: 1, test_code: 1, test_name: 1,
          priority: 1, collected_at: 1, result_count: 1 }
    ).sort({ priority: -1, collected_at: 1 }).limit(10).toArray().length;
});

bench("Q4 analyte trend", function () {
    return db.lab_results.aggregate([
        { $match: {
            patient_id: patientId,
            "results.analyte": TREND_ANALYTE
        } },
        { $unwind: "$results" },
        { $match: { "results.analyte": TREND_ANALYTE } },
        { $project: {
            _id: 0, collected_at: 1, value: "$results.value",
            unit: "$results.unit", ref_low: "$results.ref_low",
            ref_high: "$results.ref_high", flag: "$results.flag"
        } },
        { $sort: { collected_at: 1 } }
    ]).toArray().length;
});

bench("Q5 dashboard facet", function () {
    return db.lab_results.aggregate([
        { $match: { collected_at: { $gte: DASHBOARD_SINCE } } },
        { $facet: {
            by_status: [
                { $group: { _id: "$status", orders: { $sum: 1 },
                            results: { $sum: "$result_count" } } },
                { $sort: { orders: -1 } }
            ],
            by_test: [
                { $group: { _id: "$test_code", orders: { $sum: 1 },
                            avg_results: { $avg: "$result_count" } } },
                { $sort: { orders: -1 } }
            ],
            flags: [
                { $unwind: "$results" },
                { $group: { _id: "$results.flag", n: { $sum: 1 } } },
                { $sort: { n: -1 } }
            ],
            turnaround: [
                { $match: { status: "REPORTED", collected_at: { $ne: null },
                            reported_at: { $ne: null } } },
                { $project: {
                    test_code: 1,
                    hours: { $divide: [
                        { $subtract: ["$reported_at", "$collected_at"] }, 3600000
                    ] }
                } },
                { $group: { _id: "$test_code", avg_hours: { $avg: "$hours" },
                            n: { $sum: 1 } } },
                { $sort: { avg_hours: -1 } }
            ]
        } }
    ]).toArray().length;
});
