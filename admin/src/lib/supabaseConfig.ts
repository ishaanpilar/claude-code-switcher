/**
 * The publishable Supabase pair, mirrored from
 * app/Sources/ClaudeCodeSwitcher/Supabase/Config.swift. Safe to commit: every browser-side
 * operation this key authorizes goes through Row Level Security, same as the Swift app. The
 * secret pair (SUPABASE_SERVICE_ROLE_KEY) is never here -- it's an env var read only inside
 * src/lib/supabaseAdmin.ts, which only the API route handlers import.
 */
export const SUPABASE_URL = "https://ciqczzwiuigllkpdebup.supabase.co";
export const SUPABASE_ANON_KEY = "sb_publishable_0JCxQekzhJmEV8mZIoiPSg_Vb1wuMQ8";
