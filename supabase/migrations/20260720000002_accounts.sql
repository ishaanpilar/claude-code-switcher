-- The pool of Claude accounts. ``anthropic_account_uuid`` is the same
-- identity ccswitch-core resolves locally (oauth.fetch_oauth_profile /
-- oauthAccount.accountUuid) — dedup keys on this, never on email, per
-- BUILD_PLAN.md invariant 4.

create type share_mode as enum ('shared', 'visibility_only');
create type account_status as enum ('active', 'disabled', 'quarantined');

create table accounts (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references teams(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id),
  label text,
  email text not null,
  organization_uuid text,
  anthropic_account_uuid text not null,
  share_mode share_mode not null default 'visibility_only',
  status account_status not null default 'active',
  created_at timestamptz not null default now(),
  unique (team_id, anthropic_account_uuid)
);

create index accounts_team_id_idx on accounts(team_id);
create index accounts_owner_idx on accounts(owner_user_id);

-- Token ciphertext lives in its own table, deliberately NOT flat columns on
-- ``accounts`` — this is the one real upgrade over the plan's first draft.
-- v1 (shared team-key model) stores exactly one row per account with
-- recipient_user_id NULL: "encrypted to the team key, any member can
-- decrypt." v2 (per-member sealed boxes, BUILD_PLAN.md section 5) adds one
-- row per team member instead, each encrypted to that member's public key —
-- an additive migration (insert more rows, stop writing the NULL row) with
-- no schema change and no rewrite of every consumer. A visibility_only
-- account simply has zero rows here.
create table account_tokens (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references accounts(id) on delete cascade,
  recipient_user_id uuid references auth.users(id),
  ciphertext text not null,
  nonce text not null,
  updated_at timestamptz not null default now()
);

-- Postgres does not treat two NULLs as equal, so a plain UNIQUE(account_id,
-- recipient_user_id) would silently allow multiple team-key rows per
-- account. Enforce "at most one NULL-recipient row" explicitly.
create unique index account_tokens_team_key_uniq
  on account_tokens(account_id) where recipient_user_id is null;
create unique index account_tokens_per_member_uniq
  on account_tokens(account_id, recipient_user_id) where recipient_user_id is not null;

alter table accounts enable row level security;
alter table account_tokens enable row level security;

create policy accounts_select on accounts
  for select using (is_team_member(team_id));

create policy accounts_insert on accounts
  for insert with check (is_team_member(team_id) and owner_user_id = auth.uid());

create policy accounts_update on accounts
  for update using (is_team_member(team_id) and owner_user_id = auth.uid());

create policy accounts_delete on accounts
  for delete using (is_team_member(team_id) and owner_user_id = auth.uid());

-- Ciphertext is readable by any team member (that's the point — anyone can
-- decrypt a team-key row locally) but only the account's owner may write it,
-- since only the owner should be the one choosing to share/rotate a token.
create policy account_tokens_select on account_tokens
  for select using (
    exists (
      select 1 from accounts a
      where a.id = account_tokens.account_id and is_team_member(a.team_id)
    )
  );

create policy account_tokens_write on account_tokens
  for insert with check (
    exists (
      select 1 from accounts a
      where a.id = account_tokens.account_id and a.owner_user_id = auth.uid()
    )
  );

create policy account_tokens_update on account_tokens
  for update using (
    exists (
      select 1 from accounts a
      where a.id = account_tokens.account_id and a.owner_user_id = auth.uid()
    )
  );

create policy account_tokens_delete on account_tokens
  for delete using (
    exists (
      select 1 from accounts a
      where a.id = account_tokens.account_id and a.owner_user_id = auth.uid()
    )
  );
