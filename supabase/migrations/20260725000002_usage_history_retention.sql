-- usage_history gets one row per usage_current write (the trigger added in
-- 20260721000002_usage_history_trigger.sql), and usage_current is rewritten roughly every 3
-- minutes per account by whichever client is polling it. That is ~480 rows per account per day,
-- or ~175k rows per account per year, growing forever with no reader: the Team-usage digest
-- aggregates turn_log, not this table, and nothing in the app has ever issued a select against
-- usage_history.
--
-- Keep the table -- it is the raw material for usage deltas if the digest ever wants them -- but
-- bound it. 30 days is well past the 7-day window anything in the UI looks at.

select cron.schedule(
  'reap-old-usage-history',
  '17 3 * * *',
  $$ delete from usage_history where fetched_at < now() - interval '30 days'; $$
);
