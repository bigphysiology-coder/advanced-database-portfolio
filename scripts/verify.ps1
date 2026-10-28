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
#   6. the P4 collection is present with the expected counts and indexes
#   7. the committed P4 evidence files are present
#
# Usage:
#   pwsh scripts/verify.ps1
#   pwsh scripts/verify.ps1 -Mongosh "C:\path\to\mongosh.exe"
#
# Exit code 0 = every check passed. 1 = something is wrong; the output says what.
#
# Note on row counts: the checks are "exactly this" for reference data and
# "at least this" for transactional data, so this script still passes after you
# start adding rows in Portfolio 2 and 3.
# ============================================================================

param(
    [string]$Mongosh = 'mongosh'
)

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
$deadline = (Get-Date).AddMinutes(12)
$settled = $false
while ((Get-Date) -lt $deadline) {
    try {
        $t = Query "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE';"
        $p = Query "SELECT count(*) FROM patient;"
        $a = Query "SELECT count(*) FROM appointment;"
        $r = Query "SELECT count(*) FROM lab_result;"
        if ($t -eq '21' -and [int]$p -ge 20000 -and [int]$a -ge 82000 -and [int]$r -ge 150000) {
            # The data is visible, but the entrypoint may still be shutting the
            # temporary server down. Wait through the restart and confirm the
            # real server still answers before declaring the load finished.
            Start-Sleep -Seconds 15
            $stable = Query "SELECT count(*) FROM lab_result;"
            if ([int]$stable -ge 150000) { $settled = $true; break }
        }
    } catch { }
    Start-Sleep -Seconds 3
}

if (-not $settled) {
    Fail "initialisation did not complete within 12 minutes"
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
    staff           = 86
    doctor_profile  = 50
    doctor_schedule = 250
}

$atLeast = [ordered]@{
    patient      = 20000
    next_of_kin  = 11500
    appointment  = 82000
    encounter    = 62000
    diagnosis    = 90000
    prescription = 120000
    lab_order    = 90000
    lab_result   = 150000
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
    # The official mongo image ships mongosh; a locally built fallback image
    # may not. Use the container shell when available, otherwise a host shell
    # supplied with -Mongosh.
    & docker exec portfolio-mongodb sh -c 'command -v mongosh >/dev/null 2>&1' 2>$null
    $script:mongoshInContainer = ($LASTEXITCODE -eq 0)
    $hostShell = Get-Command $Mongosh -ErrorAction SilentlyContinue
    $mongoUri = 'mongodb://portfolio:portfolio@localhost:27017/hospital_labs?authSource=admin'

    if (-not $script:mongoshInContainer -and $null -eq $hostShell) {
        Warn "mongosh not found in the container or on PATH; P4 collection checks skipped"
    } else {
        function Invoke-VerifyMongo([string]$Expression) {
            $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-mongo-" + [guid]::NewGuid().ToString('N') + ".js")
            Set-Content -Path $tempFile -Value $Expression -Encoding utf8
            try {
                if ($script:mongoshInContainer) {
                    docker cp $tempFile portfolio-mongodb:/tmp/verify-p4.js | Out-Null
                    $output = docker exec -T portfolio-mongodb mongosh --quiet `
                        --username portfolio --password portfolio `
                        --authenticationDatabase admin hospital_labs `
                        --file /tmp/verify-p4.js 2>&1
                    docker exec portfolio-mongodb rm -f /tmp/verify-p4.js *> $null
                }
                else {
                    $output = & $Mongosh --quiet $mongoUri --file $tempFile 2>&1
                }
                $code = $LASTEXITCODE
            }
            finally {
                Remove-Item $tempFile -ErrorAction SilentlyContinue
            }
            if ($code -ne 0) { throw (($output | ForEach-Object { "$_" }) -join "`n") }
            return @($output | ForEach-Object { "$_" })
        }

        try {
            $ping = (Invoke-VerifyMongo 'print(db.adminCommand({ ping: 1 }).ok)' | Select-Object -Last 1).Trim()
            if ($ping -eq '1') { Pass "responding to authenticated ping" }
            else { Fail "unexpected ping response: $ping" }

            $stats = Invoke-VerifyMongo @'
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
'@

            $line = @{}
            foreach ($item in $stats) {
                if ($item -match '^([a-z]+)=(.*)$') { $line[$matches[1]] = $matches[2] }
            }

            if ($line['exists'] -ne '1' -or [int]$line['documents'] -eq 0) {
                Warn "P4 collection not loaded; run: powershell -File scripts/load-p4.ps1"
            }
            else {
                if ([int]$line['documents'] -eq 93885) { Pass "lab_results documents = 93885" }
                else { Fail "lab_results documents = $($line['documents']), expected 93885 (reload P4)" }

                if ([int]$line['results'] -eq 163387) { Pass "embedded result rows = 163387" }
                else { Fail "embedded result rows = $($line['results']), expected 163387" }

                if ([int]$line['refs'] -eq 15200) { Pass "patient_refs documents = 15200" }
                else { Fail "patient_refs documents = $($line['refs']), expected 15200" }

                $expectedIndexes = @('ux_order_id', 'ix_patient_collected',
                    'ix_status_priority_collected', 'ix_result_flag_collected',
                    'ix_patient_analyte_collected', 'ix_collected')
                $actualIndexes = @($line['indexes'] -split ',' | Where-Object { $_ })
                $missing = @($expectedIndexes | Where-Object { $actualIndexes -notcontains $_ })
                if ($missing.Count -eq 0) { Pass "all six P4 indexes present" }
                else { Fail "missing P4 indexes: $($missing -join ', ')" }
            }
        } catch {
            Fail "MongoDB check failed: $_"
        }
    }
}

# ----------------------------------------------------------------------------
# 5b. Portfolio 4 artefacts
# ----------------------------------------------------------------------------
Section "Portfolio 4 artefacts"

$p4Files = @(
    'portfolio-4-nosql/model-design.md',
    'portfolio-4-nosql/README.md',
    'portfolio-4-nosql/sample-documents.json',
    'portfolio-4-nosql/evidence/00-environment.txt',
    'portfolio-4-nosql/evidence/01-load.txt',
    'portfolio-4-nosql/evidence/02-validator.txt',
    'portfolio-4-nosql/evidence/03-consistency.txt',
    'portfolio-4-nosql/evidence/04-queries.txt',
    'portfolio-4-nosql/evidence/05-compare-postgres.txt',
    'portfolio-4-nosql/evidence/06-collection-stats.txt',
    'portfolio-4-nosql/evidence/07-benchmark.txt'
)
$missingFiles = @($p4Files | Where-Object { -not (Test-Path (Join-Path $repoRoot $_)) })
if ($missingFiles.Count -eq 0) { Pass "11 P4 report and evidence files present" }
else { Fail "missing P4 files: $($missingFiles -join ', ')" }

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
