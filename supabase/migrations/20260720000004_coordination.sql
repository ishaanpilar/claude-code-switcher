-- Distributed locks: which account is currently claimed by whom, and which
-- team member is the poll leader (BUILD_PLAN.md sections 3a and 5). Both are
-- lease rows mutated only through RPCs below — never direct table writes —
-- so the atomic-conditional-update guarantee can't be bypassed by a client
-- doing a plain UPDATE.

create table claims (
  account_id uuid primary key references accounts(id) on delete cascade,
  held_by uuid references auth.users(id),
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  heartbeat_at timestamptz,
  purpose text check (purpose in ('active_use', 'auto'))
);

create table poll_leader (
  team_id uuid primary key references teams(id) on delete cascade,
  leader_user_id uuid references auth.users(id),
  lease_expires_at timestamptz,
  heartbeat_at timestamptz
);

alter table claims enable row level security;
alter table poll_leader enable row level security;

-- Read is a plain team-membership check (everyone needs to see who holds
-- what for the claimed-by badges); writes go only through the RPCs, which
-- run as security definer and therefore bypass these policies entirely —
-- there is deliberately no insert/update/delete policy on either table, so
-- a client attempting a raw UPDATE against claims/poll_leader is rejected
-- by RLS regardless of membership.
create policy claims_select on claims
  for select using (
    exists (select 1 from accounts a where a.id = claims.account_id and is_team_member(a.team_id))
  );

create policy poll_leader_select on poll_leader
  for select using (is_team_member(team_id));

-- A claims row is created (held_by null) the moment its account is created,
-- so claim_account below always has a row to conditionally update rather
-- than needing an upsert race of its own.
create or replace function seed_claim_row()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into claims (account_id) values (new.id);
  return new;
end;
$$;

create trigger accounts_seed_claim
  after insert on accounts
  for each row execute function seed_claim_row();

-- Atomic claim: succeeds only if the account is unclaimed, the lease has
-- expired, or the caller already holds it (idempotent re-claim / heartbeat).
-- Returns the resulting row, or NULL when someone else holds a live lease —
-- the caller (Swift) reads NULL as "pick the next-best candidate instead."
create or replace function claim_account(p_account uuid, p_purpose text default 'active_use')
returns claims
language plpgsql
security definer
set search_path = public
as $$
declare
  result claims;
begin
  if not exists (
    select 1 from accounts a where a.id = p_account and is_team_member(a.team_id)
  ) then
    raise exception 'account % not visible to caller', p_account;
  end if;

  update claims
     set held_by = auth.uid(),
         claimed_at = now(),
         lease_expires_at = now() + interval '5 minutes',
         heartbeat_at = now(),
         purpose = p_purpose
   where account_id = p_account
     and (held_by is null or lease_expires_at < now() or held_by = auth.uid())
  returning * into result;

  return result;  -- NULL row when the WHERE excluded every row (held by someone else)
end;
$$;

create or replace function heartbeat_claim(p_account uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update claims
     set lease_expires_at = now() + interval '5 minutes',
         heartbeat_at = now()
   where account_id = p_account and held_by = auth.uid();
  return found;
end;
$$;

create or replace function release_claim(p_account uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update claims
     set held_by = null, claimed_at = null, lease_expires_at = null, purpose = null
   where account_id = p_account and held_by = auth.uid();
  return found;
end;
$$;

-- Poll-leader election, same shape as claim_account but keyed by team_id.
create or replace function try_become_poll_leader(p_team uuid)
returns poll_leader
language plpgsql
security definer
set search_path = public
as $$
declare
  result poll_leader;
begin
  if not is_team_member(p_team) then
    raise exception 'not a member of team %', p_team;
  end if;

  insert into poll_leader (team_id) values (p_team)
    on conflict (team_id) do nothing;

  update poll_leader
     set leader_user_id = auth.uid(),
         lease_expires_at = now() + interval '90 seconds',
         heartbeat_at = now()
   where team_id = p_team
     and (leader_user_id is null or lease_expires_at < now() or leader_user_id = auth.uid())
  returning * into result;

  return result;
end;
$$;

create or replace function heartbeat_poll_leader(p_team uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update poll_leader
     set lease_expires_at = now() + interval '90 seconds',
         heartbeat_at = now()
   where team_id = p_team and leader_user_id = auth.uid();
  return found;
end;
$$;

create or replace function release_poll_leader(p_team uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  update poll_leader
     set leader_user_id = null, lease_expires_at = null
   where team_id = p_team and leader_user_id = auth.uid();
  return found;
end;
$$;
