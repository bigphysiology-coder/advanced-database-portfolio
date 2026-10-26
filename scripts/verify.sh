#!/usr/bin/env bash
# ============================================================================
# Verify that the Docker environment is fully initialised.
# Portable counterpart to verify.ps1 — for macOS, Linux, WSL or Git Bash.
#
# Usage:  bash scripts/verify.sh
# Exit:   0 = all checks passed, 1 = something is wrong
# ============================================================================

set -uo pipefail
cd "$(dirname "$0")/.."

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
    mongo_ok=$(docker compose exec -T mongodb mongosh --quiet \
        --username portfolio --password portfolio \
        --authenticationDatabase admin \
        --eval "db.adminCommand({ ping: 1 }).ok" 2>/dev/null | tr -d '\r')
    if [ "$mongo_ok" = "1" ]; then pass "responding to authenticated ping"; else fail "unexpected response: '$mongo_ok'"; fi
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
