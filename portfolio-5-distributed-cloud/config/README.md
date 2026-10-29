# P5 Configuration Fragments

These files are the committed, reviewable form of the settings used by
`../replication-setup.ps1`. They are not mounted into the containers: the
script starts PostgreSQL with the equivalent `-c` flags, and `pg_basebackup -R`
writes the replica's `primary_conninfo` and `standby.signal`.

| File | Applied on | Purpose |
|---|---|---|
| `primary.conf` | primary | WAL level, senders, retention, commit timestamp |
| `replica.conf` | replica | hot standby and upstream connection |
| `pg_hba-replication.conf` | primary | allows the `replicator` role to open a replication connection |

The live values are captured in `../evidence/06-configs.txt` with `SHOW` and by
reading `postgresql.auto.conf`, so the fragments can be checked against the
running cluster rather than taken on trust.

The password in `replica.conf` is a disposable demo credential. A real
deployment should use a `.pgpass`/secret mount and restrict the `pg_hba` rule to
the private replication subnet.
