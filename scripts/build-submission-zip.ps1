#!/usr/bin/env pwsh
# ============================================================================
# Build the LMS submission ZIP from the committed repository.
#
# Why a committed-tree archive rather than Compress-Archive on the folder:
#   - .git/ is excluded automatically (history is not part of the submission)
#   - ignored artifacts are excluded (portfolio-4-nosql/data/ is 93 MB of
#     regenerable NDJSON; Docker volumes and ca_material are also ignored)
#   - the ZIP matches the public GitHub commit exactly
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-submission-zip.ps1
#
# Output:
#   dist/advanced-database-portfolio-submission.zip
# ============================================================================

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$zipPath = Join-Path $repoRoot 'dist/advanced-database-portfolio-submission.zip'
$prefix = 'advanced-database-portfolio/'

Push-Location $repoRoot
try {
    $dirty = @(git status --porcelain)
    if ($dirty.Count -gt 0) {
        throw ("The working tree has uncommitted changes. Commit them first so the " +
            "ZIP matches the public repository.`n" + ($dirty -join "`n"))
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $zipPath) -Force | Out-Null
    if (Test-Path $zipPath) { Remove-Item $zipPath -Force }

    git archive --format=zip --prefix=$prefix -o $zipPath HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) {
        throw "git archive failed to write $zipPath"
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $required = @(
            'README.md',
            'docker-compose.yml',
            'docs/case-study.md',
            'docs/ai-use-declaration.md',
            'final-documentation/README.md',
            'final-documentation/portfolio-summary.md',
            'final-documentation/portfolio-summary.pdf',
            'final-documentation/reflection.md',
            'portfolio-1-database-design/schema.sql',
            'portfolio-2-query-optimisation/execution-plans.md',
            'portfolio-3-transactions-concurrency/README.md',
            'portfolio-4-nosql/model-design.md',
            'portfolio-5-distributed-cloud/README.md'
        )
        $missing = @($required | Where-Object { $names -notcontains ($prefix + $_) })
        if ($missing.Count -gt 0) {
            throw "ZIP is missing required files: $($missing -join ', ')"
        }

        $sizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        Write-Host ""
        Write-Host "Wrote $zipPath"
        Write-Host ("Entries: {0}" -f $zip.Entries.Count)
        Write-Host ("Size:    {0} MB" -f $sizeMb)
        Write-Host "Required files present. The ZIP excludes .git, local data and ca_material."
    }
    finally {
        $zip.Dispose()
    }
}
finally {
    Pop-Location
}
