# ============================================================================
# Portfolio 4: build the MongoDB copy of the laboratory data.
#
#   1. export lab orders and patient IDs from PostgreSQL as NDJSON;
#   2. create the validated collection and its indexes;
#   3. import the NDJSON into a staging collection;
#   4. convert ISO strings to BSON dates and $merge into lab_results;
#   5. run the validator and cross-document consistency checks.
#
# The export is one line per lab order, with results embedded as an array. The
# source is the same seeded database used by Portfolios 1-3.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/load-p4.ps1
#   powershell ... -File scripts/load-p4.ps1 -Force -SkipTests
# ============================================================================
param(
    [switch]$Force,
    [switch]$SkipTests,
    [string]$Mongosh = 'mongosh'
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$p4Root   = Join-Path $repoRoot 'portfolio-4-nosql'
$dataDir  = Join-Path $p4Root 'data'
$pg       = 'portfolio-postgres'
$mongo    = 'portfolio-mongodb'
$uri      = 'mongodb://portfolio:portfolio@localhost:27017/hospital_labs?authSource=admin'

if (-not (Test-Path $dataDir)) {
    New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
}

function Assert-Container([string]$Name) {
    & docker inspect --format '{{.State.Status}}' $Name *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Container '$Name' does not exist. Run: docker compose up -d"
    }
    $state = (& docker inspect --format '{{.State.Status}}' $Name).Trim()
    if ($state -ne 'running') {
        throw "Container '$Name' is '$state', not running. Run: docker compose up -d"
    }
}

function Invoke-Docker([string[]]$Arguments) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    $lines = @($output | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw ("docker {0} failed with exit code {1}:{2}{3}" -f
            ($Arguments -join ' '), $code, [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }
    return $lines
}

function Export-PostgresQuery([string]$SqlFile, [string]$OutFile) {
    $containerPath = '/tmp/' + (Split-Path -Leaf $SqlFile)
    Invoke-Docker @('cp', $SqlFile, "$($pg):$containerPath") | Out-Null

    $errFile = $OutFile + '.err'
    $proc = Start-Process -FilePath 'docker' `
        -ArgumentList @('exec', '-i', $pg, 'psql', '-U', 'portfolio', '-d', 'hospital',
                        '-X', '-q', '-A', '-t', '-f', $containerPath) `
        -RedirectStandardOutput $OutFile `
        -RedirectStandardError $errFile `
        -NoNewWindow -Wait -PassThru

    if ($proc.ExitCode -ne 0) {
        $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
        throw "psql export failed with exit code $($proc.ExitCode): $err"
    }
    Remove-Item $errFile -ErrorAction SilentlyContinue

    $size = (Get-Item $OutFile).Length
    if ($size -eq 0) {
        throw "export produced an empty file: $OutFile"
    }
    Write-Host ("exported {0} ({1:N1} MB)" -f (Split-Path -Leaf $OutFile), ($size / 1MB))
}

function Invoke-MongoFile([string]$LocalFile) {
    $name = Split-Path -Leaf $LocalFile
    Write-Host "running $name"
    if ($script:mongoshInContainer) {
        $containerPath = "/tmp/$name"
        Invoke-Docker @('cp', $LocalFile, "$($mongo):$containerPath") | Out-Null
        return Invoke-Docker @('exec', $mongo, 'mongosh', '--quiet', $uri, '--file', $containerPath)
    }

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $Mongosh --quiet $uri --file $LocalFile 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    $lines = @($output | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw ("mongosh failed with exit code {0}:{1}{2}" -f
            $code, [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }
    return $lines
}

function Invoke-MongoEval([string]$Expression) {
    if ($script:mongoshInContainer) {
        return Invoke-Docker @('exec', $mongo, 'mongosh', '--quiet', $uri, '--eval', $Expression)
    }

    # Passing JavaScript through PowerShell to a native executable strips the
    # quotes around string literals, so write it to a file and use --file.
    $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("mongo-eval-" + [guid]::NewGuid().ToString('N') + ".js")
    Set-Content -Path $tempFile -Value $Expression -Encoding utf8
    try {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $Mongosh --quiet $uri --file $tempFile 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $oldPreference
        }
    }
    finally {
        Remove-Item $tempFile -ErrorAction SilentlyContinue
    }

    $lines = @($output | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw ("mongosh --file failed with exit code {0}:{1}{2}" -f
            $code, [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }
    return $lines
}

Write-Host '=== Portfolio 4 loader ==='
Assert-Container $pg
Assert-Container $mongo

# The official mongo image ships mongosh. A locally built server image may not,
# so the loader uses the host shell against the published port instead of
# failing half-way through the load.
& docker exec $mongo sh -c 'command -v mongosh >/dev/null 2>&1' 2>$null
$script:mongoshInContainer = ($LASTEXITCODE -eq 0)
if ($script:mongoshInContainer) {
    Write-Host 'mongosh: inside the container'
}
else {
    Write-Host "mongosh: host binary ($Mongosh) -> localhost:27017"
}

# ----------------------------------------------------------------------------
# 1. Export
# ----------------------------------------------------------------------------
$labFile   = Join-Path $dataDir 'lab_results.ndjson'
$refsFile  = Join-Path $dataDir 'patient_refs.ndjson'

if ($Force -or -not (Test-Path $labFile)) {
    Export-PostgresQuery (Join-Path $p4Root 'export-lab-results.sql') $labFile
}
else {
    Write-Host "using existing $labFile (use -Force to re-export)"
}

if ($Force -or -not (Test-Path $refsFile)) {
    Export-PostgresQuery (Join-Path $p4Root 'export-patient-refs.sql') $refsFile
}
else {
    Write-Host "using existing $refsFile (use -Force to re-export)"
}

$expectedOrders = [int](& docker exec $pg psql -U portfolio -d hospital -X -tA -c 'select count(*) from lab_order')
$expectedRefs   = [int](& docker exec $pg psql -U portfolio -d hospital -X -tA -c 'select count(distinct e.patient_id) from encounter e join lab_order lo using (encounter_id)')
Write-Host "source: $expectedOrders lab orders, $expectedRefs patients with lab orders"

# ----------------------------------------------------------------------------
# 2. Collection, validator and indexes
# ----------------------------------------------------------------------------
Invoke-MongoFile (Join-Path $p4Root 'mongodb-setup.js') | ForEach-Object { Write-Host $_ }

# ----------------------------------------------------------------------------
# 3. Import into the staging collection
# ----------------------------------------------------------------------------
Invoke-MongoEval 'db.lab_results_raw.drop()' | ForEach-Object { Write-Host $_ }

# The staging loader reads the file from disk. Inside the container that is
# /tmp; from the host it is the exported Windows path passed via env var.
$env:LAB_NDJSON = $labFile
$env:PATIENT_REFS_NDJSON = $refsFile
if ($script:mongoshInContainer) {
    Invoke-Docker @('cp', $labFile, "$($mongo):/tmp/lab_results.ndjson") | Out-Null
    Invoke-Docker @('cp', $refsFile, "$($mongo):/tmp/patient_refs.ndjson") | Out-Null
}

& docker exec $mongo sh -c 'command -v mongoimport >/dev/null 2>&1'
$hasMongoimport = ($LASTEXITCODE -eq 0)

if ($hasMongoimport) {
    Write-Host 'importing lab_results_raw with mongoimport'
    Invoke-Docker @('exec', $mongo, 'mongoimport',
        "--uri=$uri", '--collection=lab_results_raw',
        '--file=/tmp/lab_results.ndjson', '--numInsertionWorkers=2') | ForEach-Object { Write-Host $_ }

    Write-Host 'importing patient_refs with mongoimport'
    Invoke-MongoEval 'db.patient_refs.deleteMany({})' | ForEach-Object { Write-Host $_ }
    Invoke-Docker @('exec', $mongo, 'mongoimport',
        "--uri=$uri", '--collection=patient_refs',
        '--file=/tmp/patient_refs.ndjson', '--mode=upsert', '--upsertFields=_id') | ForEach-Object { Write-Host $_ }
}
else {
    Write-Host 'mongoimport not present; importing lab_results_raw with mongosh'
    Invoke-MongoFile (Join-Path $p4Root 'load-ndjson.js') | ForEach-Object { Write-Host $_ }

    Write-Host 'importing patient_refs with mongosh'
    Invoke-MongoEval @'
const fs = require("fs");
const source = process.env.PATIENT_REFS_NDJSON || "/tmp/patient_refs.ndjson";
const lines = fs.readFileSync(source, "utf8").split("\n").filter(l => l.trim());
db.patient_refs.deleteMany({});
for (const line of lines) { db.patient_refs.insertOne(EJSON.parse(line)); }
print("patient_refs documents: " + db.patient_refs.countDocuments({}));
'@ | ForEach-Object { Write-Host $_ }
}

$rawCount = [int](Invoke-MongoEval 'print(db.lab_results_raw.countDocuments({}))' | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
$refCount = [int](Invoke-MongoEval 'print(db.patient_refs.countDocuments({}))' | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
Write-Host "staged: $rawCount lab orders, $refCount patient references"

if ($rawCount -ne $expectedOrders) {
    throw "staging count $rawCount does not match PostgreSQL $expectedOrders"
}
if ($refCount -ne $expectedRefs) {
    throw "patient_refs count $refCount does not match PostgreSQL $expectedRefs"
}

# ----------------------------------------------------------------------------
# 4. Transform and merge
#
# Building five secondary indexes while inserting 93,885 documents makes the
# merge pay index maintenance on every write. Keep ux_order_id (the $merge key
# must be unique) and drop the rest; mongodb-setup.js recreates them after the
# load. This is an ETL detail, not a schema change: the final collection has
# exactly the indexes defined in mongodb-setup.js.
# ----------------------------------------------------------------------------
Invoke-MongoEval @'
const keep = new Set(["_id_", "ux_order_id"]);
const dropped = [];
db.lab_results.getIndexes().forEach(function (index) {
    if (!keep.has(index.name)) {
        db.lab_results.dropIndex(index.name);
        dropped.push(index.name);
    }
});
print("dropped before bulk merge: " + (dropped.length ? dropped.join(", ") : "none"));
'@ | ForEach-Object { Write-Host $_ }

Invoke-MongoFile (Join-Path $p4Root 'transform-lab-results.js') | ForEach-Object { Write-Host $_ }

Write-Host 'recreating the secondary indexes'
Invoke-MongoFile (Join-Path $p4Root 'mongodb-setup.js') | ForEach-Object { Write-Host $_ }

# ----------------------------------------------------------------------------
# 5. Checks
# ----------------------------------------------------------------------------
if (-not $SkipTests) {
    Write-Host ''
    Write-Host '=== Validator tests ==='
    Invoke-MongoFile (Join-Path $p4Root 'validation-tests.js') | ForEach-Object { Write-Host $_ }

    Write-Host ''
    Write-Host '=== Consistency checks ==='
    Invoke-MongoFile (Join-Path $p4Root 'consistency-checks.js') | ForEach-Object { Write-Host $_ }
}

Write-Host ''
Write-Host 'Portfolio 4 load complete.'
