<#
.SYNOPSIS
    Capture the Portfolio 5 replication evidence from the running P5 cluster.

.DESCRIPTION
    Writes raw command output to portfolio-5-distributed-cloud/evidence/. Each
    file records the step, the timestamp, the full output and the elapsed time,
    so the figures quoted in the report can be traced back to a command.

    Steps:
      00-environment.txt   host, Docker and PostgreSQL versions, disk, images
      01-setup.txt         destroy and rebuild primary + replica, load seed data
      02-replication.txt   pg_stat_replication, recovery state, write/read, logs
      03-lag.txt           measured commit-to-visible delay under a burst insert
      04-sync-vs-async.txt synchronous_standby_names and commit timings
      05-stale-read.txt    paused replay, stale read, lag-aware router, resume
      06-configs.txt       effective settings and replication config files
      07-failover.txt      stop primary, promote replica, post-failover write

    The capture is destructive: step 01 removes the existing P5 containers,
    volumes and network, then rebuilds them and reloads the seed data. That is
    deliberate; it proves the setup path rather than capturing a hand-edited
    cluster. The primary from Portfolios 1-4 (portfolio-postgres) is untouched.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p5.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p5.ps1 -SkipSetup
#>
param(
    [string]$EvidenceDir = 'portfolio-5-distributed-cloud/evidence',
    [int]$LagRows = 50000,
    [switch]$SkipSetup
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$p5Root   = Join-Path $repoRoot 'portfolio-5-distributed-cloud'
$harness  = Join-Path $p5Root 'replication-setup.ps1'
$evidence = Join-Path $repoRoot $EvidenceDir
$primary  = 'portfolio-p5-primary'
$replica  = 'portfolio-p5-replica'

if (-not (Test-Path $evidence)) {
    New-Item -ItemType Directory -Path $evidence -Force | Out-Null
}

function Assert-Container([string]$Name) {
    $state = (& docker inspect --format '{{.State.Status}}' $Name 2>$null)
    if ($LASTEXITCODE -ne 0 -or $state.Trim() -ne 'running') {
        throw "Container '$Name' is not running. Run: replication-setup.ps1 up -Force"
    }
}

function Invoke-Harness {
    param([string]$Action, [string[]]$Extra = @())

    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $harness,
        '-Action', $Action) + $Extra
    & powershell @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "replication-setup.ps1 -Action $Action exited with $LASTEXITCODE"
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
        # Add each line as it arrives so a failure later in the step still
        # leaves the earlier output in the evidence file.
        & $Body *>&1 | ForEach-Object {
            $text = "$_"
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

Write-Host '=== Portfolio 5 evidence capture ==='

Invoke-Step '00-environment.txt' 'Host, Docker and PostgreSQL environment' {
    "os: $([System.Environment]::OSVersion.VersionString)"
    "powershell: $($PSVersionTable.PSVersion)"
    "captured at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss K')"
    "base git commit: $(git rev-parse HEAD 2>$null)"
    docker version --format 'client {{.Client.Version}} server {{.Server.Version}}'
    docker info --format 'server {{.ServerVersion}} os={{.OperatingSystem}} cpus={{.NCPU}} memory={{.MemTotal}}'
    docker images postgres:16 --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}}'
    $drive = Get-PSDrive -Name C
    "disk C: used=$([math]::Round($drive.Used / 1GB, 1))GB free=$([math]::Round($drive.Free / 1GB, 1))GB"
    'The P5 cluster is rebuilt in step 01; Portfolios 1-4 use portfolio-postgres.'
}

if (-not $SkipSetup) {
    Invoke-Step '01-setup.txt' 'Destroy and rebuild the P5 primary and replica' {
        'This step is destructive: it removes the P5 containers, volumes and network,'
        'then creates a new primary, loads schema.sql and seed-data.sql, takes a'
        'pg_basebackup, and starts the replica.'
        'P5 containers before the rebuild (may be empty or from a previous run):'
        docker ps -a --filter name=portfolio-p5 --format '{{.Names}} | {{.Image}} | {{.Status}}'
        Invoke-Harness -Action up -Extra @('-Force')
        docker ps -a --filter name=portfolio-p5 --format '{{.Names}} | {{.Image}} | {{.Status}}'
    }
}
else {
    Write-Host 'skipping setup; using the existing P5 cluster'
}

Assert-Container $primary
Assert-Container $replica

Invoke-Step '02-replication.txt' 'Streaming replication, write/read path and logs' {
    Invoke-Harness -Action status
    '=== primary log (tail) ==='
    # cmd merges the native stderr stream before PowerShell sees it; without
    # this, Docker log lines on stderr become terminating errors under Stop.
    & cmd /c "docker logs --tail 40 $primary 2>&1"
    '=== replica log (tail) ==='
    & cmd /c "docker logs --tail 40 $replica 2>&1"
}

Invoke-Step '03-lag.txt' 'Measured commit-to-visible replication lag' {
    "burst size: $LagRows rows"
    Invoke-Harness -Action lag -Extra @('-LagRows', "$LagRows")
    'The replica-side poll starts before the primary insert. lag_ms is measured'
    'from the commit timestamp (track_commit_timestamp=on) to the moment the'
    'replica first sees all rows. poll_wait_ms includes the insert itself.'
}

Invoke-Step '04-sync-vs-async.txt' 'Synchronous vs asynchronous commit latency' {
    'synchronous_commit=on alone does not make replication synchronous.'
    'synchronous_standby_names is what requires the standby acknowledgement.'
    Invoke-Harness -Action sync
    'The transaction commits are single-row inserts; the timing includes client'
    'round trips. This is an order-of-magnitude comparison, not a benchmark.'
}

Invoke-Step '05-stale-read.txt' 'Read-your-writes stale read, router and recovery' {
    Invoke-Harness -Action stale
    'The paused-replay lag_ms is the intentional pause duration, not the normal'
    'replication lag measured in 03-lag.txt.'
}

Invoke-Step '06-configs.txt' 'Effective settings and replication config files' {
    Invoke-Harness -Action configs
    'Source fragments committed with the portfolio:'
    Get-ChildItem (Join-Path $p5Root 'config') -File -ErrorAction SilentlyContinue |
        ForEach-Object { "config/{0} ({1} bytes)" -f $_.Name, $_.Length }
    foreach ($fragment in @('primary.conf', 'replica.conf', 'pg_hba-replication.conf')) {
        "--- config/$fragment ---"
        Get-Content (Join-Path $p5Root "config/$fragment") -Encoding UTF8
    }
}

Invoke-Step '07-failover.txt' 'Primary failure, promotion and post-failover write' {
    Invoke-Harness -Action failover
    '=== container state after promotion ==='
    docker ps -a --filter name=portfolio-p5 --format '{{.Names}} | {{.Status}}'
}

Write-Host ''
if ($script:failures -gt 0) {
    throw "$($script:failures) evidence step(s) failed"
}
Write-Host "Evidence written to $evidence"
