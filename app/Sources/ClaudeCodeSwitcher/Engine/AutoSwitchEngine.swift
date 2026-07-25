import CryptoKit
import Foundation

/// User-configurable auto-switch policy. Defaults match claude-swap's `AutoSwitchSettings`
/// exactly: the product of real tuning against the usage API's rate-limit shape, not arbitrary
/// starting points.
struct AutoSwitchSettings: Codable, Equatable {
    var enabled: Bool = false
    var threshold: Double = 90.0
    var hysteresisPct: Double = 10.0
    var cooldownSeconds: TimeInterval = 300
    var intervalSeconds: TimeInterval = 60
    var unhealthyTicks: Int = 3

    private static let defaultsKey = "com.claudecodeswitcher.autoSwitchSettings"

    /// UserDefaults rather than claude-swap's settings.json, because this app has one settings
    /// surface instead of a CLI, TUI and menu bar needing to agree on a file. Revisit if a second
    /// surface ever needs to share these.
    static func loadFromDefaults() -> AutoSwitchSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let settings = try? JSONDecoder().decode(AutoSwitchSettings.self, from: data)
        else { return AutoSwitchSettings() }
        return settings
    }

    func saveToDefaults() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}

enum AutoSwitchEvent {
    case switched(to: String, trigger: String)
    case blocked(reason: String)
    case quarantined(email: String, reason: String)
    case recovered(email: String)
    case allExhausted
    case error(String)
}

/// The auto-switch decision engine: a claim-aware port of claude-swap's `autoswitch.py`
/// `_tick_inner`/`_perform`/`_freshen_target` (MIT). Ported, not reinvented. Trigger
/// classification (proactive, at-limit, failover), the hysteresis gate, cooldown, and
/// freshen-before-activate sequencing all mirror the source. The new axis is claim-awareness: a
/// candidate held by another team member is never selected, which a single-user engine has no
/// concept of.
///
/// Reads its input entirely from `AppState`'s cached `usageByAccount`/`displayAccounts`, kept warm
/// by each client's refresh cycle plus Realtime, rather than fetching anything itself. So this
/// engine spends no extra Anthropic API budget; `PollLeaderController` is where calls happen.
@MainActor
final class AutoSwitchEngine {
    private let bridge: CoreBridge
    private let poolSync = PoolSyncService()
    private unowned let state: AppState

    private var settings = AutoSwitchSettings()
    private var teamKey: SymmetricKey?
    private var myUserId: UUID?
    private var teamId: UUID?

    /// Persisted via `QuarantineStore`, so it survives relaunch and auto-releases on a real
    /// re-login via refresh-token fingerprint comparison. See `releaseRecovered()`.
    private var quarantine: [String: QuarantineEntry]
    private var unhealthyTicks = 0
    private var lastSwitchAt: Date?
    private var tickTask: Task<Void, Never>?

    /// In-memory only, unlike quarantine. A relaunch clearing this is fine: it guards against
    /// rapid repeated attempts within one session, which is not something that needs to survive a
    /// restart. See `tryActivate`'s freshen step for why it exists.
    private var lastFreshenAttempt: [String: Date] = [:]
    private let freshenCooldownS: TimeInterval = 120

    var onEvent: ((AutoSwitchEvent) -> Void)?

    init(bridge: CoreBridge, state: AppState) {
        self.bridge = bridge
        self.state = state
        self.quarantine = QuarantineStore.load()
    }

    func start(settings: AutoSwitchSettings, teamKey: SymmetricKey?, myUserId: UUID?, teamId: UUID?) {
        self.settings = settings
        self.teamKey = teamKey
        self.myUserId = myUserId
        self.teamId = teamId
        // Cancel before the enabled check, not after. Starting with auto-switch off has to tear
        // down any loop still running from a previous configuration (a team switch, say) rather
        // than leaving it spinning against the new team's credentials for the app's lifetime.
        tickTask?.cancel()
        tickTask = nil
        guard settings.enabled else { return }
        tickTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.tick()
                let interval = self.settings.intervalSeconds
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1_000_000_000))
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    func updateSettings(_ newSettings: AutoSwitchSettings) {
        let wasEnabled = settings.enabled
        settings = newSettings
        if newSettings.enabled, !wasEnabled {
            start(settings: newSettings, teamKey: teamKey, myUserId: myUserId, teamId: teamId)
        } else if !newSettings.enabled {
            stop()
        }
    }

    // MARK: - Tick (port of `_tick_inner`'s trigger classification)

    private func tick() async {
        guard settings.enabled, let active = state.activeAccount else { return }
        // Shares AppState's switch mutex with manual row clicks and the quick-switch buttons.
        // Without it, the automatic engine can race a manual switch.
        guard state.beginSwitching() else { return }
        defer { state.endSwitching() }
        await releaseRecovered()

        guard let activePct = state.usageByAccount[active.accountUuid]?.tightestPct else {
            // Active usage unreadable: count toward failover rather than acting immediately, so a
            // transient read blip can't itself trigger a switch.
            unhealthyTicks += 1
            if unhealthyTicks < settings.unhealthyTicks {
                onEvent?(.blocked(reason: "active usage unknown (\(unhealthyTicks)/\(settings.unhealthyTicks) before failover)"))
                return
            }
            await evaluate(trigger: "failover", activeHeadroom: nil)
            return
        }
        unhealthyTicks = 0

        let activeHeadroom = 100.0 - activePct
        if activePct < settings.threshold {
            onEvent?(.blocked(reason: "\(Int(activePct))% < \(Int(settings.threshold))%"))
            return
        }
        let trigger = activeHeadroom <= 0 ? "at-limit" : "proactive"
        if trigger == "proactive", inCooldown() {
            onEvent?(.blocked(reason: "cooldown"))
            return
        }
        await evaluate(trigger: trigger, activeHeadroom: activeHeadroom)
    }

    // MARK: - Candidate selection (port of the qualifying/hysteresis loop)

    private func evaluate(trigger: String, activeHeadroom: Double?) async {
        let active = state.activeAccount
        let candidates = eligibleManualCandidates(excluding: active?.accountUuid)

        var qualifying: [(headroom: Double, account: DisplayAccount)] = []
        var anyKnown = false
        for candidate in candidates {
            guard let pct = candidate.usage?.tightestPct else { continue }
            anyKnown = true
            let headroom = 100.0 - pct
            if headroom <= 0 { continue }  // at its own limit, never a target
            if trigger == "proactive", let activeHeadroom {
                // Hysteresis: the candidate must land below the threshold and beat the active
                // account by the full margin, so two accounts hovering at the line can't
                // ping-pong. at-limit and failover skip this gate, since anything with headroom
                // beats a blocked or dead account.
                if pct >= settings.threshold { continue }
                if headroom - activeHeadroom < settings.hysteresisPct { continue }
            }
            qualifying.append((headroom, candidate))
        }
        qualifying.sort { $0.headroom > $1.headroom }
        let ordered = qualifying.map(\.account)

        guard !ordered.isEmpty else {
            if !anyKnown {
                onEvent?(.blocked(reason: "no candidate has readable usage"))
                return
            }
            let allExhausted = candidates.allSatisfy { c in
                guard let pct = c.usage?.tightestPct else { return false }
                return (100.0 - pct) <= 0
            }
            onEvent?(allExhausted ? .allExhausted : .blocked(reason: "no qualifying candidate"))
            return
        }

        await activateFirstViable(ordered, trigger: trigger)
    }

    /// Candidate filter shared by the automatic tick and the manual quick-switch actions:
    /// quarantine-aware, and always claim-aware. A live reservation is honored regardless of this
    /// device's own preference, since a claim only exists because the account's owner made it.
    /// Creating a reservation is opt-in and owner-only; respecting an existing one is not.
    private func eligibleManualCandidates(excluding activeUuid: String?) -> [DisplayAccount] {
        state.displayAccounts.filter { account in
            account.accountUuid != activeUuid
                && quarantine[account.accountUuid] == nil
                && account.isActivatableHere
                && (account.claim?.heldBy == nil || account.claim?.heldBy == myUserId)
        }
    }

    /// Tries each candidate in order until one activates. On success this is also where
    /// `lastSwitchAt` (cooldown timing) is set and local plus pool state get refreshed. Shared by
    /// the automatic tick and the quick-switch buttons; only how `ordered` was built differs.
    @discardableResult
    private func activateFirstViable(_ ordered: [DisplayAccount], trigger: String) async -> AutoSwitchEvent {
        for candidate in ordered {
            let previousAccountUuid = state.activeAccount?.accountUuid
            switch await tryActivate(candidate) {
            case .switched:
                lastSwitchAt = Date()
                // Give up whatever we held; a no-op if we never claimed anything. Unconditional,
                // matching AppState.switchTo's release.
                if let previousPoolAccountId = previousAccountUuid.flatMap({ state.poolAccountsByUuid[$0]?.id }),
                   previousPoolAccountId != candidate.poolAccount?.id {
                    try? await poolSync.releaseClaim(accountId: previousPoolAccountId)
                }
                // Adopt a reservation on the new account only if it's ours to reserve and we opted
                // in, the same condition tryActivate took the claim under. This just keeps
                // AppState's heartbeat in sync with it.
                if state.reserveAccountsWhileInUse, let poolAccount = candidate.poolAccount, poolAccount.ownerUserId == myUserId {
                    state.adoptClaim(accountId: poolAccount.id)
                }
                await logSwitch(from: previousAccountUuid, to: candidate.accountUuid, trigger: trigger)
                let event = AutoSwitchEvent.switched(to: candidate.email, trigger: trigger)
                onEvent?(event)
                await state.refresh()
                await state.refreshPool()
                return event
            case .quarantine(let reason, let fingerprint):
                quarantine[candidate.accountUuid] = QuarantineEntry(
                    reason: reason, quarantinedAt: Date(), refreshTokenFingerprint: fingerprint
                )
                QuarantineStore.save(quarantine)
                onEvent?(.quarantined(email: candidate.email, reason: reason))
            case .skip:
                continue
            }
        }
        let event = AutoSwitchEvent.blocked(reason: "no viable target")
        onEvent?(event)
        return event
    }

    /// Best-effort audit row in `switch_log`, the same table `AppState.switchTo` writes for manual
    /// switches. Maps this engine's finer-grained triggers onto the table's constrained reasons.
    private func logSwitch(from: String?, to: String?, trigger: String) async {
        guard let teamId, let myUserId else { return }
        let reason: String
        switch trigger {
        case "failover": reason = "failover"
        case "manual-best", "manual-rotate": reason = "manual"
        default: reason = "auto"  // "proactive" / "at-limit"
        }
        let fromId = from.flatMap { state.poolAccountsByUuid[$0]?.id }
        let toId = to.flatMap { state.poolAccountsByUuid[$0]?.id }
        guard fromId != nil || toId != nil else { return }
        try? await poolSync.logSwitch(teamId: teamId, userId: myUserId, from: fromId, to: toId, reason: reason)
    }

    // MARK: - Manual "switch now" actions (quick-switch buttons)

    /// One-click "switch to best": the same claim- and quarantine-aware scoring the automatic
    /// engine uses, but not gated by threshold, hysteresis or cooldown, since an explicit request
    /// overrides all of that by design.
    @discardableResult
    func switchToBest() async -> AutoSwitchEvent {
        await releaseRecovered()
        let candidates = eligibleManualCandidates(excluding: state.activeAccount?.accountUuid)
        let ordered = candidates
            .filter { ($0.usage?.tightestPct ?? 0) < 100 }
            .sorted { (100 - ($0.usage?.tightestPct ?? 0)) > (100 - ($1.usage?.tightestPct ?? 0)) }
        guard !ordered.isEmpty else {
            let event: AutoSwitchEvent = candidates.isEmpty ? .blocked(reason: "no other eligible account") : .allExhausted
            onEvent?(event)
            return event
        }
        return await activateFirstViable(ordered, trigger: "manual-best")
    }

    /// One-click "rotate": moves to the next eligible account after the active one, in the same
    /// email-sorted order the panel shows, wrapping around. Ignores usage by design, since this is
    /// a manual round-robin rather than a usage decision.
    @discardableResult
    func rotate() async -> AutoSwitchEvent {
        await releaseRecovered()
        let activeUuid = state.activeAccount?.accountUuid
        let candidates = eligibleManualCandidates(excluding: activeUuid)
        guard !candidates.isEmpty else {
            let event = AutoSwitchEvent.blocked(reason: "no other eligible account")
            onEvent?(event)
            return event
        }
        let all = state.displayAccounts.sorted { $0.email < $1.email }
        let startIndex = all.firstIndex(where: { $0.accountUuid == activeUuid }).map { ($0 + 1) % all.count } ?? 0
        let rotatedOrder = Array(all[startIndex...] + all[..<startIndex])
        let ordered = rotatedOrder.filter { row in candidates.contains { $0.accountUuid == row.accountUuid } }
        return await activateFirstViable(ordered, trigger: "manual-rotate")
    }

    /// Claude-swap's re-login detection (`_release_recovered_quarantines`): compare the
    /// refresh-token fingerprint now on disk for a quarantined account against the one captured at
    /// quarantine time. A changed fingerprint means someone logged that account in again, so
    /// release it. Only touches locally-known accounts; one nobody has activated on this device
    /// has no local token to check and stays quarantined until a client holding it releases it.
    ///
    /// Internal, not private: `AppState.refresh()` calls this on every refresh, not just while
    /// this engine's tick loop runs. Recovery has to work whether or not auto-switch is enabled,
    /// since "log back in and it's detected" shouldn't depend on an unrelated toggle.
    func releaseRecovered() async {
        guard !quarantine.isEmpty else { return }
        var changed = false
        for (accountUuid, entry) in quarantine {
            guard let account = state.displayAccounts.first(where: { $0.accountUuid == accountUuid }),
                  account.isLocallyKnown,
                  let token = try? await bridge.exportToken(accountUuid: accountUuid),
                  let currentFingerprint = QuarantineStore.fingerprint(ofCredentialJSON: token)
            else { continue }
            if let oldFingerprint = entry.refreshTokenFingerprint, oldFingerprint != currentFingerprint {
                quarantine.removeValue(forKey: accountUuid)
                changed = true
                onEvent?(.recovered(email: account.email))
            }
        }
        if changed { QuarantineStore.save(quarantine) }
    }

    // MARK: - Freshen + claim + activate (port of `_freshen_target` + `_perform`)

    private enum ActivateOutcome {
        case switched
        case quarantine(reason: String, fingerprint: String?)
        case skip
    }

    private func tryActivate(_ candidate: DisplayAccount) async -> ActivateOutcome {
        var token: String
        if candidate.isLocallyKnown {
            guard let t = try? await bridge.exportToken(accountUuid: candidate.accountUuid) else { return .skip }
            token = t
        } else if let poolAccount = candidate.poolAccount, poolAccount.shareMode == .shared, let teamKey {
            guard let tokenRow = try? await poolSync.fetchTeamKeyToken(accountId: poolAccount.id) else { return .skip }
            guard let plaintext = try? TeamCrypto.decrypt(ciphertext: tokenRow.ciphertext, nonce: tokenRow.nonce, key: teamKey) else {
                return .skip
            }
            token = plaintext
        } else {
            return .skip  // visibility-only and not locally known, so nothing to activate
        }

        // Freshen: make sure the token outlives Claude Code's own 5-minute refresh buffer before
        // activation, using the same 10-minute margin as claude-swap's FRESHEN_BUFFER_MS.
        //
        // A second guard beyond the buffer: never freshen the same account twice within
        // freshenCooldownS, whatever isNearExpiry says. A refresh_token is typically single-use,
        // so back-to-back freshen attempts on one account (rapid clicking, or an overlap between
        // this device and another) race, and the loser's copy is already spent. That is how two
        // real accounts got permanently logged out. The cooldown makes it impossible from this
        // engine's side, independently of AppState.switchTo's mutex, which serializes only this
        // device's switches and not a race against another device holding the same token.
        if isNearExpiry(token) {
            let now = Date()
            if let last = lastFreshenAttempt[candidate.accountUuid], now.timeIntervalSince(last) < freshenCooldownS {
                return .skip  // freshened moments ago, by us or a race; don't pile on
            }
            lastFreshenAttempt[candidate.accountUuid] = now
            do {
                let refreshed = try await bridge.refreshToken(token)
                token = refreshed.token
                // Persisted before activation is attempted. See CoreBridge.saveCredentials: a
                // failed activate must never discard the only valid copy.
                try? await bridge.saveCredentials(accountUuid: candidate.accountUuid, token: token)
                if let poolAccount = candidate.poolAccount, let teamKey {
                    try? await poolSync.pushToken(accountId: poolAccount.id, plaintextToken: token, teamKey: teamKey)
                }
            } catch let error as CoreBridgeError where error.code == "invalid_grant" {
                return .quarantine(reason: "invalid_grant", fingerprint: QuarantineStore.fingerprint(ofCredentialJSON: token))
            } catch {
                return .skip  // transient: try the next candidate now, retry this one next tick
            }
        }

        // Claim before activating, only when reservations are on (off by default) and only for a
        // pool account we own. This engine never reserves a teammate's account for them.
        // `eligibleManualCandidates` already filtered out anything someone else reserved, so a
        // failed claim here means a race across the owner's own devices. Skip either way.
        if state.reserveAccountsWhileInUse, let poolAccount = candidate.poolAccount, poolAccount.ownerUserId == myUserId {
            guard (try? await poolSync.claim(accountId: poolAccount.id)) != nil else { return .skip }
        }

        guard (try? await bridge.importActivate(
            accountUuid: candidate.accountUuid, token: token,
            email: candidate.email, organizationUuid: candidate.organizationUuid
        )) != nil else { return .skip }

        return .switched
    }

    private func isNearExpiry(_ token: String) -> Bool {
        guard let data = token.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? Double
        else { return false }
        let nowMs = Date().timeIntervalSince1970 * 1000
        let freshenBufferMs = 10.0 * 60 * 1000
        return nowMs + freshenBufferMs >= expiresAt
    }

    private func inCooldown() -> Bool {
        guard let lastSwitchAt else { return false }
        return Date().timeIntervalSince(lastSwitchAt) < settings.cooldownSeconds
    }
}
