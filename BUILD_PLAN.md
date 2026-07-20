# Claude Code Switcher — Build Plan

**Audience:** an AI coding agent (Sonnet) that will implement this app phase by phase.
**Author of plan:** architecture pass (Opus). Read this top to bottom before writing code.
**Platform scope:** macOS first. Windows is a later expansion — the architecture below
keeps every OS-specific concern behind two seams (the Python core's credential layer,
and the Swift GUI) so Windows means adding implementations, not rewriting.

> **Reference codebase:** `realiti4/claude-swap` (MIT) is the proven prior art. This plan
> tells you exactly which of its modules to reuse, which to port, and which to drop. Clone
> it and keep it open — do **not** re-derive its hard-won edge cases (lockfile cooperation,
> credential-field merge, hot-reload mtime bump, token freshening). Those are called out
> explicitly below with file references.

---

## 0. What we are building (one paragraph)

A group of friends — from a couple up to ~10 people — each run VS Code + Claude Code on
their own Mac. They want to pool their Claude accounts: when one account nears its rate
limit, switch to whichever pooled account has the most quota left — automatically, and
visible to everyone in real time. The design assumes a small trusted team (**target max
~10 members**), not a public service; nothing hardcodes a fixed member count. The app is a
**macOS menu bar dropdown** showing every pooled account's live usage, who is currently
using each one, and one-click (or automatic) switching. New logins are captured
automatically. Usage is attributed per person so the group can see who is consuming what.
State is coordinated through **Supabase** (Postgres + Realtime + Auth). OAuth tokens for
"shared" accounts are **end-to-end encrypted** with a team key the server never sees.

---

## 1. Architecture decision (chosen: Option C, refined)

### The two-process split

| Process | Language | Lifetime | Owns |
|---|---|---|---|
| **`ClaudeCodeSwitcher.app`** | Swift / SwiftUI | Always running (menu bar) | GUI, Supabase (auth + realtime + REST), the decision/scheduling engine, claim & poll-leader leases, team-key encryption, launch-at-login, file-watching for auto-capture |
| **`ccswitch-core`** | Python (derived from claude-swap) | Short-lived subprocess, one command per invocation | All local Claude-credential operations: read/write Keychain, cooperate with Claude Code's lockfiles, activate a credential, call Anthropic's usage/refresh API |

**Why this split (the pros/cons you asked about):**

- **Pro — reuse the proven core.** claude-swap already solved the genuinely hard, dangerous
  parts (a switch racing Claude Code's own token refresh, the shared-vs-account-owned
  credential merge, the macOS Keychain fallback). Reimplementing those in Swift would risk
  silent credential corruption. We keep them in Python, unchanged.
- **Pro — native, low-resource GUI.** The always-running process is tiny native Swift, not
  Electron and not an idle Python daemon. Python runs only for the ~1s a switch or a usage
  read takes, then exits. This is the "less resources / better than what exists" win: idle
  footprint is a native menu bar app plus a websocket, nothing else.
- **Pro — full color/design control.** `MenuBarExtra` with `.menuBarExtraStyle(.window)`
  gives a fully custom SwiftUI panel — real colors, bars, avatars — which `rumps` (native
  `NSMenu` text rows) cannot do.
- **Con — an IPC boundary.** Swift talks to Python by spawning a bundled binary and
  exchanging JSON over stdin/stdout. This is simple (no socket protocol) but it is a
  boundary to keep clean: **all decisions in Swift, all credential I/O in Python.** Never
  duplicate logic across it.
- **Con — packaging.** Python must be bundled so end users need no Python install. We ship
  `ccswitch-core` as a standalone binary (PyInstaller) inside the `.app` bundle.

### Responsibility rule (do not violate)

- **Swift decides *what* and *when*.** Which account to switch to, when to poll, who holds a
  claim, when to auto-switch, all Supabase reads/writes, all encryption.
- **Python does *the credential act*.** Given an instruction (and, where needed, a plaintext
  token on stdin), it performs the local Keychain/file/lock/API operation and returns JSON.
- Plaintext tokens cross the Swift↔Python boundary **only on the local machine, only via
  stdin/stdout, never via argv, never logged.** They are E2E-encrypted before they ever
  touch Supabase.

### Data-flow diagram

```
  Mac A                          Mac B                          Mac C
┌──────────────────┐          ┌──────────────────┐          ┌──────────────────┐
│ Swift menu bar   │          │ Swift menu bar   │          │ Swift menu bar   │
│  · GUI (SwiftUI) │          │  · GUI           │          │  · GUI           │
│  · engine/sched  │          │  · engine        │          │  · engine        │
│  · Supabase SDK  │          │  · Supabase SDK  │          │  · Supabase SDK  │
│  · team-key enc  │          │  · team-key enc  │          │  · team-key enc  │
│      │  ▲        │          │      │  ▲        │          │      │  ▲        │
│ spawn│  │json    │          │      │  │        │          │      │  │        │
│      ▼  │        │          │      ▼  │        │          │      ▼  │        │
│ ccswitch-core    │          │ ccswitch-core    │          │ ccswitch-core    │
│ (Python, ephem.) │          │ (Python)         │          │ (Python)         │
│  · Keychain      │          │                  │          │                  │
│  · ~/.claude.*   │          │                  │          │                  │
│  · Anthropic API │          │                  │          │                  │
└────────┬─────────┘          └────────┬─────────┘          └────────┬─────────┘
         │  REST + Realtime (websocket)          │                    │
         └──────────────────────┬────────────────┴────────────────────┘
                                ▼
                        ┌───────────────────────────────┐
                        │ Supabase (project)            │
                        │  · Postgres: accounts,        │
                        │    usage_current/history,     │
                        │    claims, poll_leader,       │
                        │    turn_log, switch_log       │
                        │  · Realtime (row changes)     │
                        │  · Auth (3 members)           │
                        │  · RLS (team-scoped)          │
                        │  · pg_cron (reap dead leases) │
                        │  Never sees plaintext tokens. │
                        └───────────────────────────────┘
```

*Macs A/B/C are illustrative — the same design scales to any team of up to ~10 members;
one poll leader still means monitoring cost does not grow with the group.*

---

## 2. The Python core: `ccswitch-core`

A thin CLI wrapping logic derived from claude-swap. **One command per process invocation.**
Every command reads flags/stdin and prints a single JSON object to stdout (`{"ok": true, ...}`
or `{"ok": false, "error": {"code": "...", "message": "..."}}`), exit code 0 on success.

### Command surface (build exactly these)

| Command | Input | Output | Reuses from claude-swap |
|---|---|---|---|
| `snapshot` | — | active account identity + list of locally-known accounts `[{email, org_uuid, account_uuid, has_creds, kind}]` | `switcher._get_current_account`, config read |
| `add-current` | — | identity of the now-logged-in account, captured into local store | `switcher.add_account` (trimmed) |
| `export-token --account-uuid U` | — | `{token: "<plaintext oauth json>"}` on stdout (for the owner to encrypt+share) | `credentials._read_account_credentials` |
| `import-activate` | plaintext token on **stdin** | stores token locally + activates it (full switch) | `credentials._write_credentials`, `switcher.perform_switch`, `claude_locks` |
| `switch --account-uuid U` | — | activate a locally-stored account | `switcher.perform_switch`, `claude_locks` |
| `read-usage` | plaintext token on **stdin** (or `--account-uuid U`) | `{five_hour, seven_day, scoped[], spend, resets...}` | `oauth.fetch_usage` |
| `refresh-token` | plaintext token on **stdin** | freshened token JSON (refresh if expiring < 10 min) | `oauth.refresh_oauth_credentials` |
| `remove --account-uuid U` | — | delete local backups for that account | `credentials._delete_account_credentials` |

### Reuse map — port these modules **as-is** (they are correctness-critical)

- **`claude_locks.py` → reuse verbatim.** This is the single most important file to not
  rewrite. It cooperates with Claude Code's `proper-lockfile` directory locks
  (`~/.claude.lock`, `~/.claude.json.lock`) so a switch can never land mid-token-refresh and
  get silently overwritten. Every `switch` / `import-activate` must hold these locks while
  writing, exactly as claude-swap does.
- **`credentials.py` → reuse the macOS paths.** Keep: OAuth Keychain read/write, the
  `SHARED_CREDENTIAL_KEYS` merge (`_prepare_credentials_for_activation` /
  `merge_shared_credential_fields` — preserves live MCP OAuth state instead of clobbering it
  with a slot's older snapshot), API-key detection, the `.enc` file fallback when Keychain is
  unavailable. **Drop:** Windows Credential Manager code, keyring-migration code.
- **`oauth.py` → reuse.** Anthropic usage-API fetch, token refresh (the "freshen before
  activate" logic), reset-time formatting.
- **`paths.py` → reuse macOS branches.** Drop XDG/Windows branches for v1 (add back for
  Windows expansion).
- **`switcher.py` → extract only the switch execution path.** The relevant logic:
  back up the outgoing account, write the target credential, merge `oauthAccount` into
  `~/.claude.json`, bump `.credentials.json` mtime so a running Claude Code hot-reloads
  (`credentials._refresh_stale_credentials_file`, issue #86). **Drop** the large
  swap/move/mappings/session/quarantine machinery — Supabase now owns pool identity and
  slot numbering, so most of `switcher.py` (4,800 lines) is not needed.

### Drop entirely for v1 (Supabase or Swift replaces them)

`tui/`, `menubar.py` (→ Swift), `session.py`, `mappings.py`, `transfer.py` (→ Supabase
sync), `migrations.py`, `snapshot_source.py`, `usage_store.py` (→ Swift in-memory + Supabase
`usage_current`).

### Port to **Swift** (pure logic, no OS calls — must run in the always-on process)

- **`poll_policy.py` (203 lines)** — the adaptive per-account poll-cadence math (poll
  busy/near-threshold accounts more often, idle/exhausted ones less). This is the heart of
  the efficiency engine and must run in the Swift scheduler.
- **`autoswitch.py` decision logic** — the scoring, hysteresis margin, and cooldown (NOT its
  I/O). Reimplement as pure Swift functions; execution (freshen + switch) delegates to Python.
- **`pace.py`** — "ahead of pace" weekly projection, for the dashboard.

### Packaging

Build `ccswitch-core` with PyInstaller into a single binary, place it in
`ClaudeCodeSwitcher.app/Contents/Resources/ccswitch-core`. Swift locates it via
`Bundle.main.resourceURL` and spawns with `Foundation.Process`. No system Python required.

---

## 3. The efficiency engine (this is the "better than what exists" core)

The expensive, rate-limit-sensitive operation is polling Anthropic's usage endpoint. Naive
design = 3 machines × N accounts of redundant calls, which can itself trip per-account rate
limits just from *monitoring*. Two mechanisms fix this:

### 3a. Single poll-leader election (not everyone polls)

At any moment **exactly one online client** is the poll leader for the team, elected via a
short-lease row in the `poll_leader` table (same atomic-conditional-update pattern as
account claims, section 5). Only the leader polls; it writes results to `usage_current`;
**the other two clients receive updates for free over Realtime.** If the leader goes offline,
its lease expires (pg_cron reaps it) and another client takes over within one lease interval.

This preserves end-to-end encryption: the **server never polls** (it can't — it has no
plaintext token). Polling is done by a *client*, which can decrypt shared tokens with the
team key, plus its own local visibility-only tokens.

### 3b. Adaptive cadence (port of `poll_policy.py`)

The leader does not poll every account every tick. Per account, cadence scales with:
movement (usage changing fast → poll sooner), distance to threshold (near the limit → poll
sooner), reset proximity, and 429-backoff. Baseline volume is **O(1) requests per tick** —
the active account plus one "most-stale" candidate — not a full sweep. Escalate to a full
candidate refresh only when a switch could actually be imminent (active usage within a
margin of the threshold, or active usage unknown). Copy the constants and the scheduling
shape directly from `poll_policy.py`. Because the per-tick budget is bounded (one active +
one stale candidate), monitoring cost stays flat whether the pool holds 3 accounts or 30 —
this is exactly what lets membership scale to ~10 people without adding Anthropic load.

### 3c. What each account's usage source is

- **Shared account:** any online client (via the leader) can poll it — decrypts the token
  with the team key, calls Anthropic, publishes numbers to `usage_current`.
- **Visibility-only account:** only the **owner's** machine holds the token, so only the
  owner publishes its `usage_current` (numbers only, never the token). If the owner is
  offline, that account's usage simply goes stale and is shown with an age marker
  (`· 6m ago`) — same graceful degradation claude-swap uses. Never blank, never a lie.

### 3d. Refresh loop timing

- Realtime is the primary "keep everyone in loop" channel: a switch/claim/usage change on
  one Mac fans out to the others in ~1s over the websocket. **Do not poll Supabase on a
  timer for state** — subscribe.
- The poll leader runs its adaptive Anthropic-usage loop on a background `Task` (default
  tick 60s, adjusted per `poll_policy`).
- Auto-capture (section 6) watches `~/.claude.json` via **FSEvents** (native, event-driven,
  zero idle cost), not polling.

---

## 4. Supabase schema

Provision via the Supabase MCP tools (`apply_migration`). RLS on every table, scoped to team
membership. `pg_cron` for lease reaping. (The plan author can scaffold this directly when
you reach Phase 0.)

```sql
-- teams & membership -------------------------------------------------------
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
  role text not null default 'member',           -- 'owner' | 'member'
  joined_at timestamptz not null default now(),
  primary key (user_id, team_id)
);

-- accounts (the pool) ------------------------------------------------------
create type share_mode as enum ('shared', 'visibility_only');
create type account_status as enum ('active', 'disabled', 'quarantined');

create table accounts (
  id uuid primary key default gen_random_uuid(),
  team_id uuid not null references teams(id) on delete cascade,
  owner_user_id uuid not null references auth.users(id),
  label text,                                     -- alias, e.g. "work"
  email text not null,
  organization_uuid text,
  anthropic_account_uuid text not null,           -- identity for dedup (oauthAccount.accountUuid)
  share_mode share_mode not null default 'visibility_only',
  encrypted_token text,                           -- base64 ciphertext; NULL when visibility_only
  token_nonce text,                               -- base64 nonce
  token_updated_at timestamptz,
  status account_status not null default 'active',
  created_at timestamptz not null default now(),
  unique (team_id, anthropic_account_uuid)        -- one pool row per real account
);

-- usage --------------------------------------------------------------------
create table usage_current (                      -- upsert, 1 row/account, drives the UI
  account_id uuid primary key references accounts(id) on delete cascade,
  fetched_at timestamptz not null,
  fetched_by uuid references auth.users(id),
  five_hour_pct numeric,
  seven_day_pct numeric,
  five_hour_resets_at timestamptz,
  seven_day_resets_at timestamptz,
  scoped jsonb,                                   -- per-model weekly limits [{name, pct, resets_at}]
  spend jsonb
);

create table usage_history (                      -- append-only, for attribution & charts
  id bigint generated always as identity primary key,
  account_id uuid not null references accounts(id) on delete cascade,
  fetched_at timestamptz not null,
  five_hour_pct numeric,
  seven_day_pct numeric,
  scoped jsonb
);

-- coordination -------------------------------------------------------------
create table claims (
  account_id uuid primary key references accounts(id) on delete cascade,
  held_by uuid references auth.users(id),
  claimed_at timestamptz,
  lease_expires_at timestamptz,
  heartbeat_at timestamptz,
  purpose text                                    -- 'active_use' | 'auto'
);

create table poll_leader (
  team_id uuid primary key references teams(id) on delete cascade,
  leader_user_id uuid references auth.users(id),
  lease_expires_at timestamptz,
  heartbeat_at timestamptz
);

-- attribution & audit ------------------------------------------------------
create table turn_log (
  id bigint generated always as identity primary key,
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  account_id uuid references accounts(id) on delete set null,
  ts timestamptz not null default now(),
  event text not null                             -- 'prompt_submit' | 'stop'
);

create table switch_log (
  id bigint generated always as identity primary key,
  team_id uuid not null references teams(id) on delete cascade,
  user_id uuid not null references auth.users(id),
  account_from uuid references accounts(id),
  account_to uuid references accounts(id),
  ts timestamptz not null default now(),
  reason text not null                            -- 'manual' | 'auto' | 'failover' | 'captured'
);
```

### Atomic claim RPC (collision-free by construction)

```sql
create or replace function claim_account(p_account uuid, p_purpose text)
returns claims language plpgsql security definer as $$
declare result claims;
begin
  update claims
     set held_by = auth.uid(), claimed_at = now(),
         lease_expires_at = now() + interval '5 minutes',
         heartbeat_at = now(), purpose = p_purpose
   where account_id = p_account
     and (held_by is null or lease_expires_at < now() or held_by = auth.uid())
  returning * into result;
  return result;                                  -- NULL row ⇒ someone else holds it
end $$;
```

Poll-leader election is the identical pattern on `poll_leader`. Heartbeat every 60s while
holding; release (set `held_by = null`) on switch-away or quit.

### pg_cron reapers

```sql
select cron.schedule('reap-claims', '* * * * *', $$
  update claims set held_by = null where lease_expires_at < now();$$);
select cron.schedule('reap-leader', '* * * * *', $$
  update poll_leader set leader_user_id = null where lease_expires_at < now();$$);
```

### RLS (sketch)

Every table: `using (team_id in (select team_id from members where user_id = auth.uid()))`.
`encrypted_token` is readable by team members but is ciphertext — the server and RLS never
decrypt it. Add a `log_turn(p_account, p_event)` `security definer` RPC for the hook.

---

## 5. Security & the account-sharing model (per-account choice — detail you asked for)

### How "per-account choice" works end to end

At **add-account** time the owner picks one of two modes for *that* account:

**A) Shared token (seamless).**
1. `ccswitch-core add-current` captures the account locally; `export-token` returns the
   plaintext OAuth JSON.
2. Swift encrypts it with the **team key** (libsodium secretbox / XSalsa20-Poly1305) →
   `(ciphertext, nonce)`.
3. Insert/upsert the `accounts` row with `share_mode='shared'`, `encrypted_token`,
   `token_nonce`. The server stores only ciphertext.
4. Any teammate switching to this account: Swift downloads the ciphertext, decrypts with the
   team key, pipes plaintext to `ccswitch-core import-activate` on stdin → local activation.
   Fully hands-free after setup.

**B) Visibility-only (token never leaves the owner).**
1. `add-current` captures locally; **no `export-token`, no upload of any token.**
2. Insert the `accounts` row with `share_mode='visibility_only'`, `encrypted_token = NULL`.
3. Teammates *see* this account's live usage (the owner's machine publishes numbers to
   `usage_current`) and can see it's a good candidate — but "switching to it" means the
   owner activates it on their side, or converts it to shared later. Nothing sensitive
   leaves the owner's Mac.

An account can be **upgraded/downgraded** between modes later (owner-only action): upgrading
runs the encrypt+upload step; downgrading nulls `encrypted_token` server-side.

### The team key

- A 32-byte symmetric key, generated once by the first member, shown as a recovery phrase /
  QR. Each member enters it during onboarding. Stored **in each member's local macOS
  Keychain, never in Supabase.**
- Result: a fully compromised Supabase project leaks **no usable tokens** — only ciphertext
  and usage percentages.
- Trade-off (document in-app): a single shared key means **rotation is manual** — rotating
  (e.g. when a member leaves a 10-person team) requires re-encrypting every shared token,
  and there is no clean per-member revocation. That is fine for a 3-person group but gets
  uncomfortable as membership approaches ~10.
- **Strongly recommended target (schedule by Phase 5): per-member sealed boxes.** Give each
  member a libsodium keypair (public key stored in `members`, private key in their Keychain)
  and encrypt each shared token to every current member's public key. This gives clean
  per-member revocation (drop a member → re-encrypt without them; no group-wide secret to
  rotate) at the cost of N ciphertexts per token. Ship the shared-team-key model in v1 for
  speed, but design the `accounts` token columns to hold either shape so the migration to
  sealed boxes is additive, not a rewrite.

### Honest caveats to surface in the app (do not hide these)

- **Anthropic ToS / anomaly signal.** Pooling one subscription across several people and IPs
  (a team of up to ~10) cuts against consumer terms and *can* look anomalous to Anthropic's
  systems — and the larger the group, the stronger that signal. This is a
  deliberate, low-harm choice among friends — but the app should state it plainly in
  onboarding, not bury it. Do not add anything that evades detection; just be transparent.
- **Plaintext token locality.** Tokens are decrypted only in memory on a member's own Mac
  and passed to Python via stdin — never written to Supabase in the clear, never in argv,
  never logged. Verify no debug log path prints them.

---

## 6. Auto-capture of new logins

The app watches for a fresh `/login` and adds the account to the pool automatically.

- Swift watches `~/.claude.json` with **FSEvents** (event-driven; no polling).
- On change: run `ccswitch-core snapshot`; compare the active account's
  `anthropic_account_uuid` against the set already known locally + in Supabase.
- **Known identity →** it's an ordinary switch; just reflect it. (This is also why normal
  switching never mis-fires the capture path — a switch always lands on a known account.)
- **New identity →** debounce ~2–3s (Claude Code writes `oauthAccount` and the credential a
  beat apart), then:
  1. `ccswitch-core add-current`. If it fails because the credential hasn't landed yet,
     **retry on the next FSEvents tick** (leave a pending marker) rather than giving up;
     hard ceiling ~15s.
  2. Prompt (non-blocking) for share-mode: "Add *email* to the pool as **Shared** or
     **Visibility-only**?" Default to the team's configured default.
  3. Push to Supabase per section 5. **Dedup on `(team_id, anthropic_account_uuid)`** — if a
     teammate already registered this account, refresh the existing row's token (a fresh
     login is newer than the stored one) instead of creating a duplicate.
- Silent by default (a toast, not a modal). One settings toggle: **Auto-capture new logins**.

---

## 7. The GUI (SwiftUI — polished & professional)

`MenuBarExtra("Claude Switcher", systemImage: "arrow.triangle.2.circlepath") { PanelView() }`
`.menuBarExtraStyle(.window)` — a custom SwiftUI dropdown panel.

### Look & feel (one fixed appearance — no user theming)

The goal is simply a **clean, polished, professional-looking** dashboard that does its job
well — **not** a color-customization or theming feature. Ship **one** carefully chosen
appearance; the only variation is automatic system light/dark. The app should feel refined
and restrained (good spacing, clear hierarchy, subtle depth), not flashy. Give it its own
quiet identity — do **not** copy Anthropic/Claude branding (no clay orange, no Claude logo);
that would read as impersonation. The palette below is the **internal design spec** the
builder implements (asset-catalog color sets), *not* anything the user configures:

| Token | Light | Dark | Use |
|---|---|---|---|
| `accent` | `#5B5BD6` (indigo) | `#8B8BF0` | brand accent, active row, primary buttons |
| `surface` | `#FFFFFF` | `#1C1C22` | panel background |
| `surface-2` | `#F4F4F8` | `#26262E` | rows, cards |
| `text` | `#1A1A22` | `#ECECF2` | primary text |
| `text-dim` | `#6B6B76` | `#9A9AA6` | emails, timestamps |
| `ok` | `#2F9E6B` (green) | `#46C88A` | usage < 60% |
| `warn` | `#D9942B` (amber) | `#F0B44A` | usage 60–85% |
| `crit` | `#D14D57` (red) | `#F06A72` | usage > 85% |

Usage bars are gradient fills tinted by the semantic color for their fill %. Keep the design
calm and information-dense; this is a glanceable dashboard, not a marketing page.

### Menu bar title

Icon + (optionally) the active account's tightest usage %, tinted `ok/warn/crit`. Settings
control whether to show the % and which window (5h / 7d / both).

### Panel layout (top → bottom)

1. **Header** — team name · your display name · a small dot indicating whether *you* are the
   poll leader.
2. **Account list** — one card per pooled account:
   - alias (bold) + email (dim)
   - two thin usage bars: **5h** and **7d**, colored by fill; reset countdown at the right
   - **share badge**: 🔓 shared / 👁 visibility-only
   - **claimed-by badge**: colored initials of the teammate currently driving it (from
     `claims` via Realtime) — blank if free
   - a check on the row that is *your* active account
   - **tap a row → claim + switch** (attempt `claim_account`; if it returns null, toast
     "*Name* is using this — switched to next-best instead" and fall through to the best
     free candidate)
3. **Quick actions** — Rotate to next · Switch to best · Next available.
4. **Add account** — captures current login → share-mode prompt → push.
5. **Toggles** — Auto-capture new logins · Auto-switch (+ threshold submenu 80/90/95/98).
6. **Team usage** — opens the attribution view (section 8).
7. **Settings · Quit.**

### Threading rule (carry over from claude-swap's menubar)

All UI mutation on the main thread. Background work (Python subprocess calls, Anthropic
polls, Supabase writes) runs on `Task`/background queues and hands results back via
`@MainActor` state updates; SwiftUI re-renders reactively. Realtime callbacks likewise
marshal to `@MainActor` before touching view state. Keep exactly one in-flight refresh
worker (an "is-refreshing" guard) so the paced poller's state isn't touched concurrently.

---

## 8. Attribution ("who is consuming how much")

Anthropic's usage API is **per-account, never per-user** — so we attribute via **turn
counts**, a far better proxy than claim wall-clock time.

- Install a Claude Code **`UserPromptSubmit` hook** in each member's `~/.claude/settings.json`
  that runs a tiny script POSTing `{user, active_account, ts, event: 'prompt_submit'}` to the
  `log_turn` Supabase RPC. (Ship this script + the settings snippet; the app writes it on
  first run, with consent.)
- Attribution for a usage delta over a window = *user's share = their turn count / total
  turns in that window*. A heavy multi-file edit costs more than a one-line question, but
  turn count tracks consumption far better than idle time does.
- **Deliverables:** a per-user weekly digest (turn count, estimated % of pool consumed,
  top accounts) shown in the Team-usage view, and optionally a Discord/Slack webhook. The
  plan author can build a live web dashboard (reads Supabase directly) once the schema is up.

---

## 9. Build phases (each has acceptance criteria — self-check before moving on)

### Phase 0 — Scaffolding

- Swift app: `MenuBarExtra` window skeleton renders a static panel; launch-at-login via
  `SMAppService`.
- Python: `ccswitch-core` CLI skeleton with `snapshot` returning real local state.
- Supabase: project created; schema + RLS + `claim_account`/`log_turn` RPCs + pg_cron
  applied; Auth enabled (magic-link or GitHub).
- **Accept:** menu bar icon appears; `ccswitch-core snapshot` prints correct active account;
  `select * from accounts` works under RLS for a signed-in test user.

### Phase 1 — Local single-user MVP (no Supabase yet)

- Swift spawns Python for `snapshot`, `add-current`, `switch`, `remove`.
- Auto-capture via FSEvents (section 6), known-vs-new dedup, debounce+retry.
- **Accept:** log into a new account in Claude Code → it appears in the panel within a few
  seconds without any manual action; clicking another account switches Claude Code (verify
  the next `claude` message uses the new account); `claude_locks` cooperation verified by
  switching while a `claude` process is mid-refresh (no corruption).

### Phase 2 — Supabase sync (the pool goes live)

- Auth for team members (up to ~10); team creation + join; team-key onboarding
  (generate/enter, store in Keychain).
- Push accounts per share-mode (encrypt shared tokens); publish `usage_current`; subscribe
  to Realtime for `accounts` + `usage_current` + `claims`.
- Claimed-by badges; tap-to-claim-and-switch with graceful fallback.
- **Accept:** an account added on one Mac appears on every other member's Mac within ~1s;
  switching on one shows a claimed-by badge on all the others; a shared account added on one
  Mac can be activated on another purely from the encrypted token (the origin Mac not
  involved); the Supabase row shows only ciphertext.

### Phase 3 — The efficiency engine

- Poll-leader election + heartbeat + failover; adaptive cadence ported from `poll_policy`.
- Auto-switch decision engine (scoring with claim-awareness + hysteresis + cooldown) →
  executes via Python `refresh-token` then `switch`.
- **Accept:** with all members online, only one client issues Anthropic usage calls (verify
  via logs); total usage-API volume stays flat as accounts *and members* are added; when the
  active account crosses the threshold, the app switches to the highest-headroom *free*
  account without flip-flopping; killing the leader process → another client takes over
  within one lease.

### Phase 4 — Attribution

- Turn-log hook installed (with consent); weekly digest in the Team-usage view.
- **Accept:** prompts submitted by different members produce correct per-user turn shares;
  digest numbers reconcile with `usage_history` deltas.

### Phase 5 — Polish & hardening

- Notifications (switched / quarantined / all-exhausted), dead-token quarantine + re-login
  recovery, share-mode upgrade/downgrade UI, error surfaces, onboarding copy incl. the ToS
  caveat, code-signing + notarization for distribution.
- **Then** Windows expansion: add Windows branches to the Python credential/paths layer and
  a Windows tray GUI (WinUI/Tauri) reusing the same Supabase + engine contracts.

---

## 10. Repository layout

```
claude-code-switcher/
├── BUILD_PLAN.md                      # this file
├── core/                              # Python ccswitch-core (derived from claude-swap)
│   ├── pyproject.toml
│   ├── src/ccswitch_core/
│   │   ├── __main__.py                # CLI dispatch (one command per run)
│   │   ├── claude_locks.py            # ← reuse verbatim from claude-swap
│   │   ├── credentials.py             # ← reuse macOS paths; trim Windows/keyring
│   │   ├── oauth.py                   # ← reuse (usage fetch + refresh)
│   │   ├── paths.py                   # ← reuse macOS branches
│   │   └── switch.py                  # ← extract perform_switch path only
│   └── tests/
├── app/                               # Swift menu bar app
│   ├── ClaudeCodeSwitcher.xcodeproj
│   └── Sources/
│       ├── App.swift                  # MenuBarExtra entry
│       ├── Panel/                      # SwiftUI views (colored dashboard)
│       ├── Engine/                     # scheduler, poll-leader, auto-switch (port poll_policy/pace)
│       ├── Supabase/                   # SDK client, realtime, RPCs
│       ├── Crypto/                     # team-key secretbox (CryptoKit/libsodium)
│       ├── CoreBridge/                 # Process spawner + JSON codec for ccswitch-core
│       └── Capture/                    # FSEvents watcher for ~/.claude.json
├── supabase/
│   └── migrations/                    # schema, RLS, RPCs, pg_cron
└── hooks/
    └── log_turn.sh                    # UserPromptSubmit hook script
```

---

## 11. Invariants the builder must never break

1. **All credential I/O in Python, all decisions in Swift.** Never duplicate switch logic
   across the boundary.
2. **Hold Claude Code's lockfiles during every credential write** (`claude_locks`). A switch
   that skips this can be silently overwritten by a concurrent token refresh.
3. **Plaintext tokens never reach Supabase, argv, or logs.** Only team-key ciphertext is
   uploaded; plaintext crosses Swift↔Python via stdin only.
4. **Dedup accounts on `anthropic_account_uuid`**, not on email or slot number.
5. **Subscribe, don't poll, for coordination state.** Timers are only for the leader's
   Anthropic-usage cadence and FSEvents-driven capture.
6. **One poll leader at a time.** Adding accounts *or members* must not increase Anthropic
   API volume — the whole point of scaling to ~10 people cheaply.
7. **Degrade gracefully.** A stale/unreadable usage number is shown with an age marker,
   never blanked and never presented as fresh.
8. **Surface the ToS caveat honestly** in onboarding; never build detection-evasion.
```
