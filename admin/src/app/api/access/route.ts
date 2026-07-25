import { NextResponse } from "next/server";
import { requireAdmin } from "@/lib/auth";
import { supabaseAdmin } from "@/lib/supabaseAdmin";

export async function POST(request: Request) {
  const admin = await requireAdmin(request);
  if (!admin) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  const body = await request.json();
  const userId = typeof body.userId === "string" ? body.userId : null;
  const onlineAccess = typeof body.onlineAccess === "boolean" ? body.onlineAccess : null;
  if (!userId || onlineAccess === null) {
    return NextResponse.json({ error: "userId and onlineAccess are required" }, { status: 400 });
  }

  const client = supabaseAdmin();
  const { error } = await client
    .from("profiles")
    .update({
      online_access: onlineAccess,
      access_granted_at: onlineAccess ? new Date().toISOString() : null,
      access_granted_by: onlineAccess ? admin.id : null,
    })
    .eq("user_id", userId);

  if (error) {
    return NextResponse.json({ error: error.message }, { status: 500 });
  }
  return NextResponse.json({ ok: true });
}
