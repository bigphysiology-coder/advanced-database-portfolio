#!/usr/bin/env bash
# ============================================================================
# Verify that the Docker environment is fully initialised.
# Portable counterpart to verify.ps1 — for macOS, Linux, WSL or Git Bash.
#
# Checks containers, PostgreSQL schema/seed data, the MongoDB P4 collection
# when it is loaded, and the committed P4 and P5 report/evidence files.
#
# Usage:  bash scripts/verify.sh
#         MONGOSH=/path/to/mongosh bash scripts/verify.sh
# Exit:   0 = all checks passed, 1 = something is wrong
# ============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

MONGOSH=${MONGOSH:-mongosh}
MONGO_URI='mongodb://portfolio:portfolio@localhost:27017/hospital_labs?authSource=admin'

FAILURES=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
section() { printf '\n\033[36m%s\033[0m\n' "$1"; }

section "Containers"
pg_state=$(docker inspect --format '{{.State.Status}}' portfolio-postgres 2>/dev/null || echo missing)
if [ "$pg_state" = "running" ]; then
    pass "portfolio-postgres is running"
elif [ "$pg_state" = "missing" ]; then
    fail "portfolio-postgres does not exist. Run: docker compose up -d postgres"
else
    fail "portfolio-postgres is '$pg_state'. Check: docker compose logs postgres"
fi

# MongoDB is only needed from Portfolio 4 onwards; not running it is a warning.
MONGO_RUNNING=0
mongo_state=$(docker inspect --format '{{.State.Status}}' portfolio-mongodb 2>/dev/null || echo missing)
if [ "$mongo_state" = "running" ]; then
    pass "portfolio-mongodb is running"
    MONGO_RUNNING=1
elif [ "$mongo_state" = "missing" ]; then
    printf '  WARN  portfolio-mongodb not started (needed from Portfolio 4). Start: docker compose up -d mongodb\n'
else
    printf '  WARN  portfolio-mongodb is %s\n' "$mongo_state"
fi

if [ "$FAILURES" -gt 0 ]; then
    section "Result"
    printf '  Environment is not ready.\n'
    exit 1
fi

section "PostgreSQL"
ready=0
for _ in $(seq 1 90); do
    if docker compose exec -T postgres pg_isready -U portfolio -d hospital >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 2
done
if [ "$ready" -eq 1 ]; then pass "accepting connections"; else fail "not ready after 3 minutes"; fi

q() { docker compose exec -T postgres psql -U portfolio -d hospital -tAc "$1" 2>/dev/null | tr -d '\r'; }

# The entrypoint runs the init scripts against a temporary server, then restarts.
# "Ready" therefore does not mean "initialised"; wait for the data itself.
settled=0
for _ in $(seq 1 240); do
    t=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
    p=$(q "SELECT count(*) FROM patient;")
    a=$(q "SELECT count(*) FROM appointment;")
    r=$(q "SELECT count(*) FROM lab_result;")
    if [ "$t" = "21" ] && [ "${p:-0}" -ge 20000 ] && [ "${a:-0}" -ge 82000 ] && [ "${r:-0}" -ge 150000 ] 2>/dev/null; then
        # The entrypoint may still be shutting the temporary server down.
        # Wait through the restart and confirm the real server still answers.
        sleep 15
        r2=$(q "SELECT count(*) FROM lab_result;")
        if [ "${r2:-0}" -ge 150000 ] 2>/dev/null; then
            settled=1; break
        fi
    fi
    sleep 3
done
if [ "$settled" -eq 1 ]; then
    pass "initialisation complete (schema and seed data present)"
else
    fail "initialisation did not complete within 12 minutes"
    fail "inspect with: docker compose logs postgres"
fi

section "Schema"
tables=$(q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
if [ "$tables" = "21" ]; then pass "21 base tables present"; else fail "found '$tables' tables, expected 21"; fi

excl=$(q "SELECT count(*) FROM pg_constraint WHERE conname = 'no_double_booking';")
if [ "$excl" = "1" ]; then pass "double-booking exclusion constraint present"; else fail "no_double_booking missing"; fi

section "Seed data"
check_exact() {
    actual=$(q "SELECT count(*) FROM $1;")
    if [ "$actual" = "$2" ]; then pass "$1 = $actual"; else fail "$1 = '$actual', expected $2"; fi
}
check_min() {
    actual=$(q "SELECT count(*) FROM $1;")
    if [ "${actual:-0}" -ge "$2" ] 2>/dev/null; then pass "$1 = $actual (>= $2)"; else fail "$1 = '$actual', expected at least $2"; fi
}

check_exact department 10
check_exact ward 6
check_exact bed 60
check_exact icd_code 20
check_exact medication 15
check_exact test_catalogue 10
check_exact analyte 25
check_exact staff 86
check_exact doctor_profile 50
check_exact doctor_schedule 250

check_min patient 20000
check_min next_of_kin 11500
check_min appointment 82000
check_min encounter 62000
check_min diagnosis 90000
check_min prescription 120000
check_min lab_order 90000
check_min lab_result 150000

section "MongoDB"
if [ "$MONGO_RUNNING" -ne 1 ]; then
    printf '  WARN  skipped - container not running (required from Portfolio 4)\n'
else
    # The official mongo image ships mongosh; a locally built fallback image
    # may not. Prefer the container shell, then a host shell via MONGOSH.
    if docker exec portfolio-mongodb sh -c 'command -v mongosh >/dev/null 2>&1'; then
        MONGO_IN_CONTAINER=1
    else
        MONGO_IN_CONTAINER=0
    fi
    HOST_MONGO=$(command -v "$MONGOSH" 2>/dev/null || true)

    if [ "$MONGO_IN_CONTAINER" -ne 1 ] && [ -z "$HOST_MONGO" ]; then
        printf '  WARN  mongosh not found in the container or on PATH; P4 collection checks skipped\n'
    else
        run_mongo_file() {
            file=$1
            if [ "$MONGO_IN_CONTAINER" -eq 1 ]; then
                docker exec -i portfolio-mongodb mongosh --quiet \
                    --username portfolio --password portfolio \
                    --authenticationDatabase admin hospital_labs \
                    < "$file" 2>&1 | tr -d '\r'
            else
                "$MONGOSH" --quiet "$MONGO_URI" --file "$file" 2>&1 | tr -d '\r'
            fi
        }

        tmp_js=$(mktemp "${TMPDIR:-/tmp}/verify-p4.XXXXXX.js")
        trap 'rm -f "$tmp_js"' EXIT

        printf 'print(db.adminCommand({ ping: 1 }).ok)\n' > "$tmp_js"
        mongo_ok=$(run_mongo_file "$tmp_js" | tail -1)
        if [ "$mongo_ok" = "1" ]; then pass "responding to authenticated ping"; else fail "unexpected ping response: '$mongo_ok'"; fi

        cat > "$tmp_js" <<'JS'
const hasLab = db.getCollectionNames().indexOf("lab_results") >= 0;
const hasRefs = db.getCollectionNames().indexOf("patient_refs") >= 0;
const docs = hasLab ? db.lab_results.countDocuments({}) : 0;
const results = hasLab
    ? (db.lab_results.aggregate([{ $group: { _id: null, n: { $sum: "$result_count" } } }]).toArray()[0] || { n: 0 }).n
    : 0;
const refs = hasRefs ? db.patient_refs.countDocuments({}) : 0;
const indexes = hasLab ? db.lab_results.getIndexes().map(i => i.name).sort().join(",") : "";
print("exists=" + (hasLab ? 1 : 0));
print("documents=" + docs);
print("results=" + results);
print("refs=" + refs);
print("indexes=" + indexes);
JS
        mongo_stats=$(run_mongo_file "$tmp_js")

        mongo_field() { printf '%s\n' "$mongo_stats" | sed -n "s/^$1=//p" | tail -1; }
        exists=$(mongo_field exists)
        documents=$(mongo_field documents)
        results=$(mongo_field results)
        refs=$(mongo_field refs)
        indexes=$(mongo_field indexes)

        if [ "$exists" != "1" ] || [ "${documents:-0}" -eq 0 ] 2>/dev/null; then
            printf '  WARN  P4 collection not loaded; run: powershell -File scripts/load-p4.ps1\n'
        else
            if [ "$documents" = "93885" ]; then pass "lab_results documents = 93885"; else fail "lab_results documents = '$documents', expected 93885 (reload P4)"; fi
            if [ "$results" = "163387" ]; then pass "embedded result rows = 163387"; else fail "embedded result rows = '$results', expected 163387"; fi
            if [ "$refs" = "15200" ]; then pass "patient_refs documents = 15200"; else fail "patient_refs documents = '$refs', expected 15200"; fi

            missing_indexes=""
            for index in ux_order_id ix_patient_collected ix_status_priority_collected \
                         ix_result_flag_collected ix_patient_analyte_collected ix_collected; do
                case ",$indexes," in
                    *",$index,"*) ;;
                    *) missing_indexes="$missing_indexes $index" ;;
                esac
            done
            if [ -z "$missing_indexes" ]; then pass "all six P4 indexes present"; else fail "missing P4 indexes:$missing_indexes"; fi
        fi
    fi
fi

section "Portfolio 4 artefacts"
missing_p4=""
for file in \
    portfolio-4-nosql/model-design.md \
    portfolio-4-nosql/README.md \
    portfolio-4-nosql/sample-documents.json \
    portfolio-4-nosql/evidence/00-environment.txt \
    portfolio-4-nosql/evidence/01-load.txt \
    portfolio-4-nosql/evidence/02-validator.txt \
    portfolio-4-nosql/evidence/03-consistency.txt \
    portfolio-4-nosql/evidence/04-queries.txt \
    portfolio-4-nosql/evidence/05-compare-postgres.txt \
    portfolio-4-nosql/evidence/06-collection-stats.txt \
    portfolio-4-nosql/evidence/07-benchmark.txt; do
    [ -f "$file" ] || missing_p4="$missing_p4 $file"
done
if [ -z "$missing_p4" ]; then pass "11 P4 report and evidence files present"; else fail "missing P4 files:$missing_p4"; fi

section "Portfolio 5 artefacts"
missing_p5=""
for file in \
    portfolio-5-distributed-cloud/README.md \
    portfolio-5-distributed-cloud/architecture.md \
    portfolio-5-distributed-cloud/replication-setup.ps1 \
    portfolio-5-distributed-cloud/config/README.md \
    portfolio-5-distributed-cloud/config/primary.conf \
    portfolio-5-distributed-cloud/config/replica.conf \
    portfolio-5-distributed-cloud/config/pg_hba-replication.conf \
    portfolio-5-distributed-cloud/evidence/00-environment.txt \
    portfolio-5-distributed-cloud/evidence/01-setup.txt \
    portfolio-5-distributed-cloud/evidence/02-replication.txt \
    portfolio-5-distributed-cloud/evidence/03-lag.txt \
    portfolio-5-distributed-cloud/evidence/04-sync-vs-async.txt \
    portfolio-5-distributed-cloud/evidence/05-stale-read.txt \
    portfolio-5-distributed-cloud/evidence/06-configs.txt \
    portfolio-5-distributed-cloud/evidence/07-failover.txt \
    scripts/capture-p5.ps1; do
    [ -f "$file" ] || missing_p5="$missing_p5 $file"
done
if [ -z "$missing_p5" ]; then pass "16 P5 report, config and evidence files present"; else fail "missing P5 files:$missing_p5"; fi

section "Final documentation"
missing_final=""
for file in \
    final-documentation/README.md \
    final-documentation/portfolio-summary.md \
    final-documentation/portfolio-summary.pdf \
    final-documentation/reflection.md \
    docs/ai-use-declaration.md \
    scripts/export-summary.ps1; do
    [ -f "$file" ] || missing_final="$missing_final $file"
done
if [ -z "$missing_final" ]; then pass "6 final-documentation files present"; else fail "missing final-documentation files:$missing_final"; fi

placeholder=""
for file in README.md final-documentation/portfolio-summary.md docs/ai-use-declaration.md; do
    if grep -q '\[insert before submission\]' "$file" 2>/dev/null; then
        placeholder="$placeholder $file"
    fi
done
if [ -z "$placeholder" ]; then
    pass "matriculation number present in submission files"
else
    printf '  WARN  matriculation number placeholder remains in:%s\n' "$placeholder"
fi

section "Result"
if [ "$FAILURES" -eq 0 ]; then
    printf '  All checks passed. The database is seeded and ready.\n'
    printf '  Connect:  docker compose exec postgres psql -U portfolio -d hospital\n'
    exit 0
fi

printf '  %s check(s) failed.\n' "$FAILURES"
printf '  If the init scripts failed, rebuild the volume from scratch:\n'
printf '    docker compose down -v && docker compose up -d\n'
exit 1
