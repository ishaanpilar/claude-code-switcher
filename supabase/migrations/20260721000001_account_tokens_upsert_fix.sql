-- Fixes another real gap, found while writing the Swift upsert call this time: PostgREST's
-- `upsert(onConflict:)` generates a plain `ON CONFLICT (columns)`, and Postgres can only infer a
-- partial unique index as the arbiter for that when the ON CONFLICT clause *also* carries the
-- index's WHERE predicate — which PostgREST's on_conflict query param has no way to express. The
-- two partial unique indexes from 0002_accounts.sql (`account_tokens_team_key_uniq` /
-- `account_tokens_per_member_uniq`) therefore can never be reached through a client upsert call,
-- only through raw SQL.
--
-- Fix: a generated column that coalesces NULL (the v1 team-key row) to a sentinel, backed by one
-- ordinary (non-partial) unique constraint — which PostgREST *can* target directly.

alter table account_tokens
  add column recipient_key text generated always as (coalesce(recipient_user_id::text, 'TEAM')) stored;

drop index account_tokens_team_key_uniq;
drop index account_tokens_per_member_uniq;

alter table account_tokens
  add constraint account_tokens_account_recipient_uniq unique (account_id, recipient_key);
