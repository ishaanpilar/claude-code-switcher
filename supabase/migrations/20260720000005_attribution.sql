-- Turn-count attribution (BUILD_PLAN.md section 8) and the switch audit
-- trail. turn_log is written by the Claude Code hook script
-- (hooks/log_turn.sh) via the log_turn() RPC below, not by direct insert —
-- that keeps the hook's HTTP call a single stable RPC signature regardless
-- of how the underlying table evolves.

create table turn_log (
  id bigint generated always as identity primary key,
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  account_id uuid references accounts(id) on delete set null,
  ts timestamptz not null default now(),
  event text not null check (event in ('prompt_submit', 'stop'))
);

create index turn_log_team_ts_idx on turn_log(team_id, ts desc);
create index turn_log_account_ts_idx on turn_log(account_id, ts desc);

create table switch_log (
  id bigint generated always as identity primary key,
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  account_from uuid references accounts(id),
  account_to uuid references accounts(id),
  ts timestamptz not null default now(),
  reason text not null check (reason in ('manual', 'auto', 'failover', 'captured'))
);

create index switch_log_team_ts_idx on switch_log(team_id, ts desc);

alter table turn_log enable row level security;
alter table switch_log enable row level security;

create policy turn_log_select on turn_log
  for select using (is_team_member(team_id));

create policy switch_log_select on switch_log
  for select using (is_team_member(team_id));

-- switch_log is a plain policy-gated insert (no RPC needed — it's an
-- append-only audit row, not a lease, so there's no race to make atomic).
create policy switch_log_insert on switch_log
  for insert with check (is_team_member(team_id) and user_id = auth.uid());

-- turn_log has no direct insert policy — every row goes through log_turn()
-- (security definer), so the hook script's auth token only ever needs
-- execute-on-function, not table-level insert.
create or replace function log_turn(p_team uuid, p_account uuid, p_event text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_team_member(p_team) then
    raise exception 'not a member of team %', p_team;
  end if;
  insert into turn_log (team_id, user_id, account_id, event)
  values (p_team, auth.uid(), p_account, p_event);
end;
$$;
