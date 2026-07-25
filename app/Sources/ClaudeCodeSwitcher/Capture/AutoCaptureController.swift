import Foundation

/// Decides what a `~/.claude.json` change means and, if it's a fresh `/login`, captures it:
/// debounce the OAuth flow's multi-step writes, tell a genuine new login apart from an ordinary
/// switch (unknown vs. known account_uuid), and retry with a ceiling rather than giving up on the
/// first attempt, since the credential file can land a beat after `.claude.json` does.
///
/// Runs on the main actor because its output feeds SwiftUI state directly.
@MainActor
final class AutoCaptureController {
    private let bridge: CoreBridge
    private let onCaptured: (AccountIdentity) -> Void
    private let onKnownAccountActive: (AccountIdentity) -> Void

    private var pending: (accountUuid: String, firstSeenAt: Date)?
    private var retryTimer: Timer?
    private var watcher: CaptureWatcher?

    /// Wait this long after first seeing an unknown account_uuid before trying to capture it.
    /// Claude Code's login flow writes `oauthAccount` and the credential a beat apart.
    private let settleSeconds: TimeInterval = 3
    /// Give up retrying after this long total; a login that never completes shouldn't retry forever.
    private let maxWaitSeconds: TimeInterval = 15

    init(
        bridge: CoreBridge,
        onCaptured: @escaping (AccountIdentity) -> Void,
        onKnownAccountActive: @escaping (AccountIdentity) -> Void
    ) {
        self.bridge = bridge
        self.onCaptured = onCaptured
        self.onKnownAccountActive = onKnownAccountActive
    }

    func start(configPath: String) {
        watcher = CaptureWatcher(path: configPath) { [weak self] in
            Task { @MainActor in self?.handleFileChanged() }
        }
        watcher?.start()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func handleFileChanged() {
        Task { await reconcile() }
    }

    /// A short-lived timer, armed only while a capture is pending, so there's no perpetual
    /// polling. It starts when we first see an unknown account and cancels itself the moment that
    /// account resolves either way.
    private func armRetry() {
        retryTimer?.invalidate()
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.reconcile() }
        }
    }

    private func disarmRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
    }

    private func reconcile() async {
        guard let snapshot = try? await bridge.snapshot() else { return }
        guard let active = snapshot.active else {
            pending = nil
            disarmRetry()
            return
        }

        let knownUuids = Set(snapshot.knownAccounts.map(\.accountUuid))
        if knownUuids.contains(active.accountUuid) {
            // An ordinary switch never enters the capture path, because a switch always lands on
            // an already-managed account. This is what stops auto-capture misfiring on one.
            pending = nil
            disarmRetry()
            onKnownAccountActive(active)
            return
        }

        // Unknown account_uuid: either a fresh /login mid-flight, or one that's finished settling.
        if pending?.accountUuid != active.accountUuid {
            pending = (active.accountUuid, Date())
            armRetry()
            return
        }

        let elapsed = Date().timeIntervalSince(pending!.firstSeenAt)
        if elapsed < settleSeconds {
            return  // still mid-flow; wait for the next tick
        }
        if elapsed > maxWaitSeconds {
            pending = nil
            disarmRetry()
            return
        }

        do {
            let captured = try await bridge.addCurrent()
            pending = nil
            disarmRetry()
            onCaptured(captured)
        } catch {
            // Likely the credential hasn't landed yet (NoCredentialsError), so leave `pending`
            // set so the retry timer tries again, up to maxWaitSeconds.
        }
    }
}
