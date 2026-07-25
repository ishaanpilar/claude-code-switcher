import { createClient } from "@supabase/supabase-js";
import { SUPABASE_URL } from "./supabaseConfig";

/**
 * Service-role client. Bypasses RLS entirely, same caveat as supabase/README.md -- only ever
 * import this from a route handler under src/app/api/, never from a "use client" component.
 */
export function supabaseAdmin() {
  const key = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key) {
    throw new Error("SUPABASE_SERVICE_ROLE_KEY is not set");
  }
  return createClient(SUPABASE_URL, key, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
