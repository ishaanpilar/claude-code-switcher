import Foundation
import Supabase

/// Sign-in via a 6-digit email code rather than a magic link. Supabase's OTP email supports
/// typing the code back in regardless of what the template sends, which avoids depending on deep
/// linking for the primary path. Adding a magic link later is additive, not a rewrite.
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
    /// The current session's access token. Needed outside this class only for the attribution
    /// hook's session file, which the hook script reads to call `log_turn` as this user. Published
    /// separately rather than folded into `State` so a token refresh (same user, new token)
    /// doesn't ripple through every `Equatable` comparison of `state`.
    @Published private(set) var accessToken: String?

    private let client = SupabaseClientProvider.shared
    private var listenTask: Task<Void, Never>?

    /// Runs once per app lifetime, same rationale as `AppState.init`'s call to `start()`.
    /// `authStateChanges` emits `.initialSession` immediately, so `state` resolves out of
    /// `.checking` on the first iteration even with no prior session.
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
            break  // unused: no password auth in this app
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
            // event), so `state` isn't set here: one path for "we're signed in" instead of two
            // that could disagree.
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
