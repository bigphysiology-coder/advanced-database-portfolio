// ============================================================================
// Portfolio 4: transform raw JSON imports into validated lab result documents.
//
// Input:  lab_results_raw  (one document per lab order, dates as ISO strings)
// Output: lab_results      (validated collection, dates as BSON dates)
//
// Run:
//   mongosh ... hospital_labs transform-lab-results.js
//
// The raw collection exists only for the load. It is dropped at the end, so a
// reader of the final database sees one collection and one schema.
// ============================================================================

const raw = db.lab_results_raw;
const target = db.lab_results;

print("raw documents: " + raw.countDocuments({}));
print("target documents before transform: " + target.countDocuments({}));

// A clean load: the loader drops and recreates the target before calling this.
// Clearing here as well makes the transform safe to re-run on its own.
target.deleteMany({});

const pipeline = [
    {
        $addFields: {
            ordered_at: {
                $convert: { input: "$ordered_at", to: "date", onError: null, onNull: null }
            },
            collected_at: {
                $convert: { input: "$collected_at", to: "date", onError: null, onNull: null }
            },
            reported_at: {
                $convert: { input: "$reported_at", to: "date", onError: null, onNull: null }
            },
            results: {
                $map: {
                    input: "$results",
                    as: "r",
                    in: {
                        $mergeObjects: [
                            "$$r",
                            {
                                resulted_at: {
                                    $convert: {
                                        input: "$$r.resulted_at",
                                        to: "date",
                                        onError: null,
                                        onNull: null
                                    }
                                }
                            }
                        ]
                    }
                }
            }
        }
    },
    {
        $addFields: {
            result_count: { $size: "$results" },
            schema_version: 1
        }
    },
    {
        $merge: {
            into: "lab_results",
            on: "order_id",
            whenMatched: "replace",
            whenNotMatched: "insert"
        }
    }
];

raw.aggregate(pipeline).toArray();
print("target documents after transform: " + target.countDocuments({}));

const counts = target.aggregate([
    { $group: { _id: "$status", orders: { $sum: 1 }, results: { $sum: "$result_count" } } },
    { $sort: { _id: 1 } }
]).toArray();
printjson(counts);

raw.drop();
print("dropped staging collection lab_results_raw");
