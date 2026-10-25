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
for svc in portfolio-postgres portfolio-mongodb; do
    state=$(docker inspect --format '{{.State.Status}}' "$svc" 2>/dev/null || echo missing)
    if [ "$state" = "running" ]; then
        pass "$svc is running"
    elif [ "$state" = "missing" ]; then
        fail "$svc does not exist. Run: docker compose up -d"
    else
        fail "$svc is '$state'. Check: docker compose logs $svc"
    fi
done

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
check_exact staff 60
check_exact doctor_profile 50
check_exact doctor_schedule 250

check_min patient 500
check_min next_of_kin 308
check_min appointment 5700
check_min encounter 4470
check_min diagnosis 6652
check_min prescription 8940
check_min lab_order 6652
check_min lab_result 11877

section "MongoDB"
mongo_ok=$(docker compose exec -T mongodb mongosh --quiet \
    --username portfolio --password portfolio \
    --authenticationDatabase admin \
    --eval "db.adminCommand({ ping: 1 }).ok" 2>/dev/null | tr -d '\r')
if [ "$mongo_ok" = "1" ]; then pass "responding to authenticated ping"; else fail "unexpected response: '$mongo_ok'"; fi

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
