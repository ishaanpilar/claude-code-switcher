-- Sign-up itself is open to anyone (AuthController.swift calls signInWithOTP with
-- shouldCreateUser: true) but that must not imply access to the online pool — every synced
-- feature (Realtime, Postgres storage, the poll leader's Anthropic calls) costs the project
-- owner money. Everything downstream of team membership already gates on is_team_member()
-- (accounts, usage_current/history, claims, poll_leader, turn_log, switch_log,
-- reauth_requests), so the only two on-ramps that need a new check are create_team() and
-- join_team() — block those and nothing else is reachable.

create table profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  email text,
  online_access boolean not null default false,
  access_granted_at timestamptz,
  access_granted_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

-- A user may read their own flag (so the app can show "pending approval"), nothing else. All
-- writes happen via the trigger below or the admin dashboard's service-role key, which bypasses
-- RLS by design and is never exposed to the Swift app.
create policy profiles_select_own on profiles
  for select using (user_id = auth.uid());

-- Every new auth.users row gets a profiles row automatically, defaulting to no access.
create or replace function handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into profiles (user_id, email) values (new.id, new.email)
  on conflict (user_id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- Backfill: anyone already in `members` is already using the pool today, so grandfather them in
-- rather than letting this migration lock out people already relying on it.
insert into profiles (user_id, email, online_access, access_granted_at)
select u.id, u.email, true, now()
from auth.users u
where exists (select 1 from members m where m.user_id = u.id)
on conflict (user_id) do update
  set online_access = true,
      access_granted_at = coalesce(profiles.access_granted_at, now());

-- Backfill any remaining pre-existing signups that never joined a team (no access, same as any
-- brand-new signup).
insert into profiles (user_id, email)
select u.id, u.email
from auth.users u
where not exists (select 1 from profiles p where p.user_id = u.id);

create or replace function has_online_access()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select coalesce((select online_access from profiles where user_id = auth.uid()), false);
$$;

create or replace function create_team(p_name text)
returns teams
language plpgsql
security definer
set search_path = public
as $$
declare
  new_team teams;
begin
  if not has_online_access() then
    raise exception 'online access is not enabled for this account yet';
  end if;

  insert into teams (name, created_by) values (p_name, auth.uid())
  returning * into new_team;

  insert into members (user_id, team_id, display_name, role)
  values (auth.uid(), new_team.id, coalesce(auth.jwt() ->> 'email', 'Member'), 'owner');

  return new_team;
end;
$$;

create or replace function join_team(p_code text)
returns members
language plpgsql
security definer
set search_path = public
as $$
declare
  invite team_invites;
  new_member members;
begin
  if not has_online_access() then
    raise exception 'online access is not enabled for this account yet';
  end if;

  select * into invite from team_invites where code = p_code for update;

  if invite is null then
    raise exception 'invite code not found';
  end if;
  if invite.expires_at < now() then
    raise exception 'invite code has expired';
  end if;
  if invite.use_count >= invite.max_uses then
    raise exception 'invite code has already been used';
  end if;
  if exists (select 1 from members where team_id = invite.team_id and user_id = auth.uid()) then
    raise exception 'already a member of this team';
  end if;

  insert into members (user_id, team_id, display_name, role)
  values (auth.uid(), invite.team_id, coalesce(auth.jwt() ->> 'email', 'Member'), 'member')
  returning * into new_member;

  update team_invites set use_count = use_count + 1 where code = p_code;

  return new_member;
end;
$$;
