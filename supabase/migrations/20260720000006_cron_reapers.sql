-- Reap expired leases every minute, so a crashed/offline client's claim or
-- poll-leader lease frees itself without anyone needing to notice (BUILD_PLAN.md
-- section 3a / 5). pg_cron runs as the postgres superuser, so these functions
-- are plain SQL (no security definer / auth.uid() needed — cron isn't a
-- request, there's no caller to check membership against).

create extension if not exists pg_cron;

select cron.schedule(
  'reap-expired-claims',
  '* * * * *',
  $$ update claims set held_by = null, claimed_at = null, lease_expires_at = null, purpose = null
     where held_by is not null and lease_expires_at < now(); $$
);

select cron.schedule(
  'reap-expired-poll-leader',
  '* * * * *',
  $$ update poll_leader set leader_user_id = null, lease_expires_at = null
     where leader_user_id is not null and lease_expires_at < now(); $$
);
