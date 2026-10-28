// ============================================================================
// Portfolio 4: export representative documents from the running database.
//
// Prints a JSON array in MongoDB Extended JSON (relaxed) so the file can be
// read by a human and re-imported by mongoimport / mongosh.
//
// Run:
//   mongosh --quiet "$uri" --file export-samples.js
// ============================================================================

const samples = [];

// 1. A reported lipid panel: four embedded analytes, notable flags.
samples.push(db.lab_results.findOne(
    { test_code: "LIPID", status: "REPORTED", result_count: 4 },
    { _id: 0 }
));

// 2. A textual result, proving the value union is real and not theoretical.
samples.push(db.lab_results.findOne(
    { status: "REPORTED", "results.value_type": "text" },
    { _id: 0 }
));

// 3. A pending order with no results: the validator still accepts it.
samples.push(db.lab_results.findOne(
    { status: "IN_PROGRESS", result_count: 0 },
    { _id: 0 }
));

// 4. An order waiting for collection. (All ORDERED orders in this seed are
// routine; urgent orders are already reported, so do not filter on priority.)
samples.push(db.lab_results.findOne(
    { status: "ORDERED", result_count: 0 },
    { _id: 0 }
));

if (samples.some(function (doc) { return doc === null; })) {
    throw new Error("a sample query returned no document; is the collection loaded?");
}

print(EJSON.stringify(samples, null, 2));
