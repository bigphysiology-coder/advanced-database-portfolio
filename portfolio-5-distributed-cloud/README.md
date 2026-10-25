# Portfolio 5 — Distributed and Cloud Database Exercise

**Marks:** 6 / 40

## Required Evidence

The brief accepts a **discussion or a setup**. Chasing a full cloud deployment is not
worth 6 marks — but a discussion with no evidence behind it reads like an essay. The
right balance is a real, small, single-machine deployment that proves the mechanism, plus
reasoning about what changes at production scale.

- [ ] Discussion or setup based on the same case study
- [ ] Replication **or** sharding
- [ ] Availability / consistency trade-off addressed
- [ ] Deployment evidence (configs, command output, logs)

## Pick One Thread and Follow It

Doing three things shallowly scores worse than one done properly. The strongest option
for this case study is **read replication + a consistency discussion**, because it maps
onto a real hospital problem: many readers (dashboards, reporting, clinicians), relatively
few writers.

| Option | Effort | Fit for this case study |
|---|---|---|
| Streaming replication + read replica routing | Medium | **Strong** — read-heavy workload, natural failover story |
| PostgreSQL partitioning (declarative) | Low–medium | Good, but it is not distribution |
| Sharding by hospital/region | High | Good story, hard to demo convincingly |
| Managed cloud (RDS/Atlas) + multi-AZ | Low | Fine for discussion, weak on your own evidence |
| MongoDB replica set | Low–medium | Good if P4 is MongoDB-centric |

## Files

| File | Purpose |
|---|---|
| `architecture.md` | The design and the trade-offs |
| `replication-setup.sh` | Scripted deployment, so it is reproducible |
| `config/` | `postgresql.conf` / `pg_hba.conf` fragments |
| `evidence/` | Command output, `pg_stat_replication`, logs, failover screenshots |

## Minimum Demo

1. Primary + one streaming replica (two containers or two clusters).
2. Replication working — show `pg_stat_replication` with `state = streaming`
   and a non-zero `replay_lsn`.
3. A write on the primary visible on the replica.
4. **Replication lag measured**, not just mentioned: write a row, poll the replica,
   record the milliseconds.
5. **Read-your-writes problem demonstrated** — a write on the primary, an immediate read
   on the replica, and the stale result. Then your mitigation (sticky routing to the
   primary for a session, or a bounded-lag check before serving).
6. Failover (manual is fine): stop the primary, promote the replica, show it accepting
   writes. Note how much data was lost, or why nothing was lost with synchronous commit.

Step 5 is what separates a real understanding from a tutorial. Most student submissions
show replication working and stop there.

## Discussion to Write

**Consistency model.** Synchronous vs asynchronous commit, and the exact trade-off:
`synchronous_commit = on` means a committed write survives failover but the client waits
for the replica. Which does a hospital appointment booking need? Which does a lab result
ingestion pipeline need? They probably differ — say so.

**CAP framing.** Be precise rather than reciting the acronym: a partition is rare, but
latency is constant. Under normal operation the choice is really between consistency and
response time, not between C and A.

**Sharding.** If the hospital grows to multiple regions, the natural shard key is
_<_region, hospital_id_>_ for operational data — but a global medical record number must
stay unique across shards, which forces either a central ID service or a composite key.
Naming that problem is worth more than claiming sharding is easy.

**Failure modes.** What happens when the replica falls behind during a nightly reporting
job? What does a clinician see? Document the decision, not just the mechanism.

**Cost and operations.** Managed vs self-hosted, backup/restore, monitoring. Brief, but
it shows the difference between a lab exercise and a system.

## Evidence Checklist

- [ ] `pg_stat_replication` output showing streaming state
- [ ] Write on primary → read on replica, with the timestamps visible
- [ ] Measured lag under a burst write (e.g. `pgbench` or a loop of inserts)
- [ ] The stale read captured, then the mitigation working
- [ ] Promotion output and the post-failover write succeeding
- [ ] Config files committed, not just described
