# Portfolio 5 — Distributed and Cloud Database

**Marks:** 6 / 40
**Status:** complete
**Case study:** Riverbend Teaching Hospital — the same clinical records system used in Portfolios 1–4.

This portfolio delivers a real, reproducible PostgreSQL streaming-replication
deployment and uses it to answer the distributed-database question for the
hospital: **which reads may be served from a replica, what does a stale read
look like, and what happens when the primary fails?**

The short answer: a primary plus one hot-standby replica is a good fit for a
read-heavy hospital, but only if the application stops treating the replica as
transparent. The deployment measured 525 ms of replica lag under a 50,000-row
burst, captured a read-your-writes stale read, and routed that read to the
primary until replay caught up. Manual promotion completed in 2.95 s and lost
zero rows because the replica was deliberately caught up first; asynchronous
replication still has a non-zero RPO in a real crash.

---

## Requirements Mapping

| Requirement | Where it is addressed |
|---|---|
| Discussion or setup based on the same case study | Same Riverbend schema and seed data; `architecture.md` §1–2 |
| Replication **or** sharding | PostgreSQL 16 streaming replication; primary + hot standby; `architecture.md` §3 |
| Availability / consistency trade-off | Measured lag, stale read, lag-aware router, sync vs async, RPO/RTO; `architecture.md` §4, §6–7 |
| Deployment evidence (configs, command output, logs) | `evidence/00`–`07`, `config/`, `replication-setup.ps1` |

The brief allows a discussion instead of a cloud deployment. This is a small
deployment **plus** the discussion: every mechanism claimed below has raw output
behind it, and the production-scale caveats are stated rather than hidden.

---

## What Was Deployed

```text
writes ───────────────▶ primary (read/write)
                         │
                         │ WAL streaming, async by default
                         ▼
reads ──▶ lag-aware ──▶ replica (hot standby, read-only)
          router
```

| Component | Value |
|---|---|
| Database | PostgreSQL 16.15 (`postgres:16`) |
| Topology | One primary, one hot-standby replica |
| Network | Private Docker network `portfolio-p5-repl`; no host ports |
| Replication | WAL streaming; `wal_level=replica`, `max_wal_senders=5`, `wal_keep_size=256MB` |
| Default mode | Asynchronous (`sync_state=async`) |
| Synchronous demo | `synchronous_standby_names = 'ANY 1 ("portfolio-p5-replica")'` → `sync_state=quorum` |
| Lag measurement | `track_commit_timestamp=on`; commit time → first replica visibility |
| Failover | Manual `pg_promote(true, 60)` |
| Data | Same synthetic schema/seed as P1–P4; P5 reloads it independently |

The P5 cluster is separate from `portfolio-postgres`. Rebuilding P5 does not
touch Portfolios 1–4.

---

## Reproduce It

Prerequisites: Docker Desktop and Windows PowerShell 5.1+ (the tested path).
`replication-setup.ps1` only needs Docker and PowerShell, but `capture-p5.ps1`
also uses `cmd.exe` to merge Docker's log streams, so the evidence capture is
Windows-specific. The captured evidence is from Windows PowerShell 5.1.

```powershell
# Build the primary, load schema + seed, take the base backup, start the replica
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 up -Force

# Inspect streaming state, write on the primary, read on the replica
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 status

# Measure commit-to-visible lag under a 50,000-row burst
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 lag

# Compare synchronous and asynchronous commit latency
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 sync

# Pause replay, show the stale read, route to the primary, resume
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 stale

# Effective settings, pg_hba line and replica connection config
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 configs

# Stop the primary, promote the replica, write to the new primary
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 failover

# Remove the P5 containers, volumes and network
powershell -NoProfile -ExecutionPolicy Bypass -File `
  portfolio-5-distributed-cloud/replication-setup.ps1 down
```

`up -Force` is destructive: it removes the existing P5 containers, both
volumes and the network before rebuilding. That is intentional; the report is
based on a clean rebuild, not a hand-edited cluster.

To regenerate all evidence in one run:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/capture-p5.ps1
```

The capture is also destructive and takes several minutes because it reloads
the full seed data. Use `-SkipSetup` only when the P5 cluster is already running
and you want to recapture the later steps.

---

## Evidence

All files are raw command output with the step title, timestamp, host, exit
status and elapsed time. The final report uses only the run captured at
**2026-10-29 07:55 +01:00** (`base git commit 329901c`).

| File | What it proves |
|---|---|
| [`evidence/00-environment.txt`](evidence/00-environment.txt) | Host, Docker, PostgreSQL image, disk, capture metadata |
| [`evidence/01-setup.txt`](evidence/01-setup.txt) | Clean rebuild: schema/seed load, base backup, replica start, streaming |
| [`evidence/02-replication.txt`](evidence/02-replication.txt) | `pg_stat_replication`, recovery state, write-on-primary/read-on-replica, logs |
| [`evidence/03-lag.txt`](evidence/03-lag.txt) | 50,000-row burst and measured commit-to-visible lag |
| [`evidence/04-sync-vs-async.txt`](evidence/04-sync-vs-async.txt) | `sync_state=quorum`, ten commits per mode, median timings |
| [`evidence/05-stale-read.txt`](evidence/05-stale-read.txt) | Paused replay, stale read, lag-aware router, resume |
| [`evidence/06-configs.txt`](evidence/06-configs.txt) | Effective settings, `pg_hba` replication line, replica `postgresql.auto.conf`, committed fragments |
| [`evidence/07-failover.txt`](evidence/07-failover.txt) | Primary stop, promotion, post-failover write, zero rows lost |

The committed configuration fragments are in [`config/`](config/):
`primary.conf`, `replica.conf` and `pg_hba-replication.conf`. The live values
are printed in `06-configs.txt` so the fragments can be checked against the
running cluster.

The `FATAL` lines in the primary/replica logs are expected: the primary's
`FATAL: database "hospital" does not exist` is the entrypoint's pre-`CREATE
DATABASE` probe, and the replica's `FATAL: the database system is starting up`
lines are readiness checks during recovery startup. The authoritative signals
are the `state=streaming` row and the successful post-failover write.

---

## Results

### 1. Streaming replication

`evidence/02-replication.txt` shows the primary's view:

```text
application_name     | client_addr | state     | sync_state | sent_lsn  | replay_lsn | lag_bytes
portfolio-p5-replica | 172.19.0.3  | streaming | async      | 0/21022D60| 0/21022D60 | 0
```

The replica reports `pg_is_in_recovery = t`, `transaction_read_only = on`, and
the same received/replayed LSN. A row written on the primary at
`2026-10-29 07:00:28.2126+00` was read back on the replica with the same
`created_at` value; the primary insert took 6.173 ms and the replica read took
5.015 ms in that capture.

### 2. Measured lag

`evidence/03-lag.txt` inserts 50,000 rows while a replica-side poll is already
running. Measuring from `pg_xact_commit_timestamp` avoids counting client
start-up time:

| Measurement | Value |
|---|---:|
| Burst size | 50,000 rows |
| Primary insert time | 1,427.431 ms |
| Approximate insert rate | ~35,000 rows/s |
| **Commit-to-first-visible lag** | **525.469 ms** |
| Poll wall time (includes insert) | 2,787.977 ms |

This is the normal lag measurement. The 9.0 s figure in the stale-read step is
an intentional replay pause, not normal replication lag; the capture labels it
that way.

### 3. Synchronous vs asynchronous commit

`evidence/04-sync-vs-async.txt` first shows the important distinction:

- `synchronous_commit=on` with an empty `synchronous_standby_names` is still
  **asynchronous** replication (`sync_state=async`).
- Setting `synchronous_standby_names = 'ANY 1 ("portfolio-p5-replica")'` changes
  the standby to `sync_state=quorum`; only then does a commit wait for the
  standby.

Ten single-row commits in each mode:

| Mode | Min | Median | Max |
|---|---:|---:|---:|
| Synchronous (`ANY 1`) | 12.338 ms | **16.913 ms** | 23.055 ms |
| Asynchronous | 4.097 ms | **6.971 ms** | 16.915 ms |

The median difference is about 9.9 ms on a loopback Docker network. The numbers
include the psql client round trip and are an order-of-magnitude comparison, not
a throughput benchmark. The bigger cost of synchronous mode is availability: if
the named standby is down, writes wait.

### 4. Stale read and mitigation

`evidence/05-stale-read.txt` is the step that separates replication working from
replication being usable:

1. Replay is paused on the replica.
2. A row is committed on the primary at `2026-10-29 07:00:52.940614+00`.
3. The immediate replica read returns **0 rows**.
4. The replica has **296 bytes** of received-but-unapplied WAL.
5. The lag-aware router compares the primary LSN `0/21BF37B8` with the replica
   replay LSN `0/21BF3690`, sees a non-zero difference, and sends the read to
   the primary. The primary returns **1 row**.
6. Replay is resumed. The row becomes visible on the replica, the LSNs match,
   and the router serves the read from the replica.

The mitigation is deliberately a **heuristic**: lag can change between the LSN
check and the query. It bounds the stale window; it does not prove
linearizability. A booking path should also use a synchronous commit or a
read-your-writes token. The report says this rather than claiming the router
solves consistency completely.

### 5. Failover

`evidence/07-failover.txt` stops the primary and promotes the replica:

| Step | Measured |
|---|---:|
| `docker stop` primary | 1,973.4 ms |
| `pg_promote(true, 60)` call | 1,698.7 ms |
| Promotion complete (`pg_is_in_recovery = f`) | **2,946.7 ms** |
| Post-failover write | succeeded (`probe_id 50029`) |
| Probe rows before / after | 50,022 / 50,023 |
| Rows lost | **0** |
| Remaining upstreams | 0 |

The 0-row loss is a **controlled** result: the script waited until
`pg_stat_replication` showed zero lag before stopping the primary. It does not
mean asynchronous replication has RPO 0. A crash at an arbitrary moment can
lose the last transactions that had not reached the standby. The ~2.95 s is
promotion time, not full RTO; detection, decision, service repointing and client
reconnection are outside that measurement.

---

## Design Decisions and Trade-offs

| Decision | Why | What it costs |
|---|---|---|
| Async replication by default | Primary stays writable if the replica is slow or down; best write latency | Non-zero RPO on a primary crash |
| Sync mode demonstrated, not default | Shows the zero-acknowledged-loss option for booking writes | A missing standby can stall writes |
| One replica | Minimum to demonstrate streaming, routing and promotion | Reporting load competes with the failover target |
| Lag-aware routing | Keeps read scaling while bounding staleness | LSN check is a race; not a linearizability guarantee |
| Manual `pg_promote` | Simple, auditable, appropriate for a 6-mark exercise | No automatic detection/fencing; split-brain risk if the old primary returns |
| No replication slot | Avoids unbounded WAL accumulation on the primary | A long replica outage may require a fresh base backup |
| `archive_mode=off` | Out of scope for a replication demo | No PITR; streaming replication is not a backup |
| No host ports | Isolates P5 from P1–P4 and from the host | A real client would need the Docker network or a proxy |

`architecture.md` covers the CAP framing, partitioning/sharding reasoning,
failure modes, cost, monitoring and migration notes in more detail.

---

## What This Deployment Is Not

- It is **not** a multi-AZ or multi-region deployment. Both containers share one
  Docker Desktop VM and one disk.
- It is **not** an automatic failover system. There is no Patroni, fencing or
  leader election; restarting the old primary after promotion could create a
  split-brain.
- It is **not** a backup. `archive_mode=off`; a dropped table is replicated
  immediately and there is no PITR.
- It is **not** a load test. The 50,000-row burst is a controlled write burst,
  not a hospital workload; peak sessions and the read/write ratio are not
  measured.
- It is **not** a claim that sharding is unnecessary forever. At 317 MB and
  20,000 patients, sharding would be premature; the shard-key and global-MRN
  problems are discussed in `architecture.md` §5.

---

## P5 Files

| File | Purpose |
|---|---|
| `README.md` | This report: results, evidence index, reproduction |
| `architecture.md` | Workload, replication design, consistency, sharding, availability, CAP, operations, limitations |
| `replication-setup.ps1` | Reproducible `up` / `status` / `lag` / `sync` / `stale` / `configs` / `failover` / `down` harness |
| `config/primary.conf` | Primary settings fragment |
| `config/replica.conf` | Replica settings fragment |
| `config/pg_hba-replication.conf` | Replication authentication rule |
| `config/README.md` | How the fragments map to the running cluster |
| `evidence/00`–`07` | Raw final-run output |
| `../scripts/capture-p5.ps1` | One-command evidence capture |

---

## Data and AI Use

All patient, staff and laboratory data is **synthetic**, generated by
`portfolio-1-database-design/seed-data.sql`. No real patient data is used,
stored or derived. The P5 cluster is local-only and publishes no host ports.

AI use is recorded in [`../docs/ai-use-declaration.md`](../docs/ai-use-declaration.md),
Entry 6. The short version: the harness and report were drafted with OpenCode
(DeepSeek V4.1 Flash Free); the deployment was executed, the output inspected,
and the report's numbers were checked against the committed evidence files. The
mistakes found during that process — the Docker init race, PowerShell treating
`docker logs` stderr as fatal, the UTF-8 config echo, and the promotion timing
including a temp-file copy — are recorded there rather than hidden.
