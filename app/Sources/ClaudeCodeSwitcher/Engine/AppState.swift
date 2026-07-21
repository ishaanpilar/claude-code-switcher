import Combine
import CryptoKit
import Foundation
import SwiftUI

/// One row in the panel's account list — a merge of what ccswitch-core knows locally
/// (`KnownAccount`) and what the pool knows (`PoolAccount`/`ClaimRow`), joined on
/// `anthropicAccountUuid`. Neither source alone is enough to render the list correctly: a
/// teammate's shared account the pool knows about but this Mac has never activated has no local
/// row at all, and a personal account never pushed to the pool has no `PoolAccount`.
struct DisplayAccount: Identifiable {
    let accountUuid: String
    let email: String
    let organizationUuid: String?
    let isLocallyKnown: Bool
    let poolAccount: PoolAccount?
    let usage: Usage?
    let claim: ClaimRow?
    let claimedByName: String?

    var id: String { accountUuid }
    var isActivatableHere: Bool { isLocallyKnown || poolAccount?.shareMode == .shared }
}

/// Central observable state for the panel. Phase 1 (local snapshot, add/switch/remove,
/// auto-capture) plus Phase 2 pool sync (BUILD_PLAN.md): pushing/pulling `accounts` /
/// `usage_current` / `claims`, claim-aware switching, and the claimed-by badges. The
/// poll-leader election from Phase 3 is NOT here yet — see PoolSyncService's header comment for
/// exactly what that means for usage-push volume in the meantime.
///
/// Threading rule (BUILD_PLAN.md section 7): all `@Published` mutation happens on the main
/// actor. Every method below is either already `@MainActor` (this whole class is) or hops back
/// via `await` before touching state.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activeAccount: AccountIdentity?
    @Published private(set) var knownAccounts: [KnownAccount] = []
    @Published private(set) var usageByAccount: [String: Usage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published var lastError: String?
    @Published var toast: String?

    // Pool state (empty/inert until configurePool(team:member:) runs).
    @Published private(set) var poolAccountsByUuid: [String: PoolAccount] = [:]
    @Published private(set) var claimsByAccountId: [UUID: ClaimRow] = [:]
    @Published private(set) var membersById: [UUID: Member] = [:]
    @Published private(set) var autoSwitchSettings = AutoSwitchSettings.loadFromDefaults()
    @Published private(set) var isPollLeader = false
    /// Whether the `UserPromptSubmit` turn-log hook (BUILD_PLAN.md section 8) is installed —
    /// opt-in, never assumed; reflects the actual on-disk state at launch rather than a
    /// separately-tracked preference that could drift from it.
    @Published private(set) var attributionEnabled = AttributionHookService.isInstalled()
    /// Whether this device reserves an account while it's in use — a "held by X" lease that blocks
    /// teammates from switching to it and steers auto-switch away. **Off by default**: two people
    /// can happily share one account at the same time, so nothing is claimed, blocked, or badged
    /// unless the user opts in (Settings → Team). Purely a local preference.
    @Published private(set) var reserveAccountsWhileInUse = UserDefaults.standard.bool(forKey: "com.claudecodeswitcher.reserveAccounts")

    private let bridge: CoreBridge
    private let poolSync = PoolSyncService()
    private lazy var autoCapture = AutoCaptureController(
        bridge: bridge,
        onCaptured: { [weak self] account in self?.handleCaptured(account) },
        onKnownAccountActive: { [weak self] account in self?.handleKnownAccountActive(account) }
    )
    // `onEvent` wired here rather than in `configurePool()` so quick-switch buttons work (and
    // report their outcome as a toast) even for a solo user who never sets up a pool at all.
    private lazy var autoSwitchEngine: AutoSwitchEngine = {
        let engine = AutoSwitchEngine(bridge: bridge, state: self)
        engine.onEvent = { [weak self] event in self?.handleAutoSwitchEvent(event) }
        return engine
    }()
    private lazy var pollLeaderController = PollLeaderController(bridge: bridge)
    private var pollLeaderStatusTimer: Timer?

    private var currentTeam: Team?
    private var currentMember: Member?
    private var teamKey: SymmetricKey?
    private var realtimeTasks: [Task<Void, Never>] = []
    private var heldClaimAccountId: UUID?
    private var heartbeatTimer: Timer?
    private var lastAccessToken: String?
    private var authCancellable: AnyCancellable?

    init(bridge: CoreBridge = .resolveDefault()) {
        self.bridge = bridge
        // Started here, not from a view's `.task`/`.onAppear`: `@StateObject` guarantees this
        // instance is created exactly once for the app's lifetime, which is the exactly-once
        // semantics the file watcher needs — a view-attached start could re-fire every time the
        // menu bar dropdown opens.
        start()
    }

    func start() {
        let configPath = (ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? NSHomeDirectory())
        let claudeJSON = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] != nil
            ? (configPath as NSString).appendingPathComponent(".claude.json")
            : (NSHomeDirectory() as NSString).appendingPathComponent(".claude.json")
        autoCapture.start(configPath: claudeJSON)
        Diagnostics.log("app started")
        Task { await refresh() }
    }

    func stop() {
        autoCapture.stop()
        realtimeTasks.forEach { $0.cancel() }
        heartbeatTimer?.invalidate()
        autoSwitchEngine.stop()
        pollLeaderController.stop()
        pollLeaderStatusTimer?.invalidate()
        authCancellable?.cancel()
    }

    // MARK: - Local (ccswitch-core) state

    /// One in-flight refresh at a time (BUILD_PLAN.md invariant/section 7) — a second call while
    /// one is already running is a silent no-op rather than a queued duplicate.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snap = try await bridge.snapshot()
            activeAccount = snap.active
            knownAccounts = snap.knownAccounts
            lastError = nil
            await refreshUsage()
            // Unconditional — not gated on auto-switch being enabled. Covers both a purely local
            // account's quarantine (fingerprint-based, see AutoSwitchEngine.releaseRecovered) and,
            // via refreshUsage below, a shared account's owner recovering and re-syncing it.
            await autoSwitchEngine.releaseRecovered()
            refreshAttributionSessionState()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    private func refreshUsage() async {
        for account in knownAccounts {
            guard let usage = try? await bridge.readUsage(accountUuid: account.accountUuid) else { continue }
            usageByAccount[account.accountUuid] = usage
            // v1 usage-push (see PoolSyncService's header comment on why this isn't the
            // poll-leader engine yet): whichever client actually has local credentials for an
            // account is exactly the client that can read its usage, so pushing here — rather
            // than from a separate polling loop — costs nothing extra and needs no coordination.
            if let poolAccount = poolAccountsByUuid[account.accountUuid], let member = currentMember {
                try? await poolSync.pushUsage(accountId: poolAccount.id, usage: usage, fetchedBy: member.userId)
            }
            // A successful read is proof this device's stored credential for the account
            // currently works — the only signal the owner's own device needs to know a re-login
            // actually landed (see request_reauth's header comment for why a fingerprint-diff
            // check, used for the local case, doesn't fit here: whoever *reported* it broken
            // never had this account's token to fingerprint in the first place).
            if let poolAccount = poolAccountsByUuid[account.accountUuid],
               poolAccount.status == .quarantined, poolAccount.ownerUserId == myUserId {
                await syncRecoveredOwnedAccount(account, poolAccount: poolAccount)
            }
        }
    }

    /// Clears the shared quarantine flag and, for a shared account, re-encrypts and re-pushes the
    /// now-working token so teammates can actually use it again — this is the "gets synced on my
    /// account here" half of the re-login request flow, triggered automatically the moment this
    /// device proves (via the successful read in `refreshUsage`) that re-authentication landed.
    private func syncRecoveredOwnedAccount(_ account: KnownAccount, poolAccount: PoolAccount) async {
        do {
            try await poolSync.clearAccountReauth(accountId: poolAccount.id)
            if poolAccount.shareMode == .shared, let teamKey {
                let token = try await bridge.exportToken(accountUuid: account.accountUuid)
                try await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
            }
            toast = "\(account.email) is working again — synced to the team"
            Diagnostics.log("re-auth recovered: \(account.email)")
            await refreshPool()
        } catch {
            // Best-effort — retried on the next refresh cycle if this failed transiently.
        }
    }

    /// Adds the currently logged-in account locally. When the pool is configured, `shareMode`
    /// also pushes it to the team (and, for `.shared`, uploads the encrypted token) — pass `nil`
    /// to skip the pool entirely (e.g. pool not configured yet, or the panel didn't ask).
    func addCurrentAccount(shareMode: ShareMode? = nil) async {
        do {
            let account = try await bridge.addCurrent()
            toast = "Added \(account.email)"
            if let shareMode, let team = currentTeam, let member = currentMember {
                let poolAccount = try await poolSync.pushAccount(
                    teamId: team.id, ownerUserId: member.userId, identity: account, shareMode: shareMode
                )
                if shareMode == .shared {
                    let token = try await bridge.exportToken(accountUuid: account.accountUuid)
                    if let teamKey {
                        try await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
                    }
                }
                await refreshPool()
            }
            await refresh()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Switches to a row from the merged display list — handles all three shapes: an
    /// already-local account (plain activate), a shared pool account never activated here
    /// before (claim → decrypt → import-activate), and a visibility-only pool account this
    /// device can't activate at all (surfaces an error rather than silently no-op'ing).
    /// No re-entrancy guard here used to mean a burst of rapid clicks fired overlapping async
    /// switches: each one snapshots `activeAccount` at call-start, so a second call launched
    /// before the first's trailing `refresh()` lands would capture a stale "previous account,"
    /// releasing the wrong claim (or none) and leaving multiple accounts claimed at once with no
    /// error and no visual sign anything was happening — exactly what looked like "switching does
    /// nothing." `beginSwitching()`/`endSwitching()` below is the shared mutex now guarding every
    /// switch-initiating path, not just this one — see their doc comment.
    func switchTo(_ display: DisplayAccount) async {
        guard beginSwitching() else { return }
        defer { endSwitching() }
        let previousUuid = activeAccount?.accountUuid
        let previousPoolAccountId = previousUuid.flatMap { poolAccountsByUuid[$0]?.id }
        do {
            if display.isLocallyKnown {
                try await claimIfPossible(display)
                _ = try await bridge.switchTo(accountUuid: display.accountUuid)
            } else if let poolAccount = display.poolAccount, poolAccount.shareMode == .shared {
                guard let teamKey else {
                    lastError = "This device doesn't have the team key yet — can't decrypt shared accounts."
                    return
                }
                // An existing reservation is honored no matter who's looking — reserving is only
                // ever the account owner's call to make (and only for their own account, see
                // below), but once made, everyone respects it rather than just whoever happens to
                // have the toggle on themselves.
                if let heldBy = display.claim?.heldBy, heldBy != myUserId {
                    lastError = "\(display.email) is reserved by \(display.claimedByName ?? "someone else") right now — try another account."
                    return
                }
                // Only the account's *owner* may create a reservation on it, and only if they've
                // opted in — this device never reserves an account someone else owns.
                if reserveAccountsWhileInUse, poolAccount.ownerUserId == myUserId,
                   let claim = try await poolSync.claim(accountId: poolAccount.id) {
                    heldClaimAccountId = poolAccount.id
                    startHeartbeat()
                    _ = claim
                }
                guard let tokenRow = try await poolSync.fetchTeamKeyToken(accountId: poolAccount.id) else {
                    lastError = "No shared token found for \(display.email) yet."
                    return
                }
                let plaintext = try TeamCrypto.decrypt(ciphertext: tokenRow.ciphertext, nonce: tokenRow.nonce, key: teamKey)
                _ = try await bridge.importActivate(
                    accountUuid: display.accountUuid, token: plaintext,
                    email: display.email, organizationUuid: display.organizationUuid
                )
            } else {
                lastError = "\(display.email) is visibility-only — ask its owner to switch to it, or share the token."
                return
            }
            // Release the account we just switched away from — only after the new switch has
            // actually succeeded, so a failed attempt never gives up a claim on the account the
            // user is still genuinely on. Unconditional (not toggle-gated): we only ever hold a
            // claim here if we created one, which is a no-op to release otherwise.
            if let previousPoolAccountId, previousPoolAccountId != display.poolAccount?.id {
                try? await poolSync.releaseClaim(accountId: previousPoolAccountId)
                if heldClaimAccountId == previousPoolAccountId { heldClaimAccountId = nil }
            }
            toast = "Switched — takes effect within ~30s, or restart Claude Code now"
            await logSwitchIfPooled(from: previousUuid, to: display.accountUuid, reason: "manual")
            await refresh()
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Best-effort audit row for the switch-log (`switch_log` — see `0005_attribution.sql`).
    /// Silently skipped when there's no team (nothing to audit against) or neither side of the
    /// switch is a pool account (a purely local switch between two never-pooled accounts).
    private func logSwitchIfPooled(from: String?, to: String?, reason: String) async {
        guard let team = currentTeam, let member = currentMember else { return }
        let fromId = from.flatMap { poolAccountsByUuid[$0]?.id }
        let toId = to.flatMap { poolAccountsByUuid[$0]?.id }
        guard fromId != nil || toId != nil else { return }
        try? await poolSync.logSwitch(teamId: team.id, userId: member.userId, from: fromId, to: toId, reason: reason)
    }

    /// This device's member id in the current team, or nil solo/pre-pool — exposed read-only so
    /// the panel can tell which pool accounts the signed-in user owns (only an owner may change
    /// share mode; see `setShareMode` and the `accounts_update` RLS policy it relies on).
    var myUserId: UUID? { currentMember?.userId }

    /// Upgrades push a fresh encrypted token (only possible from a device that actually holds
    /// local credentials for the account); downgrades delete the ciphertext outright rather than
    /// leaving a stale row — see `PoolSyncService.deleteToken`'s header comment. A no-op if the
    /// caller doesn't own the account or it's already in the requested mode.
    func setShareMode(_ display: DisplayAccount, to mode: ShareMode) async {
        guard let poolAccount = display.poolAccount, poolAccount.ownerUserId == myUserId, poolAccount.shareMode != mode else { return }
        do {
            try await poolSync.updateShareMode(accountId: poolAccount.id, shareMode: mode)
            if mode == .shared {
                if display.isLocallyKnown, let teamKey {
                    let token = try await bridge.exportToken(accountUuid: display.accountUuid)
                    try await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
                }
            } else {
                try await poolSync.deleteToken(accountId: poolAccount.id)
            }
            toast = "\(display.email) is now \(mode == .shared ? "shared" : "visibility-only")"
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// "Someone else's account looks broken" — flags it (visible to the whole team via the
    /// account's `status`) and records that this user asked, which fires a system notification on
    /// the owner's own device (see the `reauth_requests` Realtime subscription in
    /// `startPoolRealtime`). Available on any pool account regardless of quarantine state — the
    /// person noticing the problem is often ahead of the app's own diagnosis.
    func requestReauth(_ display: DisplayAccount) async {
        guard let poolAccount = display.poolAccount else { return }
        do {
            try await poolSync.requestReauth(accountId: poolAccount.id)
            toast = "Asked \(ownerName(of: poolAccount) ?? "the owner") to re-login \(display.email)"
            await refreshPool()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func ownerName(of poolAccount: PoolAccount) -> String? {
        membersById[poolAccount.ownerUserId]?.displayName
    }

    /// Called for locally-known accounts — which isn't the same thing as *owned*: a teammate's
    /// shared account you've activated here before is locally known too. Only ever reserves an
    /// account you actually own, and only if you've opted in; a non-owned account here is simply
    /// skipped rather than blocking the switch, since local credentials already work regardless
    /// (the claimed-by badge, if any, still reflects the owner's own reservation honestly).
    private func claimIfPossible(_ display: DisplayAccount) async throws {
        guard reserveAccountsWhileInUse, let poolAccount = display.poolAccount, poolAccount.ownerUserId == myUserId else { return }
        if let claim = try await poolSync.claim(accountId: poolAccount.id) {
            heldClaimAccountId = poolAccount.id
            startHeartbeat()
            _ = claim
        }
    }

    /// The reservation opt-in (Settings → Team). Off by default. Turning it off gives up any lease
    /// this device currently holds so nothing shows as reserved by us anymore.
    func setReserveAccountsWhileInUse(_ enabled: Bool) {
        reserveAccountsWhileInUse = enabled
        UserDefaults.standard.set(enabled, forKey: "com.claudecodeswitcher.reserveAccounts")
        if !enabled, let held = heldClaimAccountId {
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
            heldClaimAccountId = nil
            Task { try? await poolSync.releaseClaim(accountId: held); await refreshPool() }
        }
    }

    /// Adopts a claim made outside `switchTo`/`claimIfPossible` — specifically `AutoSwitchEngine`,
    /// which claims a candidate itself before activating it (see `tryActivate`). Without this, an
    /// auto-switched-to (or quick-switch-button-switched-to) account's claim would never get
    /// heartbeated here and would silently expire after 5 minutes even while genuinely active —
    /// only claims taken by clicking a row directly were being kept alive before this existed.
    func adoptClaim(accountId: UUID) {
        heldClaimAccountId = accountId
        startHeartbeat()
    }

    /// Single mutex guarding every switch-initiating path — manual row clicks (`switchTo`), the
    /// quick-switch buttons, and `AutoSwitchEngine`'s own automatic tick — so none of them can
    /// race each other. Without this, two switches in flight at once each capture a stale
    /// "previous account" snapshot and release the wrong claim (or none), which is exactly the
    /// bug that made switching look broken: rapid clicks left multiple accounts claimed
    /// simultaneously with no error and no visual feedback that anything was happening.
    func beginSwitching() -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true
        return true
    }

    func endSwitching() {
        isSwitching = false
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let accountId = self.heldClaimAccountId else { return }
                try? await self.poolSync.heartbeatClaim(accountId: accountId)
            }
        }
    }

    func remove(_ accountUuid: String) async {
        do {
            _ = try await bridge.remove(accountUuid: accountUuid)
            usageByAccount.removeValue(forKey: accountUuid)
            await refresh()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    private func handleCaptured(_ account: AccountIdentity) {
        toast = "New account captured: \(account.email)"
        let previousUuid = activeAccount?.accountUuid
        Task {
            await refresh()
            await logSwitchIfPooled(from: previousUuid, to: account.accountUuid, reason: "captured")
        }
    }

    private func handleKnownAccountActive(_ account: AccountIdentity) {
        if account.accountUuid != activeAccount?.accountUuid {
            let previousUuid = activeAccount?.accountUuid
            Task {
                await refresh()
                await logSwitchIfPooled(from: previousUuid, to: account.accountUuid, reason: "captured")
            }
        }
    }

    // MARK: - Pool (Supabase) state

    /// Called once from RootView when `PoolState.step` reaches `.ready`. Idempotent against
    /// being called again with the same team (e.g. a spurious SwiftUI re-evaluation). `auth` is
    /// `PoolState`'s `AuthController` — subscribed to here (not passed per-call) so the attribution
    /// hook's session-state file stays current on every token refresh for the app's whole
    /// lifetime, independent of whether the panel view happens to be on-screen at the time.
    func configurePool(team: Team, member: Member, auth: AuthController) {
        guard currentTeam?.id != team.id else { return }
        // Switching teams (multi-team): tear the previous team's live wiring down first so its
        // Realtime subscriptions, poll-leader lease, engines and cached rows don't leak into or
        // race the new team. A first-time setup (currentTeam == nil) skips straight past this.
        if currentTeam != nil { teardownPool() }
        currentTeam = team
        currentMember = member
        teamKey = TeamKeyStore.load(teamId: team.id)
        authCancellable = auth.$accessToken
            .sink { [weak self] token in self?.updateAuthSession(accessToken: token) }
        Task {
            await refreshPool()
            await refreshUsage()  // now that pool accounts are known, push what's already cached
        }
        startPoolRealtime()

        pollLeaderController.start(
            team: team, myUserId: member.userId, teamKey: teamKey,
            getAccounts: { [weak self] in
                guard let self else { return [] }
                return Array(self.poolAccountsByUuid.values)
            },
            onUsagePolled: { [weak self] accountUuid, usage in self?.usageByAccount[accountUuid] = usage }
        )
        pollLeaderStatusTimer?.invalidate()
        pollLeaderStatusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let leading = self.pollLeaderController.isLeader
                if leading != self.isPollLeader { self.isPollLeader = leading }
            }
        }

        autoSwitchEngine.start(settings: autoSwitchSettings, teamKey: teamKey, myUserId: member.userId, teamId: team.id)
    }

    /// Unwinds everything `configurePool` set up for the current team — used when switching to a
    /// different team, so the app can be reconfigured cleanly. Clears pool-derived caches but
    /// leaves `usageByAccount` (a later `refresh()` rebuilds local usage; stale pool entries drop
    /// out once `poolAccountsByUuid` no longer references them).
    private func teardownPool() {
        realtimeTasks.forEach { $0.cancel() }
        realtimeTasks = []
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        heldClaimAccountId = nil
        autoSwitchEngine.stop()
        pollLeaderController.stop()
        pollLeaderStatusTimer?.invalidate()
        pollLeaderStatusTimer = nil
        isPollLeader = false
        authCancellable?.cancel()
        poolAccountsByUuid = [:]
        claimsByAccountId = [:]
        membersById = [:]
        currentTeam = nil
        currentMember = nil
        teamKey = nil
    }

    // MARK: - Attribution (turn-log hook — BUILD_PLAN.md section 8)

    /// Installs/removes the `UserPromptSubmit` hook with explicit consent (called from a toggle
    /// in `TeamUsageView`, never automatically) and keeps the on-disk state matching what actually
    /// happened rather than what was requested, in case the install itself fails (e.g. no write
    /// access to `~/.claude/`).
    func setAttributionEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try AttributionHookService.install()
                attributionEnabled = true
                refreshAttributionSessionState()
            } else {
                try AttributionHookService.uninstall()
                attributionEnabled = false
            }
        } catch {
            lastError = "Couldn't \(enabled ? "enable" : "disable") turn-count attribution: \(error.localizedDescription)"
        }
    }

    private func updateAuthSession(accessToken: String?) {
        lastAccessToken = accessToken
        refreshAttributionSessionState()
    }

    /// Rewrites `~/.ccswitch/session.env` (the hook script's only input) whenever any of the four
    /// pieces of state it needs might have changed. Cheap and idempotent by design — every call
    /// site here just calls this rather than trying to diff what actually changed.
    private func refreshAttributionSessionState() {
        guard attributionEnabled else { return }
        guard let team = currentTeam, let token = lastAccessToken else {
            AttributionHookService.clearSessionState()
            return
        }
        let activeAccountId = activeAccount.flatMap { poolAccountsByUuid[$0.accountUuid]?.id }
        AttributionHookService.writeSessionState(accessToken: token, teamId: team.id, activeAccountId: activeAccountId)
    }

    // MARK: - Quick-switch (manual, distinct from the automatic engine above)

    /// One-click "switch to whichever eligible account has the most headroom right now" —
    /// reuses `AutoSwitchEngine`'s claim-aware, quarantine-aware scoring but isn't gated by the
    /// enabled toggle, threshold, hysteresis, or cooldown: the user asked for this switch
    /// directly. Works standalone too (no pool configured) across purely local accounts.
    @discardableResult
    func switchToBestAccount() async -> AutoSwitchEvent {
        guard beginSwitching() else { return .blocked(reason: "a switch is already in progress") }
        defer { endSwitching() }
        return await autoSwitchEngine.switchToBest()
    }

    /// One-click "move to the next account" in the same email-sorted order the panel renders,
    /// wrapping around. Ignores usage by design — a manual round-robin, not a usage decision.
    @discardableResult
    func rotateAccount() async -> AutoSwitchEvent {
        guard beginSwitching() else { return .blocked(reason: "a switch is already in progress") }
        defer { endSwitching() }
        return await autoSwitchEngine.rotate()
    }

    // MARK: - Auto-switch settings

    func setAutoSwitchEnabled(_ enabled: Bool) {
        autoSwitchSettings.enabled = enabled
        autoSwitchSettings.saveToDefaults()
        autoSwitchEngine.updateSettings(autoSwitchSettings)
    }

    func setAutoSwitchThreshold(_ threshold: Double) {
        autoSwitchSettings.threshold = threshold
        autoSwitchSettings.saveToDefaults()
        autoSwitchEngine.updateSettings(autoSwitchSettings)
    }

    /// General setter for the Settings window's auto-switch tab, where cooldown / hysteresis /
    /// interval are also exposed. Persists and hands the whole struct to the engine (which
    /// re-arms its loop if `enabled`/`intervalSeconds` changed) in one pass, so the panel's quick
    /// toggle and the full settings tab can't disagree about what's active.
    func updateAutoSwitchSettings(_ newSettings: AutoSwitchSettings) {
        autoSwitchSettings = newSettings
        autoSwitchSettings.saveToDefaults()
        autoSwitchEngine.updateSettings(autoSwitchSettings)
    }

    // MARK: - Account management (Settings → My Accounts)

    /// Whether the signed-in user owns this account (added it) and so may change its sharing,
    /// remove it, or transfer it — everywhere the Settings UI needs to gate an owner-only control.
    func isOwner(of account: DisplayAccount) -> Bool {
        account.poolAccount?.ownerUserId == myUserId
    }

    /// Forgets an account from the team pool entirely (owner-only) — distinct from `remove`, which
    /// only drops the *local* copy on this Mac. Also drops the local copy if present, so an
    /// account you both own and hold locally disappears from both places in one action.
    func removeFromPool(_ account: DisplayAccount) async {
        guard let poolAccount = account.poolAccount else { return }
        do {
            try await poolSync.removeAccountFromPool(accountId: poolAccount.id)
            if account.isLocallyKnown {
                _ = try? await bridge.remove(accountUuid: account.accountUuid)
            }
            usageByAccount.removeValue(forKey: account.accountUuid)
            toast = "\(account.email) removed from the team pool"
            await refresh()
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Hands an account you own to another team member (the "wrong person added it" fix). After
    /// this you lose owner controls over it and they gain them — enforced server-side too, so a
    /// stale client can't keep editing it.
    func transferOwnership(_ account: DisplayAccount, to newOwner: UUID) async {
        guard let poolAccount = account.poolAccount else { return }
        do {
            try await poolSync.transferOwnership(accountId: poolAccount.id, to: newOwner)
            let name = membersById[newOwner]?.displayName ?? "teammate"
            toast = "\(account.email) is now owned by \(name)"
            await refreshPool()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - General settings

    var launchAtLoginEnabled: Bool { LaunchAtLogin.isEnabled }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LaunchAtLogin.set(enabled)
            objectWillChange.send()  // isEnabled is read live from SMAppService, not @Published
        } catch {
            lastError = "Couldn't \(enabled ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
    }

    var notificationsEnabled: Bool { NotificationService.isEnabled }

    func setNotificationsEnabled(_ enabled: Bool) {
        NotificationService.isEnabled = enabled
        objectWillChange.send()  // stored in UserDefaults via NotificationService, not @Published
    }

    private func handleAutoSwitchEvent(_ event: AutoSwitchEvent) {
        switch event {
        case .switched(let email, let trigger):
            let isManual = trigger.hasPrefix("manual")
            toast = isManual ? "Switched to \(email)" : "Auto-switched to \(email) (\(trigger))"
            Diagnostics.log("switch: \(email) (\(trigger))")
            if !isManual {
                NotificationService.post(title: "Switched accounts", body: "Now using \(email) (\(trigger))")
            }
        case .quarantined(let email, let reason):
            toast = "\(email) quarantined (\(reason)) — re-login to recover it"
            Diagnostics.log("quarantine: \(email) (\(reason))")
            NotificationService.post(title: "Account quarantined", body: "\(email) needs re-login (\(reason))")
        case .recovered(let email):
            toast = "\(email) recovered from quarantine — eligible again"
            Diagnostics.log("recovered: \(email)")
        case .allExhausted:
            toast = "All accounts near their limit — nothing to switch to"
            Diagnostics.log("all accounts exhausted")
            NotificationService.post(title: "All accounts near their limit", body: "No account has headroom to switch to right now")
        case .error(let message):
            lastError = message
            Diagnostics.log("auto-switch error: \(message)")
        case .blocked:
            break  // routine — not worth surfacing as a toast every tick
        }
    }

    /// Internal (not private): AutoSwitchEngine calls this after it performs a switch of its own,
    /// so claimed-by badges and cached usage reflect the new state without waiting for the next
    /// Realtime event to round-trip.
    func refreshPool() async {
        guard let team = currentTeam else { return }
        do {
            let accounts = try await poolSync.fetchAccounts(teamId: team.id)
            poolAccountsByUuid = Dictionary(uniqueKeysWithValues: accounts.map { ($0.anthropicAccountUuid, $0) })

            let ids = accounts.map(\.id)
            let claims = try await poolSync.fetchClaims(teamAccountIds: ids)
            claimsByAccountId = Dictionary(uniqueKeysWithValues: claims.compactMap { claim in
                claim.heldBy != nil ? (claim.accountId, claim) : nil
            })

            let usageRows = try await poolSync.fetchUsage(teamAccountIds: ids)
            for row in usageRows {
                guard let account = accounts.first(where: { $0.id == row.accountId }) else { continue }
                if usageByAccount[account.anthropicAccountUuid] == nil {
                    usageByAccount[account.anthropicAccountUuid] = Usage(
                        fiveHour: row.fiveHourPct.map { UsageWindow(pct: $0, resetsAt: row.fiveHourResetsAt) },
                        sevenDay: row.sevenDayPct.map { UsageWindow(pct: $0, resetsAt: row.sevenDayResetsAt) },
                        scoped: row.scoped?.map { ScopedUsage(name: $0.name, pct: $0.pct, resetsAt: $0.resetsAt) }
                    )
                }
            }

            let members = try await poolSync.fetchMembers(teamId: team.id)
            membersById = Dictionary(uniqueKeysWithValues: members.map { ($0.userId, $0) })
            refreshAttributionSessionState()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func startPoolRealtime() {
        realtimeTasks.forEach { $0.cancel() }
        realtimeTasks = [
            Task { [poolSync] in
                await poolSync.subscribeChanges(table: "accounts", as: PoolAccount.self) { [weak self] account in
                    Task { @MainActor in self?.poolAccountsByUuid[account.anthropicAccountUuid] = account }
                }
            },
            Task { [poolSync] in
                await poolSync.subscribeChanges(table: "usage_current", as: UsageCurrentRow.self) { [weak self] row in
                    Task { @MainActor in
                        guard let self, let account = self.poolAccountsByUuid.values.first(where: { $0.id == row.accountId }) else { return }
                        self.usageByAccount[account.anthropicAccountUuid] = Usage(
                            fiveHour: row.fiveHourPct.map { UsageWindow(pct: $0, resetsAt: row.fiveHourResetsAt) },
                            sevenDay: row.sevenDayPct.map { UsageWindow(pct: $0, resetsAt: row.sevenDayResetsAt) },
                            scoped: row.scoped?.map { ScopedUsage(name: $0.name, pct: $0.pct, resetsAt: $0.resetsAt) }
                        )
                    }
                }
            },
            Task { [poolSync] in
                await poolSync.subscribeChanges(table: "claims", as: ClaimRow.self) { [weak self] claim in
                    Task { @MainActor in
                        if claim.heldBy != nil {
                            self?.claimsByAccountId[claim.accountId] = claim
                        } else {
                            self?.claimsByAccountId.removeValue(forKey: claim.accountId)
                        }
                    }
                }
            },
            Task { [poolSync] in
                await poolSync.subscribeChanges(table: "reauth_requests", as: ReauthRequest.self) { [weak self] request in
                    Task { @MainActor in self?.handleReauthRequest(request) }
                }
            },
        ]
    }

    /// Fires the actual "Ishaan Pilar is requesting re-login…" system notification — but only on
    /// the device belonging to the account's *owner*; every other team member's client also
    /// receives this same Realtime insert (it's team-wide, not targeted), so the owner check here
    /// is what keeps it from popping up on everyone's screen.
    private func handleReauthRequest(_ request: ReauthRequest) {
        guard let poolAccount = poolAccountsByUuid.values.first(where: { $0.id == request.accountId }),
              poolAccount.ownerUserId == myUserId
        else { return }
        let requesterName = membersById[request.requestedBy]?.displayName ?? "A teammate"
        toast = "\(requesterName) is requesting re-login on \(poolAccount.email)"
        Diagnostics.log("reauth requested by \(requesterName) for \(poolAccount.email)")
        NotificationService.post(
            title: "Re-login requested",
            body: "\(requesterName) is requesting re-login on this Claude account (\(poolAccount.email))"
        )
    }

    /// The merged list the panel actually renders — see `DisplayAccount`'s header comment for
    /// why neither source alone is sufficient.
    var displayAccounts: [DisplayAccount] {
        var rows: [String: DisplayAccount] = [:]
        for account in knownAccounts {
            rows[account.accountUuid] = makeDisplayAccount(
                accountUuid: account.accountUuid, email: account.email, organizationUuid: account.organizationUuid,
                isLocallyKnown: true
            )
        }
        for pool in poolAccountsByUuid.values where rows[pool.anthropicAccountUuid] == nil {
            rows[pool.anthropicAccountUuid] = makeDisplayAccount(
                accountUuid: pool.anthropicAccountUuid, email: pool.email, organizationUuid: pool.organizationUuid,
                isLocallyKnown: false
            )
        }
        return rows.values.sorted { $0.email < $1.email }
    }

    private func makeDisplayAccount(accountUuid: String, email: String, organizationUuid: String?, isLocallyKnown: Bool) -> DisplayAccount {
        let poolAccount = poolAccountsByUuid[accountUuid]
        let claim = poolAccount.flatMap { claimsByAccountId[$0.id] }
        // Always reflects real claim state, regardless of the viewer's own reservation preference
        // — a claim only ever exists because the account's *owner* reserved it (see switchTo /
        // claimIfPossible), so showing it honestly is what makes that reservation mean anything.
        let claimedByName = claim?.heldBy.flatMap { membersById[$0]?.displayName }
        return DisplayAccount(
            accountUuid: accountUuid, email: email, organizationUuid: organizationUuid,
            isLocallyKnown: isLocallyKnown, poolAccount: poolAccount,
            usage: usageByAccount[accountUuid], claim: claim, claimedByName: claimedByName
        )
    }

    /// Menu bar title text: active account's email + tightest usage window, or a neutral
    /// placeholder when nobody's logged in yet. Kept here (not in the view) so both the
    /// `MenuBarExtra` label and any future notification text render it identically.
    var titleText: String {
        guard let active = activeAccount else { return "Not logged in" }
        if let pct = usageByAccount[active.accountUuid]?.tightestPct {
            return "\(active.email)  \(Int(pct))%"
        }
        return active.email
    }
}
