#!/usr/bin/env bash
# ============================================================================
# Portfolio 5: Streaming replication setup
#
# Reproducible deployment of a primary + hot-standby replica on one machine.
# Run against Docker so the evidence is repeatable, not a one-off manual setup.
#
# Prerequisites: Docker, and the portfolio schema + seed data loaded.
#
# Usage:
#   bash replication-setup.sh up
#   bash replication-setup.sh status
#   bash replication-setup.sh failover
#   bash replication-setup.sh down
# ============================================================================

set -euo pipefail

PRIMARY=portfolio-primary
REPLICA=portfolio-replica
NETWORK=portfolio-repl
PGDATA=/var/lib/postgresql/data
REPL_USER=replicator
REPL_PASS=replpass

# TODO: the implementation below is a skeleton. Fill in the actual commands and
#       commit the output — the evidence is the output, not this script.

case "${1:-}" in

  up)
    # 1. Create the network
    #    docker network create "$NETWORK"

    # 2. Start the primary with wal_level = replica
    #    docker run -d --name "$PRIMARY" --network "$NETWORK" \
    #      -e POSTGRES_USER=portfolio -e POSTGRES_PASSWORD=portfolio \
    #      -e POSTGRES_DB=hospital -p 5432:5432 postgres:16 \
    #      -c wal_level=replica -c max_wal_senders=3 -c hot_standby=on

    # 3. Create the replication role
    #    docker exec -it "$PRIMARY" psql -U portfolio -d hospital -c \
    #      "CREATE ROLE $REPL_USER WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';"

    # 4. Take a base backup onto the replica volume
    #    docker run --rm --network "$NETWORK" -v replica-data:/var/lib/postgresql/data \
    #      postgres:16 pg_basebackup -h "$PRIMARY" -U "$REPL_USER" -D "$PGDATA" \
    #      -Fp -Xs -P -R

    # 5. Start the replica
    #    docker run -d --name "$REPLICA" --network "$NETWORK" -v replica-data:/var/lib/postgresql/data \
    #      -p 5433:5432 postgres:16

    # 6. Load schema + seed on the primary so there is data to replicate
    #    docker exec -i "$PRIMARY" psql -U portfolio -d hospital < ../portfolio-1-database-design/schema.sql
    echo "TODO: implement 'up'"
    ;;

  status)
    # Evidence command 1: replication is streaming
    #   docker exec "$PRIMARY" psql -U portfolio -d hospital -c \
    #     "SELECT client_addr, state, sent_lsn, replay_lsn,
    #             pg_wal_lsn_diff(sent_lsn, replay_lsn) AS lag_bytes
    #      FROM pg_stat_replication;"
    #
    # Evidence command 2: replica is in recovery
    #   docker exec "$REPLICA" psql -U portfolio -d hospital -c \
    #     "SELECT pg_is_in_recovery(), pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn();"
    echo "TODO: implement 'status'"
    ;;

  failover)
    # Promotion evidence: stop the primary, promote, write to the new primary
    #   docker stop "$PRIMARY"
    #   docker exec "$REPLICA" psql -U portfolio -d hospital -c "SELECT pg_promote();"
    #   docker exec "$REPLICA" psql -U portfolio -d hospital -c \
    #     "INSERT INTO audit_log (...) VALUES (...);"
    #
    # Record: how many seconds until promotion completed, and how many writes
    # (if any) were lost because replication was asynchronous.
    echo "TODO: implement 'failover'"
    ;;

  down)
    # docker rm -f "$PRIMARY" "$REPLICA" 2>/dev/null || true
    # docker network rm "$NETWORK" 2>/dev/null || true
    # docker volume rm replica-data 2>/dev/null || true
    echo "TODO: implement 'down'"
    ;;

  *)
    echo "Usage: $0 {up|status|failover|down}"
    exit 1
    ;;
esac
