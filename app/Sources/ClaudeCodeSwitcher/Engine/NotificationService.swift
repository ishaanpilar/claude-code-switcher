import Foundation
import UserNotifications

/// Local banners for the three events that matter when the dropdown isn't open: switched,
/// quarantined, all-exhausted. Manual actions already give immediate feedback via the panel's
/// toast while the user is looking at it, so only the automatic engine's decisions, made while
/// nobody was necessarily watching, warrant a banner.
///
/// `UNUserNotificationCenter` requires a real application bundle (a `CFBundleIdentifier` in
/// `Info.plist`) to register with, and a bare `swift run` executable has neither, so it
/// throws if asked. `isAvailable` guards every entry point so this is a silent no-op in that dev
/// shape and only actually posts once the app is packaged as a proper `.app` (BUILD_PLAN.md
/// Phase 5's code-signing/notarization step, not yet done).
enum NotificationService {
    private static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }
    private static let enabledKey = "com.claudecodeswitcher.notificationsEnabled"

    /// User-facing on/off (Settings → General). Defaults to on. Gates `post` so the auto-switch
    /// engine's `post` calls don't need to know about the preference. One choke point, here.
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func requestAuthorizationIfNeeded() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(title: String, body: String) {
        guard isAvailable, isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
