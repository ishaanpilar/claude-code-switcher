-- usage_history (created in 0003) has had no writer since — usage_current is
-- upserted by whichever client last read an account's usage (the poll leader,
-- once Phase 3 landed), but nothing ever copied those readings forward into
-- history. Attribution (BUILD_PLAN.md section 8) needs real deltas to
-- reconcile turn-share digests against, so mirror every usage_current write
-- into an append-only history row here instead of threading a second insert
-- through every Swift call site that publishes usage.
create or replace function usage_current_to_history()
returns trigger
language plpgsql
as $$
begin
  insert into usage_history (account_id, fetched_at, five_hour_pct, seven_day_pct, scoped)
  values (new.account_id, new.fetched_at, new.five_hour_pct, new.seven_day_pct, new.scoped);
  return new;
end;
$$;

create trigger usage_current_history_trigger
  after insert or update on usage_current
  for each row execute function usage_current_to_history();
