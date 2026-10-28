// ============================================================================
// Portfolio 4: validator evidence.
//
// Proves the lab_results collection accepts the documents the model allows and
// rejects the documents it does not. Each case prints PASS or FAIL with the
// MongoDB error code, so the evidence is the server's answer, not a claim.
//
// Run:
//   mongosh ... hospital_labs validation-tests.js
//
// The script cleans up after itself and is safe to re-run.
// ============================================================================

const TEST_PREFIX = "11111111-";

function cleanup() {
    const r = db.lab_results.deleteMany({ order_id: { $regex: "^" + TEST_PREFIX } });
    print("cleanup: removed " + r.deletedCount + " test document(s)");
}

function baseDoc(suffix) {
    return {
        order_id: TEST_PREFIX + "1111-4111-8111-11111111111" + suffix,
        encounter_id: "22222222-2222-4222-8222-222222222222",
        patient_id: "33333333-3333-4333-8333-333333333333",
        patient_mrn: "MRN-9999999",
        test_code: "LIPID",
        test_name: "Lipid Profile",
        specimen_type: "Blood",
        department: "Pathology and Laboratory",
        priority: "ROUTINE",
        status: "REPORTED",
        ordered_at: new Date("2026-09-01T08:00:00Z"),
        collected_at: new Date("2026-09-01T09:00:00Z"),
        reported_at: new Date("2026-09-01T15:00:00Z"),
        ordered_by: "44444444-4444-4444-8444-444444444444",
        results: [{
            analyte_id: NumberInt(1),
            analyte: "Total cholesterol",
            value: 5.8,
            value_type: "numeric",
            unit: "mmol/L",
            ref_low: 0.0,
            ref_high: 5.0,
            flag: "HIGH",
            resulted_at: new Date("2026-09-01T15:00:00Z"),
            resulted_by: "55555555-5555-4555-8555-555555555555"
        }],
        result_count: NumberInt(1),
        schema_version: NumberInt(1)
    };
}

function clone(doc) {
    return EJSON.parse(EJSON.stringify(doc));
}

let passed = 0;
let failed = 0;

function record(name, ok, detail) {
    if (ok) {
        passed++;
        print("PASS  " + name + (detail ? " (" + detail + ")" : ""));
    } else {
        failed++;
        print("FAIL  " + name + (detail ? " (" + detail + ")" : ""));
    }
}

const ERROR_NAMES = {
    121: "DocumentValidationFailure",
    11000: "DuplicateKey"
};

function errorDetail(e) {
    return "code " + e.code + " " + (e.codeName || ERROR_NAMES[e.code] || e.name || "error");
}

function expectAccept(name, doc) {
    try {
        db.lab_results.insertOne(doc);
        record(name, true, "accepted");
    } catch (e) {
        record(name, false, "rejected: " + errorDetail(e));
    }
}

function expectReject(name, doc, expectedCode) {
    try {
        db.lab_results.insertOne(doc);
        record(name, false, "accepted but should have been rejected");
    } catch (e) {
        const ok = e.code === expectedCode;
        record(name, ok, errorDetail(e));
    }
}

print("=== Validator tests: lab_results ===");
cleanup();

const valid = baseDoc("1");
expectAccept("valid REPORTED document with one result", valid);

const pending = clone(valid);
pending.order_id = TEST_PREFIX + "1111-4111-8111-111111111112";
pending.status = "IN_PROGRESS";
pending.reported_at = null;
pending.results = [];
pending.result_count = NumberInt(0);
expectAccept("IN_PROGRESS document with empty results", pending);

const missingField = clone(valid);
missingField.order_id = TEST_PREFIX + "1111-4111-8111-111111111113";
delete missingField.test_code;
expectReject("missing required test_code", missingField, 121);

const reportedEmpty = clone(valid);
reportedEmpty.order_id = TEST_PREFIX + "1111-4111-8111-111111111114";
reportedEmpty.results = [];
reportedEmpty.result_count = NumberInt(0);
expectReject("REPORTED with empty results", reportedEmpty, 121);

const stringDate = clone(valid);
stringDate.order_id = TEST_PREFIX + "1111-4111-8111-111111111115";
stringDate.ordered_at = "2026-09-01T08:00:00Z";
expectReject("ordered_at as a string, not a BSON date", stringDate, 121);

const badFlag = clone(valid);
badFlag.order_id = TEST_PREFIX + "1111-4111-8111-111111111116";
badFlag.results[0].flag = "ABNORMAL";
expectReject("result flag outside the closed enum", badFlag, 121);

const badMrn = clone(valid);
badMrn.order_id = TEST_PREFIX + "1111-4111-8111-111111111117";
badMrn.patient_mrn = "MRN-123";
expectReject("patient_mrn that does not match ^MRN-[0-9]{7}$", badMrn, 121);

const badCount = clone(valid);
badCount.order_id = TEST_PREFIX + "1111-4111-8111-111111111118";
badCount.result_count = NumberInt(-1);
expectReject("negative result_count", badCount, 121);

const duplicate = clone(valid);
expectReject("duplicate order_id", duplicate, 11000);

const badValueType = clone(valid);
badValueType.order_id = TEST_PREFIX + "1111-4111-8111-111111111119";
badValueType.results[0].value_type = "number";
expectReject("value_type outside the closed enum", badValueType, 121);

const nullResult = clone(valid);
nullResult.order_id = TEST_PREFIX + "1111-4111-8111-111111111120";
nullResult.results[0].resulted_at = null;
expectReject("result without a resulted_at date", nullResult, 121);

print("");
print("validator tests: " + passed + " passed, " + failed + " failed");
cleanup();

if (failed > 0) {
    throw new Error("validator tests failed");
}
