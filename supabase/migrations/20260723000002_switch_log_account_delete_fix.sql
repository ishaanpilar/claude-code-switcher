-- "Remove from pool" has been failing on every single account, always, silently: every account
-- accumulates switch_log rows (account_from/account_to) as soon as it's ever switched to or from
-- -- ordinary use, not an edge case -- and those two foreign keys had no ON DELETE rule at all
-- (confirmed live: every account in the pool had 5-38 referencing rows). Postgres correctly
-- refused every delete with a foreign-key violation. turn_log.account_id, in the very same
-- original migration, already uses ON DELETE SET NULL for exactly this reason -- switch_log's two
-- columns just missed it. Preserve the audit trail (don't cascade-delete history) by matching that
-- existing precedent: null out the reference, keep the row.
alter table switch_log drop constraint switch_log_account_from_fkey;
alter table switch_log add constraint switch_log_account_from_fkey
  foreign key (account_from) references accounts(id) on delete set null;

alter table switch_log drop constraint switch_log_account_to_fkey;
alter table switch_log add constraint switch_log_account_to_fkey
  foreign key (account_to) references accounts(id) on delete set null;
