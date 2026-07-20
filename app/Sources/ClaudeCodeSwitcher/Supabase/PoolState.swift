import Combine
import CryptoKit
import Foundation

/// Drives onboarding end to end: auth → team membership → local team-key presence → ready.
/// Kept separate from `AppState` (local ccswitch-core state, Phase 1) deliberately — this file
/// is everything that's new in Phase 2, and `AppState` didn't need to change shape to make room
/// for it, exactly as planned in BUILD_PLAN.md's phase breakdown.
@MainActor
final class PoolState: ObservableObject {
    enum Step: Equatable {
        case checking
        case signedOut
        case awaitingCode(email: String)
        /// Signed in, but this identity has no team yet — show create/join.
        case needsTeamSetup
        /// A member of `team`, but this specific device has never had the team key entered —
        /// e.g. the same person signing in on a second Mac. Distinct from `needsTeamSetup`
        /// because the fix here is "paste the key," not "create or join."
        case needsTeamKey(team: Team)
        case ready(team: Team, member: Member)
    }

    @Published private(set) var step: Step = .checking
    @Published var lastError: String?
    @Published private(set) var isBusy = false

    let auth = AuthController()
    private let teamService = TeamService()
    private var cancellable: AnyCancellable?

    init() {
        // Same exactly-once rationale as AppState.init()'s call to start(): @StateObject
        // guarantees this instance is created once for the app's lifetime.
        start()
    }

    func start() {
        auth.start()
        cancellable = auth.$state
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in await self?.reconcile() }
            }
    }

    private func reconcile() async {
        switch auth.state {
        case .checking:
            step = .checking
        case .signedOut:
            step = .signedOut
        case .awaitingCode(let email):
            step = .awaitingCode(email: email)
        case .signedIn(let userId, _):
            await loadMembership(userId: userId)
        }
    }

    private func loadMembership(userId: UUID) async {
        do {
            guard let member = try await teamService.myMembership(userId: userId) else {
                step = .needsTeamSetup
                return
            }
            let team = try await teamService.team(id: member.teamId)
            if TeamKeyStore.load(teamId: team.id) != nil {
                step = .ready(team: team, member: member)
            } else {
                step = .needsTeamKey(team: team)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Actions the onboarding view calls

    func sendCode(email: String) async {
        isBusy = true
        defer { isBusy = false }
        await auth.sendCode(email: email)
        lastError = auth.lastError
    }

    func verifyCode(_ code: String, email: String) async {
        isBusy = true
        defer { isBusy = false }
        await auth.verifyCode(code, email: email)
        lastError = auth.lastError
    }

    func backToSignIn() {
        auth.cancelCodeEntry()
    }

    func createTeam(name: String) async {
        guard case .signedIn(let userId, _) = auth.state else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let team = try await teamService.createTeam(name: name)
            let key = TeamKeyStore.generate()
            try TeamKeyStore.store(key, teamId: team.id)
            await loadMembership(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// A teammate needs both the invite code (grants Supabase membership) and the team key
    /// (decrypts shared tokens) — two different secrets with two different trust boundaries,
    /// handed over together out-of-band during onboarding.
    func joinTeam(code: String, teamKeyString: String) async {
        guard case .signedIn(let userId, _) = auth.state else { return }
        guard let key = TeamKeyStore.import(teamKeyString) else {
            lastError = "That team key doesn't look right — check it was copied in full."
            return
        }
        isBusy = true
        defer { isBusy = false }
        do {
            let member = try await teamService.joinTeam(code: code)
            try TeamKeyStore.store(key, teamId: member.teamId)
            await loadMembership(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The `.needsTeamKey` recovery path: already a member, just missing the key on this device.
    func enterTeamKey(_ teamKeyString: String, team: Team) async {
        guard let key = TeamKeyStore.import(teamKeyString) else {
            lastError = "That team key doesn't look right — check it was copied in full."
            return
        }
        guard case .signedIn(let userId, _) = auth.state else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try TeamKeyStore.store(key, teamId: team.id)
            await loadMembership(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The exported team key string for display right after `createTeam` succeeds — read back
    /// from the Keychain rather than threaded through as a return value, so there is exactly one
    /// place a raw key ever gets read out (here) instead of two call paths carrying it around.
    func currentTeamKeyForSharing(team: Team) -> String? {
        guard let key = TeamKeyStore.load(teamId: team.id) else { return nil }
        return TeamKeyStore.export(key)
    }

    /// Owner-only (enforced server-side by `create_team_invite`'s `security definer` check, not
    /// just here) — generates a fresh single-use, 7-day code. This is the only place in the app
    /// that ever calls it: without this, a team could never grow past whoever created it, since
    /// `joinTeam` requires a code nothing else produces.
    func createInvite() async -> String? {
        guard case .ready(let team, let member) = step, member.role == "owner" else { return nil }
        do {
            return try await teamService.createInvite(teamId: team.id)
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func signOut() async {
        await auth.signOut()
    }
}
