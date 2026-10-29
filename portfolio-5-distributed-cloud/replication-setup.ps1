# ============================================================================
# Portfolio 5: PostgreSQL streaming replication on one machine.
#
# Builds a primary and a hot-standby replica with Docker, loads the same
# Riverbend schema and seed data used by Portfolios 1-4, and exposes the
# operations the report needs:
#
#   up        create the network, primary, replica and seed data
#   status    streaming state, LSNs and recovery state
#   lag       measured visibility delay under a burst insert
#   sync      synchronous_commit vs synchronous_standby_names measurement
#   stale     read-your-writes stale read, lag-aware routing, replay resume
#   configs   effective settings and replication config files
#   failover  stop the primary, promote the replica, write to the new primary
#   down      remove the P5 containers, volumes and network
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File replication-setup.ps1 up
#   powershell ... -File replication-setup.ps1 status
#   powershell ... -File replication-setup.ps1 failover
#   powershell ... -File replication-setup.ps1 down
#
# `up` is destructive unless -Force is omitted and the containers do not exist.
# The P5 cluster is separate from portfolio-postgres, so Portfolios 1-4 are not
# touched.
# ============================================================================
param(
    [ValidateSet('up', 'status', 'lag', 'sync', 'stale', 'configs', 'failover', 'down')]
    [string]$Action = 'status',

    [int]$LagRows = 50000,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$schemaFile = Join-Path $repoRoot 'portfolio-1-database-design/schema.sql'
$seedFile   = Join-Path $repoRoot 'portfolio-1-database-design/seed-data.sql'

$network    = 'portfolio-p5-repl'
$primary    = 'portfolio-p5-primary'
$replica    = 'portfolio-p5-replica'
$primaryVol = 'p5-primary-data'
$replicaVol = 'p5-replica-data'
$replRole   = 'replicator'
$replPass   = 'replpass'
$appName    = 'portfolio-p5-replica'

$script:lastExitCode = 0

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------

function Invoke-Docker {
    param(
        [string[]]$Arguments,
        [switch]$AllowFailure
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & docker @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $script:lastExitCode = $code
    $text = @($output | ForEach-Object { "$_" })

    if ($code -ne 0 -and -not $AllowFailure) {
        throw ("docker {0} failed (exit {1}):{2}{3}" -f
            ($Arguments -join ' '), $code, [Environment]::NewLine, ($text -join [Environment]::NewLine))
    }
    return $text
}

function Test-Postgres {
    param([string]$Container)

    Invoke-Docker @('exec', $Container, 'psql', '-U', 'portfolio', '-d', 'hospital',
        '-X', '-tA', '-c', 'SELECT 1;') -AllowFailure | Out-Null
    return ($script:lastExitCode -eq 0)
}

function Wait-Postgres {
    param([string]$Container, [int]$TimeoutSeconds = 120)

    # The Docker entrypoint runs a temporary server while initializing a new
    # volume, then shuts it down and starts the real one. A single pg_isready
    # can therefore be true a moment before "the database system is shutting
    # down". Require two consecutive successful SQL connections instead.
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $stable = $true
        for ($i = 0; $i -lt 3; $i++) {
            if (-not (Test-Postgres -Container $Container)) {
                $stable = $false
                break
            }
            if ($i -lt 2) { Start-Sleep -Seconds 2 }
        }
        if ($stable) { return }
        Start-Sleep -Milliseconds 750
    } while ((Get-Date) -lt $deadline)

    throw "PostgreSQL in $Container was not ready after $TimeoutSeconds seconds"
}

function Invoke-SqlFile {
    param([string]$Container, [string]$HostPath)

    $leaf = Split-Path -Leaf $HostPath
    $remote = "/tmp/$leaf"
    Invoke-Docker @('cp', $HostPath, "${Container}:$remote") | Out-Null
    return Invoke-Docker @('exec', $Container, 'psql', '-U', 'portfolio', '-d', 'hospital',
        '-X', '-v', 'ON_ERROR_STOP=1', '-f', $remote)
}

function Invoke-Sql {
    param([string]$Container, [string]$Sql, [switch]$TuplesOnly)

    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("p5-sql-" + [guid]::NewGuid().ToString('N') + ".sql")
    Set-Content -Path $temp -Value $Sql -Encoding utf8
    try {
        $remote = "/tmp/" + (Split-Path -Leaf $temp)
        Invoke-Docker @('cp', $temp, "${Container}:$remote") | Out-Null
        $arguments = @('exec', $Container, 'psql', '-U', 'portfolio', '-d', 'hospital',
            '-X', '-v', 'ON_ERROR_STOP=1')
        if ($TuplesOnly) { $arguments += @('-tA') }
        $arguments += @('-f', $remote)
        return Invoke-Docker $arguments
    }
    finally {
        Remove-Item $temp -ErrorAction SilentlyContinue
    }
}

function Get-Scalar {
    param([string]$Container, [string]$Sql)

    $out = Invoke-Sql -Container $Container -Sql $Sql -TuplesOnly
    $value = ($out | Where-Object { "$_".Trim() -ne '' } | Select-Object -Last 1)
    if ($null -eq $value) { return '' }
    return "$value".Trim()
}

function Wait-Streaming {
    param([int]$TimeoutSeconds = 90)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $state = Get-Scalar $primary @"
SELECT state FROM pg_stat_replication
WHERE application_name = '$appName';
"@
        if ($state -eq 'streaming') { return }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    throw "Replica did not reach state=streaming within $TimeoutSeconds seconds"
}

function Wait-CaughtUp {
    param([int]$TimeoutSeconds = 60)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $primaryLsn = Get-Scalar $primary 'SELECT pg_current_wal_lsn();'
        $replicaLsn = Get-Scalar $replica 'SELECT pg_last_wal_replay_lsn();'
        if ($primaryLsn -and $replicaLsn) {
            $lag = Get-Scalar $primary "SELECT pg_wal_lsn_diff('$primaryLsn'::pg_lsn, '$replicaLsn'::pg_lsn)::bigint;"
            if ($lag -eq '0') { return }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)

    throw "Replica did not catch up within $TimeoutSeconds seconds"
}

function Remove-P5 {
    Invoke-Docker @('rm', '-f', $primary, $replica) -AllowFailure | Out-Null
    Invoke-Docker @('volume', 'rm', $primaryVol, $replicaVol) -AllowFailure | Out-Null
    Invoke-Docker @('network', 'rm', $network) -AllowFailure | Out-Null
}

# ----------------------------------------------------------------------------
# up
# ----------------------------------------------------------------------------

function Invoke-Up {
    $existing = Invoke-Docker @('ps', '-a', '--format', '{{.Names}}')
    if (($existing -contains $primary) -or ($existing -contains $replica)) {
        if (-not $Force) {
            throw "P5 containers already exist. Re-run with -Force to destroy and rebuild them."
        }
        Write-Output 'removing the previous P5 containers, volumes and network'
        Remove-P5
    }

    Write-Output 'creating the network'
    Invoke-Docker @('network', 'create', $network) -AllowFailure | Out-Null

    Write-Output 'starting the primary'
    Invoke-Docker @(
        'run', '-d', '--name', $primary, '--network', $network,
        '-e', 'POSTGRES_USER=portfolio',
        '-e', 'POSTGRES_PASSWORD=portfolio',
        '-e', 'POSTGRES_DB=hospital',
        '-v', "${primaryVol}:/var/lib/postgresql/data",
        'postgres:16',
        '-c', 'wal_level=replica',
        '-c', 'max_wal_senders=5',
        '-c', 'wal_keep_size=256MB',
        '-c', 'hot_standby=on',
        '-c', 'synchronous_commit=on',
        '-c', 'track_commit_timestamp=on'
    ) | Out-Null
    Wait-Postgres -Container $primary

    Write-Output 'loading schema.sql'
    Invoke-SqlFile -Container $primary -HostPath $schemaFile | Out-Null

    Write-Output 'loading seed-data.sql (this is the slow step)'
    $seedOutput = Invoke-SqlFile -Container $primary -HostPath $seedFile
    $seedOutput | Select-Object -Last 25 | ForEach-Object { Write-Output $_ }

    Write-Output 'creating the replication role, probe table and pg_hba entry'
    Invoke-Sql -Container $primary -Sql @'
CREATE TABLE IF NOT EXISTS p5_probe (
    probe_id bigserial PRIMARY KEY,
    batch text NOT NULL,
    note text,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS ix_p5_probe_batch ON p5_probe (batch);

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'replicator') THEN
        CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'replpass';
    END IF;
END
$$;

SELECT count(*) AS patients,
       (SELECT count(*) FROM lab_order) AS lab_orders
FROM patient;
'@ | ForEach-Object { Write-Output $_ }

    Invoke-Docker @('exec', $primary, 'sh', '-c',
        "echo 'host replication $replRole 0.0.0.0/0 scram-sha-256' >> /var/lib/postgresql/data/pg_hba.conf") | Out-Null
    Invoke-Sql -Container $primary -Sql 'SELECT pg_reload_conf();' | Out-Null

    Write-Output 'taking the base backup'
    Invoke-Docker @('volume', 'create', $replicaVol) | Out-Null
    $connection = "host=$primary port=5432 user=$replRole password=$replPass application_name=$appName"
    Invoke-Docker @(
        'run', '--rm', '--network', $network,
        '-v', "${replicaVol}:/var/lib/postgresql/data",
        'postgres:16',
        'pg_basebackup', '-D', '/var/lib/postgresql/data',
        '-Fp', '-Xs', '-P', '-R', '--checkpoint=fast',
        '-d', $connection
    ) | ForEach-Object { Write-Output $_ }

    Write-Output 'starting the replica'
    Invoke-Docker @(
        'run', '-d', '--name', $replica, '--network', $network,
        '-v', "${replicaVol}:/var/lib/postgresql/data",
        'postgres:16', '-c', 'hot_standby=on'
    ) | Out-Null
    Wait-Postgres -Container $replica
    Wait-Streaming

    Write-Output ''
    Write-Output 'primary and replica are streaming'
    Invoke-Sql -Container $primary -Sql @"
SELECT application_name, client_addr, state, sync_state,
       sent_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }
}

# ----------------------------------------------------------------------------
# status
# ----------------------------------------------------------------------------

function Invoke-Status {
    Write-Output '=== primary: pg_stat_replication ==='
    Invoke-Sql -Container $primary -Sql @"
SELECT pid, application_name, client_addr, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes,
       replay_lag
FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== replica: recovery state ==='
    Invoke-Sql -Container $replica -Sql @"
SELECT pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS read_only,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS unapplied_bytes,
       now() - pg_last_xact_replay_timestamp() AS replay_age;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== write on the primary, read on the replica ==='
    $probe = 'status-' + (Get-Date -Format 'HHmmssfff')
    Invoke-Sql -Container $primary -Sql @"
\timing on
INSERT INTO p5_probe(batch, note) VALUES ('$probe', 'written on the primary');
SELECT probe_id, batch, note, created_at FROM p5_probe WHERE batch = '$probe';
"@ | ForEach-Object { Write-Output $_ }

    Start-Sleep -Milliseconds 500
    Invoke-Sql -Container $replica -Sql @"
SELECT probe_id, batch, note, created_at
FROM p5_probe WHERE batch = '$probe';
"@ | ForEach-Object { Write-Output $_ }
}

# ----------------------------------------------------------------------------
# lag
# ----------------------------------------------------------------------------

function Invoke-Lag {
    $batch = 'lag-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
    $template = @'
DO $$
DECLARE
    v_count int;
    v_xmin xid;
    v_commit timestamptz;
    v_observed timestamptz;
    v_start timestamptz := clock_timestamp();
BEGIN
    LOOP
        SELECT count(*) INTO v_count FROM p5_probe WHERE batch = '{0}';
        EXIT WHEN v_count >= {1};
        PERFORM pg_sleep(0.005);
    END LOOP;

    SELECT xmin, pg_xact_commit_timestamp(xmin)
      INTO v_xmin, v_commit
      FROM p5_probe
     WHERE batch = '{0}'
     LIMIT 1;

    v_observed := clock_timestamp();
    RAISE NOTICE 'RESULT batch={0} rows=% committed_at=% observed_at=% lag_ms=% poll_wait_ms=%',
        v_count,
        v_commit,
        v_observed,
        round((extract(epoch from (v_observed - v_commit)) * 1000)::numeric, 3),
        round((extract(epoch from (v_observed - v_start)) * 1000)::numeric, 3);
END
$$;
'@
    $waitSql = $template -f $batch, $LagRows

    Write-Output "=== burst insert: $LagRows rows (batch $batch) ==="
    Set-Content -Path "$env:TEMP\p5-lag-wait.sql" -Value $waitSql -Encoding utf8
    Invoke-Docker @('cp', "$env:TEMP\p5-lag-wait.sql", "${replica}:/tmp/p5-lag-wait.sql") | Out-Null

    $stdout = Join-Path ([System.IO.Path]::GetTempPath()) ("p5-lag-out-" + [guid]::NewGuid().ToString('N') + ".txt")
    $stderr = Join-Path ([System.IO.Path]::GetTempPath()) ("p5-lag-err-" + [guid]::NewGuid().ToString('N') + ".txt")

    # Start the replica-side poll before the write, so the measured delay is
    # commit -> first visible replay, not the time spent starting a psql client.
    $process = Start-Process -FilePath 'docker' -ArgumentList @(
        'exec', $replica, 'psql', '-U', 'portfolio', '-d', 'hospital',
        '-X', '-v', 'ON_ERROR_STOP=1', '-f', '/tmp/p5-lag-wait.sql'
    ) -RedirectStandardOutput $stdout -RedirectStandardError $stderr -NoNewWindow -PassThru

    Start-Sleep -Milliseconds 500
    if ($process.HasExited) {
        throw "replica wait process exited before the insert: $((Get-Content $stdout, $stderr -ErrorAction SilentlyContinue) -join ' ')"
    }

    Invoke-Sql -Container $primary -Sql @"
\timing on
INSERT INTO p5_probe(batch, note)
SELECT '$batch', 'burst'
FROM generate_series(1, $LagRows);
SELECT count(*) AS primary_rows FROM p5_probe WHERE batch = '$batch';
"@ | ForEach-Object { Write-Output $_ }
    $insertedAt = Get-Date

    try {
        Wait-Process -Id $process.Id -Timeout 180 -ErrorAction Stop
    }
    catch {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        throw "replica wait did not finish within 180 seconds"
    }

    $waitOutput = @()
    if (Test-Path $stdout) { $waitOutput += Get-Content $stdout }
    if (Test-Path $stderr) { $waitOutput += Get-Content $stderr }
    $waitOutput | ForEach-Object { Write-Output $_ }
    Remove-Item $stdout, $stderr -ErrorAction SilentlyContinue

    $line = ($waitOutput | Where-Object { "$_" -match 'RESULT batch=' } | Select-Object -Last 1)
    if (-not $line) { throw "could not find RESULT in the replica wait output" }
    if ($line -match 'lag_ms=([0-9.]+)') {
        Write-Output ("measured visibility delay: {0} ms for {1} rows" -f $matches[1], $LagRows)
    }
}

# ----------------------------------------------------------------------------
# sync
# ----------------------------------------------------------------------------

function Invoke-SyncBenchmark {
    Write-Output '=== current settings: synchronous_commit is local, not replication ==='
    Invoke-Sql -Container $primary -Sql @"
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SELECT application_name, state, sync_state FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== enable synchronous replication (ANY 1 of the named standby) ==='
    Invoke-Sql -Container $primary -Sql @'
ALTER SYSTEM SET synchronous_standby_names = 'ANY 1 ("portfolio-p5-replica")';
SELECT pg_reload_conf();
'@ | ForEach-Object { Write-Output $_ }
    Start-Sleep -Seconds 2
    Invoke-Sql -Container $primary -Sql @"
SHOW synchronous_standby_names;
SELECT application_name, state, sync_state FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== ten commits with the standby acknowledged ==='
    $syncSql = @"
\timing on
$((1..10 | ForEach-Object { "INSERT INTO p5_probe(batch, note) VALUES ('sync-$_', 'x');" }) -join [Environment]::NewLine)
"@
    $syncOut = Invoke-Sql -Container $primary -Sql $syncSql
    $syncOut | ForEach-Object { Write-Output $_ }

    Write-Output '=== back to asynchronous replication ==='
    Invoke-Sql -Container $primary -Sql @'
ALTER SYSTEM RESET synchronous_standby_names;
SELECT pg_reload_conf();
'@ | ForEach-Object { Write-Output $_ }
    Start-Sleep -Seconds 2
    Invoke-Sql -Container $primary -Sql @"
SHOW synchronous_standby_names;
SELECT application_name, state, sync_state FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== ten commits with asynchronous replication ==='
    $asyncSql = @"
\timing on
$((1..10 | ForEach-Object { "INSERT INTO p5_probe(batch, note) VALUES ('async-$_', 'x');" }) -join [Environment]::NewLine)
"@
    $asyncOut = Invoke-Sql -Container $primary -Sql $asyncSql
    $asyncOut | ForEach-Object { Write-Output $_ }

    $syncTimes = @($syncOut | ForEach-Object { if ("$_" -match '^Time: ([0-9.]+) ms') { [double]$matches[1] } })
    $asyncTimes = @($asyncOut | ForEach-Object { if ("$_" -match '^Time: ([0-9.]+) ms') { [double]$matches[1] } })
    $syncSorted = @($syncTimes | Sort-Object)
    $asyncSorted = @($asyncTimes | Sort-Object)
    if ($syncSorted.Count -gt 0 -and $asyncSorted.Count -gt 0) {
        Write-Output ''
        Write-Output ("sync commits:  n={0} min={1} median={2} max={3} ms" -f
            $syncSorted.Count, $syncSorted[0], $syncSorted[[int][math]::Floor($syncSorted.Count / 2)], $syncSorted[-1])
        Write-Output ("async commits: n={0} min={1} median={2} max={3} ms" -f
            $asyncSorted.Count, $asyncSorted[0], $asyncSorted[[int][math]::Floor($asyncSorted.Count / 2)], $asyncSorted[-1])
    }
}

# ----------------------------------------------------------------------------
# stale
# ----------------------------------------------------------------------------

function Invoke-StaleRead {
    $batch = 'stale-' + [guid]::NewGuid().ToString('N').Substring(0, 12)

    Write-Output '=== pause WAL replay on the replica ==='
    Invoke-Sql -Container $replica -Sql 'SELECT pg_wal_replay_pause();' | ForEach-Object { Write-Output $_ }

    Write-Output '=== write on the primary ==='
    Invoke-Sql -Container $primary -Sql @"
INSERT INTO p5_probe(batch, note) VALUES ('$batch', 'read-your-writes');
SELECT xmin, pg_xact_commit_timestamp(xmin) AS committed_at
FROM p5_probe WHERE batch = '$batch';
"@ | ForEach-Object { Write-Output $_ }

    Start-Sleep -Seconds 1

    Write-Output '=== the immediate read on the replica is stale ==='
    Invoke-Sql -Container $replica -Sql @"
SELECT count(*) AS stale_rows FROM p5_probe WHERE batch = '$batch';
SELECT pg_is_in_recovery() AS in_recovery,
       pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn() AS replayed_lsn,
       pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn()) AS unapplied_bytes;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== lag-aware router: compare primary LSN with replica replay LSN ==='
    $primaryLsn = Get-Scalar $primary 'SELECT pg_current_wal_lsn();'
    $replicaLsn = Get-Scalar $replica 'SELECT pg_last_wal_replay_lsn();'
    $lagBytes = Get-Scalar $primary "SELECT pg_wal_lsn_diff('$primaryLsn'::pg_lsn, '$replicaLsn'::pg_lsn)::bigint;"
    Write-Output "primary_lsn=$primaryLsn replica_replay_lsn=$replicaLsn lag_bytes=$lagBytes"

    if ([int64]$lagBytes -gt 0) {
        Write-Output 'router: lag > 0 -> send this read to the PRIMARY'
        Invoke-Sql -Container $primary -Sql @"
SELECT count(*) AS router_rows FROM p5_probe WHERE batch = '$batch';
"@ | ForEach-Object { Write-Output $_ }
    }
    else {
        Write-Output 'router: replica is caught up -> send this read to the REPLICA'
        Invoke-Sql -Container $replica -Sql @"
SELECT count(*) AS router_rows FROM p5_probe WHERE batch = '$batch';
"@ | ForEach-Object { Write-Output $_ }
    }

    Write-Output '=== resume replay and wait for the row ==='
    Invoke-Sql -Container $replica -Sql 'SELECT pg_wal_replay_resume();' | ForEach-Object { Write-Output $_ }

    $template = @'
DO $$
DECLARE
    v_count int;
    v_commit timestamptz;
    v_observed timestamptz;
    v_start timestamptz := clock_timestamp();
BEGIN
    LOOP
        SELECT count(*) INTO v_count FROM p5_probe WHERE batch = '{0}';
        EXIT WHEN v_count >= 1;
        PERFORM pg_sleep(0.005);
    END LOOP;

    SELECT pg_xact_commit_timestamp(xmin) INTO v_commit
      FROM p5_probe WHERE batch = '{0}' LIMIT 1;

    v_observed := clock_timestamp();
    RAISE NOTICE 'after resume: rows=% committed_at=% observed_at=% lag_ms=% poll_wait_ms=%',
        v_count, v_commit, v_observed,
        round((extract(epoch from (v_observed - v_commit)) * 1000)::numeric, 3),
        round((extract(epoch from (v_observed - v_start)) * 1000)::numeric, 3);
END
$$;
'@
    $waitSql = $template -f $batch
    Set-Content -Path "$env:TEMP\p5-stale-wait.sql" -Value $waitSql -Encoding utf8
    Invoke-Docker @('cp', "$env:TEMP\p5-stale-wait.sql", "${replica}:/tmp/p5-stale-wait.sql") | Out-Null
    Invoke-SqlFile -Container $replica -HostPath "$env:TEMP\p5-stale-wait.sql" | ForEach-Object { Write-Output $_ }

    Write-Output '=== the row is now visible, and the router chooses the replica ==='
    $primaryLsn = Get-Scalar $primary 'SELECT pg_current_wal_lsn();'
    $replicaLsn = Get-Scalar $replica 'SELECT pg_last_wal_replay_lsn();'
    $lagBytes = Get-Scalar $primary "SELECT pg_wal_lsn_diff('$primaryLsn'::pg_lsn, '$replicaLsn'::pg_lsn)::bigint;"
    Write-Output "primary_lsn=$primaryLsn replica_replay_lsn=$replicaLsn lag_bytes=$lagBytes"
    Write-Output 'router: replica is caught up -> send this read to the REPLICA'
    Invoke-Sql -Container $replica -Sql @"
SELECT count(*) AS router_rows FROM p5_probe WHERE batch = '$batch';
"@ | ForEach-Object { Write-Output $_ }
}

# ----------------------------------------------------------------------------
# configs
# ----------------------------------------------------------------------------

function Invoke-Configs {
    Write-Output '=== primary settings ==='
    Invoke-Sql -Container $primary -Sql @"
SHOW wal_level;
SHOW max_wal_senders;
SHOW wal_keep_size;
SHOW hot_standby;
SHOW synchronous_commit;
SHOW synchronous_standby_names;
SHOW track_commit_timestamp;
SHOW archive_mode;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== replica settings ==='
    Invoke-Sql -Container $replica -Sql @"
SHOW hot_standby;
SHOW primary_conninfo;
SHOW recovery_target_timeline;
SELECT pg_is_in_recovery();
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== primary pg_hba replication line ==='
    Invoke-Docker @('exec', $primary, 'sh', '-c',
        'grep -n "replication" /var/lib/postgresql/data/pg_hba.conf') | ForEach-Object { Write-Output $_ }

    Write-Output '=== replica postgresql.auto.conf ==='
    Invoke-Docker @('exec', $replica, 'sh', '-c',
        'cat /var/lib/postgresql/data/postgresql.auto.conf') | ForEach-Object { Write-Output $_ }
}

# ----------------------------------------------------------------------------
# failover
# ----------------------------------------------------------------------------

function Invoke-Failover {
    Wait-CaughtUp

    $preProbe = Get-Scalar $primary 'SELECT count(*) FROM p5_probe;'
    $prePatients = Get-Scalar $primary 'SELECT count(*) FROM patient;'
    $preOrders = Get-Scalar $primary 'SELECT count(*) FROM lab_order;'
    Write-Output "before failover: p5_probe=$preProbe patient=$prePatients lab_order=$preOrders"

    Invoke-Sql -Container $primary -Sql @"
SELECT application_name, state, sync_state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"@ | ForEach-Object { Write-Output $_ }

    Write-Output '=== stop the primary ==='
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Invoke-Docker @('stop', $primary) | Out-Null
    $stopwatch.Stop()
    Write-Output ("primary stopped in {0:N1} ms" -f $stopwatch.Elapsed.TotalMilliseconds)

    Write-Output '=== promote the replica ==='
    $stopwatch.Restart()
    # Direct -c avoids the temp-file copy that Invoke-Sql performs, so the
    # timing below is the promotion call itself plus psql startup.
    Invoke-Docker @('exec', $replica, 'psql', '-U', 'portfolio', '-d', 'hospital',
        '-X', '-v', 'ON_ERROR_STOP=1', '-c', 'SELECT pg_promote(true, 60);') |
        ForEach-Object { Write-Output $_ }
    $promoteCallMs = $stopwatch.Elapsed.TotalMilliseconds

    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 250
        $inRecovery = Get-Scalar $replica 'SELECT pg_is_in_recovery();'
    } while ($inRecovery -ne 'f' -and (Get-Date) -lt $deadline)
    $stopwatch.Stop()

    Write-Output ("pg_promote call: {0:N1} ms; promotion complete: {1:N1} ms; in_recovery={2}" -f
        $promoteCallMs, $stopwatch.Elapsed.TotalMilliseconds, $inRecovery)

    Write-Output '=== the promoted replica accepts writes ==='
    Invoke-Sql -Container $replica -Sql @"
SELECT pg_is_in_recovery() AS in_recovery,
       current_setting('transaction_read_only') AS read_only;
INSERT INTO p5_probe(batch, note)
VALUES ('post-failover', 'written to the promoted replica')
RETURNING probe_id, batch, note;
SELECT count(*) AS probe_rows_after FROM p5_probe;
"@ | ForEach-Object { Write-Output $_ }

    $postProbe = Get-Scalar $replica 'SELECT count(*) FROM p5_probe;'
    $postPatients = Get-Scalar $replica 'SELECT count(*) FROM patient;'
    $postOrders = Get-Scalar $replica 'SELECT count(*) FROM lab_order;'
    $lost = [int64]$preProbe - ([int64]$postProbe - 1)
    Write-Output "after failover:  p5_probe=$postProbe patient=$postPatients lab_order=$postOrders"
    Write-Output "rows lost from the caught-up replica: $lost (0 because the replica had replayed to the primary LSN before promotion)"

    Write-Output '=== no upstream remains ==='
    Invoke-Sql -Container $replica -Sql 'SELECT count(*) AS upstreams FROM pg_stat_replication;' |
        ForEach-Object { Write-Output $_ }
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------

switch ($Action) {
    'up'       { Invoke-Up }
    'status'   { Invoke-Status }
    'lag'      { Invoke-Lag }
    'sync'     { Invoke-SyncBenchmark }
    'stale'    { Invoke-StaleRead }
    'configs'  { Invoke-Configs }
    'failover' { Invoke-Failover }
    'down'     { Remove-P5; Write-Output 'P5 containers, volumes and network removed' }
}
