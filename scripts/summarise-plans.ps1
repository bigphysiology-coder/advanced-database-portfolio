<#
.SYNOPSIS
    Summarise a capture-plans.ps1 output file.

.DESCRIPTION
    Parses the "===== Qn run m =====" blocks, discards the first (cold-cache)
    run when more than one is present, and reports the median execution time,
    min, max, median planning time and the top plan node for each query.

    Also writes a CSV next to the input file so the numbers in the report can
    be traced back to a machine-readable artifact.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/summarise-plans.ps1 `
        -InputFile portfolio-2-query-optimisation/results/baseline.txt
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$InputFile
)

$ErrorActionPreference = 'Stop'

if (-not [System.IO.Path]::IsPathRooted($InputFile)) {
    $InputFile = Join-Path (Split-Path -Parent $PSScriptRoot) $InputFile
}
if (-not (Test-Path $InputFile)) { throw "Not found: $InputFile" }

$text = Get-Content -Raw $InputFile
$blockPattern = '(?s)===== (Q\d+) run (\d+) =====(.*?)(?====== Q\d+ run |\z)'
$blocks = [regex]::Matches($text, $blockPattern)

if ($blocks.Count -eq 0) { throw "No '===== Qn run m =====' blocks found in $InputFile" }

function Get-Median {
    param([double[]]$Values)
    $sorted = @($Values | Sort-Object)
    $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2 -eq 1) { return [double]$sorted[[int](($n - 1) / 2)] }
    return ([double]$sorted[$n / 2 - 1] + [double]$sorted[$n / 2]) / 2.0
}

$rows = @()
foreach ($b in $blocks) {
    $qid = $b.Groups[1].Value
    $run = [int]$b.Groups[2].Value
    $body = $b.Groups[3].Value

    $exec = [regex]::Match($body, 'Execution Time:\s*([0-9.]+)\s*ms')
    $plan = [regex]::Match($body, 'Planning Time:\s*([0-9.]+)\s*ms')
    $node = [regex]::Match($body, 'QUERY PLAN\s*\r?\n-+\r?\n\s*([A-Za-z][A-Za-z ]*?)\s+\(cost=')

    $rows += [pscustomobject]@{
        Query       = $qid
        Run         = $run
        ExecMs      = if ($exec.Success) { [double]$exec.Groups[1].Value } else { $null }
        PlanningMs  = if ($plan.Success) { [double]$plan.Groups[1].Value } else { $null }
        TopNode     = if ($node.Success) { $node.Groups[1].Value.Trim() } else { '' }
    }
}

$summary = @()
foreach ($group in ($rows | Group-Object Query | Sort-Object Name)) {
    $runs = @($group.Group | Sort-Object Run)
    $measured = if ($runs.Count -gt 1) { @($runs | Select-Object -Skip 1) } else { $runs }

    $execValues = @($measured | Where-Object { $null -ne $_.ExecMs } | ForEach-Object { $_.ExecMs })
    $planValues = @($measured | Where-Object { $null -ne $_.PlanningMs } | ForEach-Object { $_.PlanningMs })

    $summary += [pscustomobject]@{
        Query         = $group.Name
        Runs          = $runs.Count
        Used          = $execValues.Count
        MedianExecMs  = [math]::Round((Get-Median $execValues), 3)
        MinExecMs     = [math]::Round(($execValues | Measure-Object -Minimum).Minimum, 3)
        MaxExecMs     = [math]::Round(($execValues | Measure-Object -Maximum).Maximum, 3)
        MedianPlanMs  = [math]::Round((Get-Median $planValues), 3)
        TopNode       = ($measured | Select-Object -Last 1).TopNode
    }
}

$csvPath = [System.IO.Path]::ChangeExtension($InputFile, '.csv')
$summary | Export-Csv -Path $csvPath -NoTypeInformation -Encoding UTF8

Write-Output ''
Write-Output ('| Query | Runs | Median exec (ms) | Min | Max | Median planning (ms) | Top node |')
Write-Output ('|---|---:|---:|---:|---:|---:|---|')
foreach ($s in $summary) {
    Write-Output ('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f `
        $s.Query, $s.Runs, $s.MedianExecMs, $s.MinExecMs, $s.MaxExecMs, $s.MedianPlanMs, $s.TopNode)
}
Write-Output ''
Write-Output ("CSV: {0}" -f $csvPath)
