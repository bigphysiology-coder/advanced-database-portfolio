<#
.SYNOPSIS
    Capture the Portfolio 4 evidence from the running MongoDB and PostgreSQL
    containers.

.DESCRIPTION
    Writes raw command output to portfolio-4-nosql/evidence/. Each file records
    the step, the timestamp, the full output and the elapsed time, so the
    figures quoted in the report can be traced back to a command.

    Steps:
      00-environment.txt     versions, container state, source counts
      01-load.txt            export -> create -> import -> transform
      02-validator.txt       accepted and rejected documents with error codes
      03-consistency.txt     cross-document and cross-store checks
      04-queries.txt         Q1-Q6 including explain("executionStats")
      05-compare-postgres.txt the relational equivalents, with \timing
      06-collection-stats.txt BSON size, per-index size, document sizes
      07-benchmark.txt       warm-up + five timed runs per query (median)

    The loader is destructive: it re-exports from PostgreSQL and replaces the
    MongoDB collection. That is deliberate; it proves the pipeline rather than
    capturing a hand-edited database.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p4.ps1
#>
param(
    [string]$EvidenceDir = 'portfolio-4-nosql/evidence',
    [string]$Mongosh = 'mongosh',
    [string]$MongoUri = 'mongodb://portfolio:portfolio@localhost:27017/hospital_labs?authSource=admin',
    [switch]$SkipLoad
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$p4Root   = Join-Path $repoRoot 'portfolio-4-nosql'
$evidence = Join-Path $repoRoot $EvidenceDir

if (-not (Test-Path $evidence)) {
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
}

function Assert-Container([string]$Name) {
    $state = (& docker inspect --format '{{.State.Status}}' $Name 2>$null)
    if ($LASTEXITCODE -ne 0 -or $state.Trim() -ne 'running') {
        throw "Container '$Name' is not running. Run: docker compose up -d"
    }
}

function Invoke-Mongo([string[]]$Arguments) {
    # PowerShell strips the quotes from a JavaScript string passed to a native
    # executable through --eval. Route evals through a temporary .js file.
    if ($Arguments.Length -ge 2 -and $Arguments[0] -eq '--eval') {
        $tempFile = Join-Path ([System.IO.Path]::GetTempPath()) ("mongo-eval-" + [guid]::NewGuid().ToString('N') + ".js")
        Set-Content -Path $tempFile -Value $Arguments[1] -Encoding utf8
        try {
            & $Mongosh --quiet $MongoUri --file $tempFile
        }
        finally {
            Remove-Item $tempFile -ErrorAction SilentlyContinue
        }
    }
    else {
        & $Mongosh --quiet $MongoUri @Arguments
    }
    if ($LASTEXITCODE -ne 0) {
        throw "mongosh exited with $LASTEXITCODE"
    }
}

$script:failures = 0

function Invoke-Step {
    param(
        [string]$FileName,
        [string]$Title,
        [scriptblock]$Body
    )

    $path = Join-Path $evidence $FileName
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("=== $Title ===")
    $lines.Add("captured: " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss K'))
    $lines.Add("host: " + $env:COMPUTERNAME)
    $lines.Add("")

    Write-Host ''
    Write-Host "=== $Title ==="
    $started = Get-Date
    $exit = 0

    try {
        $output = & $Body *>&1
        foreach ($line in $output) {
            $text = "$line"
            $lines.Add($text)
            Write-Host $text
        }
    } catch {
        $exit = 1
        $message = "ERROR: $($_.Exception.Message)"
        $lines.Add($message)
        Write-Host $message -ForegroundColor Red
    }

    $elapsed = ((Get-Date) - $started).TotalSeconds
    $lines.Add("")
    $lines.Add(("exit: {0} (elapsed {1:N1}s)" -f $exit, $elapsed))
    $lines | Set-Content -Path $path -Encoding utf8

    if ($exit -ne 0) {
        $script:failures++
        throw "step failed: $Title (see $path)"
    }
}

Write-Host '=== Portfolio 4 evidence capture ==='
Assert-Container 'portfolio-postgres'
Assert-Container 'portfolio-mongodb'

Invoke-Step '00-environment.txt' 'Environment and source counts' {
    docker version --format 'client {{.Client.Version}} server {{.Server.Version}}'
    docker ps --filter name=portfolio- --format '{{.Names}} {{.Image}} {{.Status}}'
    docker exec portfolio-mongodb mongod --version | Select-Object -First 2
    docker exec portfolio-postgres psql -U portfolio -d hospital -X -tA -c 'select version()' |
        Select-Object -First 1
    docker exec portfolio-postgres psql -U portfolio -d hospital -X -tA -F '|' -c @'
select 'patients', count(*) from patient
union all select 'encounters', count(*) from encounter
union all select 'lab_orders', count(*) from lab_order
union all select 'lab_results', count(*) from lab_result
union all select 'patients_with_lab_orders',
    count(distinct e.patient_id) from encounter e join lab_order lo using (encounter_id)
order by 1;
'@
}

if (-not $SkipLoad) {
    Invoke-Step '01-load.txt' 'PostgreSQL export, MongoDB import and transform' {
        & (Join-Path $PSScriptRoot 'load-p4.ps1') -Force -SkipTests -Mongosh $Mongosh
        if ($LASTEXITCODE -ne 0) { throw "load-p4.ps1 exited with $LASTEXITCODE" }
    }
}

Invoke-Step '02-validator.txt' 'Validator: accepted and rejected documents' {
    Invoke-Mongo @('--file', (Join-Path $p4Root 'validation-tests.js'))
}

Invoke-Step '03-consistency.txt' 'Cross-document consistency checks' {
    Invoke-Mongo @('--file', (Join-Path $p4Root 'consistency-checks.js'))
}

Invoke-Step '04-queries.txt' 'Query patterns Q1-Q6 with executionStats' {
    Invoke-Mongo @('--file', (Join-Path $p4Root 'queries.js'))
}

Invoke-Step '05-compare-postgres.txt' 'PostgreSQL equivalents with \timing' {
    $sql = Join-Path $p4Root 'compare-postgres.sql'
    docker cp $sql portfolio-postgres:/tmp/compare-postgres.sql | Out-Null
    docker exec portfolio-postgres psql -U portfolio -d hospital -X -f /tmp/compare-postgres.sql
    if ($LASTEXITCODE -ne 0) { throw "psql exited with $LASTEXITCODE" }
}

Invoke-Step '06-collection-stats.txt' 'Collection and index sizes' {
    Invoke-Mongo @('--eval', @'
const s = db.lab_results.stats();
printjson({
  documents: s.count,
  averageDocumentBytes: Math.round(s.avgObjSize),
  collectionBytes: s.size,
  storageBytes: s.storageSize,
  totalIndexBytes: s.totalIndexSize,
  indexSizes: s.indexSizes,
  indexes: db.lab_results.getIndexes().map(i => ({ name: i.name, key: i.key }))
});
printjson({
  patient_refs: db.patient_refs.countDocuments({}),
  patient_refs_indexes: db.patient_refs.getIndexes().map(i => i.name)
});
'@)
}

Invoke-Step '07-benchmark.txt' 'Steady-state MongoDB timings (median of five runs)' {
    Invoke-Mongo @('--file', (Join-Path $p4Root 'benchmark.js'))
}

# The representative documents are evidence too, and are small enough to keep
# in the repository as a readable JSON file. This one is written as pure JSON,
# not wrapped in a capture header, so it can be re-imported.
Write-Host ''
Write-Host '=== Representative documents ==='
$samples = & $Mongosh --quiet $MongoUri --file (Join-Path $p4Root 'export-samples.js')
if ($LASTEXITCODE -ne 0) {
    throw "export-samples.js exited with $LASTEXITCODE"
}
$samplesPath = Join-Path $p4Root 'sample-documents.json'
$samples | Set-Content -Path $samplesPath -Encoding utf8
$samples | ConvertFrom-Json | Out-Null
Write-Host "wrote $samplesPath ($((Get-Item $samplesPath).Length) bytes)"

Write-Host ''
if ($script:failures -gt 0) {
    throw "$($script:failures) evidence step(s) failed"
}
Write-Host "Evidence written to $evidence"
