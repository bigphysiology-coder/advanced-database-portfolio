-- One pg_stat_activity sample. Run repeatedly by the monitor loop in
-- scripts/capture-p3.ps1 while two sessions are active.
--
-- The monitor connection excludes itself; both test sessions remain visible.
SELECT to_char(clock_timestamp(), 'HH24:MI:SS.MS') AS sampled_at,
       pid,
       state,
       coalesce(wait_event_type, '-') AS wait_type,
       coalesce(wait_event, '-') AS wait_event,
       coalesce(round(extract(epoch FROM (clock_timestamp() - xact_start))::numeric, 2)::text, '-') AS xact_age_s,
       coalesce(left(regexp_replace(query, '\s+', ' ', 'g'), 70), '-') AS query
FROM pg_stat_activity
WHERE datname = current_database()
  AND backend_type = 'client backend'
  AND pid <> pg_backend_pid()
ORDER BY pid;
