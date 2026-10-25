#!/usr/bin/env pwsh
# ============================================================================
# Verify that the Docker environment is fully initialised.
#
# Checks:
#   1. both containers exist and are running
#   2. PostgreSQL accepts connections and reports healthy
#   3. the schema init ran (required tables and the exclusion constraint exist)
#   4. seed data reached the expected row counts
#   5. MongoDB accepts an authenticated connection
#
# Usage:
#   pwsh scripts/verify.ps1
#
# Exit code 0 = every check passed. 1 = something is wrong; the output says what.
#
# Note on row counts: the checks are "exactly this" for reference data and
# "at least this" for transactional data, so this script still passes after you
# start adding rows in Portfolio 2 and 3.
# ============================================================================

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot

$script:failures = 0
$script:warnings = 0

function Pass($msg) { Write-Host "  PASS  $msg" -ForegroundColor Green }
function Fail($msg) { Write-Host "  FAIL  $msg" -ForegroundColor Red; $script:failures++ }
function Warn($msg) { Write-Host "  WARN  $msg" -ForegroundColor Yellow; $script:warnings++ }
function Section($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }

# ----------------------------------------------------------------------------
# 1. Containers
# ----------------------------------------------------------------------------
Section "Containers"

function Get-ContainerState([string]$name) {
    try {
        $state = docker inspect --format '{{.State.Status}}' $name 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return "$state".Trim()
    } catch {
        return $null
    }
}

$postgresState = Get-ContainerState 'portfolio-postgres'
if ($null -eq $postgresState) {
    Fail "portfolio-postgres does not exist. Run: docker compose up -d postgres"
} elseif ($postgresState -ne 'running') {
    Fail "portfolio-postgres is '$postgresState'. Check: docker compose logs postgres"
} else {
    Pass "portfolio-postgres is running"
}

# MongoDB is only needed from Portfolio 4 onwards, and its image is ~300 MB.
# Not running it is a warning, not a failure.
$script:mongoRunning = $false
$mongoState = Get-ContainerState 'portfolio-mongodb'
if ($null -eq $mongoState) {
    Warn "portfolio-mongodb not started (needed from Portfolio 4). Start: docker compose up -d mongodb"
} elseif ($mongoState -ne 'running') {
    Warn "portfolio-mongodb is '$mongoState'"
} else {
    Pass "portfolio-mongodb is running"
    $script:mongoRunning = $true
}

if ($script:failures -gt 0) {
    Section "Result"
    Write-Host "  Environment is not ready. Fix the failures above." -ForegroundColor Red
    Pop-Location
    exit 1
}

# ----------------------------------------------------------------------------
# 2. PostgreSQL readiness
# ----------------------------------------------------------------------------
Section "PostgreSQL"

$deadline = (Get-Date).AddMinutes(3)
$ready = $false
while ((Get-Date) -lt $deadline) {
    try {
        docker compose exec -T postgres pg_isready -U portfolio -d hospital *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 2
}

if (-not $ready) {
    Fail "PostgreSQL did not become ready within 3 minutes"
    Section "Result"
    Write-Host "  Environment is not ready." -ForegroundColor Red
    Pop-Location
    exit 1
}
Pass "accepting connections"

function Query([string]$sql) {
    $out = docker compose exec -T postgres psql -U portfolio -d hospital -tAc $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($out -join "`n") }
    return ($out -join "`n").Trim()
}

# The PostgreSQL entrypoint starts a temporary server to run the init scripts, then
# stops it and starts the real one. Both accept connections, so "ready" is not the
# same as "initialised". Wait until the expected schema and data actually exist
# instead of trusting the first successful connection.
$deadline = (Get-Date).AddMinutes(5)
$settled = $false
while ((Get-Date) -lt $deadline) {
    try {
        $t = Query "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
        $p = Query "SELECT count(*) FROM patient;"
        if ($t -eq '21' -and [int]$p -ge 500) { $settled = $true; break }
    } catch { }
    Start-Sleep -Seconds 3
}

if (-not $settled) {
    Fail "initialisation did not complete within 5 minutes"
    Fail "inspect with: docker compose logs postgres"
} else {
    Pass "initialisation complete (schema and seed data present)"
}

# ----------------------------------------------------------------------------
# 3. Schema initialised
# ----------------------------------------------------------------------------
Section "Schema"

try {
    $tableCount = [int](Query "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';")
    if ($tableCount -eq 21) { Pass "21 base tables present" }
    else { Fail "found $tableCount base tables, expected 21 - the init script may have failed partway" }

    $excl = Query "SELECT count(*) FROM pg_constraint WHERE conname = 'no_double_booking';"
    if ($excl -eq '1') { Pass "double-booking exclusion constraint present" }
    else { Fail "no_double_booking constraint missing" }
} catch {
    Fail "could not inspect the schema: $_"
}

# ----------------------------------------------------------------------------
# 4. Seed data
# ----------------------------------------------------------------------------
Section "Seed data"

$exact = [ordered]@{
    department      = 10
    ward            = 6
    bed             = 60
    icd_code        = 20
    medication      = 15
    test_catalogue  = 10
    analyte         = 25
    staff           = 60
    doctor_profile  = 50
    doctor_schedule = 250
}

$atLeast = [ordered]@{
    patient      = 500
    next_of_kin  = 280
    appointment  = 5700
    encounter    = 4470
    diagnosis    = 6400
    prescription = 8940
    lab_order    = 6400
    lab_result   = 11000
}

try {
    foreach ($t in $exact.Keys) {
        $actual = [int](Query "SELECT count(*) FROM $t;")
        if ($actual -eq $exact[$t]) { Pass "$t = $actual" }
        else { Fail "$t = $actual, expected $($exact[$t])" }
    }
    foreach ($t in $atLeast.Keys) {
        $actual = [int](Query "SELECT count(*) FROM $t;")
        if ($actual -ge $atLeast[$t]) { Pass "$t = $actual (>= $($atLeast[$t]))" }
        else { Fail "$t = $actual, expected at least $($atLeast[$t])" }
    }
} catch {
    Fail "seed data query failed: $_"
}

# ----------------------------------------------------------------------------
# 5. MongoDB
# ----------------------------------------------------------------------------
Section "MongoDB"

if (-not $script:mongoRunning) {
    Warn "skipped - container not running (required from Portfolio 4)"
} else {
    try {
        $ok = docker compose exec -T mongodb mongosh --quiet `
                --username portfolio --password portfolio `
                --authenticationDatabase admin `
                --eval "db.adminCommand({ ping: 1 }).ok" 2>&1
        if (("$ok".Trim()) -eq '1') { Pass "responding to authenticated ping" }
        else { Fail "unexpected response: $ok" }
    } catch {
        Fail "could not reach MongoDB: $_"
    }
}

# ----------------------------------------------------------------------------
# Result
# ----------------------------------------------------------------------------
Section "Result"

if ($script:failures -eq 0) {
    Write-Host "  All checks passed. The database is seeded and ready." -ForegroundColor Green
    Write-Host "  Connect:  docker compose exec postgres psql -U portfolio -d hospital"
    Pop-Location
    exit 0
}

Write-Host "  $($script:failures) check(s) failed." -ForegroundColor Red
Write-Host "  If the init scripts failed, rebuild the volume from scratch:"
Write-Host "    docker compose down -v"
Write-Host "    docker compose up -d"
Pop-Location
exit 1
