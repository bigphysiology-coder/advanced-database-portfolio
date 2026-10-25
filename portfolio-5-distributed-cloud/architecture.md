# Distributed and Cloud Architecture

Case study: _<organisation>_ — hospital records system.
Scope of this document: how the database is distributed, and what that costs.

---

## 1. Workload Characterisation

Distribution decisions follow from the workload, so quantify it first. Use the actual
numbers from Portfolios 2 and 3 where available.

| Metric | Value | Source |
|---|---|---|
| Read/write ratio | | `pg_stat_database` (`blks_read` vs `tup_inserted`-family unwieldy; simpler: empirical 80/20 statement audit) |
| Peak concurrent sessions | | `pg_stat_activity` during a `pgbench` run |
| Largest table | | `pg_total_relation_size` |
| Growth per month | | seed-data assumptions |
| Cross-entity transactions | | appointment booking, encounter recording |

The last row matters most: the more transactions that must span entities, the less
freedom you have to shard.

## 2. Architecture

```text
                 ┌──────────────┐
   writes ──────▶│   PRIMARY    │
                 └──────┬───────┘
                        │ streaming replication (WAL)
                 ┌──────▼───────┐
   reads  ──────▶│   REPLICA    │
                 └──────────────┘
```

_Diagram above is the starting shape. Redraw to match what was actually deployed, and
include the application's routing layer — that is where the consistency decision lives._

## 3. Replication Design

| Decision | Choice | Justification |
|---|---|---|
| Async vs sync commit | | |
| Number of replicas | | |
| Replica purpose | | reporting? failover? both? |
| Read routing | | |
| Failover mechanism | | manual / Patroni / cloud-managed |

## 4. Consistency

**The problem to demonstrate:** a clinician books an appointment, then immediately opens
the schedule. If that read goes to a replica that has not yet replayed the WAL, the
appointment is missing. The user sees a booking they just made vanish.

**Measured lag:** _<ms, under <n> writes/sec>_

**Mitigation chosen:**

- [ ] Sticky routing — route the writer's session to the primary for _N_ seconds
- [ ] Lag-aware routing — check `pg_last_wal_replay_lsn()` vs primary LSN before serving
- [ ] Synchronous commit on booking writes only, async elsewhere

**Why this mitigation:** _<justify against the alternative you rejected>_

## 5. Partitioning / Sharding

Even if not implemented, the reasoning is expected.

**Partitioning considered:** _<e.g. lab_results by collected_at, monthly ranges>_

| Benefit | Cost |
|---|---|
| | |

**Shard key if the hospital scaled to regions:** _<key>_

**The hard problem:** a patient's medical record number must be globally unique, but a
sharded sequence is local to a shard. Resolve this explicitly — central ID allocator,
UUIDv7, or composite key including the region.

## 6. Availability

| Failure | Detection | Response | Data loss |
|---|---|---|---|
| Replica down | | | none |
| Primary down | | | |
| Network partition | | | |
| Region outage | | | |

State the RPO and RTO you are designing for. For a hospital, RPO of zero for clinical
writes is a defensible position — but then say what you are paying for it.

## 7. CAP in Practical Terms

Avoid reciting the acronym. Under normal operation there is no partition, so the real
choice is between consistency and latency. State which you chose for which operation:

| Operation | Choice | Why |
|---|---|---|
| Book appointment | strong consistency | double-booking is a safety issue |
| View patient history | bounded staleness | seconds-old data is clinically acceptable |
| Departmental reporting | eventual consistency | runs on a lagging replica by design |

## 8. Operations

- **Backup:** base backup + WAL archiving, and the restore you actually tested.
- **Monitoring:** replication lag, connection saturation, disk.
- **Cost:** rough monthly figure for the described setup, managed vs self-hosted.
- **Deployment:** what a schema migration looks like with a live replica.

## 9. Conclusion

_<Two or three sentences: is this architecture appropriate for the case study, what is
its weakest point, and what would you change first>_
