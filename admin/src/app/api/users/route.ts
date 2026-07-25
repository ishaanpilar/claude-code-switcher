import { NextResponse } from "next/server";
import { requireAdmin } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabaseAdmin";

export async function GET(request: Request) {
  const admin = await requireAdmin(request);
  if (!admin) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const client = supabaseAdmin();

  // auth.users isn't a public-schema table PostgREST can select from, so signups come from the
  // admin API instead -- paginated, since listUsers() caps each page and this must not silently
  // truncate as signups grow past one page.
  const users: { id: string; email: string | null; created_at: string }[] = [];
  let page = 1;
  const perPage = 200;
  while (true) {
    const { data, error } = await client.auth.admin.listUsers({ page, perPage });
    if (error) {
      return NextResponse.json({ error: error.message }, { status: 500 });
    }
    users.push(
      ...data.users.map((u) => ({ id: u.id, email: u.email ?? null, created_at: u.created_at }))
    );
    if (data.users.length < perPage) break;
    page += 1;
  }

  const { data: profiles, error: profilesError } = await client
    .from("profiles")
    .select("user_id, online_access, access_granted_at");
  if (profilesError) {
    return NextResponse.json({ error: profilesError.message }, { status: 500 });
  }
  const profileById = new Map((profiles ?? []).map((p) => [p.user_id as string, p]));

  // Teams joined per signup: lets the admin tell "signed up, never touched the pool" apart from
  // "already in a team and consuming Supabase usage" at a glance, without a second query elsewhere.
  const { data: memberships } = await client.from("members").select("user_id");
  const teamCountByUser = new Map<string, number>();
  for (const m of memberships ?? []) {
    const id = m.user_id as string;
    teamCountByUser.set(id, (teamCountByUser.get(id) ?? 0) + 1);
  }

  const rows = users
    .map((u) => {
      const profile = profileById.get(u.id);
      return {
        userId: u.id,
        email: u.email,
        signedUpAt: u.created_at,
        onlineAccess: profile?.online_access ?? false,
        accessGrantedAt: profile?.access_granted_at ?? null,
        teamCount: teamCountByUser.get(u.id) ?? 0,
      };
    })
    .sort((a, b) => (a.signedUpAt < b.signedUpAt ? 1 : -1));

  return NextResponse.json({ users: rows });
}
