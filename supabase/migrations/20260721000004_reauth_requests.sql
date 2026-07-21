-- Re-login requests. Quarantine (an account's refresh token has died) was previously a purely
-- local concept — whichever device happened to hit invalid_grant recorded it in its own
-- UserDefaults, invisible to the account's actual owner or anyone else on the team. That's the
-- gap this closes: `accounts.status` (already had a 'quarantined' value, unused until now)
-- becomes the shared, Realtime-visible signal, and this table is the "who asked, when" audit
-- trail behind the "Request re-login" action and the owner's push notification.
--
-- No update/delete policy and no resolved_at column on purpose — like turn_log/switch_log, this
-- is an append-only event log, not a piece of mutable state. "Resolved" is just "the account's
-- status went back to active," visible on the accounts row itself.
create table reauth_requests (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  requested_by uuid not null references auth.users(id),
  requested_at timestamptz not null default now()
);

create index reauth_requests_account_idx on reauth_requests(account_id);

alter table reauth_requests enable row level security;

create policy reauth_requests_select on reauth_requests
  for select using (
    exists (select 1 from accounts a where a.id = reauth_requests.account_id and is_team_member(a.team_id))
  );

-- No direct-insert policy — every row goes through request_reauth() (security definer), same
-- pattern as log_turn(): the RPC validates membership itself and stamps requested_by from
-- auth.uid(), so the client can't forge either.

-- Any team member may flag a shared account as needing re-login — not owner-only, since the
-- person who discovers a shared account is broken is very often not its owner. Idempotent
-- against re-flagging an already-quarantined account (the update is a no-op then).
create or replace function request_reauth(p_account uuid)
returns reauth_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  acct accounts;
  result reauth_requests;
begin
  select * into acct from accounts where id = p_account;
  if acct is null then
    raise exception 'account % not found', p_account;
  end if;
  if not is_team_member(acct.team_id) then
    raise exception 'not a member of this account''s team';
  end if;

  update accounts set status = 'quarantined' where id = p_account and status <> 'quarantined';

  insert into reauth_requests (account_id, requested_by) values (p_account, auth.uid())
  returning * into result;

  return result;
end;
$$;

-- Owner-only — only the person who re-authenticated can credibly declare their account working
-- again. AppState calls this automatically once a post-re-login usage read actually succeeds,
-- not as a manual "mark resolved" button.
create or replace function clear_account_reauth(p_account uuid)
returns accounts
language plpgsql
security definer
set search_path = public
as $$
declare
  result accounts;
begin
  update accounts set status = 'active'
  where id = p_account and owner_user_id = auth.uid()
  returning * into result;

  if result is null then
    raise exception 'account % not found, or you are not its owner', p_account;
  end if;

  return result;
end;
$$;

alter publication supabase_realtime add table reauth_requests;
