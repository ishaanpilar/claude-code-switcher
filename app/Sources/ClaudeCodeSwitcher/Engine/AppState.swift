import Combine
import CryptoKit
import Foundation
import SwiftUI

/// One row in the panel's account list: a merge of what ccswitch-core knows locally
/// (`KnownAccount`) and what the pool knows (`PoolAccount`/`ClaimRow`), joined on
/// `anthropicAccountUuid`. Neither source alone is enough. A teammate's shared account this Mac
/// has never activated has no local row, and a personal account never pushed to the pool has no
/// `PoolAccount`.
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

/// Central observable state for the panel: the local snapshot (add/switch/remove, auto-capture)
/// and pool sync (`accounts` / `usage_current` / `claims`, claim-aware switching, claimed-by
/// badges). Poll-leader election lives in `PollLeaderController`, wired up in `configurePool`.
///
/// Threading rule: all `@Published` mutation happens on the main actor. Every method here is
/// either already `@MainActor` (this whole class is) or hops back via `await` first.
@MainActor
final class AppState: ObservableObject {
    @Published private(set) var activeAccount: AccountIdentity?
    @Published private(set) var knownAccounts: [KnownAccount] = []
    @Published private(set) var usageByAccount: [String: Usage] = [:]
    @Published private(set) var isRefreshing = false
    @Published private(set) var isSwitching = false
    @Published var lastError: String?
    /// Transient status line under the panel. Clears itself after `toastDuration` so a message
    /// from ten minutes ago can't sit there looking like the result of what you just did.
    @Published var toast: String? {
        didSet {
            guard toast != nil else { return }
            toastClearTask?.cancel()
            toastClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.toastDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.toast = nil
            }
        }
    }
    private static let toastDuration: TimeInterval = 6
    private var toastClearTask: Task<Void, Never>?

    // Pool state (empty/inert until configurePool(team:member:) runs).
    @Published private(set) var poolAccountsByUuid: [String: PoolAccount] = [:]
    @Published private(set) var claimsByAccountId: [UUID: ClaimRow] = [:]
    @Published private(set) var membersById: [UUID: Member] = [:]
    @Published private(set) var autoSwitchSettings = AutoSwitchSettings.loadFromDefaults()
    @Published private(set) var isPollLeader = false
    /// Whether the `UserPromptSubmit` turn-log hook is installed. Opt-in, never assumed; reads
    /// actual on-disk state rather than a preference that could drift from it.
    @Published private(set) var attributionEnabled = AttributionHookService.isInstalled()
    /// Whether this device reserves an account while in use: a "held by X" lease that blocks
    /// teammates from switching to it and steers auto-switch away. Off by default, since two
    /// people can share one account at the same time. Local preference (Settings → Team).
    @Published private(set) var reserveAccountsWhileInUse = UserDefaults.standard.bool(forKey: "com.claudecodeswitcher.reserveAccounts")

    private let bridge: CoreBridge
    private let poolSync = PoolSyncService()
    private lazy var autoCapture = AutoCaptureController(
        bridge: bridge,
        onCaptured: { [weak self] account in self?.handleCaptured(account) },
        onKnownAccountActive: { [weak self] account in self?.handleKnownAccountActive(account) }
    )
    // `onEvent` wired here rather than in `configurePool()` so quick-switch buttons work, and
    // report their outcome, even for a solo user who never sets up a pool.
    private lazy var autoSwitchEngine: AutoSwitchEngine = {
        let engine = AutoSwitchEngine(bridge: bridge, state: self)
        engine.onEvent = { [weak self] event in self?.handleAutoSwitchEvent(event) }
        return engine
    }()
    private lazy var pollLeaderController = PollLeaderController(bridge: bridge)
    private var pollLeaderStatusTimer: Timer?
    private var claimExpiryTimer: Timer?

    private var currentTeam: Team?
    private var currentMember: Member?
    private var teamKey: SymmetricKey?
    private var realtimeTasks: [Task<Void, Never>] = []
    private var heldClaimAccountId: UUID?
    private var heartbeatTimer: Timer?
    private var lastAccessToken: String?
    private var authCancellable: AnyCancellable?

    /// The one live instance, so `AppDelegate` can hand back a reservation on quit. `@StateObject`
    /// guarantees exactly one `AppState` per app lifetime (see `init`), so this refers to *the*
    /// app state rather than acting as a general service locator.
    private(set) static weak var shared: AppState?

    init(bridge: CoreBridge = .resolveDefault()) {
        self.bridge = bridge
        Self.shared = self
        // Started here, not from a view's `.task`/`.onAppear`: `@StateObject` creates this
        // instance exactly once per app lifetime, which is what the file watcher needs. A
        // view-attached start would re-fire every time the menu bar dropdown opens.
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
        claimExpiryTimer?.invalidate()
        authCancellable?.cancel()
        toastClearTask?.cancel()
    }

    /// Whether quitting right now would strand a reservation on the server.
    var holdsReleasableClaim: Bool { heldClaimAccountId != nil }

    /// Hands back the reservation this device holds, on the way out. Nothing used to do this:
    /// `stop()` had no callers at all, so quitting left `held_by` set on the row with no heartbeat
    /// behind it. Teammates then saw "held by you" on an account nobody was using until the
    /// server-side reaper got to it, and if pg_cron isn't running on the project, indefinitely.
    ///
    /// Bounded by `timeout` because this runs inside `applicationShouldTerminate`: a slow or dead
    /// network must delay quitting by a beat, never block it. Missing the release is survivable
    /// now that a lapsed lease is ignored client-side anyway (see `ClaimRow.isLive`); this just
    /// frees the account immediately rather than five minutes later.
    func releaseHeldClaimBeforeQuit(timeout: TimeInterval = 2) async {
        guard let accountId = heldClaimAccountId else { return }
        heldClaimAccountId = nil
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [poolSync] in try? await poolSync.releaseClaim(accountId: accountId) }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000)) }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - Local (ccswitch-core) state

    /// One in-flight refresh at a time. A second call while one is running is a silent no-op,
    /// not a queued duplicate.
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
            // Unconditional, not gated on auto-switch being enabled. Covers a purely local
            // account's quarantine (fingerprint-based, see AutoSwitchEngine.releaseRecovered) and,
            // via refreshUsage above, a shared account's owner recovering and re-syncing it.
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
            // Whichever client holds local credentials for an account is exactly the client that
            // can read its usage, so publishing here costs nothing extra and needs no
            // coordination. `PollLeaderController` covers the accounts nobody is driving.
            if let poolAccount = poolAccountsByUuid[account.accountUuid], let member = currentMember {
                try? await poolSync.pushUsage(accountId: poolAccount.id, usage: usage, fetchedBy: member.userId)
            }
            // A successful read proves this device's stored credential works, which is the signal
            // the owner's device needs to know a re-login landed. A fingerprint diff (used for the
            // local case) can't work here: whoever reported it broken never held the token.
            if let poolAccount = poolAccountsByUuid[account.accountUuid],
               poolAccount.status == .quarantined, poolAccount.ownerUserId == myUserId {
                await syncRecoveredOwnedAccount(account, poolAccount: poolAccount)
            }
        }
    }

    /// Clears the shared quarantine flag and, for a shared account, re-encrypts and re-pushes the
    /// now-working token so teammates can use it again. Triggered automatically the moment the
    /// successful read in `refreshUsage` proves re-authentication landed.
    private func syncRecoveredOwnedAccount(_ account: KnownAccount, poolAccount: PoolAccount) async {
        do {
            try await poolSync.clearAccountReauth(accountId: poolAccount.id)
            if poolAccount.shareMode == .shared, let teamKey {
                let token = try await bridge.exportToken(accountUuid: account.accountUuid)
                try await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
            }
            toast = "\(account.email) is working again. Synced to the team."
            Diagnostics.log("re-auth recovered: \(account.email)")
            await refreshPool()
        } catch {
            // Best-effort: retried on the next refresh cycle if this failed transiently.
        }
    }

    /// Adds the currently logged-in account locally. When the pool is configured, `shareMode`
    /// also pushes it to the team, and for `.shared` uploads the encrypted token. Pass `nil` to
    /// skip the pool entirely (pool not configured, or the panel didn't ask).
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

    /// Switches to a row from the merged display list. Three shapes: an already-local account
    /// (plain activate), a shared pool account never activated here (claim, decrypt,
    /// import-activate), and a visibility-only account this device can't activate (surfaces an
    /// error rather than silently no-op'ing).
    ///
    /// Guarded by `beginSwitching()`/`endSwitching()`, the mutex shared with the quick-switch
    /// buttons and the automatic engine. Without it, overlapping switches each snapshot
    /// `activeAccount` at call-start, so one launched before another's trailing `refresh()` lands
    /// releases the wrong claim and leaves several accounts claimed at once.
    func switchTo(_ display: DisplayAccount) async {
        guard beginSwitching() else { return }
        defer { endSwitching() }
        let previousUuid = activeAccount?.accountUuid
        let previousPoolAccountId = previousUuid.flatMap { poolAccountsByUuid[$0]?.id }
        // Set once a reservation has been taken for the account being switched *to*, so every
        // early return below can hand it back. Without this, a switch that claimed the account and
        // then failed (no token row, wrong team key, activate error) left the account reserved by
        // this device with nothing holding it, blocking teammates until the 5-minute lease lapsed.
        var claimedTarget: UUID?
        func releaseClaimedTargetOnFailure() async {
            guard let claimedTarget else { return }
            try? await poolSync.releaseClaim(accountId: claimedTarget)
            if heldClaimAccountId == claimedTarget {
                heldClaimAccountId = nil
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
            }
        }
        // A live reservation blocks every route to the account, not just the shared-pool one. This
        // check used to sit inside the `else if` branch below, which only runs for an account this
        // Mac has *never* activated. Any account you had used before took the `isLocallyKnown`
        // branch instead and skipped the check entirely, so a row could show "held by <teammate>"
        // and still switch on click. The auto-switch engine filtered claimed accounts out all
        // along, and Settings promises reserving "blocks others", so the manual path was the odd
        // one out. `display.claim` is nil for a lapsed lease (see ClaimRow.isLive), so a stale
        // reservation can't lock anyone out of their own account.
        if let heldBy = display.claim?.heldBy, heldBy != myUserId {
            lastError = "\(display.email) is reserved by \(display.claimedByName ?? "someone else"). Try another account."
            return
        }
        do {
            if display.isLocallyKnown {
                claimedTarget = try await claimIfPossible(display)
                do {
                    _ = try await bridge.switchTo(accountUuid: display.accountUuid)
                } catch {
                    await releaseClaimedTargetOnFailure()
                    throw error
                }
            } else if let poolAccount = display.poolAccount, poolAccount.shareMode == .shared {
                guard let teamKey else {
                    lastError = "This device doesn't have the team key yet, so it can't decrypt shared accounts."
                    return
                }
                // Only the account's owner may reserve it, and only if they've opted in. This
                // device never reserves an account someone else owns.
                if reserveAccountsWhileInUse, poolAccount.ownerUserId == myUserId,
                   (try await poolSync.claim(accountId: poolAccount.id)) != nil {
                    claimedTarget = poolAccount.id
                    heldClaimAccountId = poolAccount.id
                    startHeartbeat()
                }
                guard let tokenRow = try await poolSync.fetchTeamKeyToken(accountId: poolAccount.id) else {
                    await releaseClaimedTargetOnFailure()
                    lastError = "No shared token found for \(display.email) yet."
                    return
                }
                do {
                    let plaintext = try TeamCrypto.decrypt(ciphertext: tokenRow.ciphertext, nonce: tokenRow.nonce, key: teamKey)
                    _ = try await bridge.importActivate(
                        accountUuid: display.accountUuid, token: plaintext,
                        email: display.email, organizationUuid: display.organizationUuid
                    )
                } catch {
                    await releaseClaimedTargetOnFailure()
                    throw error
                }
            } else {
                lastError = "\(display.email) is visibility-only. Ask its owner to switch to it, or to share the token."
                return
            }
            // Release the account we just switched away from, only after the new switch actually
            // succeeded, so a failed attempt never gives up a claim on the account the user is
            // still on. Unconditional: releasing a claim we never took is a no-op.
            if let previousPoolAccountId, previousPoolAccountId != display.poolAccount?.id {
                try? await poolSync.releaseClaim(accountId: previousPoolAccountId)
                if heldClaimAccountId == previousPoolAccountId { heldClaimAccountId = nil }
            }
            toast = "Switched. Takes effect within 30s, or restart Claude Code now."
            await logSwitchIfPooled(from: previousUuid, to: display.accountUuid, reason: "manual")
            await refresh()
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Best-effort audit row for `switch_log`. Skipped when there's no team to audit against, or
    /// when neither side of the switch is a pool account.
    private func logSwitchIfPooled(from: String?, to: String?, reason: String) async {
        guard let team = currentTeam, let member = currentMember else { return }
        let fromId = from.flatMap { poolAccountsByUuid[$0]?.id }
        let toId = to.flatMap { poolAccountsByUuid[$0]?.id }
        guard fromId != nil || toId != nil else { return }
        try? await poolSync.logSwitch(teamId: team.id, userId: member.userId, from: fromId, to: toId, reason: reason)
    }

    /// This device's member id in the current team, or nil when solo. Read-only so the panel can
    /// tell which pool accounts the signed-in user owns; only an owner may change share mode.
    var myUserId: UUID? { currentMember?.userId }

    /// Promotes an account this Mac already holds into the team pool.
    ///
    /// The add dialog offers shared / visibility-only / local-only once, at capture time, and
    /// choosing local-only used to be permanent: `setShareMode` below requires a pool row, which a
    /// local-only account by definition doesn't have, and every context-menu branch was gated on
    /// `poolAccount != nil`, so the menu came up empty. The only escape was to switch to the
    /// account and run "Add current account" again, which works only for the active account and is
    /// findable by accident at best.
    func addToPool(_ display: DisplayAccount, shareMode: ShareMode) async {
        guard display.poolAccount == nil, display.isLocallyKnown,
              let team = currentTeam, let member = currentMember
        else { return }
        lastError = nil
        do {
            let identity = AccountIdentity(
                accountUuid: display.accountUuid,
                email: display.email,
                organizationUuid: display.organizationUuid
            )
            let poolAccount = try await poolSync.pushAccount(
                teamId: team.id, ownerUserId: member.userId, identity: identity, shareMode: shareMode
            )
            if shareMode == .shared, let teamKey {
                let token = try await bridge.exportToken(accountUuid: display.accountUuid)
                try await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
            }
            toast = "\(display.email) is now \(shareMode == .shared ? "shared with the team" : "visible to the team")"
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Upgrades push a fresh encrypted token, which is only possible from a device holding local
    /// credentials. Downgrades delete the ciphertext rather than leaving a stale row. A no-op if
    /// the caller doesn't own the account or it's already in the requested mode.
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

    /// "Someone else's account looks broken". Flags it team-wide via the account's `status` and
    /// records who asked, which fires a notification on the owner's device (see the
    /// `reauth_requests` Realtime subscription). Available on any pool account regardless of
    /// quarantine state, since the person noticing is often ahead of the app's own diagnosis.
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

    /// Called for locally-known accounts, which is not the same as owned: a teammate's shared
    /// account you've activated here before is locally known too. Only ever reserves an account
    /// you own, and only if you've opted in. A non-owned account is skipped rather than blocking
    /// the switch, since local credentials work regardless.
    ///
    /// Returns the pool account id if a reservation was actually taken, so the caller can hand it
    /// back should the switch itself then fail.
    @discardableResult
    private func claimIfPossible(_ display: DisplayAccount) async throws -> UUID? {
        guard reserveAccountsWhileInUse, let poolAccount = display.poolAccount, poolAccount.ownerUserId == myUserId else { return nil }
        guard try await poolSync.claim(accountId: poolAccount.id) != nil else { return nil }
        heldClaimAccountId = poolAccount.id
        startHeartbeat()
        return poolAccount.id
    }

    /// The reservation opt-in (Settings → Team). Off by default. Turning it off gives up any lease
    /// this device holds, so nothing shows as reserved by us anymore.
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

    /// Adopts a claim made outside `switchTo`/`claimIfPossible`, specifically by
    /// `AutoSwitchEngine`, which claims a candidate itself before activating it. Without this, an
    /// auto-switched-to account's claim would never be heartbeated and would expire after 5
    /// minutes while genuinely active.
    func adoptClaim(accountId: UUID) {
        heldClaimAccountId = accountId
        startHeartbeat()
    }

    /// Single mutex guarding every switch-initiating path: manual row clicks, the quick-switch
    /// buttons, and `AutoSwitchEngine`'s automatic tick. Without it, two switches in flight each
    /// capture a stale "previous account" snapshot and release the wrong claim.
    func beginSwitching() -> Bool {
        guard !isSwitching else { return false }
        isSwitching = true
        return true
    }

    func endSwitching() {
        isSwitching = false
    }

    private func pruneExpiredClaims() {
        let expired = claimsByAccountId.filter { !$0.value.isLive }.keys
        guard !expired.isEmpty else { return }
        for accountId in expired { claimsByAccountId.removeValue(forKey: accountId) }
        // If the lease we let lapse was our own, stop pretending we still hold it, so the next
        // switch doesn't try to release a claim the server already considers free.
        if let held = heldClaimAccountId, expired.contains(held) {
            heldClaimAccountId = nil
            heartbeatTimer?.invalidate()
            heartbeatTimer = nil
        }
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

    /// Called from RootView when `PoolState.step` reaches `.ready`. Idempotent against being
    /// called again with the same team. `auth` is subscribed to here rather than passed per-call,
    /// so the attribution hook's session file stays current on every token refresh regardless of
    /// whether the panel is on-screen.
    func configurePool(team: Team, member: Member, auth: AuthController) {
        guard currentTeam?.id != team.id else { return }
        // Switching teams: tear the previous team's wiring down first so its Realtime
        // subscriptions, poll-leader lease, engines and cached rows don't leak into the new team.
        // First-time setup (currentTeam == nil) skips this.
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

        // Drops reservations whose lease has run out. Purely local bookkeeping against rows we
        // already hold, with no network call: a lapsing lease generates no event of its own, so
        // without this tick a "held by" badge stays on screen until something unrelated happens to
        // refresh the pool. Mutating the dictionary is what republishes it to the views.
        claimExpiryTimer?.invalidate()
        claimExpiryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.pruneExpiredClaims() }
        }

        autoSwitchEngine.start(settings: autoSwitchSettings, teamKey: teamKey, myUserId: member.userId, teamId: team.id)
    }

    /// Unwinds everything `configurePool` set up, so the app can be reconfigured cleanly when
    /// switching teams. Clears pool-derived caches but leaves `usageByAccount`: a later
    /// `refresh()` rebuilds local usage, and stale pool entries drop out once
    /// `poolAccountsByUuid` no longer references them.
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
        claimExpiryTimer?.invalidate()
        claimExpiryTimer = nil
        isPollLeader = false
        authCancellable?.cancel()
        poolAccountsByUuid = [:]
        claimsByAccountId = [:]
        membersById = [:]
        currentTeam = nil
        currentMember = nil
        teamKey = nil
    }

    // MARK: - Attribution (turn-log hook)

    /// Installs or removes the `UserPromptSubmit` hook with explicit consent, never automatically.
    /// Keeps the flag matching what actually happened rather than what was requested, in case the
    /// install fails (no write access to `~/.claude/`, say).
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
            lastError = "Couldn't \(enabled ? "enable" : "disable") prompt logging: \(error.localizedDescription)"
        }
    }

    private func updateAuthSession(accessToken: String?) {
        lastAccessToken = accessToken
        refreshAttributionSessionState()
    }

    /// Rewrites `~/.ccswitch/session.env`, the hook script's only input, whenever any of the state
    /// it needs might have changed. Cheap and idempotent by design, so call sites don't diff.
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

    /// One-click "switch to whichever eligible account has the most headroom". Reuses
    /// `AutoSwitchEngine`'s claim- and quarantine-aware scoring, but isn't gated by the enabled
    /// toggle, threshold, hysteresis, or cooldown, since the user asked for it directly. Works
    /// with no pool configured, across purely local accounts.
    @discardableResult
    func switchToBestAccount() async -> AutoSwitchEvent {
        guard beginSwitching() else { return .blocked(reason: "a switch is already in progress") }
        defer { endSwitching() }
        return await autoSwitchEngine.switchToBest()
    }

    /// One-click "move to the next account" in the same email-sorted order the panel renders,
    /// wrapping around. Ignores usage by design: a manual round-robin, not a usage decision.
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

    /// General setter for the Settings window's auto-switch pane, where cooldown, hysteresis and
    /// interval are also exposed. Persists and hands the whole struct to the engine in one pass,
    /// so the panel's quick toggle and the settings pane can't disagree about what's active.
    func updateAutoSwitchSettings(_ newSettings: AutoSwitchSettings) {
        autoSwitchSettings = newSettings
        autoSwitchSettings.saveToDefaults()
        autoSwitchEngine.updateSettings(autoSwitchSettings)
    }

    // MARK: - Account management (Settings → My Accounts)

    /// Whether the signed-in user owns this account and so may change its sharing, remove it, or
    /// transfer it. Gates every owner-only control in Settings.
    func isOwner(of account: DisplayAccount) -> Bool {
        account.poolAccount?.ownerUserId == myUserId
    }

    /// Pulls an account out of the pool while keeping this Mac's own copy: the exact inverse of
    /// `addToPool`, and the reason choosing a share mode is no longer a one-way decision in either
    /// direction. Owner-only, enforced again by the `accounts_delete` RLS policy.
    ///
    /// Distinct from `removeFromPool` below, which additionally deletes the local credentials and
    /// so forgets the account entirely. Here the row goes away, cascading its token, usage and
    /// claim rows so no orphaned ciphertext is left behind in Supabase, but the account stays
    /// switchable on this Mac. `switch_log` history survives, since those foreign keys are
    /// `on delete set null` (20260723000002).
    ///
    /// Requires a local copy: without one there would be nothing left to demote *to*, and this
    /// would silently become a full delete. The UI hides the action in that case rather than
    /// relying on this guard.
    func demoteToLocalOnly(_ account: DisplayAccount) async {
        guard let poolAccount = account.poolAccount,
              poolAccount.ownerUserId == myUserId,
              account.isLocallyKnown
        else { return }
        lastError = nil
        do {
            try await poolSync.removeAccountFromPool(accountId: poolAccount.id)
            // The lease died with the row, so stop heartbeating something that no longer exists.
            if heldClaimAccountId == poolAccount.id {
                heldClaimAccountId = nil
                heartbeatTimer?.invalidate()
                heartbeatTimer = nil
            }
            claimsByAccountId.removeValue(forKey: poolAccount.id)
            poolAccountsByUuid.removeValue(forKey: account.accountUuid)
            toast = "\(account.email) is on this Mac only now. Teammates can't see it."
            await refreshPool()
        } catch {
            lastError = (error as? CoreBridgeError)?.message ?? error.localizedDescription
        }
    }

    /// Forgets an account from the team pool (owner-only). Distinct from `remove`, which drops
    /// only this Mac's local copy. Drops the local copy too when present, so an account you both
    /// own and hold locally disappears from both places in one action.
    func removeFromPool(_ account: DisplayAccount) async {
        guard let poolAccount = account.poolAccount else { return }
        lastError = nil  // clear any stale error so it can't be mistaken for this attempt's result
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

    /// Hands an account you own to another team member: the "wrong person added it" fix. After
    /// this you lose owner controls and they gain them, enforced server-side too, so a stale
    /// client can't keep editing it.
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

    // MARK: - Updates (Sparkle)

    var canCheckForUpdates: Bool { UpdaterProvider.isAvailable }

    func checkForUpdates() {
        guard UpdaterProvider.isAvailable else { return }
        UpdaterProvider.shared.checkForUpdates(nil)
    }

    var automaticUpdateChecksEnabled: Bool { UpdaterProvider.shared.updater.automaticallyChecksForUpdates }

    func setAutomaticUpdateChecksEnabled(_ enabled: Bool) {
        UpdaterProvider.shared.updater.automaticallyChecksForUpdates = enabled
        objectWillChange.send()  // read live from SPUUpdater, not @Published
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
            toast = "\(email) quarantined (\(reason)). Re-login to recover it."
            Diagnostics.log("quarantine: \(email) (\(reason))")
            NotificationService.post(title: "Account quarantined", body: "\(email) needs re-login (\(reason))")
        case .recovered(let email):
            toast = "\(email) recovered. Eligible again."
            Diagnostics.log("recovered: \(email)")
        case .allExhausted:
            toast = "All accounts near their limit. Nothing to switch to."
            Diagnostics.log("all accounts exhausted")
            NotificationService.post(title: "All accounts near their limit", body: "No account has headroom to switch to right now")
        case .error(let message):
            lastError = message
            Diagnostics.log("auto-switch error: \(message)")
        case .blocked:
            break  // routine, not worth a toast every tick
        }
    }

    /// Internal, not private: AutoSwitchEngine calls this after a switch of its own, so
    /// claimed-by badges and cached usage reflect the new state without waiting for Realtime.
    func refreshPool() async {
        guard let team = currentTeam else { return }
        do {
            let accounts = try await poolSync.fetchAccounts(teamId: team.id)
            poolAccountsByUuid = Dictionary(uniqueKeysWithValues: accounts.map { ($0.anthropicAccountUuid, $0) })

            let ids = accounts.map(\.id)
            let claims = try await poolSync.fetchClaims(teamAccountIds: ids)
            claimsByAccountId = Dictionary(uniqueKeysWithValues: claims.compactMap { claim in
                claim.isLive ? (claim.accountId, claim) : nil
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
                        if claim.isLive {
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

    /// Fires the "requesting re-login" notification, but only on the account owner's device. Every
    /// team member's client receives this same Realtime insert, since it's team-wide rather than
    /// targeted, so the owner check here is what keeps it off everyone else's screen.
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

    /// The merged list the panel renders. See `DisplayAccount` for why neither source alone
    /// suffices.
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
        // Re-checked at render time, not just when the row was stored: a lease can lapse with no
        // corresponding server event to react to, so the stored copy goes stale on its own.
        let claim = poolAccount
            .flatMap { claimsByAccountId[$0.id] }
            .flatMap { $0.isLive ? $0 : nil }
        // Always reflects real claim state, regardless of the viewer's own reservation preference.
        // A claim only ever exists because the account's owner reserved it, so showing it honestly
        // is what makes that reservation mean anything.
        let claimedByName = claim?.heldBy.flatMap { membersById[$0]?.displayName }
        return DisplayAccount(
            accountUuid: accountUuid, email: email, organizationUuid: organizationUuid,
            isLocallyKnown: isLocallyKnown, poolAccount: poolAccount,
            usage: usageByAccount[accountUuid], claim: claim, claimedByName: claimedByName
        )
    }

    /// Menu bar title: active account's email plus its tightest usage window, or a placeholder
    /// when nobody's logged in. Kept here rather than in the view so every surface renders it
    /// identically.
    var titleText: String {
        guard let active = activeAccount else { return "Not logged in" }
        if let pct = usageByAccount[active.accountUuid]?.tightestPct {
            return "\(active.email)  \(Int(pct))%"
        }
        return active.email
    }
}
