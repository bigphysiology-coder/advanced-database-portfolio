#!/usr/bin/env pwsh
# ============================================================================
# Build the LMS submission ZIP and the separate submission README.
#
# LMS naming rules applied here:
#   - archive:       Abdulrazak_Abdulrasheed_301926758.zip
#   - top folder:    Abdulrazak_Abdulrasheed_301926758/
#   - README:        Abdulrazak_Abdulrasheed_README.md
#
# Why a committed-tree archive rather than Compress-Archive on the folder:
#   - .git/ is excluded automatically (history is not part of the submission)
#   - ignored artifacts are excluded (portfolio-4-nosql/data/ is 93 MB of
#     regenerable NDJSON; Docker volumes and ca_material are also ignored)
#   - the ZIP matches the public GitHub commit exactly, apart from the two
#     LMS-required README renames documented below
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build-submission-zip.ps1
#
# Output:
#   dist/Abdulrazak_Abdulrasheed_301926758.zip
#   dist/Abdulrazak_Abdulrasheed_README.md
# ============================================================================

param(
    [switch]$IncludeSections
)

$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$repoRoot = Split-Path -Parent $PSScriptRoot
$studentSlug = 'Abdulrazak_Abdulrasheed_301926758'
$studentReadmeName = 'Abdulrazak_Abdulrasheed_README.md'
$repoUrl = 'https://github.com/bigphysiology-coder/advanced-database-portfolio'

$zipPath = Join-Path $repoRoot "dist/$studentSlug.zip"
$readmePath = Join-Path $repoRoot "dist/$studentReadmeName"
$prefix = "$studentSlug/"

function Get-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName
    )

    $entry = $Zip.GetEntry($EntryName)
    if (-not $entry) { throw "ZIP entry not found: $EntryName" }
    $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Set-ZipEntryText {
    param(
        [System.IO.Compression.ZipArchive]$Zip,
        [string]$EntryName,
        [string]$Text
    )

    $entry = $Zip.GetEntry($EntryName)
    if ($entry) { $entry.Delete() }
    $newEntry = $Zip.CreateEntry($EntryName, [System.IO.Compression.CompressionLevel]::Optimal)
    $writer = New-Object System.IO.StreamWriter(
        $newEntry.Open(),
        (New-Object System.Text.UTF8Encoding($false))
    )
    try { $writer.Write($Text) }
    finally { $writer.Dispose() }
}

Push-Location $repoRoot
try {
    $dirty = @(git status --porcelain)
    if ($dirty.Count -gt 0) {
        throw ("The working tree has uncommitted changes. Commit them first so the " +
            "ZIP matches the public repository.`n" + ($dirty -join "`n"))
    }

    New-Item -ItemType Directory -Path (Split-Path -Parent $zipPath) -Force | Out-Null
    foreach ($path in @($zipPath, $readmePath)) {
        if (Test-Path $path) { Remove-Item $path -Force }
    }

    git archive --format=zip --prefix=$prefix -o $zipPath HEAD
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $zipPath)) {
        throw "git archive failed to write $zipPath"
    }

    # --- rename the root README inside the ZIP ------------------------------
    # The repository keeps README.md so GitHub renders the landing page. The
    # LMS copy must use Surname_Firstname_DocumentType, and the one relative
    # link to the root README (from P4) is patched to the new name.
    $zip = [System.IO.Compression.ZipFile]::Open(
        $zipPath,
        [System.IO.Compression.ZipArchiveMode]::Update
    )
    try {
        $rootReadmeName = "${prefix}README.md"
        $rootReadme = Get-ZipEntryText -Zip $zip -EntryName $rootReadmeName
        $rootReadme = $rootReadme.Replace(
            'README.md                  <- you are here',
            "$studentReadmeName <- you are here"
        )

        $p4ReadmeName = "${prefix}portfolio-4-nosql/README.md"
        $p4Readme = Get-ZipEntryText -Zip $zip -EntryName $p4ReadmeName
        $p4Readme = $p4Readme.Replace(
            '../README.md',
            "../$studentReadmeName"
        )

        Set-ZipEntryText -Zip $zip -EntryName "${prefix}$studentReadmeName" -Text $rootReadme
        Set-ZipEntryText -Zip $zip -EntryName $p4ReadmeName -Text $p4Readme
        $zip.GetEntry($rootReadmeName).Delete()
    }
    finally {
        $zip.Dispose()
    }

    # --- build the separate README upload -----------------------------------
    # Same content as the README in the ZIP, but relative links are rewritten
    # to absolute GitHub URLs so the file still works when opened alone.
    $standaloneReadme = $rootReadme
    $standaloneReadme = [regex]::Replace(
        $standaloneReadme,
        '\]\(([^)]+)\)',
        {
            param($m)
            $target = $m.Groups[1].Value
            if ($target -match '^(https?:|#|mailto:)') { return $m.Value }

            $anchor = ''
            $path = $target
            $hash = $target.IndexOf('#')
            if ($hash -ge 0) {
                $path = $target.Substring(0, $hash)
                $anchor = $target.Substring($hash)
            }
            $path = $path.TrimStart('./')
            if (-not $path) { return $m.Value }

            $kind = if ($path.EndsWith('/')) { 'tree' } else { 'blob' }
            return "]($repoUrl/$kind/main/$path$anchor)"
        }
    )
    $cover = @"
> **LMS submission README.** Uploaded separately as ``$studentReadmeName``. The same
> README is included at the root of ``$studentSlug.zip``.

"@
    [System.IO.File]::WriteAllText(
        $readmePath,
        ($cover + "`n" + $standaloneReadme),
        (New-Object System.Text.UTF8Encoding($false))
    )

    # --- verify -------------------------------------------------------------
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $names = @($zip.Entries | ForEach-Object { $_.FullName })
        $required = @(
            $studentReadmeName,
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
        if ($names -contains "${prefix}README.md") {
            throw "ZIP still contains the generic root README.md"
        }

        $zipSizeMb = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        $readmeSizeKb = [math]::Round((Get-Item $readmePath).Length / 1KB, 1)
        if ($zipSizeMb -ge 100) { throw "ZIP is over the 100 MB LMS limit" }
        if ($readmeSizeKb -ge (100 * 1024)) { throw "README is over the 100 MB LMS limit" }

        Write-Host ""
        Write-Host "Wrote $zipPath"
        Write-Host ("Entries: {0}" -f $zip.Entries.Count)
        Write-Host ("Size:    {0} MB" -f $zipSizeMb)
        Write-Host ""
        Write-Host "Wrote $readmePath"
        Write-Host ("Size:    {0} KB" -f $readmeSizeKb)
        Write-Host ""
        Write-Host "Required files present. Root folder and README use the LMS naming format."
    }
    finally {
        $zip.Dispose()
    }

    # --- optional per-section uploads ---------------------------------------
    # Only generated on request. The main ZIP already contains every section;
    # these exist for an LMS form that has a separate field per portfolio.
    if ($IncludeSections) {
        $sectionsDir = Join-Path $repoRoot 'dist/sections'
        New-Item -ItemType Directory -Path $sectionsDir -Force | Out-Null
        $sections = @(
            'portfolio-1-database-design',
            'portfolio-2-query-optimisation',
            'portfolio-3-transactions-concurrency',
            'portfolio-4-nosql',
            'portfolio-5-distributed-cloud',
            'final-documentation'
        )

        Write-Host ""
        Write-Host "Section archives:"
        foreach ($section in $sections) {
            $sectionSlug = "Abdulrazak_Abdulrasheed_$section"
            $sectionZip = Join-Path $sectionsDir "$sectionSlug.zip"
            if (Test-Path $sectionZip) { Remove-Item $sectionZip -Force }

            git archive --format=zip --prefix="$sectionSlug/" -o $sectionZip HEAD $section
            if ($LASTEXITCODE -ne 0 -or -not (Test-Path $sectionZip)) {
                throw "git archive failed to write $sectionZip"
            }

            $sectionSize = [math]::Round((Get-Item $sectionZip).Length / 1MB, 2)
            Write-Host ("  {0} ({1} MB)" -f $sectionZip, $sectionSize)
        }
    }
}
finally {
    Pop-Location
}
