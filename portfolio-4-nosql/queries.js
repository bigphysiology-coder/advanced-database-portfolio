// ============================================================================
// Portfolio 4: the queries that justify the document model and its indexes.
//
// Run:
//   mongosh ... hospital_labs queries.js
//
// Q1  patient lab history (the clinical read)
// Q2  abnormal results across patients (the cross-document read)
// Q3  laboratory work queue (the operational write-side read)
// Q4  one analyte over time for one patient (multikey index)
// Q5  dashboard in one pass ($facet)
// Q6  patient reference reconciliation ($lookup)
//
// Each explain summary reports nReturned, keysExamined, docsExamined and the
// winning stage, so the index claims can be checked rather than believed.
// ============================================================================

const PATIENT_MRN = "MRN-0003927";
const TREND_ANALYTE = "Total cholesterol";
const ABNORMAL_SINCE = new Date("2026-09-27T00:00:00Z");
const DASHBOARD_SINCE = new Date("2026-07-29T00:00:00Z");

function stageSummary(plan) {
    const parts = [];

    function visit(node) {
        if (!node) { return; }
        if (node.stage) {
            parts.push(node.indexName
                ? node.stage + "[" + node.indexName + "]"
                : node.stage);
        }
        if (node.inputStage) { visit(node.inputStage); }
        if (node.inputStages) { node.inputStages.forEach(visit); }
        if (node.stages) {
            Object.keys(node.stages).forEach(function (key) {
                (node.stages[key] || []).forEach(visit);
            });
        }
    }

    visit(plan);
    return parts.join(" -> ");
}

// find() explain puts executionStats at the top level; aggregate() explain
// nests it under the leading $cursor stage. Handle both shapes.
function getExecutionStats(explain) {
    if (explain.executionStats) { return explain.executionStats; }
    const stages = explain.stages || [];
    for (let i = 0; i < stages.length; i++) {
        if (stages[i].$cursor && stages[i].$cursor.executionStats) {
            return stages[i].$cursor.executionStats;
        }
    }
    return null;
}

function pipelineSummary(explain) {
    if (!Array.isArray(explain.stages)) {
        return stageSummary(explain.queryPlanner.winningPlan);
    }
    const cursor = explain.stages[0].$cursor;
    const parts = [stageSummary(cursor.queryPlanner.winningPlan)];
    explain.stages.slice(1).forEach(function (stage) {
        const name = Object.keys(stage).filter(function (key) {
            return key.charAt(0) === "$";
        })[0];
        if (name) { parts.push(name); }
    });
    return parts.join(" -> ");
}

function explainSummary(label, explain) {
    const stats = getExecutionStats(explain);
    if (!stats) {
        throw new Error("No executionStats in explain output for " + label);
    }
    print(label
        + ": nReturned=" + stats.nReturned
        + " keysExamined=" + stats.totalKeysExamined
        + " docsExamined=" + stats.totalDocsExamined
        + " executionTimeMillis=" + stats.executionTimeMillis
        + " stages=" + pipelineSummary(explain));
}

// The MRN -> patient_id resolution uses the small, indexed patient_refs
// projection. Lab documents themselves are reached by the UUID, so the MRN is
// never an unindexed filter over 93,885 documents.
const patientRef = db.patient_refs.findOne({ mrn: PATIENT_MRN });
if (!patientRef) {
    throw new Error("No patient_refs row for " + PATIENT_MRN + "; run scripts/load-p4.ps1 first");
}
const patient = { patient_id: patientRef._id, patient_mrn: patientRef.mrn };

print("=== Q1. Patient lab history, newest first ===");
print("patient: " + patient.patient_mrn + " (" + patient.patient_id + ")");
printjson(db.lab_results.find(
    { patient_id: patient.patient_id },
    {
        _id: 0, order_id: 1, test_code: 1, test_name: 1, status: 1,
        collected_at: 1, reported_at: 1, result_count: 1
    }
).sort({ collected_at: -1 }).toArray());

explainSummary("Q1 explain", db.lab_results.find(
    { patient_id: patient.patient_id }
).sort({ collected_at: -1 }).explain("executionStats"));

print("");
print("=== Q2. Abnormal results across patients, last 30 days ===");
const q2Pipeline = [
    {
        $match: {
            collected_at: { $gte: ABNORMAL_SINCE },
            "results.flag": { $in: ["HIGH", "LOW", "CRITICAL"] }
        }
    },
    { $unwind: "$results" },
    { $match: { "results.flag": { $in: ["HIGH", "LOW", "CRITICAL"] } } },
    {
        $project: {
            _id: 0,
            patient_mrn: 1,
            test_code: 1,
            collected_at: 1,
            analyte: "$results.analyte",
            value: "$results.value",
            unit: "$results.unit",
            flag: "$results.flag"
        }
    },
    { $sort: { collected_at: -1 } },
    { $limit: 20 }
];
printjson(db.lab_results.aggregate(q2Pipeline).toArray());
explainSummary("Q2 explain", db.lab_results.explain("executionStats").aggregate(q2Pipeline));

print("");
print("=== Q3. Laboratory work queue: IN_PROGRESS, urgent first, oldest first ===");
printjson(db.lab_results.find(
    { status: "IN_PROGRESS" },
    {
        _id: 0, order_id: 1, patient_mrn: 1, test_code: 1, test_name: 1,
        priority: 1, collected_at: 1, result_count: 1
    }
).sort({ priority: -1, collected_at: 1 }).limit(10).toArray());

explainSummary("Q3 explain", db.lab_results.find(
    { status: "IN_PROGRESS" }
).sort({ priority: -1, collected_at: 1 }).limit(10).explain("executionStats"));

print("");
print("=== Q4. " + TREND_ANALYTE + " over time for " + PATIENT_MRN + " ===");
const q4Pipeline = [
    {
        $match: {
            patient_id: patient.patient_id,
            "results.analyte": TREND_ANALYTE
        }
    },
    { $unwind: "$results" },
    { $match: { "results.analyte": TREND_ANALYTE } },
    {
        $project: {
            _id: 0,
            collected_at: 1,
            value: "$results.value",
            unit: "$results.unit",
            ref_low: "$results.ref_low",
            ref_high: "$results.ref_high",
            flag: "$results.flag"
        }
    },
    { $sort: { collected_at: 1 } }
];
printjson(db.lab_results.aggregate(q4Pipeline).toArray());
explainSummary("Q4 explain", db.lab_results.explain("executionStats").aggregate(q4Pipeline));

print("");
print("=== Q5. Dashboard for collected_at >= 2026-07-29 (single $facet pass) ===");
const q5Pipeline = [
    { $match: { collected_at: { $gte: DASHBOARD_SINCE } } },
    {
        $facet: {
            by_status: [
                { $group: {
                    _id: "$status",
                    orders: { $sum: 1 },
                    results: { $sum: "$result_count" }
                } },
                { $sort: { orders: -1 } }
            ],
            by_test: [
                { $group: {
                    _id: "$test_code",
                    orders: { $sum: 1 },
                    avg_results: { $avg: "$result_count" }
                } },
                { $sort: { orders: -1 } }
            ],
            flags: [
                { $unwind: "$results" },
                { $group: { _id: "$results.flag", n: { $sum: 1 } } },
                { $sort: { n: -1 } }
            ],
            turnaround: [
                { $match: {
                    status: "REPORTED",
                    collected_at: { $ne: null },
                    reported_at: { $ne: null }
                } },
                { $project: {
                    test_code: 1,
                    hours: { $divide: [
                        { $subtract: ["$reported_at", "$collected_at"] },
                        3600000
                    ] }
                } },
                { $group: {
                    _id: "$test_code",
                    avg_hours: { $avg: "$hours" },
                    n: { $sum: 1 }
                } },
                { $sort: { avg_hours: -1 } }
            ]
        }
    }
];
printjson(db.lab_results.aggregate(q5Pipeline).toArray());
explainSummary("Q5 explain", db.lab_results.explain("executionStats").aggregate(q5Pipeline));

print("");
print("=== Q6. Cross-store reference check with $lookup ===");
print("patient_refs lookup by MRN (ux_patient_mrn): " + patientRef._id);
printjson(db.lab_results.aggregate([
    { $match: { patient_id: patientRef._id } },
    {
        $lookup: {
            from: "patient_refs",
            localField: "patient_id",
            foreignField: "_id",
            as: "patient_ref"
        }
    },
    {
        $project: {
            _id: 0,
            order_id: 1,
            patient_mrn: 1,
            referenced_mrn: { $arrayElemAt: ["$patient_ref.mrn", 0] },
            mrn_matches: {
                $eq: ["$patient_mrn", { $arrayElemAt: ["$patient_ref.mrn", 0] }]
            },
            test_code: 1,
            status: 1,
            collected_at: 1
        }
    },
    { $limit: 5 }
]).toArray());

print("");
print("=== Collection summary ===");
printjson({
    documents: db.lab_results.countDocuments({}),
    result_rows: db.lab_results.aggregate([
        { $group: { _id: null, n: { $sum: "$result_count" } } }
    ]).toArray()[0].n,
    patient_refs: db.patient_refs.countDocuments({})
});
