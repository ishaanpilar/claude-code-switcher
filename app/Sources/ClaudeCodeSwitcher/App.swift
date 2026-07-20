import SwiftUI

@main
struct ClaudeCodeSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()
    @StateObject private var pool = PoolState()

    var body: some Scene {
        MenuBarExtra(state.titleText, systemImage: "arrow.triangle.2.circlepath") {
            RootView(state: state, pool: pool)
        }
        .menuBarExtraStyle(.window)

        // A real window, not menu bar content — the Team-usage digest (BUILD_PLAN.md section 8)
        // is a data table, not a quick-glance status. `.accessory` activation policy (below)
        // still allows normal windows to open; it only suppresses the Dock icon.
        WindowGroup(id: "team-usage") {
            TeamUsageView(state: state, pool: pool)
        }
        .windowResizability(.contentSize)
    }
}

/// Branches between onboarding and the real panel on `pool.step` — see PoolState.swift for the
/// full state machine (auth → team membership → local team-key presence → ready).
private struct RootView: View {
    @ObservedObject var state: AppState
    @ObservedObject var pool: PoolState

    var body: some View {
        if case .ready = pool.step {
            PanelView(state: state, pool: pool)
        } else {
            OnboardingView(pool: pool)
        }
    }
}

/// `MenuBarExtra` alone doesn't hide the Dock icon / Cmd-Tab entry the way rumps's accessory
/// mode does for claude-swap's Python menu bar (see the earlier design discussion) — that's set
/// explicitly here, plus where app-lifetime state (AppState.start/stop) hooks in.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        NotificationService.requestAuthorizationIfNeeded()
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
