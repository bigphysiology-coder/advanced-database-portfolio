<#
.SYNOPSIS
    Capture EXPLAIN (ANALYZE, BUFFERS) plans for the Portfolio 2 queries.

.DESCRIPTION
    Reads the six queries from queries.sql (between the -- >>> Qn and -- <<< Qn
    markers), prefixes each with EXPLAIN, and runs it a configurable number of
    times. Output is written to results/ so the baseline and every post-index
    run are produced by exactly the same procedure.

    The first run is deliberately kept in the file: it is the cold-cache run.
    summarise-plans.ps1 discards it and reports the median of the rest.

.PARAMETER Database
    Database to measure. Default: hospital.

.PARAMETER Output
    Path for the raw output. Default: results/<timestamp>-plans.txt.

.PARAMETER Runs
    Number of executions per query. Default: 5.

.PARAMETER Only
    Optional comma-separated query IDs, e.g. Q1,Q2. Default: all six.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
        -Output portfolio-2-query-optimisation/results/baseline.txt

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-plans.ps1 `
        -Only Q1 -Output portfolio-2-query-optimisation/results/after-q1.txt
#>
param(
    [string]$Database = 'hospital',
    [string]$Output,
    [int]$Runs = 5,
    [string]$Only = ''
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$queriesPath = Join-Path $repoRoot 'portfolio-2-query-optimisation/queries.sql'
$resultsDir = Join-Path $repoRoot 'portfolio-2-query-optimisation/results'

if (-not $Output) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Output = Join-Path $resultsDir "$stamp-plans.txt"
} elseif (-not [System.IO.Path]::IsPathRooted($Output)) {
    $Output = Join-Path $repoRoot $Output
}

if (-not (Test-Path $queriesPath)) { throw "Not found: $queriesPath" }
if (-not (Test-Path $resultsDir)) { New-Item -ItemType Directory -Path $resultsDir | Out-Null }
if (-not (Test-Path (Split-Path -Parent $Output))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Output) | Out-Null
}

# --- extract the marked query blocks ---------------------------------------
$content = Get-Content -Raw $queriesPath
$pattern = '(?s)-- >>> (Q\d+)\r?\n(.*?)\r?\n-- <<< \1'
$found = [regex]::Matches($content, $pattern)

if ($found.Count -eq 0) { throw "No -- >>> Qn markers found in $queriesPath" }

$wanted = @()
if ($Only) {
    $wanted = $Only.Split(',') | ForEach-Object { $_.Trim().ToUpper() } | Where-Object { $_ }
}

$selected = @()
foreach ($m in $found) {
    $id = $m.Groups[1].Value
    if ($wanted.Count -eq 0 -or $wanted -contains $id) {
        $selected += [pscustomobject]@{
            Id    = $id
            Query = $m.Groups[2].Value.Trim()
        }
    }
}

if ($selected.Count -eq 0) { throw "None of the requested queries were found: $Only" }

# --- build one psql script --------------------------------------------------
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('SET TIME ZONE ''UTC'';')
[void]$sb.AppendLine("\echo '============================================================'")
[void]$sb.AppendLine("\echo 'Portfolio 2 - execution plans'")
[void]$sb.AppendLine("\echo 'Database: $Database'")
[void]$sb.AppendLine("\echo 'Captured: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))'")
[void]$sb.AppendLine("\echo 'Runs per query: $Runs (summariser discards run 1)'")
[void]$sb.AppendLine("\echo '============================================================'")
[void]$sb.AppendLine("\echo ''")
[void]$sb.AppendLine("\echo 'Server:'")
[void]$sb.AppendLine('SELECT version();')
[void]$sb.AppendLine("\echo ''")
[void]$sb.AppendLine("\echo 'Dataset:'")
[void]$sb.AppendLine(@'
SELECT 'appointment' AS relation, count(*) FROM appointment
UNION ALL SELECT 'encounter', count(*) FROM encounter
UNION ALL SELECT 'diagnosis', count(*) FROM diagnosis
UNION ALL SELECT 'lab_order', count(*) FROM lab_order
UNION ALL SELECT 'lab_result', count(*) FROM lab_result
UNION ALL SELECT 'patient', count(*) FROM patient
ORDER BY relation;
'@)
[void]$sb.AppendLine("\echo ''")

$started = Get-Date
foreach ($q in $selected) {
    for ($i = 1; $i -le $Runs; $i++) {
        [void]$sb.AppendLine("\echo '===== $($q.Id) run $i ====='")
        [void]$sb.AppendLine("EXPLAIN (ANALYZE, BUFFERS, TIMING) $($q.Query)")
        [void]$sb.AppendLine('')
    }
}

$sql = $sb.ToString()

# --- run it ----------------------------------------------------------------
Write-Host ("Capturing {0} x {1} run(s) against '{2}'..." -f $selected.Count, $Runs, $Database)

$raw = $null
Push-Location $repoRoot
try {
    $raw = $sql | docker compose exec -T postgres psql -U portfolio -d $Database -v ON_ERROR_STOP=1 -f - 2>&1
    $exit = $LASTEXITCODE
}
finally {
    Pop-Location
}

$lines = @($raw | ForEach-Object { "$_" })
[System.IO.File]::WriteAllLines($Output, $lines, (New-Object System.Text.UTF8Encoding($false)))

if ($exit -ne 0) {
    $tail = $lines | Select-Object -Last 25
    throw ("psql failed with exit code {0}.{1}{2}" -f $exit, [Environment]::NewLine, ($tail -join [Environment]::NewLine))
}

$info = Get-Item $Output
$elapsed = (Get-Date) - $started
Write-Host ("Wrote {0}" -f $info.FullName)
Write-Host ("Size: {0:N0} bytes; elapsed: {1:N1} s" -f $info.Length, $elapsed.TotalSeconds)
Write-Host ("Now run: scripts/summarise-plans.ps1 -InputFile '{0}'" -f $Output)
