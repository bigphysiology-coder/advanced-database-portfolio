// ============================================================================
// Portfolio 4: load newline-delimited JSON into the staging collection.
//
// Used when mongoimport is not available in the image. mongosh is a Node.js
// runtime, so it can read the file directly with fs.
//
// Run inside the container:
//   mongosh ... hospital_labs load-ndjson.js
// ============================================================================

const fs = require("fs");

const SOURCE = process.env.LAB_NDJSON || "/tmp/lab_results.ndjson";
const BATCH = 1000;

const text = fs.readFileSync(SOURCE, "utf8");
const lines = text.split("\n");

let batch = [];
let total = 0;

for (let i = 0; i < lines.length; i++) {
    const line = lines[i].trim();
    if (!line) { continue; }

    batch.push(EJSON.parse(line));

    if (batch.length === BATCH) {
        db.lab_results_raw.insertMany(batch, { ordered: false });
        total += batch.length;
        batch = [];
        if (total % 10000 === 0) {
            print("  loaded " + total);
        }
    }
}

if (batch.length > 0) {
    db.lab_results_raw.insertMany(batch, { ordered: false });
    total += batch.length;
}

print("staging documents: " + total);
