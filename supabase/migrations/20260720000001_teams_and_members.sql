-- Teams & membership. A team is the trust boundary everything else is
-- scoped to (BUILD_PLAN.md section 4). Sized for small groups (~10), not a
-- public multi-tenant product, but modeled as real multi-team from day one
-- so nothing has to change if you ever run two independent pools.

create extension if not exists pgcrypto;

create table teams (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_by uuid not null references auth.users(id),
  created_at timestamptz not null default now()
);

create table members (
  user_id uuid not null references auth.users(id),
  team_id uuid not null references teams(id) on delete cascade,
  display_name text not null,
  role text not null default 'member' check (role in ('owner', 'member')),
  joined_at timestamptz not null default now(),
  primary key (user_id, team_id)
);

create index members_team_id_idx on members(team_id);

-- Helper used by every downstream RLS policy: "is auth.uid() in this team?"
-- A single function keeps the team-scoping predicate identical everywhere
-- instead of six copies of the same subquery drifting apart over time.
create or replace function is_team_member(p_team_id uuid)
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from members
    where team_id = p_team_id and user_id = auth.uid()
  );
$$;

alter table teams enable row level security;
alter table members enable row level security;

create policy teams_select on teams
  for select using (is_team_member(id));

create policy teams_insert on teams
  for insert with check (created_by = auth.uid());

create policy members_select on members
  for select using (is_team_member(team_id));

-- Only an existing owner can add members (the creator becomes owner via the
-- app's onboarding flow, which inserts the first member row itself using the
-- service role — see hooks/README in supabase/ once written).
create policy members_insert on members
  for insert with check (
    exists (
      select 1 from members m
      where m.team_id = members.team_id and m.user_id = auth.uid() and m.role = 'owner'
    )
    or not exists (select 1 from members m2 where m2.team_id = members.team_id)
  );

create policy members_delete on members
  for delete using (
    user_id = auth.uid()  -- anyone can leave
    or exists (
      select 1 from members m
      where m.team_id = members.team_id and m.user_id = auth.uid() and m.role = 'owner'
    )
  );
