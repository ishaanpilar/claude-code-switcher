import Foundation

/// Project-level Supabase config for the client app. Both values here are the **publishable**
/// pair — safe to ship inside the app bundle because every operation they authorize goes through
/// Row Level Security (see supabase/migrations/*.sql: every table has RLS enabled, and every
/// mutation either checks `is_team_member()` or goes through a `security definer` RPC that
/// checks it internally).
///
/// The `sb_secret_...` key / legacy `service_role` JWT must never appear in this file, anywhere
/// else in this target, or in any file committed to this repo — they bypass RLS entirely and
/// belong only in a trusted backend context, which this project doesn't have (nor needs one:
/// the whole point of the RLS-first schema is that an end user's own publishable-key session is
/// sufficient for everything the app does).
enum SupabaseConfig {
    static let projectURL = URL(string: "https://ciqczzwiuigllkpdebup.supabase.co")!
    static let publishableKey = "sb_publishable_0JCxQekzhJmEV8mZIoiPSg_Vb1wuMQ8"
}
