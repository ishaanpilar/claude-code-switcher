import Foundation
import Supabase

/// Sign-in via a 6-digit email code rather than a magic-link deep link. A menu bar app has no
/// registered URL scheme / web redirect target yet, so a clickable email link would need
/// `CFBundleURLTypes` + `onOpenURL` plumbing this app doesn't have; Supabase's OTP email supports
/// typing the code back in regardless of which the email template sends, so this sidesteps that
/// entirely for v1. Revisit if a magic-link deep link is wanted later — it's an additive change,
/// not a rewrite of this flow.
@MainActor
final class AuthController: ObservableObject {
    enum State: Equatable {
        case checking
        case signedOut
        case awaitingCode(email: String)
        case signedIn(userId: UUID, email: String?)
    }

    @Published private(set) var state: State = .checking
    @Published var lastError: String?
    /// The current session's access token — only needed outside this class for the attribution
    /// hook's local session-state file (`AttributionHookService`), which the hook script reads to
    /// call the `log_turn` RPC as this user. Kept as its own published field rather than folded
    /// into `State` so a token refresh (same user, new token) doesn't ripple through every
    /// `Equatable` comparison of `state` elsewhere in the app.
    @Published private(set) var accessToken: String?

    private let client = SupabaseClientProvider.shared
    private var listenTask: Task<Void, Never>?

    var currentUserId: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    /// `@StateObject`-lifetime start, same rationale as `AppState.init`'s call to `start()` — this
    /// must run exactly once for the app's lifetime, and `authStateChanges` always emits an
    /// `.initialSession` immediately so `state` resolves out of `.checking` on the very first
    /// iteration even with no prior session.
    func start() {
        listenTask?.cancel()
        listenTask = Task { [weak self] in
            guard let self else { return }
            for await (event, session) in client.auth.authStateChanges {
                self.handle(event: event, session: session)
            }
        }
    }

    private func handle(event: AuthChangeEvent, session: Session?) {
        switch event {
        case .initialSession, .signedIn, .tokenRefreshed, .userUpdated, .mfaChallengeVerified:
            if let session {
                state = .signedIn(userId: session.user.id, email: session.user.email)
                accessToken = session.accessToken
            } else {
                state = .signedOut
                accessToken = nil
            }
        case .signedOut, .userDeleted:
            state = .signedOut
            accessToken = nil
        case .passwordRecovery:
            break  // not used — no password auth in this app
        }
    }

    func sendCode(email: String) async {
        lastError = nil
        do {
            try await client.auth.signInWithOTP(email: email, shouldCreateUser: true)
            state = .awaitingCode(email: email)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func verifyCode(_ code: String, email: String) async {
        lastError = nil
        do {
            // The resulting session arrives via the authStateChanges listener (a `.signedIn`
            // event), so `state` doesn't need to be set here directly — one path for "we're
            // signed in" instead of two that could disagree.
            try await client.auth.verifyOTP(email: email, token: code, type: .email)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func cancelCodeEntry() {
        state = .signedOut
        lastError = nil
    }

    func signOut() async {
        try? await client.auth.signOut()
    }
}
