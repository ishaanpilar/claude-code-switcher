-- Live usage (one row per account, upserted by the poll leader) and
-- append-only history (feeds attribution — BUILD_PLAN.md section 8).

create table usage_current (
  account_id uuid primary key references accounts(id) on delete cascade,
  fetched_at timestamptz not null,
  fetched_by uuid references auth.users(id),
  five_hour_pct numeric,
  seven_day_pct numeric,
  five_hour_resets_at timestamptz,
  seven_day_resets_at timestamptz,
  scoped jsonb,
  spend jsonb
);

create table usage_history (
  id bigint generated always as identity primary key,
  account_id uuid not null references accounts(id) on delete cascade,
  fetched_at timestamptz not null,
  five_hour_pct numeric,
  seven_day_pct numeric,
  scoped jsonb
);

create index usage_history_account_fetched_idx on usage_history(account_id, fetched_at desc);

alter table usage_current enable row level security;
alter table usage_history enable row level security;

create policy usage_current_select on usage_current
  for select using (
    exists (select 1 from accounts a where a.id = usage_current.account_id and is_team_member(a.team_id))
  );

-- Any team member's client can publish a reading (the poll leader is
-- whichever member currently holds that lease — see 0004_coordination.sql),
-- so this is a team-membership check, not an owner-only check.
create policy usage_current_upsert on usage_current
  for insert with check (
    exists (select 1 from accounts a where a.id = usage_current.account_id and is_team_member(a.team_id))
  );

create policy usage_current_update on usage_current
  for update using (
    exists (select 1 from accounts a where a.id = usage_current.account_id and is_team_member(a.team_id))
  );

create policy usage_history_select on usage_history
  for select using (
    exists (select 1 from accounts a where a.id = usage_history.account_id and is_team_member(a.team_id))
  );

create policy usage_history_insert on usage_history
  for insert with check (
    exists (select 1 from accounts a where a.id = usage_history.account_id and is_team_member(a.team_id))
  );
