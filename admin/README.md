# Admin dashboard

A small, single-admin web app: lists every signup (from Supabase Auth) and lets
you grant or revoke `online_access` per person -- the flag `create_team()` and
`join_team()` now require (see
`supabase/migrations/20260726000001_online_access_gate.sql`). Signing up in the
Swift app stays open to anyone; this is what controls who can actually touch
the synced, Supabase-billed features.

Nothing here is a general-purpose backend for the app -- it's a thin CRUD
layer over `auth.users` and one `profiles.online_access` column, gated behind
one admin email. Payment gating later is additive: a Stripe webhook would just
flip the same flag.

## Prerequisites

Apply `supabase/migrations/20260726000001_online_access_gate.sql` first (see
`supabase/README.md`) -- the `profiles` table and the `has_online_access()`
check must exist before this app has anything to read or enforce.

Add the deployed URL (and `http://localhost:3000` for local dev) to
**Supabase dashboard -> Authentication -> URL Configuration -> Redirect URLs**.
Sign-in is a magic-link click, not a typed code (see below), and Supabase
rejects the redirect if the URL isn't on that allow-list.

## Local setup

```bash
cd admin
npm install
cp .env.example .env.local   # fill in the two values below
npm run dev                  # http://localhost:3000
```

- `SUPABASE_SERVICE_ROLE_KEY` -- Supabase dashboard -> Project Settings -> API
  -> service_role secret key. Never commit it; never rename it to start with
  `NEXT_PUBLIC_`, which would ship it to the browser.
- `ADMIN_EMAIL` -- the only email allowed to use this dashboard. Must already
  be a Supabase auth user in this project (e.g. whichever email you use to
  sign into the Swift app).

The Supabase project URL and anon/publishable key are **not** env vars here --
they're committed literals in `src/lib/supabaseConfig.ts`, mirroring
`app/Sources/ClaudeCodeSwitcher/Supabase/Config.swift`. That's intentional:
they're the publishable pair, safe to ship, same as in the Swift app.

## How the gate actually works

- Sign-in is a magic-link click (`signInWithOtp` + `emailRedirectTo`), not a typed 6-digit
  code like the Swift app. A typed code needs the "Magic Link" email template edited to print
  `{{ .Token }}`, which isn't reliably editable on every Supabase plan; a link needs no template
  changes at all. `supabase-js` auto-detects the session from the URL once the click lands back
  on this page, so there's no separate "verify" step in the code.
- `src/lib/auth.ts`'s `requireAdmin()` verifies the bearer token against
  Supabase Auth, then checks the resulting email against `ADMIN_EMAIL`. Every
  API route calls this first and 401s otherwise. Signing into this app with
  *any* valid Supabase account isn't enough -- that's exactly the population
  this dashboard exists to gate.
- `src/lib/supabaseAdmin.ts` holds the service-role client, imported only by
  route handlers under `src/app/api/`. It's what lets `GET /api/users` read
  every signup via `auth.admin.listUsers()` (paginated, so it doesn't silently
  truncate once signups pass one page) and read/write `profiles` directly,
  bypassing RLS.
- `POST /api/access` flips `profiles.online_access` for one `userId` and stamps
  `access_granted_at` / `access_granted_by`.

## Deploying (Vercel)

1. Push this repo to GitHub if it isn't already.
2. In Vercel: **New Project** -> import the repo -> set **Root Directory** to
   `admin` (this is a subfolder, not the repo root).
3. Add the two env vars from `.env.example` in the Vercel project's
   **Settings -> Environment Variables** (Production, and Preview if you want
   preview deploys to work too).
4. Deploy. Every push to the connected branch redeploys automatically.

Free tier is more than enough for a single-admin dashboard -- this only runs
on the two API routes when you load the page, no background compute.
