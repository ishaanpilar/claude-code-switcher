import Foundation
import Sparkle

/// One shared Sparkle updater for the whole process — same shared-singleton shape as
/// `SupabaseClientProvider` (Supabase/Client.swift): there's exactly one meaningful "the app's
/// updater," so unlike `state`/`pool`/`router` (SwiftUI-diffed domain state, explicitly threaded
/// through view initializers) this is infrastructure reached indirectly through the thin proxy on
/// `AppState` below rather than passed around directly.
///
/// `SPUStandardUpdaterController` requires a real bundled `.app` (`SUFeedURL`/`SUPublicEDKey`/
/// `CFBundleIdentifier` in Info.plist) — same `isAvailable` guard shape as `NotificationService`/
/// `LaunchAtLogin`, since a bare `swift run` dev binary has none of that.
@MainActor
enum UpdaterProvider {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static let shared = SPUStandardUpdaterController(
        startingUpdater: isAvailable,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}
