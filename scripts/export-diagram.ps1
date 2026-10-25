#!/usr/bin/env pwsh
# ============================================================================
# Export the Mermaid ER diagram to PNG.
#
# Uses the Chrome or Edge already installed on the machine, so mermaid-cli does
# not try to download a ~300 MB Chromium build.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export-diagram.ps1
#
# Input:  portfolio-1-database-design/er-diagram.md  (the ```mermaid block)
# Output: portfolio-1-database-design/er-diagram.png
# ============================================================================

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$mdPath = Join-Path $repoRoot 'portfolio-1-database-design/er-diagram.md'
$pngPath = Join-Path $repoRoot 'portfolio-1-database-design/er-diagram.png'

# --- locate a browser -------------------------------------------------------
$candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) {
    Write-Error "No Chrome or Edge installation found. Install one, or run mermaid-cli with its own Chromium."
    exit 1
}
$browser = $candidates[0]
Write-Host "Browser: $browser"

# --- extract the mermaid block ---------------------------------------------
$md = Get-Content -Raw $mdPath
if ($md -notmatch '(?s)```mermaid\r?\n(.*?)```') {
    Write-Error "No ```mermaid block found in $mdPath"
    exit 1
}
$diagram = $Matches[1].Trim()

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('er-' + [guid]::NewGuid().ToString('N') + '.mmd')
Set-Content -Path $tmp -Value $diagram -Encoding utf8

# --- render -----------------------------------------------------------------
$env:PUPPETEER_SKIP_DOWNLOAD = 'true'
$env:PUPPETEER_SKIP_CHROMIUM_DOWNLOAD = 'true'
$env:PUPPETEER_EXECUTABLE_PATH = $browser

try {
    # Windows PowerShell's npx.ps1 wrapper breaks on paths with spaces, so call
    # the .cmd shim directly there.
    $npx = if ($env:OS -eq 'Windows_NT') { 'npx.cmd' } else { 'npx' }

    & $npx --yes @mermaid-js/mermaid-cli@12 `
        -i $tmp `
        -o $pngPath `
        --size 2400 `
        -b white `
        --puppeteerConfigFile (Join-Path $PSScriptRoot 'puppeteer.json')

    if (-not (Test-Path $pngPath)) { throw "mermaid-cli did not produce $pngPath" }
}
finally {
    Remove-Item $tmp -ErrorAction SilentlyContinue
}

$info = Get-Item $pngPath
Write-Host ""
Write-Host "Wrote $($info.FullName)"
Write-Host ("Size: {0:N0} bytes" -f $info.Length)
