-- leave_team() predates multi-team support and never took a team argument. It resolved the
-- caller's team with `select team_id, role into my_team, my_role from members where user_id =
-- auth.uid()` -- a query that matches one row per team the user belongs to. plpgsql's SELECT INTO
-- does not error on multiple rows; it silently keeps whichever one the plan happened to return
-- first. So for anyone in two or more teams, "Leave team" left an arbitrary team, deleted the
-- accounts they owned in that team, and reported success. The Settings UI meanwhile showed the
-- action against the *active* team, so the two could disagree with no visible sign.
--
-- Fix: take the team explicitly. The no-argument form is kept so an older client keeps working,
-- but only where it is unambiguous -- exactly one membership -- and raises otherwise instead of
-- guessing.

create or replace function leave_team(p_team uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text;
  others integer;
begin
  select role into my_role
    from members where user_id = auth.uid() and team_id = p_team;
  if my_role is null then
    raise exception 'not a member of team %', p_team;
  end if;

  select count(*) into others
    from members where team_id = p_team and user_id <> auth.uid();

  if my_role = 'owner' and others > 0 then
    raise exception 'transfer team ownership or remove other members before leaving';
  end if;

  delete from accounts where team_id = p_team and owner_user_id = auth.uid();
  delete from members where team_id = p_team and user_id = auth.uid();
end;
$$;

-- Compatibility shim for clients built before the argument existed.
create or replace function leave_team()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  team_count integer;
  only_team uuid;
begin
  select count(*) into team_count from members where user_id = auth.uid();
  if team_count = 0 then
    raise exception 'not a member of any team';
  end if;
  if team_count > 1 then
    raise exception 'you belong to several teams -- update the app to choose which one to leave';
  end if;

  select team_id into only_team from members where user_id = auth.uid();
  perform leave_team(only_team);
end;
$$;
