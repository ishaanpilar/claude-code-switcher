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
        /// Offline / local-only: the panel runs against just this Mac's own captured accounts, no
        /// sign-in, no cloud, no sharing. A deliberate mode for someone who juggles several of
        /// their own accounts and doesn't want a pool at all.
        case localOnly
    }

    @Published private(set) var step: Step = .checking
    @Published var lastError: String?
    @Published private(set) var isBusy = false

    /// All teams this identity belongs to (multi-team). The active one is `activeTeamId`; the rest
    /// are switch targets shown in Settings → Team.
    @Published private(set) var memberships: [Member] = []
    @Published private(set) var teamsById: [UUID: Team] = [:]
    @Published private(set) var activeTeamId: UUID?

    let auth = AuthController()
    private let teamService = TeamService()
    private var cancellable: AnyCancellable?

    private static let localOnlyKey = "com.claudecodeswitcher.localOnlyMode"
    private static let activeTeamKey = "com.claudecodeswitcher.activeTeamId"

    /// The teams the user can switch between (for the Settings picker), active one first.
    var availableTeams: [Team] {
        memberships.compactMap { teamsById[$0.teamId] }.sorted { $0.name < $1.name }
    }

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

    private var isLocalOnly: Bool {
        UserDefaults.standard.bool(forKey: Self.localOnlyKey)
    }

    private func reconcile() async {
        // Local-only wins over auth state entirely — someone who chose offline mode shouldn't be
        // dragged back to a sign-in screen just because there's no Supabase session.
        if isLocalOnly {
            step = .localOnly
            return
        }
        switch auth.state {
        case .checking:
            step = .checking
        case .signedOut:
            memberships = []
            teamsById = [:]
            activeTeamId = nil
            step = .signedOut
        case .awaitingCode(let email):
            step = .awaitingCode(email: email)
        case .signedIn(let userId, _):
            await loadMembership(userId: userId)
        }
    }

    /// Loads every team the user is in, resolves the active one (last-used, else the first), and
    /// decides the step from the active team's local team-key presence. Multi-team: `memberships`
    /// / `teamsById` are what the Settings switcher reads; the `.ready` step only ever carries the
    /// *active* team.
    private func loadMembership(userId: UUID) async {
        do {
            let members = try await teamService.myMemberships(userId: userId)
            memberships = members
            guard !members.isEmpty else {
                teamsById = [:]
                activeTeamId = nil
                step = .needsTeamSetup
                return
            }
            let teams = try await teamService.teams(ids: members.map(\.teamId))
            teamsById = Dictionary(uniqueKeysWithValues: teams.map { ($0.id, $0) })

            let active = resolveActiveTeamId(among: members)
            activeTeamId = active
            UserDefaults.standard.set(active.uuidString, forKey: Self.activeTeamKey)

            guard let member = members.first(where: { $0.teamId == active }),
                  let team = teamsById[active] else {
                step = .needsTeamSetup
                return
            }
            step = TeamKeyStore.load(teamId: team.id) != nil
                ? .ready(team: team, member: member)
                : .needsTeamKey(team: team)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func resolveActiveTeamId(among members: [Member]) -> UUID {
        if let saved = UserDefaults.standard.string(forKey: Self.activeTeamKey),
           let savedId = UUID(uuidString: saved),
           members.contains(where: { $0.teamId == savedId }) {
            return savedId
        }
        return members.sorted { ($0.joinedAt) < ($1.joinedAt) }.first!.teamId
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
            // Make the just-created team the active one, whether this is the first team or an
            // additional one created from Settings.
            UserDefaults.standard.set(team.id.uuidString, forKey: Self.activeTeamKey)
            await loadMembership(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Local-only (offline) mode

    /// Enter offline mode: the panel runs against just this Mac's captured accounts, no cloud.
    /// Persisted so it survives relaunch; the user leaves it explicitly via `exitLocalOnly`.
    func enableLocalOnly() {
        UserDefaults.standard.set(true, forKey: Self.localOnlyKey)
        step = .localOnly
    }

    /// Leave offline mode and go (back) to the sign-in / team flow.
    func exitLocalOnly() {
        UserDefaults.standard.set(false, forKey: Self.localOnlyKey)
        Task { await reconcile() }
    }

    var isLocalOnlyMode: Bool { isLocalOnly }

    // MARK: - Multi-team switching

    /// Switch which team the app is currently pooling with. Only lands on `.ready` if this device
    /// already has that team's key; otherwise routes to the paste-the-key recovery step. Persisted
    /// so the choice sticks across relaunches. `AppState` reconfigures off the resulting `.ready`.
    func switchActiveTeam(to teamId: UUID) {
        guard teamId != activeTeamId, memberships.contains(where: { $0.teamId == teamId }) else { return }
        UserDefaults.standard.set(teamId.uuidString, forKey: Self.activeTeamKey)
        activeTeamId = teamId
        guard let member = memberships.first(where: { $0.teamId == teamId }),
              let team = teamsById[teamId] else { return }
        step = TeamKeyStore.load(teamId: teamId) != nil
            ? .ready(team: team, member: member)
            : .needsTeamKey(team: team)
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
            UserDefaults.standard.set(member.teamId.uuidString, forKey: Self.activeTeamKey)
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

    /// Leave the current team (Settings → Team). The RPC blocks the team owner from leaving while
    /// others remain — that error is surfaced here rather than silently swallowed, since the user
    /// needs to know why nothing happened. On success onboarding re-derives (membership comes back
    /// nil → back to `needsTeamSetup`).
    func leaveTeam() async {
        guard case .signedIn(let userId, _) = auth.state else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await teamService.leaveTeam()
            await loadMembership(userId: userId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func signOut() async {
        await auth.signOut()
    }
}
