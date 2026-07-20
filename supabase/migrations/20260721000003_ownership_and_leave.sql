-- Ownership transfer + leaving a team (Settings window's My Accounts / Team
-- tabs). Both are security-definer RPCs for the same reason the coordination
-- RPCs are (0004): they mutate rows the caller doesn't own under RLS, so they
-- have to run with definer rights and validate their own preconditions rather
-- than relying on a client-shaped policy predicate.

-- Reassign an account to another team member. The recommended flow is that
-- each person adds their own account (so ownership maps to the real human from
-- the start); this exists only to fix the case where the wrong person added
-- one. Only the current owner may hand it over, and only to an existing member
-- of the same team.
create or replace function transfer_account_ownership(p_account uuid, p_new_owner uuid)
returns accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  acct accounts;
  result accounts;
begin
  select * into acct from accounts where id = p_account;
  if acct is null then
    raise exception 'account % not found', p_account;
  end if;
  if acct.owner_user_id <> auth.uid() then
    raise exception 'only the current owner can transfer this account';
  end if;
  if not exists (
    select 1 from members where team_id = acct.team_id and user_id = p_new_owner
  ) then
    raise exception 'new owner is not a member of this team';
  end if;

  update accounts set owner_user_id = p_new_owner
   where id = p_account
  returning * into result;

  -- The shared token (if any) was encrypted to the team key, so it stays
  -- decryptable by the new owner and everyone else — no re-encryption needed.
  -- Any live claim is left as-is; it'll lapse on its own lease if stale.
  return result;
end;
$$;

-- Leave the team: removes the caller's membership and every account they own
-- (cascading its tokens/usage/claims). Blocked for the team's owner while other
-- members remain, so a team can't be orphaned without an owner (which would
-- break invites — create_team_invite requires role = 'owner'). The owner can
-- still leave once they're the last member, which effectively disbands it.
create or replace function leave_team()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_team uuid;
  my_role text;
  others integer;
begin
  select team_id, role into my_team, my_role
    from members where user_id = auth.uid();
  if my_team is null then
    raise exception 'not a member of any team';
  end if;

  select count(*) into others
    from members where team_id = my_team and user_id <> auth.uid();

  if my_role = 'owner' and others > 0 then
    raise exception 'transfer team ownership or remove other members before leaving';
  end if;

  delete from accounts where team_id = my_team and owner_user_id = auth.uid();
  delete from members where team_id = my_team and user_id = auth.uid();
end;
$$;
