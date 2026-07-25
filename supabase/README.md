# Database schema

Everything the app stores in the cloud. Every table has row-level security
enabled, and every mutation either checks `is_team_member()` or goes through a
`security definer` RPC that checks it internally.

**Applied through `20260723000002`.** `20260725000001` and `20260725000002` are
new and still need applying.

## Applying migrations

### Option A: Supabase CLI (recommended)

```bash
brew install supabase/tap/supabase   # if you don't have it
cd "Claude Code Switcher"
supabase link --project-ref ciqczzwiuigllkpdebup
supabase db push                     # applies every file in migrations/, in order
```

### Option B: Dashboard SQL editor

Open the project's [SQL editor](https://supabase.com/dashboard/project/ciqczzwiuigllkpdebup/sql/new)
and run each file in `migrations/` **in filename order**. Later files reference
tables and the `is_team_member()` helper that earlier ones create.

After applying, run the security advisor. RLS policies are easy to get subtly
wrong and the check catches it quickly.

## Swift app config

Set in `app/Sources/ClaudeCodeSwitcher/Supabase/Config.swift`:

- `SUPABASE_URL` is `https://ciqczzwiuigllkpdebup.supabase.co`
- `SUPABASE_ANON_KEY` is the `sb_publishable_...` key, safe to ship in the client

The `sb_secret_...` key and the legacy `service_role` JWT must **never** appear
in the Swift app or anywhere in this repo. They bypass RLS entirely and belong
only in a trusted backend context, which this project has none of: everything
runs as an authenticated end user through RLS.

## Migrations

| File | Creates |
| - | - |
| `20260720000001_teams_and_members.sql` | `teams`, `members`, the `is_team_member()` RLS helper |
| `20260720000002_accounts.sql` | `accounts`, `account_tokens` (per-recipient ciphertext; the file header explains why this isn't flat columns) |
| `20260720000003_usage.sql` | `usage_current`, `usage_history` |
| `20260720000004_coordination.sql` | `claims`, `poll_leader`, and every mutating RPC (`claim_account`, `heartbeat_claim`, `release_claim`, `try_become_poll_leader`, ...). Direct table writes are blocked by RLS; only the RPCs can mutate these |
| `20260720000005_attribution.sql` | `turn_log`, `switch_log`, `log_turn()` RPC |
| `20260720000006_cron_reapers.sql` | pg_cron jobs freeing expired claim and leader leases every minute |
| `20260720000007_realtime.sql` | adds the live tables to the `supabase_realtime` publication |
| `20260720000008_team_invites.sql` | `team_invites`, plus `create_team()`, `create_team_invite()` and `join_team()`. Fixes the bootstrap-only `members_insert` policy, which admitted only a team's first member |
| `20260721000001_account_tokens_upsert_fix.sql` | `account_tokens.recipient_key` generated column and an upsert-targetable unique constraint, since PostgREST can't target a partial unique index |
| `20260721000002_usage_history_trigger.sql` | `usage_current_history_trigger`, mirroring every `usage_current` write into `usage_history`, which had no writer before |
| `20260721000003_ownership_and_leave.sql` | `transfer_account_ownership()` and `leave_team()` |
| `20260721000004_reauth_requests.sql` | `reauth_requests`, plus `request_reauth()` and `clear_account_reauth()`. Makes quarantine a shared, Realtime-visible `accounts.status` and adds the "Request re-login" flow |
| `20260723000001_fix_create_team_invite_random.sql` | Fixes `create_team_invite()` failing with `42883: function gen_random_bytes(integer) does not exist`, since pgcrypto lives outside the function's `public` search_path. Switches to core `gen_random_uuid()` |
| `20260723000002_switch_log_account_delete_fix.sql` | Fixes "Remove from pool" failing on every account. `switch_log.account_from`/`account_to` had no `ON DELETE` rule, unlike sibling `turn_log.account_id`, so any account with switch history hit a foreign-key violation. Now matches `turn_log`'s `ON DELETE SET NULL` |
| `20260725000001_leave_team_multi_team_fix.sql` | Fixes `leave_team()` leaving an arbitrary team. It resolved the caller's team with a query matching one row per membership, and plpgsql's `SELECT INTO` silently keeps the first. Now takes `p_team`; the no-argument form remains for older clients but raises rather than guessing when the user is in several teams |
| `20260725000002_usage_history_retention.sql` | Daily cron trimming `usage_history` to 30 days. The trigger above appends roughly 480 rows per account per day and nothing reads the table |
