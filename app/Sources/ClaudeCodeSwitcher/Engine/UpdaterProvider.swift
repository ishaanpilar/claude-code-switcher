import Foundation
import Sparkle

/// One shared Sparkle updater for the whole process, same singleton shape as
/// `SupabaseClientProvider`. There is exactly one meaningful "the app's updater", so unlike the
/// SwiftUI-diffed domain state threaded through view initializers, this is infrastructure reached
/// through a thin proxy on `AppState` rather than passed around.
///
/// `SPUStandardUpdaterController` requires a real bundled `.app` (`SUFeedURL`/`SUPublicEDKey`/
/// `CFBundleIdentifier` in Info.plist), so it uses the same `isAvailable` guard as
/// `NotificationService` and `LaunchAtLogin`. A bare `swift run` dev binary has none of that.
@MainActor
enum UpdaterProvider {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    static let shared = SPUStandardUpdaterController(
        startingUpdater: isAvailable,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )
}
