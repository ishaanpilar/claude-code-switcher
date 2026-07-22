# Applying the schema

**Status: `20260723000001_fix_create_team_invite_random.sql` still needs to be applied** —
confirmed via production logs that `create_team_invite()` is currently broken (see its
entry in the table below). Everything through `20260721000004` was previously reported
applied on `ciqczzwiuigllkpdebup` —
applied directly via `psql` against the pooler connection string (the
Supabase MCP tools in this session are connected to a different Supabase
account, so `apply_migration` wasn't an option; see the conversation history
for how the direct-`psql` path was verified: 10 tables, RLS enabled on all of
them, 9 RPC functions, 2 active cron reapers, 5 tables in the realtime
publication, plus the `usage_current_history_trigger` added in
`20260721000002`).

To reapply from scratch (e.g. a second environment) or after adding a new
migration file, two ways:

## Option A — Supabase CLI (recommended, and this repo is already set up for it)

```bash
brew install supabase/tap/supabase   # if you don't have it
cd "Claude Code Switcher"
supabase link --project-ref ciqczzwiuigllkpdebup
supabase db push                     # applies every file in supabase/migrations/, in order
```

## Option B — Dashboard SQL editor

Open your project's SQL editor (`https://supabase.com/dashboard/project/ciqczzwiuigllkpdebup/sql/new`)
and run each file in `migrations/` **in filename order** (they're numbered —
`...0001_...` through `...0007_...` — because later files reference tables
and the `is_team_member()` helper the earlier ones create).

## Option C — reconnect this session's Supabase MCP to that account

If you'd rather I apply and verify it directly (and run `get_advisors` to
catch any missing-RLS issue automatically), reconnect the Supabase
integration in your Claude settings to the account that owns
`ciqczzwiuigllkpdebup`, then ask me to continue — `list_projects` will show
it and I can `apply_migration` each file and check advisors in the same pass.

## Swift app config

Already captured in `app/Sources/ClaudeCodeSwitcher/Supabase/Config.swift`:

- `SUPABASE_URL` → `https://ciqczzwiuigllkpdebup.supabase.co`
- `SUPABASE_ANON_KEY` → the `sb_publishable_...` key (safe to ship in the client)

The `sb_secret_...` key and the legacy `service_role` JWT must **never** go
into the Swift app or anywhere in this repo — they bypass RLS entirely and
belong only in a trusted backend context (none of which this project has;
everything here runs as an authenticated end user through RLS).

## What's in here

| File | Creates |
| - | - |
| `0001_teams_and_members.sql` | `teams`, `members`, the `is_team_member()` RLS helper |
| `0002_accounts.sql` | `accounts`, `account_tokens` (per-recipient ciphertext — see the file's header comment for why this isn't flat columns) |
| `0003_usage.sql` | `usage_current`, `usage_history` |
| `0004_coordination.sql` | `claims`, `poll_leader`, and every mutating RPC (`claim_account`, `heartbeat_claim`, `release_claim`, `try_become_poll_leader`, ...) — direct table writes are blocked by RLS; only the RPCs can mutate these |
| `0005_attribution.sql` | `turn_log`, `switch_log`, `log_turn()` RPC |
| `0006_cron_reapers.sql` | pg_cron jobs that free expired claims/leader leases every minute |
| `0007_realtime.sql` | adds the live tables to the `supabase_realtime` publication |
| `20260720000008_team_invites.sql` | `team_invites`, `create_team()`/`create_team_invite()`/`join_team()` RPCs (fixes the bootstrap-only `members_insert` policy) |
| `20260721000001_account_tokens_upsert_fix.sql` | `account_tokens.recipient_key` generated column + upsert-targetable unique constraint |
| `20260721000002_usage_history_trigger.sql` | `usage_current_history_trigger` — mirrors every `usage_current` write into `usage_history`, which had no writer before this |
| `20260721000003_ownership_and_leave.sql` | `transfer_account_ownership()` and `leave_team()` RPCs (Settings window's My Accounts / Team tabs) |
| `20260721000004_reauth_requests.sql` | `reauth_requests` table + `request_reauth()`/`clear_account_reauth()` RPCs — makes quarantine a shared, Realtime-visible `accounts.status`, and adds the "Request re-login" notification flow |
| `20260723000001_fix_create_team_invite_random.sql` | Fixes `create_team_invite()`, which was failing in production with `42883: function gen_random_bytes(integer) does not exist` (pgcrypto lives outside this function's `public` search_path) — switches to core `gen_random_uuid()`, no extension dependency |

Run `mcp: get_advisors(type="security")` after applying — RLS policies are
easy to get subtly wrong, and that check catches it fast.
