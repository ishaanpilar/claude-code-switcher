import SwiftUI

/// Lets the menu-bar panel open the Settings window on a specific pane. Shared between the panel
/// and `SettingsView` so a click in one selects the right pane in the other.
@MainActor
final class SettingsRouter: ObservableObject {
    @Published var pane: SettingsView.Pane = .accounts
}

@main
struct ClaudeCodeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var pool = PoolState()
    @StateObject private var router = SettingsRouter()

    var body: some Scene {
        MenuBarExtra(state.titleText, systemImage: "arrow.triangle.2.circlepath") {
            RootView(state: state, pool: pool, router: router)
        }
        .menuBarExtraStyle(.window)

        // The full Settings window: the deep-configuration surface the dropdown deliberately
        // isn't, and the home of the Team usage pane. Opened from the panel or with Cmd-comma.
        Window("Settings", id: "settings") {
            SettingsView(state: state, pool: pool, router: router)
        }
        .windowResizability(.contentMinSize)
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Branches between onboarding and the real panel on `pool.step`. See PoolState.swift for the
/// full state machine.
private struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @ObservedObject var router: SettingsRouter

    var body: some View {
        switch pool.step {
        case .ready, .localOnly:
            // Both show the real panel. `.localOnly` just means no team is wired up, and every
            // pool feature already guards on `currentTeam != nil`, so the panel degrades to
            // local-account switching on its own.
            PanelView(state: state, pool: pool, router: router)
        default:
            OnboardingView(pool: pool, router: router)
        }
    }
}

/// The app starts menu-bar-only (`.accessory`: no Dock icon, no Cmd-Tab entry). That policy is
/// also why a plain `openWindow` opens the Settings window behind whatever is frontmost and
/// refuses to come forward, since an accessory app can't activate itself. So while any real
/// window is open the app becomes `.regular`, and reverts to `.accessory` once the last closes.
enum WindowManager {
    /// Call right before `openWindow(...)`. Promotes to a real app and activates so the window
    /// that's about to appear lands in front and takes focus.
    @MainActor static func prepareToShowWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Re-checks after a window closes: if no ordinary app windows remain, drop back to accessory.
    /// The MenuBarExtra dropdown doesn't count, since it isn't a titled `NSWindow`.
    @MainActor static func windowDidClose() {
        // Deferred a runloop tick so the closing window is actually gone from `windows` first.
        DispatchQueue.main.async {
            let hasRealWindow = NSApplication.shared.windows.contains { window in
                window.isVisible && window.canBecomeMain && !window.title.isEmpty
            }
            if !hasRealWindow {
                NSApplication.shared.setActivationPolicy(.accessory)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NotificationService.requestAuthorizationIfNeeded()
        _ = UpdaterProvider.shared  // touching .shared the first time starts Sparkle's updater
        // Any real window closing may mean we should drop back to accessory (menu-bar-only).
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in WindowManager.windowDidClose() }
        }
    }

    /// Gives back any reservation this device holds before the process goes away. Uses
    /// `.terminateLater` rather than `applicationWillTerminate` because the release is a network
    /// call and `willTerminate` offers no way to await one. `AppState` bounds the wait, so a dead
    /// network delays quit by a couple of seconds at most.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = AppState.shared, state.holdsReleasableClaim else { return .terminateNow }
        Task { @MainActor in
            await state.releaseHeldClaimBeforeQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Catches the `ccswitch://auth-callback` deep link when a confirmation email is clicked.
    /// Handled here rather than via SwiftUI's `.onOpenURL` because this app has no main window and
    /// `MenuBarExtra`'s content view may not exist when the OS delivers the URL, whereas the
    /// delegate is live for the whole app lifetime.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SupabaseClientProvider.shared.auth.handle(url)
        }
    }
}
