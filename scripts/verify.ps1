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

foreach ($svc in @('portfolio-postgres', 'portfolio-mongodb')) {
    $state = Get-ContainerState $svc
    if ($null -eq $state) {
        Fail "$svc does not exist. Run: docker compose up -d"
    } elseif ($state -ne 'running') {
        Fail "$svc is '$state', expected 'running'. Check: docker compose logs $svc"
    } else {
        Pass "$svc is running"
    }
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
    patient     = 500
    next_of_kin = 308
    appointment = 5700
    encounter   = 4470
    diagnosis   = 6652
    prescription = 8940
    lab_order   = 6652
    lab_result  = 11877
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
