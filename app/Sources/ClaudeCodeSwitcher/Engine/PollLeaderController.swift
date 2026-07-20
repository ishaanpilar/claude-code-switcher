import CryptoKit
import Foundation

/// Poll-leader election and the leader's usage-sweep loop (BUILD_PLAN.md section 3a). Only one
/// online client polls Anthropic's usage API on behalf of accounts nobody is actively driving
/// right now — everyone else gets those numbers for free over Realtime (`AppState`'s
/// `usage_current` subscription). Adding accounts or team members must not increase Anthropic API
/// volume; this file is the piece that makes that true.
///
/// Scope note: "poll leader" only ever means *coordinator for accounts this device can
/// decrypt* — a visibility-only account's token never leaves its owner's Mac by design, so no
/// leader, elected or not, can poll it. Those accounts' usage numbers come only from their
/// owner's own client (`AppState.refreshUsage`), whoever the leader happens to be.
@MainActor
final class PollLeaderController {
    private let poolSync = PoolSyncService()
    private let bridge: CoreBridge

    private var team: Team?
    private var myUserId: UUID?
    private var teamKey: SymmetricKey?
    private var getAccounts: (() -> [PoolAccount])?
    private var onUsagePolled: ((String, Usage) -> Void)?

    private(set) var isLeader = false
    private var electionTimer: Timer?
    private var loopTask: Task<Void, Never>?
    private var pollStates: [UUID: AccountPollState] = [:]

    init(bridge: CoreBridge) {
        self.bridge = bridge
    }

    /// `getAccounts` and `onUsagePolled` are closures rather than a direct `AppState` reference
    /// so this controller stays testable/reusable independent of the view-layer state object —
    /// `AppState` wires both in `configurePool`.
    func start(
        team: Team,
        myUserId: UUID,
        teamKey: SymmetricKey?,
        getAccounts: @escaping () -> [PoolAccount],
        onUsagePolled: @escaping (String, Usage) -> Void
    ) {
        self.team = team
        self.myUserId = myUserId
        self.teamKey = teamKey
        self.getAccounts = getAccounts
        self.onUsagePolled = onUsagePolled

        electionTimer?.invalidate()
        electionTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.electionTick() }
        }
        Task { await electionTick() }  // don't wait a full 30s for the first attempt
    }

    func stop() {
        electionTimer?.invalidate()
        electionTimer = nil
        loopTask?.cancel()
        loopTask = nil
        if isLeader, let team {
            isLeader = false
            Task { try? await poolSync.releasePollLeader(teamId: team.id) }
        }
    }

    private func electionTick() async {
        guard let team else { return }
        if isLeader {
            do {
                try await poolSync.heartbeatPollLeader(teamId: team.id)
            } catch {
                // Lease heartbeat failed (network blip, or someone else's clock somehow won a
                // race) — stop polling rather than risk two leaders double-hitting the API;
                // the next tick re-attempts election normally.
                isLeader = false
                loopTask?.cancel()
            }
        } else if let row = try? await poolSync.tryBecomePollLeader(teamId: team.id), row.leaderUserId != nil {
            isLeader = true
            startPollingLoop()
        }
    }

    private func startPollingLoop() {
        loopTask?.cancel()
        loopTask = Task { [weak self] in
            while let self, self.isLeader, !Task.isCancelled {
                await self.pollDuePass()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    /// One sweep: for every pool account whose cadence plan says it's due, resolve a token
    /// (local backup first, else decrypt the shared team-key row), fetch usage, replan its next
    /// due time, and publish the result. Accounts this device can't decrypt (someone else's
    /// visibility-only account) are silently skipped — not an error, just not this leader's job.
    private func pollDuePass() async {
        guard let getAccounts, let myUserId else { return }
        let now = Date()
        for account in getAccounts() where account.status == .active {
            var state = pollStates[account.id] ?? AccountPollState()
            guard now >= state.nextPollAt else { continue }

            guard let token = await resolveToken(for: account) else { continue }
            do {
                let usage = try await bridge.readUsage(token: token)
                let plan = PollPolicy.planAfterFetch(
                    prevIntervalS: state.lastIntervalS,
                    prevUsage: state.lastUsage,
                    newUsage: usage,
                    isActive: false,  // the leader's sweep only ever covers non-actively-driven
                                      // accounts — an active one is already kept fresh by whoever
                                      // is driving it, via AppState.refreshUsage's own push.
                    threshold: 90,
                    recent429: state.hasRecent429,
                    now: now
                )
                state.lastUsage = usage
                state.lastIntervalS = plan.intervalS
                state.nextPollAt = plan.nextPollAt
                pollStates[account.id] = state

                onUsagePolled?(account.anthropicAccountUuid, usage)
                try? await poolSync.pushUsage(accountId: account.id, usage: usage, fetchedBy: myUserId)
            } catch let error as CoreBridgeError where error.code.hasPrefix("http-429") {
                state.recent429At = now
                state.nextPollAt = now.addingTimeInterval(PollPolicy.post429MinIntervalS)
                pollStates[account.id] = state
            } catch {
                // Any other failure (network, dead token, ...): back off to the candidate
                // default rather than hammering a broken account every 5s.
                state.nextPollAt = now.addingTimeInterval(PollPolicy.candidateDefaultIntervalS)
                pollStates[account.id] = state
            }
        }
    }

    private func resolveToken(for account: PoolAccount) async -> String? {
        if let local = try? await bridge.exportToken(accountUuid: account.anthropicAccountUuid) {
            return local
        }
        guard account.shareMode == .shared, let teamKey else { return nil }
        guard let tokenRow = try? await poolSync.fetchTeamKeyToken(accountId: account.id) else { return nil }
        return try? TeamCrypto.decrypt(ciphertext: tokenRow.ciphertext, nonce: tokenRow.nonce, key: teamKey)
    }
}
