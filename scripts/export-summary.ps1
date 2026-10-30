#!/usr/bin/env pwsh
# ============================================================================
# Export the LMS portfolio summary to PDF.
#
# Uses the Chrome or Edge already installed on the machine, plus marked (via
# npx) to render Markdown. No LaTeX or Pandoc installation is required.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/export-summary.ps1
#
# Input:  final-documentation/portfolio-summary.md
# Output: final-documentation/portfolio-summary.pdf
# ============================================================================

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$mdPath = Join-Path $repoRoot 'final-documentation/portfolio-summary.md'
$pdfPath = Join-Path $repoRoot 'final-documentation/portfolio-summary.pdf'
$repoUrl = 'https://github.com/bigphysiology-coder/advanced-database-portfolio'

if (-not (Test-Path $mdPath)) {
    Write-Error "Missing $mdPath"
    exit 1
}

# --- locate a browser -------------------------------------------------------
$candidates = @(
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { $_ -and (Test-Path $_) }

if (-not $candidates) {
    Write-Error "No Chrome or Edge installation found. Install one to export the PDF."
    exit 1
}
$browser = $candidates[0]

# --- render Markdown to an HTML fragment -----------------------------------
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('summary-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
$bodyPath = Join-Path $tmpDir 'body.html'
$htmlPath = Join-Path $tmpDir 'summary.html'

try {
    $npx = if ($env:OS -eq 'Windows_NT') { 'npx.cmd' } else { 'npx' }
    & $npx --yes marked@18 --gfm -i $mdPath -o $bodyPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $bodyPath)) {
        throw "marked failed to render $mdPath"
    }

    $body = [System.IO.File]::ReadAllText($bodyPath, [System.Text.Encoding]::UTF8)

    # Rewrite relative Markdown links to the public repository so the PDF is
    # self-contained when the assessor clicks a path.
    $body = [regex]::Replace($body, 'href="(?!https?:|#|mailto:)([^"]+)"', {
        param($m)
        $link = $m.Groups[1].Value
        if ($link.StartsWith('../')) { $link = $link.Substring(3) }
        elseif ($link -notmatch '/') { $link = 'final-documentation/' + $link }
        $isDir = $link.EndsWith('/')
        $kind = if ($isDir) { 'tree' } else { 'blob' }
        return ('href="{0}/{1}/main/{2}"' -f $repoUrl, $kind, $link)
    })

    $css = @'
@page { size: A4; margin: 17mm 18mm 16mm 18mm; }
html { font-size: 10.4pt; }
body {
  font-family: "Segoe UI", Calibri, Arial, sans-serif;
  line-height: 1.30;
  color: #1b1b1b;
  margin: 0;
}
h1 { font-size: 19pt; line-height: 1.1; margin: 0 0 3mm; color: #12324a; }
h2 {
  font-size: 12.2pt;
  line-height: 1.2;
  margin: 5.2mm 0 1.6mm;
  padding-bottom: 0.8mm;
  border-bottom: 0.5pt solid #b8c4cc;
  color: #12324a;
  page-break-after: avoid;
}
p { margin: 0 0 2.1mm; text-align: justify; }
h2 + p { page-break-inside: avoid; }
ul, ol { margin: 0 0 2.1mm 5mm; padding: 0; }
li { margin-bottom: 0.9mm; }
a { color: #0b4f8a; text-decoration: none; }
code {
  font-family: Consolas, "Courier New", monospace;
  font-size: 8.9pt;
  background: #f1f3f4;
  padding: 0 0.45mm;
}
hr { border: 0; border-top: 0.6pt solid #8d9aa3; margin: 3.5mm 0; }
strong { color: #101010; }
'@

    $html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Portfolio Summary - MIT 8103</title>
<style>$css</style>
</head>
<body>
$body
</body>
</html>
"@
    [System.IO.File]::WriteAllText($htmlPath, $html, (New-Object System.Text.UTF8Encoding($false)))

    # --- print to PDF -------------------------------------------------------
    $profileDir = Join-Path $tmpDir 'chrome-profile'
    $htmlUri = ([System.Uri]$htmlPath).AbsoluteUri
    # Start-Process is used deliberately: invoking Chrome with & returns
    # immediately when an existing browser session is running, so the PDF is
    # not written by the time the script checks for it.
    $chromeArgs = @(
        '--headless',
        '--disable-gpu',
        '--no-sandbox',
        '--no-first-run',
        '--no-default-browser-check',
        '--disable-dev-shm-usage',
        "--user-data-dir=$profileDir",
        '--no-pdf-header-footer',
        ('--print-to-pdf="' + $pdfPath + '"'),
        '--virtual-time-budget=2000',
        $htmlUri
    )
    $proc = Start-Process -FilePath $browser -ArgumentList $chromeArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0 -or -not (Test-Path $pdfPath)) {
        throw "Chrome failed to write $pdfPath (exit $($proc.ExitCode))"
    }

    # Count page objects. PDF page dictionaries are normally uncompressed.
    $pdfText = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($pdfPath))
    $pageCount = ([regex]::Matches($pdfText, '/Type\s*/Page\b')).Count
    $sizeKb = [math]::Round((Get-Item $pdfPath).Length / 1KB, 1)

    Write-Host ""
    Write-Host "Wrote $pdfPath"
    Write-Host "Size: $sizeKb KB"
    if ($pageCount -gt 0) {
        Write-Host "Pages: $pageCount"
        if ($pageCount -lt 2 -or $pageCount -gt 3) {
            Write-Warning "Target is 2-3 pages; this PDF has $pageCount. Adjust the CSS or content."
            exit 2
        }
    } else {
        Write-Warning "Could not count pages automatically. Open the PDF and check it is 2-3 pages."
    }
}
finally {
    Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
