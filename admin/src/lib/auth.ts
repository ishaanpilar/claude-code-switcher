import { createClient } from "@supabase/supabase-js";
import { SUPABASE_ANON_KEY, SUPABASE_URL } from "./supabaseConfig";

/**
 * Validates the bearer token against Supabase Auth and checks the resulting email against
 * ADMIN_EMAIL. This is the only gate on the API routes -- signing into this app with *any* valid
 * Supabase account (anyone who has ever signed into the Swift app) is not enough, since that's
 * exactly the population this dashboard exists to gate.
 */
export async function requireAdmin(request: Request) {
  const adminEmail = process.env.ADMIN_EMAIL;
  if (!adminEmail) return null;

  const authHeader = request.headers.get("authorization") ?? "";
  const token = authHeader.replace(/^Bearer\s+/i, "");
  if (!token) return null;

  const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY);
  const { data, error } = await supabase.auth.getUser(token);
  if (error || !data.user || data.user.email?.toLowerCase() !== adminEmail.toLowerCase()) {
    return null;
  }
  return data.user;
}
