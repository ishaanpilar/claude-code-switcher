-- Fixes a real gap in 0001: ``members_insert``'s bootstrap clause ("no
-- members exist yet for this team") only ever admits a team's *first*
-- member. Anyone invited afterward has no legal path to a members row —
-- they're not already an owner (they're not a member at all yet), and the
-- team already has members, so both branches of that policy reject them.
-- Found by actually working through the join flow rather than by inspection,
-- which is exactly why this file exists instead of a hand-edit of 0001:
-- migrations are append-only history, not a draft to rewrite.
--
-- Fix: team creation and joining both move to security-definer RPCs, which
-- bypass RLS by construction and can therefore validate their own
-- precondition (caller owns the team / caller holds a live invite code)
-- instead of relying on a client-shaped RLS predicate to get it right.

create table team_invites (
  code text primary key,
  team_id uuid not null references teams(id) on delete cascade,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  max_uses integer not null default 1 check (max_uses > 0),
  use_count integer not null default 0
);

alter table team_invites enable row level security;

-- Only team members can see their own team's invites (to reuse/revoke them);
-- an invite is looked up by code through join_team() below, not by select.
create policy team_invites_select on team_invites
  for select using (is_team_member(team_id));

-- No insert/update/delete policy: every write goes through the RPCs.

create or replace function create_team(p_name text)
returns teams
language plpgsql
security definer
set search_path = public
as $$
declare
  new_team teams;
begin
  insert into teams (name, created_by) values (p_name, auth.uid())
  returning * into new_team;

  insert into members (user_id, team_id, display_name, role)
  values (auth.uid(), new_team.id, coalesce(auth.jwt() ->> 'email', 'Member'), 'owner');

  return new_team;
end;
$$;

create or replace function create_team_invite(p_team uuid, p_expires_hours integer default 168, p_max_uses integer default 1)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  new_code text;
begin
  if not exists (
    select 1 from members where team_id = p_team and user_id = auth.uid() and role = 'owner'
  ) then
    raise exception 'only a team owner can create invites';
  end if;

  -- 10 bytes of randomness, base64url-ish via hex (simpler to read aloud/type
  -- than base64's mixed-case + punctuation for a code teammates copy-paste).
  new_code := encode(gen_random_bytes(10), 'hex');

  insert into team_invites (code, team_id, created_by, expires_at, max_uses)
  values (new_code, p_team, auth.uid(), now() + make_interval(hours => p_expires_hours), p_max_uses);

  return new_code;
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

-- The original bootstrap carve-out is dead code now that create_team() seeds
-- the first (owner) row itself via security definer — tightened so the only
-- direct-insert path left is "an existing owner adds someone," which is no
-- longer reachable either (create_team_invite + join_team replaced it) but
-- is harmless to leave as a defensive fallback rather than removing insert
-- entirely and forcing a migration if a future direct-add feature wants it.
drop policy members_insert on members;
create policy members_insert on members
  for insert with check (
    exists (
      select 1 from members m
      where m.team_id = members.team_id and m.user_id = auth.uid() and m.role = 'owner'
    )
  );
