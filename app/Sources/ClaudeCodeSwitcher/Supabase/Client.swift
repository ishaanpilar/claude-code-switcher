import Foundation
import Supabase

/// One shared client for the whole app. Auth session state, PostgREST queries and Realtime
/// subscriptions must all agree on the same authenticated session, so there is deliberately no
/// second instance anywhere.
///
/// `redirectToURL` points confirmation/magic-link emails at this app's custom URL scheme
/// (`CFBundleURLTypes` in Info.plist) instead of Supabase's default `localhost:3000` placeholder
/// A menu bar app has no web server to catch that, but it can catch a deep link via
/// `AppDelegate.application(_:open:)` → `auth.handle(url)`. Requires the corresponding entry in
/// the Supabase project's Auth → URL Configuration → Redirect URLs allow-list (a dashboard
/// setting, not something this codebase can apply itself).
enum SupabaseClientProvider {
    static let shared = SupabaseClient(
        supabaseURL: SupabaseConfig.projectURL,
        supabaseKey: SupabaseConfig.publishableKey,
        options: SupabaseClientOptions(
            auth: .init(redirectToURL: URL(string: "ccswitch://auth-callback"))
        )
    )
}
