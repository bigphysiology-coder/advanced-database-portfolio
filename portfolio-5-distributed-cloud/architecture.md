# Distributed and Cloud Architecture

**Case study:** Riverbend Teaching Hospital — clinical records system.
**Scope:** how the database is distributed, what that costs, and what the
Portfolio 5 deployment actually proves.

This document describes the delivered PostgreSQL 16 streaming-replication
deployment and the reasoning behind it. The deployment is deliberately small:
one primary and one hot-standby replica on a single Docker host. That is enough
to exercise the mechanism and measure the trade-off; it is not a claim of
production high availability.

---

## 1. Workload Characterisation

The P5 cluster was rebuilt from the same synthetic schema and seed generator as
Portfolios 1–4. The final evidence run loaded a 317 MB database with these
counts (see `evidence/01-setup.txt`):

| Relation | Rows | Total size |
|---|---:|---:|
| `audit_log` | 227,176 | 151 MB |
| `lab_result` | 164,292 | 54 MB |
| `prescription` | 125,176 | 22 MB |
| `appointment` | 82,000 | 16 MB |
| `lab_order` | 93,889 | 14 MB |
| `diagnosis` | 93,889 | 14 MB |
| `encounter` | 62,588 | 13 MB |
| `vitals` | 62,588 | 9.5 MB |
| `patient` | 20,000 | — |

The P5 counts differ by a few rows from P1/P4 because the seed generator hashes
random UUIDs when choosing some related rows. The P5 evidence is internally
consistent; comparisons in this document use the P5 counts above.

| Metric | Value | Status / source |
|---|---|---|
| Read/write ratio | Assumed ~80/20 | **Not measured.** The user mix is read-heavy (reception, clinicians, reporting, audit), but no production statement trace exists. This is a design assumption, not a captured statistic. |
| Peak concurrent sessions | Not load-tested | The demo uses one client per step. A production figure needs `pg_stat_activity` sampling under a representative workload. |
| Largest relation | `audit_log`, 151 MB | `pg_total_relation_size` on the P5 data |
| Database size | 317 MB | `pg_database_size` |
| Growth per month | Not modelled | The seed is a snapshot, not a time series. Capacity planning would use appointment/encounter/lab-result arrival rates. |
| Cross-entity transactions | Booking, encounter, lab result | These touch several relations plus `audit_log` in one transaction, which constrains later sharding. |

The cross-entity transactions are the important design constraint. A booking
updates `appointment` and writes `audit_log`; an encounter writes `encounter`,
`vitals`, `diagnosis`, `prescription` and `audit_log`; a lab result writes
`lab_order`, `lab_result` and `audit_log`. Splitting those across shards would
turn a local ACID transaction into a distributed transaction or a saga. At this
volume there is no reason to pay that cost.

---

## 2. Architecture

```text
                         ┌─────────────────────────────┐
   writes, read-your-    │        application          │
   writes reads ────────▶│  lag-aware read router      │
                         └──────────┬──────────┬───────┘
                                    │          │
                         writes     │          │ reads when replay LSN
                         always     │          │ is caught up
                                    ▼          ▼
                         ┌─────────────────────────────┐
                         │      portfolio-p5-primary   │
                         │  PostgreSQL 16, read/write  │
                         └──────────┬──────────────────┘
                                    │ WAL streaming
                                    │ (async by default)
                         ┌──────────▼──────────────────┐
                         │      portfolio-p5-replica   │
                         │  hot standby, read-only     │
                         │  promotion target           │
                         └─────────────────────────────┘

             both containers attach only to the private
             Docker network `portfolio-p5-repl`; no host ports
```

The deployed facts, all visible in `evidence/`:

- Primary and replica are separate `postgres:16` containers.
- The replica was created with `pg_basebackup -Fp -Xs -P -R
  --checkpoint=fast`; `-R` wrote `standby.signal` and `primary_conninfo`.
- `wal_level=replica`, `max_wal_senders=5`, `wal_keep_size=256MB`,
  `hot_standby=on`.
- `track_commit_timestamp=on` is set so lag can be measured from the commit
  timestamp to first visibility on the replica.
- Replication authentication is `scram-sha-256` for role `replicator`.
- No host ports are published. The only route to either database is the
  isolated Docker network, which keeps the exercise separate from the P1–P4
  `portfolio-postgres` container.

The application router is deliberately shown as part of the architecture. A
read replica is not transparent: the moment a client can read from it, the
system has to decide which reads may be stale. That decision lives in the
router, not in PostgreSQL.

---

## 3. Replication Design

| Decision | Choice | Justification |
|---|---|---|
| Async vs sync commit | **Asynchronous by default**; synchronous mode measured separately | Async keeps the primary writable when the replica is slow or unavailable. Synchronous mode is demonstrated with `synchronous_standby_names = 'ANY 1 ("portfolio-p5-replica")'` for the operations that need zero acknowledged-commit loss. |
| Number of replicas | **One** | The minimum needed to show streaming, read routing, lag and promotion. A production hospital would use at least two: one synchronous failover target and one asynchronous reporting replica. |
| Replica purpose | **Both read scaling and failover** | A single replica is a compromise. A reporting query that pins the replica also delays the failover target, which is a real operational weakness. |
| Read routing | **Lag-aware routing** | Compare the primary's current WAL LSN with the replica's replay LSN. If the replica is caught up, serve the read there; otherwise send it to the primary. |
| Failover mechanism | **Manual `pg_promote`** | Small enough to demonstrate and audit. Production should use an orchestrator (Patroni, CloudNativePG, or a managed multi-AZ service) with fencing and leader election. |
| WAL retention | `wal_keep_size=256MB`, no replication slot | A slot would prevent WAL removal if the replica disappears, but can fill the primary's disk. For this demo, a bounded retention window is safer and the failure is explicit. |
| Archiving | `archive_mode=off` | Streaming replication is not a backup. PITR is outside this exercise and is listed as a limitation. |

### Why asynchronous is the default

The primary commits without waiting for the replica to flush. That gives the
best write latency and, more importantly, keeps admissions, prescribing and
booking available when the replica is down. The cost is a non-zero RPO: a
primary crash can lose the last transactions that had not reached the standby.

### What synchronous mode changes

`sync_state=quorum` appears only after `synchronous_standby_names` is set. With
`ANY 1 ("portfolio-p5-replica")`, a commit is acknowledged only after one named
standby confirms it. If that standby is unavailable, writes wait. This is the
correct trade for a booking commit only if the hospital prefers a stalled
booking to a lost booking. It is not a good default for every write in the
system.

The final capture measured ten single-row commits in each mode (see
`evidence/04-sync-vs-async.txt`):

| Mode | Min | Median | Max | Standby state |
|---|---:|---:|---:|---|
| Synchronous (`ANY 1`) | 12.338 ms | **16.913 ms** | 23.055 ms | `quorum` |
| Asynchronous | 4.097 ms | **6.971 ms** | 16.915 ms | `async` |

The medians differ by about 9.9 ms on this loopback Docker network. That is a
latency observation, not a throughput benchmark: each timing includes the psql
client round trip. The more important cost of synchronous mode is availability,
which the millisecond table does not show.

---

## 4. Consistency

### The problem

A clinician books an appointment and immediately opens the schedule. If the
read goes to a replica that has not replayed the booking's WAL, the appointment
is missing. The write succeeded, but the user sees it vanish.

The final run demonstrates this directly (`evidence/05-stale-read.txt`):

1. WAL replay on the replica is paused.
2. A probe row representing a just-booked appointment is committed on the
   primary at `2026-10-29 07:00:52.940614+00`.
3. The immediate read on the replica returns **0 rows**.
4. The replica has received the WAL but has **296 bytes** of unapplied WAL.
5. The router compares `0/21BF37B8` (primary) with `0/21BF3690` (replica replay)
   and sends the read to the primary, which returns **1 row**.
6. Replay is resumed; the row becomes visible and the router then chooses the
   replica because the LSNs match.

### Measured lag under load

The normal lag measurement does not pause replay. A 50,000-row burst was
inserted on the primary while a replica-side poll was already running. The
commit timestamp came from `pg_xact_commit_timestamp`; the visibility timestamp
came from the first poll that saw all 50,000 rows (`evidence/03-lag.txt`):

| Measurement | Value |
|---|---:|
| Burst size | 50,000 rows |
| Primary insert time | 1,427.431 ms |
| Approximate insert rate | ~35,000 rows/s |
| **Commit-to-visible lag on replica** | **525.469 ms** |
| Poll wall time (includes the insert) | 2,787.977 ms |
| Commit timestamp | `2026-10-29 07:00:35.573895+00` |
| First replica observation | `2026-10-29 07:00:36.099364+00` |

Half a second is the lag for a burst of 50,000 rows written in about 1.4 s; it
is not a production SLA. It is enough to show that the stale-read window is
real and measurable, not theoretical.

### Mitigation chosen: lag-aware routing

Before serving a read from the replica, the router checks:

```text
primary current WAL LSN  vs  replica replay LSN
```

If the difference is zero, the replica is caught up and can serve the read. If
it is non-zero, the read goes to the primary. The captured router does exactly
that and switches back to the replica after replay catches up.

**Why this rather than the alternatives?**

- **Sticky routing** (send the writer's session to the primary for N seconds) is
  simpler, but it only protects the writer. Another clinician opening the same
  schedule can still be routed to a lagging replica.
- **Synchronous commit on every write** removes the stale-read window, but
  makes every write depend on the standby's availability. It is the right tool
  for a booking commit, not for every audit or lab-ingestion write.
- **Lag-aware routing** keeps the read fleet useful and bounds staleness to the
  router's check interval. It is not a linearizability guarantee: lag can
  change between the check and the query. The router is a heuristic that makes
  staleness unlikely and observable, not a proof that it cannot happen.

For a real booking path, the defensible combination is a synchronous commit (or
a read-your-writes token) for the booking transaction, plus lag-aware routing
for everything else. The demo implements lag-aware routing and measures
synchronous mode separately; it does not implement a per-booking synchronous
commit policy.

---

## 5. Partitioning and Sharding

Sharding is **not implemented**. At 317 MB and 20,000 patients, it would add
operational complexity without solving a measured bottleneck. Replication is
the appropriate first step because the workload is read-heavy and the main
availability risk is a single primary.

### Partitioning considered

| Candidate | Benefit | Cost |
|---|---|---|
| `lab_result` by `collected_at` (monthly) | Pruning for date-range reports; cheaper vacuum; old partitions can be archived | Partition management; cross-partition queries; unique constraints must include the partition key; more complex migrations |
| `audit_log` by `occurred_at` (monthly) | Append-only data is a natural fit; retention becomes a partition drop | Same management burden; auditors query across long ranges |
| `appointment` by `slot_start` (monthly) | Helps schedule reports and old-appointment cleanup | Booking checks still need a global exclusion constraint, which is difficult across partitions |

Partitioning is a storage and maintenance technique, not distribution. It does
not give a second machine or a second failure domain.

### If the hospital scaled to regions

The natural shard key for operational data is **`(region, hospital_id)`**:
appointments, encounters, admissions and staff belong to a hospital, and most
queries already filter by that context. The hard problem is the identifier that
must remain global: a patient's medical record number (MRN). A sequence local
to one shard cannot guarantee global uniqueness.

Options, in order of preference:

1. **Central ID allocator** — a small, highly available service issues MRNs;
   the shard stores the patient row under that ID. This keeps the MRN readable
   and unique but adds a dependency on the booking path.
2. **UUIDv7 or another time-ordered global ID** — no central service, but the
   human-facing MRN still needs a separate unique attribute. UUIDv7 also gives
   better index locality than UUIDv4.
3. **Composite key including the region** — `(region, local_mrn)`. This is
   simple, but the same patient crossing regions now has two identities unless
   a master patient index reconciles them.

A patient moving between regions is the cross-shard transaction that makes
sharding hard: the encounter history, appointments and prescriptions may span
shards. A real design would need a master patient index plus either a
distributed transaction protocol or a compensating saga. Naming that problem
is more useful than claiming sharding is a simple scale-out switch.

---

## 6. Availability

| Failure | Detection | Response | Data loss |
|---|---|---|---|
| Replica down | `pg_stat_replication` row disappears; replica health check fails; lag alert | Keep writing to primary; route reads to primary or another replica; rebuild the replica from a base backup | None on the primary. The replica may be stale on return. |
| Primary down | Client connection failures; health check; orchestrator heartbeat | Manual/automated promotion of the replica; repoint the router; fence the old primary | **Async default: non-zero RPO.** The controlled demo lost 0 rows because it waited for catch-up before stopping the primary. |
| Network partition | Health checks fail on one side; replication lag grows; split-brain detector | Fence the old primary before promotion; do not let both accept writes; degrade reads according to the router policy | Depends on which side accepted writes. Without fencing, divergence is possible. |
| Region outage | Provider health events; cross-region replica lag | Fail over to a cross-region replica; accept higher RPO/RTO; restore service from backups if needed | Depends on replication mode and distance. The single-host demo cannot demonstrate this. |

### Measured failover (controlled)

`evidence/07-failover.txt` shows a manual promotion after the replica had
replayed to the primary's LSN:

| Step | Measured |
|---|---:|
| Stop the primary (`docker stop`) | 1,973.4 ms |
| `pg_promote(true, 60)` call | 1,698.7 ms |
| Promotion complete (`pg_is_in_recovery = f`) | **2,946.7 ms** |
| Post-failover write | succeeded (`probe_id 50029`) |
| Probe rows before / after | 50,022 / 50,023 |
| Rows lost | **0** (because the replica was caught up first) |
| Remaining upstreams | 0 |

The ~3 s promotion is the mechanism time, not the full RTO. Real RTO also
includes failure detection, the decision to promote, DNS/service repointing and
client reconnection. The demo deliberately stops the primary cleanly, so it
does not measure crash recovery or the last uncommitted WAL.

**RPO/RTO position:**

- **Clinical booking writes:** target RPO 0. Use synchronous commit or a
  read-your-writes token; accept that a standby outage can stall bookings.
- **Lab ingestion and reporting:** async is acceptable; a few hundred
  milliseconds of replica lag does not change a clinical decision, and
  reporting can tolerate more.
- **Demo RPO:** non-zero in async mode in general; 0 in the controlled run
  because the replica was caught up before promotion.
- **Demo RTO:** ~3 s promotion time; production target should be stated
  explicitly (for example, <60 s including detection) and tested, not assumed.

---

## 7. CAP in Practical Terms

A partition is rare; latency is constant. Under normal operation the real choice
is between consistency and response time, not between a clean "C" and a clean
"A".

| Operation | Choice | Why |
|---|---|---|
| Book/reschedule appointment | Strong consistency; primary or synchronous commit | Double-booking and a vanished booking are safety and trust failures. |
| View patient history | Bounded staleness; replica if caught up, primary otherwise | Seconds-old history is usually clinically acceptable; a missing just-entered result may not be. |
| Departmental reporting | Eventual consistency; asynchronous replica | Reports are not on the critical treatment path and can tolerate lag. |
| Lab result ingestion | Strong on the write; asynchronous on downstream dashboards | The result must be durable when accepted; dashboards can catch up. |
| Audit-log read | Eventual/bounded staleness; replica | Auditors can tolerate lag, but the log itself must be append-only and durable. |

During a partition, an asynchronous primary can keep accepting writes while the
replica serves stale reads. That is an **AP** choice for reporting and an
availability risk for bookings. The router's rule — send reads to the primary
when the replica is behind — is a **CP** choice for the operations that cannot
tolerate staleness. The system does not have one global CAP label; it has a
per-operation policy.

---

## 8. Operations

### Backup and restore

`archive_mode=off` in this deployment. Streaming replication is **not** a
backup: a dropped table or a bad migration is replicated immediately. A
production deployment needs:

- a base backup (pgBackRest, WAL-G, or the managed provider's backup);
- continuous WAL archiving for point-in-time recovery;
- restore drills, not just backup jobs;
- a separate retention policy for the audit log, which is regulatory evidence.

### Monitoring

The minimum dashboard:

- `pg_stat_replication.state` and `sync_state`;
- `pg_wal_lsn_diff(sent_lsn, replay_lsn)` and `replay_lag`;
- replica `pg_last_wal_replay_lsn()` vs primary `pg_current_wal_lsn()`;
- WAL directory growth and `wal_keep_size` headroom;
- connection saturation and long-running reporting queries;
- disk space on the primary and replica volumes.

An alert on lag alone is insufficient: a replica can be caught up and still be
useless if it is not accepting connections. Alert on both.

### Cost

The demo runs on one workstation: no cloud spend, but also no real failure
domain. Indicative production costs, not a quote:

- **Managed primary + standby** (2 vCPU / 8 GB class, multi-AZ, backups):
  roughly US$150–300/month, depending on provider, storage and IOPS.
- **Self-hosted** two VMs plus object storage for backups: roughly
  US$50–150/month before labour, monitoring and on-call.
- **The hidden cost** is operational: patching, failover drills, backup
  restores, monitoring and someone who can make a promotion decision at 02:00.

### Schema migration with a live replica

The replica replays the primary's WAL, so DDL is replicated too. A safe pattern
is expand/contract: add nullable columns and new indexes first, backfill in
batches, switch reads/writes, then remove the old objects. Use
`CREATE INDEX CONCURRENTLY` on the primary and watch replica lag; a long
`ALTER TABLE` can block replay and make the standby fall behind. The P5 demo
does not perform a migration; this is a design note, not a tested procedure.

### Security

The demo uses a disposable password in `primary_conninfo` and a `pg_hba` rule
for `0.0.0.0/0` **inside an isolated Docker network with no published ports**.
That is acceptable for a local exercise and not acceptable for production.
Production requirements: TLS for replication, a secret manager or `.pgpass`,
a `pg_hba` rule restricted to the replication subnet, least-privilege roles,
and network policy that prevents application containers from opening
replication connections.

---

## 9. Limitations

1. **Single host.** Both containers share one Docker Desktop VM and one disk.
   This demonstrates the protocol, not rack, host, AZ or region failure.
2. **Manual failover.** There is no automatic detection, fencing or leader
   election. Restarting the old primary after promotion could create a
   split-brain unless it is fenced or rewound.
3. **Async by default.** The controlled failover lost 0 rows because it waited
   for catch-up. A crash at an arbitrary moment can lose the last transactions.
4. **No replication slot.** `wal_keep_size=256MB` is a bounded window. A replica
   that is down longer than the window needs a fresh base backup.
5. **No archive/PITR.** `archive_mode=off`; there is no point-in-time restore.
6. **No load test.** The 50,000-row burst is a controlled write burst, not a
   representative hospital workload. Peak sessions and read/write ratio are not
   measured.
7. **No TLS.** Replication traffic is inside the Docker network; production
   needs encryption in transit.
8. **No multi-region story tested.** The sharding/region discussion is
   reasoning, not deployment evidence.

---

## 10. Conclusion

Streaming replication is a good fit for this case study: it preserves the
single-system transactional model, gives the read-heavy clinical workload a
second read path, and provides a promotion target without introducing
cross-shard transactions. The measured 525 ms lag under a 50,000-row burst and
the captured stale read show why the router cannot be an afterthought.

The weakest point is not the replication mechanism; it is the operational
envelope around it. A single async replica with manual promotion has a non-zero
RPO and a split-brain risk. The first changes should be a synchronous commit
path for booking writes, automated failover with fencing, and tested
backup/PITR. Partitioning, and only then sharding, should wait for a measured
size or locality problem.
