import SwiftUI

/// Lets the menu-bar panel open the Settings window on a specific pane (e.g. "Team usage…" jumps
/// straight to the usage dashboard). Shared between the panel and `SettingsView` so a click in one
/// selects a pane in the other — the Team-usage digest lives inside Settings now, not a window.
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

        // The full Settings window — the deep-configuration surface the menu-bar dropdown
        // deliberately isn't, and now the home of the Team-usage dashboard too. Opened via
        // "Settings…" / "Team usage…" in the panel, and the standard Cmd-,.
        Window("Settings", id: "settings") {
            SettingsView(state: state, pool: pool, router: router)
        }
        .windowResizability(.contentMinSize)
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Branches between onboarding and the real panel on `pool.step` — see PoolState.swift for the
/// full state machine (auth → team membership → local team-key presence → ready).
private struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState
    @ObservedObject var router: SettingsRouter

    var body: some View {
        switch pool.step {
        case .ready, .localOnly:
            // Both show the real panel — `.localOnly` just means no team is wired up, and every
            // pool feature already guards on `currentTeam != nil`, so the panel degrades to
            // local-account switching on its own.
            PanelView(state: state, pool: pool, router: router)
        default:
            OnboardingView(pool: pool, router: router)
        }
    }
}

/// The app starts menu-bar-only (`.accessory`: no Dock icon, no Cmd-Tab entry). But that policy
/// is exactly why a plain `openWindow` used to open the Settings window *behind* whatever app was
/// frontmost and refuse to come forward — an accessory app can't activate itself. `WindowManager`
/// fixes that "window goes to the back" bug the proper-app way: while any real window is open the
/// app becomes `.regular` (real app, comes to front, shows in the Dock and Cmd-Tab), and reverts
/// to `.accessory` once the last one closes — so the menu bar is just the indicator and the
/// window is the actual app, which is how the user wants it to feel.
enum WindowManager {
    /// Call right before `openWindow(...)`. Promotes to a real app and activates so the window
    /// that's about to appear lands in front and takes focus.
    @MainActor static func prepareToShowWindow() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Re-checks after a window closes: if no ordinary app windows remain (the MenuBarExtra
    /// dropdown/panel doesn't count — it isn't a titled `NSWindow`), drop back to accessory.
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

    /// Catches the `ccswitch://auth-callback` deep link (see `Client.swift`'s `redirectToURL`)
    /// when the confirmation/magic-link email is clicked. `AppDelegate.application(_:open:)`
    /// rather than SwiftUI's `.onOpenURL` — this app has no main window and `MenuBarExtra`'s
    /// content view isn't guaranteed to be instantiated at the moment the OS delivers the URL,
    /// while the delegate is guaranteed live for the whole app lifetime.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            SupabaseClientProvider.shared.auth.handle(url)
        }
    }
}
