-- create_team_invite has been failing on every call in production with
-- `42883: function gen_random_bytes(integer) does not exist` (confirmed in
-- the project's Postgres logs). pgcrypto's functions live outside `public`
-- on this project (Supabase installs extensions into a separate `extensions`
-- schema by default), which this security-definer's `search_path = public`
-- can't see. Rather than widen the search_path or schema-qualify a call into
-- an extension whose install location we can't fully verify from here,
-- switch to `gen_random_uuid()`, which has been built into Postgres core
-- (no extension required) since PG13 — this can't break on search_path or
-- extension availability again.
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

  -- 32 hex chars (128 bits) from a UUID's raw bytes, dashes stripped so it
  -- reads/copy-pastes as one contiguous code like the old hex format did.
  new_code := replace(gen_random_uuid()::text, '-', '');

  insert into team_invites (code, team_id, created_by, expires_at, max_uses)
  values (new_code, p_team, auth.uid(), now() + make_interval(hours => p_expires_hours), p_max_uses);

  return new_code;
end;
$$;
