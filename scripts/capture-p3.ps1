<#
.SYNOPSIS
    Capture every Portfolio 3 transaction and concurrency test.

.DESCRIPTION
    Runs three single-session transaction tests and five two-session
    concurrency tests against the seeded hospital database, then writes the
    raw terminal output to portfolio-3-transactions-concurrency/evidence/.

    Each two-session test is run as two independent psql connections, not one
    script executed sequentially. Session A is launched first; Session B is
    launched 1.2 s later. A pg_stat_activity sampler runs throughout so the
    blocking state is visible in the evidence, not merely described.

    The script is idempotent: it cleans its own appointments and lab orders
    before and after the run, and drops the p3_demo schema at the end.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p3.ps1
#>
param(
    [string]$Database = 'hospital',
    [string]$EvidenceDir = 'portfolio-3-transactions-concurrency/evidence',
    [int]$SessionDelayMs = 1200,
    [int]$TimeoutSeconds = 90
)

$ErrorActionPreference = 'Stop'

$repoRoot  = Split-Path -Parent $PSScriptRoot
$p3Root    = Join-Path $repoRoot 'portfolio-3-transactions-concurrency'
$sessDir   = Join-Path $p3Root 'sessions'
$tempDir   = Join-Path ([System.IO.Path]::GetTempPath()) ("p3-capture-" + $PID)
$Container = 'portfolio-postgres'
$utf8      = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path $EvidenceDir)) {
    $EvidenceDir = Join-Path $repoRoot $EvidenceDir
}
if (-not (Test-Path $EvidenceDir)) {
    New-Item -ItemType Directory -Path $EvidenceDir -Force | Out-Null
}
if (-not (Test-Path $tempDir)) {
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null
}

# Clear previous captures so a failed run cannot leave stale evidence beside new
# files. .gitkeep and files with other extensions are left alone.
Get-ChildItem -Path $EvidenceDir -Filter '*.txt' -File | Remove-Item -Force
Get-ChildItem -Path $EvidenceDir -Filter 'summary.csv' -File | Remove-Item -Force

function Write-Utf8([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, $utf8)
}

function Write-Utf8Lines([string]$Path, [object[]]$Lines) {
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $utf8)
}

function Assert-Container {
    docker inspect --format '{{.State.Status}}' $Container *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "Container '$Container' does not exist. Run: docker compose up -d postgres"
    }
    $state = (docker inspect --format '{{.State.Status}}' $Container).Trim()
    if ($state -ne 'running') {
        throw "Container '$Container' is '$state', not running. Run: docker compose up -d postgres"
    }
}

function Invoke-PsqlText([string]$Sql) {
    # Windows PowerShell 5.1 turns a native command's stderr into a
    # terminating error when ErrorActionPreference is Stop, even when the
    # command succeeds. PostgreSQL NOTICEs are normal here, so relax the
    # preference for the call and judge success by the exit code.
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = $Sql | docker compose exec -T postgres psql -U portfolio -d $Database -X -v ON_ERROR_STOP=1 -f - 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    $lines = @($out | ForEach-Object { "$_" })
    if ($code -ne 0) {
        throw ("psql failed with exit code {0}:{1}{2}" -f $code, [Environment]::NewLine, ($lines -join [Environment]::NewLine))
    }
    return $lines
}

function Invoke-PsqlScalar([string]$Sql) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = docker compose exec -T postgres psql -U portfolio -d $Database -X -tA -c $Sql 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($code -ne 0) {
        throw ("scalar query failed with exit code {0}: {1}" -f $code, ($out -join ' '))
    }
    return (($out | ForEach-Object { "$_" }) -join "`n").Trim()
}

function Copy-ToContainer([string]$LocalPath, [string]$ContainerPath) {
    docker cp $LocalPath "${Container}:${ContainerPath}" *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "docker cp failed: $LocalPath -> ${Container}:${ContainerPath}"
    }
}

function Get-ContainerText([string]$Path) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = docker exec $Container cat $Path 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }
    if ($code -ne 0) {
        return "(missing: $Path)"
    }
    return ((@($out | ForEach-Object { "$_" })) -join "`n")
}

function Test-ContainerFile([string]$Path) {
    docker exec $Container test -f $Path *> $null
    return ($LASTEXITCODE -eq 0)
}

function Reset-Scenario {
    $sql = @'
SET TIME ZONE 'UTC';
DELETE FROM appointment WHERE reason LIKE 'P3 TEST%';
TRUNCATE p3_demo.booking_unprotected;
UPDATE p3_demo.on_call SET on_duty = true;
'@
    Invoke-PsqlText $sql | Out-Null
}

function Start-DbSession([string]$Name, [string]$SqlFile, [string]$PsqlArgs = '') {
    $log  = "/tmp/p3/$Name.log"
    $exit = "/tmp/p3/$Name.exit"
    $done = "/tmp/p3/$Name.done"

    docker exec $Container sh -c "rm -f $log $exit $done" *> $null

    $inner = "psql -U portfolio -d $Database -X -v ON_ERROR_STOP=0 $PsqlArgs -f /tmp/p3/$SqlFile > $log 2>&1; echo `$? > $exit; touch $done"
    docker exec -d $Container sh -c $inner
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start session '$Name'"
    }
}

function Start-Monitor([string]$Id) {
    $log  = "/tmp/p3/monitor-$Id.log"
    $stop = "/tmp/p3/monitor-$Id.stop"
    $done = "/tmp/p3/monitor-$Id.done"

    docker exec $Container sh -c "rm -f $log $stop $done" *> $null

    # Run the sampling loop inside the container. A PowerShell loop would add
    # roughly a second per docker call and could delay Session B past A's
    # commit, which would destroy the interleaving being demonstrated.
    $inner = "while [ ! -f $stop ]; do psql -U portfolio -d $Database -X -q -At -F ' | ' -f /tmp/p3/monitor.sql >> $log 2>&1; sleep 0.3; done; touch $done"
    docker exec -d $Container sh -c $inner
    if ($LASTEXITCODE -ne 0) {
        throw "Could not start pg_stat_activity monitor for '$Id'"
    }
}

function Stop-Monitor([string]$Id) {
    $log  = "/tmp/p3/monitor-$Id.log"
    $stop = "/tmp/p3/monitor-$Id.stop"
    $done = "/tmp/p3/monitor-$Id.done"

    docker exec $Container touch $stop *> $null
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if (Test-ContainerFile $done) { break }
        Start-Sleep -Milliseconds 200
    }
    return (Get-ContainerText $log)
}

function Wait-ForSessions {
    param([string[]]$Names)

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        $allDone = $true
        foreach ($n in $Names) {
            if (-not (Test-ContainerFile "/tmp/p3/$n.done")) {
                $allDone = $false
                break
            }
        }
        if ($allDone) { return }
        Start-Sleep -Milliseconds 300
    }

    throw "Timed out after $TimeoutSeconds s waiting for sessions: $($Names -join ', ')"
}

function Run-ConcurrentScenario {
    param(
        [string]$Id,
        [string]$Title,
        [string]$Description,
        [string]$AFile,
        [string]$BFile,
        [string]$AArgs = '',
        [string]$BArgs = '',
        [string]$CheckSql
    )

    Write-Host ("Capturing {0} - {1}" -f $Id, $Title)

    Reset-Scenario

    Start-Monitor $Id

    # Use fixed internal names; the evidence title identifies the scenario.
    Start-DbSession 'session-a' $AFile $AArgs
    Start-Sleep -Milliseconds $SessionDelayMs
    Start-DbSession 'session-b' $BFile $BArgs

    Wait-ForSessions -Names @('session-a', 'session-b')

    $logA  = Get-ContainerText '/tmp/p3/session-a.log'
    $logB  = Get-ContainerText '/tmp/p3/session-b.log'
    $exitA = Get-ContainerText '/tmp/p3/session-a.exit'
    $exitB = Get-ContainerText '/tmp/p3/session-b.exit'
    $monitor = Stop-Monitor $Id
    $check = (Invoke-PsqlText $CheckSql) -join "`n"

    $commandA = "docker compose exec -T postgres psql -U portfolio -d $Database -X -v ON_ERROR_STOP=0 $AArgs -f portfolio-3-transactions-concurrency/sessions/$AFile"
    $commandB = "docker compose exec -T postgres psql -U portfolio -d $Database -X -v ON_ERROR_STOP=0 $BArgs -f portfolio-3-transactions-concurrency/sessions/$BFile"

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine("Portfolio 3 - $Id - $Title")
    [void]$sb.AppendLine(('=' * 78))
    [void]$sb.AppendLine("Captured: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$sb.AppendLine("Description: $Description")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Two independent psql connections were used. Session B was launched')
    [void]$sb.AppendLine("$SessionDelayMs ms after A's launch; psql startup adds a short delay, so the")
    [void]$sb.AppendLine('timestamps printed by the sessions are the authoritative ordering.')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Commands:')
    [void]$sb.AppendLine("  A: $commandA")
    [void]$sb.AppendLine("  B: $commandB")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- SESSION A OUTPUT (exit ' + $exitA.Trim() + ') ---')
    [void]$sb.AppendLine($logA)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- SESSION B OUTPUT (exit ' + $exitB.Trim() + ') ---')
    [void]$sb.AppendLine($logB)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- pg_stat_activity MONITOR (~350 ms samples) ---')
    [void]$sb.AppendLine('sampled_at | pid | state | wait_type | wait_event | xact_age_s | query')
    [void]$sb.AppendLine($monitor)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('--- POST-RUN CHECK ---')
    [void]$sb.AppendLine($check)
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('Evidence note: the session logs are raw psql output. Expected errors')
    [void]$sb.AppendLine('(23P01, 40001) are not suppressed; they are the result being shown.')

    $outPath = Join-Path $EvidenceDir "$Id.txt"
    Write-Utf8 $outPath $sb.ToString()
    Write-Host ("  wrote {0}" -f $outPath)

    return [pscustomobject]@{
        Id      = $Id
        Check   = ($check -replace '\s+', ' ').Trim()
        ExitA   = $exitA.Trim()
        ExitB   = $exitB.Trim()
    }
}

Push-Location $repoRoot
try {
    Assert-Container

    docker exec $Container sh -c 'rm -rf /tmp/p3 && mkdir -p /tmp/p3' *> $null
    if ($LASTEXITCODE -ne 0) { throw 'Could not prepare /tmp/p3 in the container' }

    Copy-ToContainer (Join-Path $p3Root 'transactions.sql') '/tmp/p3/transactions.sql'
    foreach ($f in Get-ChildItem -Path $sessDir -Filter '*.sql' -File) {
        Copy-ToContainer $f.FullName "/tmp/p3/$($f.Name)"
    }

    # Initial cleanup of an older schema's tracked lab orders, then a clean
    # demo schema and reset of P3 test appointments.
    $setup = @'
SET TIME ZONE 'UTC';
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'p3_demo' AND table_name = 'lab_order_ids'
    ) THEN
        DELETE FROM lab_order
        WHERE lab_order_id IN (SELECT lab_order_id FROM p3_demo.lab_order_ids);
    END IF;
END $$;
DROP SCHEMA IF EXISTS p3_demo CASCADE;
CREATE SCHEMA p3_demo;
CREATE TABLE p3_demo.booking_unprotected (
    booking_id  uuid        PRIMARY KEY,
    doctor_id   uuid        NOT NULL,
    patient_id  uuid        NOT NULL,
    slot_start  timestamptz NOT NULL,
    slot_end    timestamptz NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE p3_demo.on_call (
    doctor_id  uuid    PRIMARY KEY,
    on_duty    boolean NOT NULL
);
INSERT INTO p3_demo.on_call (doctor_id, on_duty)
SELECT staff_id, true
FROM doctor_profile
WHERE license_no IN ('KMPDC-000001', 'KMPDC-000002');
DELETE FROM appointment WHERE reason LIKE 'P3 TEST%';
'@
    Invoke-PsqlText $setup | Out-Null

    # ------------------------------------------------------------------
    # Single-session tests
    # ------------------------------------------------------------------
    Write-Host 'Capturing transactions.sql - COMMIT, ROLLBACK, SAVEPOINT'
    $txOut = docker exec $Container sh -c "psql -U portfolio -d $Database -X -v ON_ERROR_STOP=0 -f /tmp/p3/transactions.sql 2>&1"
    $txExit = $LASTEXITCODE
    $txLines = @($txOut | ForEach-Object { "$_" })

    $txSb = New-Object System.Text.StringBuilder
    [void]$txSb.AppendLine(('=' * 78))
    [void]$txSb.AppendLine('Portfolio 3 - single-session transaction tests')
    [void]$txSb.AppendLine(('=' * 78))
    [void]$txSb.AppendLine("Captured: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
    [void]$txSb.AppendLine("Command: docker compose exec -T postgres psql -U portfolio -d $Database -X -v ON_ERROR_STOP=0 -f portfolio-3-transactions-concurrency/transactions.sql")
    [void]$txSb.AppendLine("Exit: $txExit")
    [void]$txSb.AppendLine('')
    [void]$txSb.AppendLine(($txLines -join "`n"))
    [void]$txSb.AppendLine('')
    [void]$txSb.AppendLine('Evidence note: the T2 exclusion violation and the T3 CHECK violation are')
    [void]$txSb.AppendLine('expected errors. The following statements prove that ROLLBACK and')
    [void]$txSb.AppendLine('ROLLBACK TO SAVEPOINT removed exactly the intended rows.')
    Write-Utf8 (Join-Path $EvidenceDir 'transactions.txt') $txSb.ToString()
    Write-Host ("  wrote {0}" -f (Join-Path $EvidenceDir 'transactions.txt'))
    if ($txExit -ne 0) {
        throw "transactions.sql failed with exit code $txExit"
    }

    # ------------------------------------------------------------------
    # Two-session tests
    # ------------------------------------------------------------------
    $results = @()

    $results += Run-ConcurrentScenario `
        -Id '01-unprotected' `
        -Title 'double-booking anomaly without a database constraint' `
        -Description 'Both sessions see the slot free and both commit a booking. This is the failure mode the exclusion constraint exists to prevent.' `
        -AFile '01-unprotected-a.sql' `
        -BFile '01-unprotected-b.sql' `
        -CheckSql @'
SELECT count(*) AS rows_for_slot_after_both_commits
FROM p3_demo.booking_unprotected
WHERE slot_start = TIMESTAMPTZ '2031-03-01 09:00:00+00';
'@

    $results += Run-ConcurrentScenario `
        -Id '02-exclusion' `
        -Title 'double-booking prevented by no_double_booking' `
        -Description 'The same race on the real appointment table. The second insert blocks on the GiST exclusion index, then raises SQLSTATE 23P01 after A commits.' `
        -AFile '02-exclusion-a.sql' `
        -BFile '02-exclusion-b.sql' `
        -CheckSql @'
SELECT count(*) AS rows_for_slot_after_race
FROM appointment
WHERE slot_start = TIMESTAMPTZ '2031-03-04 09:00:00+00';
'@

    $results += Run-ConcurrentScenario `
        -Id '03-pessimistic' `
        -Title 'pessimistic control with SELECT ... FOR UPDATE' `
        -Description 'Session A locks the doctor row. B blocks until A commits, then re-checks availability and abandons its own booking. The monitor records the lock wait.' `
        -AFile '03-pessimistic-a.sql' `
        -BFile '03-pessimistic-b.sql' `
        -CheckSql @'
SELECT count(*) AS rows_for_slot_after_pessimistic_test
FROM appointment
WHERE slot_start = TIMESTAMPTZ '2031-03-04 11:00:00+00';
'@

    $results += Run-ConcurrentScenario `
        -Id '04-read-committed' `
        -Title 'non-repeatable read under READ COMMITTED' `
        -Description 'A reads the patient appointment count, B commits an insert, A reads again. The second read sees the new row.' `
        -AFile '04-isolation-a.sql' `
        -BFile '04-isolation-b.sql' `
        -AArgs "-v iso='READ COMMITTED'" `
        -BArgs "-v p3_slot='2031-03-05 09:00:00+00'" `
        -CheckSql @'
SELECT count(*) AS test_rows_after_rc_run
FROM appointment WHERE reason = 'P3 TEST isolation';
'@

    $results += Run-ConcurrentScenario `
        -Id '05-repeatable-read' `
        -Title 'repeatable read under REPEATABLE READ' `
        -Description 'The same two reads. The transaction snapshot is taken at the first read, so the second read returns the original count even though B committed.' `
        -AFile '04-isolation-a.sql' `
        -BFile '04-isolation-b.sql' `
        -AArgs "-v iso='REPEATABLE READ'" `
        -BArgs "-v p3_slot='2031-03-05 10:00:00+00'" `
        -CheckSql @'
SELECT count(*) AS test_rows_after_rr_run
FROM appointment WHERE reason = 'P3 TEST isolation';
'@

    $results += Run-ConcurrentScenario `
        -Id '06-write-skew-read-committed' `
        -Title 'write skew under READ COMMITTED' `
        -Description 'Each transaction reads both doctors as on duty and takes only its own row off duty. Both commit, leaving nobody on duty.' `
        -AFile '05-write-skew-a.sql' `
        -BFile '05-write-skew-b.sql' `
        -AArgs "-v iso='READ COMMITTED'" `
        -BArgs "-v iso='READ COMMITTED'" `
        -CheckSql @'
SELECT count(*) AS doctors_on_duty_after_rc_write_skew
FROM p3_demo.on_call WHERE on_duty;
'@

    $results += Run-ConcurrentScenario `
        -Id '07-write-skew-serializable' `
        -Title 'write skew prevented by SERIALIZABLE' `
        -Description 'The same roster transactions at SERIALIZABLE. One transaction aborts with SQLSTATE 40001; one doctor remains on duty.' `
        -AFile '05-write-skew-a.sql' `
        -BFile '05-write-skew-b.sql' `
        -AArgs "-v iso='SERIALIZABLE'" `
        -BArgs "-v iso='SERIALIZABLE'" `
        -CheckSql @'
SELECT count(*) AS doctors_on_duty_after_serializable_write_skew
FROM p3_demo.on_call WHERE on_duty;
'@

    # ------------------------------------------------------------------
    # Final cleanup and machine-readable summary of the post-run checks.
    # ------------------------------------------------------------------
    $cleanup = @'
SET TIME ZONE 'UTC';
DELETE FROM appointment WHERE reason LIKE 'P3 TEST%';
DELETE FROM lab_order
WHERE lab_order_id IN (SELECT lab_order_id FROM p3_demo.lab_order_ids);
DROP SCHEMA IF EXISTS p3_demo CASCADE;
SELECT count(*) AS p3_test_appointments_left
FROM appointment WHERE reason LIKE 'P3 TEST%';
'@
    $cleanupOut = Invoke-PsqlText $cleanup
    $cleanupText = @(
        '============================================================'
        'Portfolio 3 - cleanup'
        '============================================================'
        'Fixtures are removed and the demo schema is dropped.'
        ''
    ) + $cleanupOut
    Write-Utf8Lines (Join-Path $EvidenceDir '08-cleanup.txt') $cleanupText

    $csv = New-Object System.Text.StringBuilder
    [void]$csv.AppendLine('scenario,session_a_exit,session_b_exit,post_run_check')
    foreach ($r in $results) {
        $check = $r.Check.Replace('"', '""')
        [void]$csv.AppendLine(('"{0}","{1}","{2}","{3}"' -f $r.Id, $r.ExitA, $r.ExitB, $check))
    }
    Write-Utf8 (Join-Path $EvidenceDir 'summary.csv') $csv.ToString()

    Write-Host ''
    Write-Host 'Portfolio 3 capture complete.'
    Write-Host ("Evidence: {0}" -f $EvidenceDir)
}
finally {
    Pop-Location
    if (Test-Path $tempDir) {
        Remove-Item -Recurse -Force $tempDir -ErrorAction SilentlyContinue
    }
}
