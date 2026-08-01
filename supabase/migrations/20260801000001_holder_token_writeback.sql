-- Holder write-back for shared account tokens.
--
-- Claude's OAuth refresh tokens are single-use: every refresh mints a new one
-- and kills the old one instantly. So whoever last *drove* a shared account
-- holds the only live lineage — and until now only the account's owner could
-- write account_tokens (0002_accounts.sql). A teammate who used the account
-- rotated its token and then had no way to put the new one back, leaving the
-- pool ciphertext permanently dead for everyone else: the direct cause of
-- "switching to a teammate's account asks me to log in again".
--
-- Fix: one sanctioned write path for non-owners, mirroring the claims model.
-- push_account_token accepts the team-key row from the account's owner OR from
-- whoever currently holds a live claim on the account — holding the claim is
-- exactly what makes that caller's copy the authoritative lineage. Direct
-- table writes stay owner-only under the existing RLS policies; this RPC runs
-- security definer and re-checks authorization itself, so widening never
-- reaches the table's own policy surface.
--
-- shared-only on purpose: a visibility_only account must have zero token rows
-- (its login is promised never to leave the owner's Mac), so the server
-- refuses the write even if a confused client attempts it.

create or replace function push_account_token(p_account uuid, p_ciphertext text, p_nonce text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (
    select 1 from accounts a
    where a.id = p_account
      and a.share_mode = 'shared'
      and is_team_member(a.team_id)
      and (
        a.owner_user_id = auth.uid()
        or exists (
          select 1 from claims c
          where c.account_id = a.id
            and c.held_by = auth.uid()
            and c.lease_expires_at > now()
        )
      )
  ) then
    raise exception 'not authorized to push a token for account %', p_account;
  end if;

  insert into account_tokens (account_id, recipient_user_id, ciphertext, nonce, updated_at)
  values (p_account, null, p_ciphertext, p_nonce, now())
  on conflict (account_id, recipient_key)
  do update set ciphertext = excluded.ciphertext,
                nonce = excluded.nonce,
                updated_at = now();
end;
$$;
