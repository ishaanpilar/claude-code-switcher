import Foundation

/// Adaptive usage-polling cadence — ported from claude-swap's `poll_policy.py` (MIT). That file's
/// header documents the measured shape this leans on: the `/api/oauth/usage` endpoint enforces a
/// rolling ~60-minute budget of ~28-30 requests per access token, not a refill-rate bucket, so
/// the constants below target a sustained average of roughly 1 request/3min per token — leaving
/// headroom for manual switches and a bounded "urgent mode" near the switch threshold. If a
/// future probe revises that shape, this is the only file to touch.
///
/// Pure functions plus one small per-account state struct — no OS calls, no actor isolation
/// requirement — so the exact same cadence math runs whether or not this device happens to be
/// poll leader this hour (see `PollLeaderController`).
enum PollPolicy {
    static let minIntervalS: TimeInterval = 180
    static let urgentIntervalS: TimeInterval = 60
    static let activeMaxIntervalS: TimeInterval = 300
    static let candidateDefaultIntervalS: TimeInterval = 300
    static let candidateMaxIntervalS: TimeInterval = 600
    static let movementDeltaPct: Double = 1.0
    static let jitterFrac: Double = 0.1
    static let escalationMarginPct: Double = 15.0
    static let resetSlackS: TimeInterval = 60
    static let post429MinIntervalS: TimeInterval = 360
    static let recent429WindowS: TimeInterval = 3600

    struct Plan {
        let nextPollAt: Date
        let intervalS: TimeInterval
    }

    /// Utilization of the binding (tightest) relevant window — same "tighter window wins" rule
    /// `Usage.tightestPct` already implements, kept as its own entry point here so the cadence
    /// math reads the same way claude-swap's `binding_pct` does.
    static func bindingPct(_ usage: Usage?) -> Double? {
        usage?.tightestPct
    }

    /// `(nextPollAt, intervalS)` for an account just fetched successfully.
    ///
    /// Movement (binding pct changed ≥ `movementDeltaPct` since the previous poll) halves the
    /// interval, floored at `minIntervalS` — or drops to `urgentIntervalS` when this is the
    /// active account moving inside the escalation band. No movement backs off ×1.5 toward the
    /// account's ceiling. A recent 429 floors the cadence at `post429MinIntervalS` and suppresses
    /// urgent mode. The result gets `jitterFrac` noise so independent clients don't fetch in
    /// lockstep, and is clamped to the account's own known window resets: never later than the
    /// next reset + slack, and an at-limit account skips straight to the reset that frees it.
    static func planAfterFetch(
        prevIntervalS: TimeInterval?,
        prevUsage: Usage?,
        newUsage: Usage?,
        isActive: Bool,
        threshold: Double,
        recent429: Bool,
        now: Date = Date(),
        rng: () -> Double = { Double.random(in: 0...1) }
    ) -> Plan {
        let defaultInterval = isActive ? minIntervalS : candidateDefaultIntervalS
        let ceiling = isActive ? activeMaxIntervalS : candidateMaxIntervalS
        let base = prevIntervalS ?? defaultInterval
        let prevPct = bindingPct(prevUsage)
        let newPct = bindingPct(newUsage)

        var moving = false
        var interval: TimeInterval
        if prevPct == nil || newPct == nil {
            interval = defaultInterval
        } else if abs(newPct! - prevPct!) >= movementDeltaPct {
            moving = true
            interval = max(minIntervalS, base / 2)
        } else {
            // Floored so a sub-floor base (urgent mode's 60s) snaps straight back to the normal
            // cadence once movement stops, instead of decaying through intervals the budget
            // never intended.
            interval = min(ceiling, max(minIntervalS, base * 1.5))
        }

        if isActive, moving, !recent429, let newPct, newPct >= threshold - escalationMarginPct {
            interval = urgentIntervalS
        }
        if recent429 {
            interval = max(interval, post429MinIntervalS)
        }

        let jittered = interval * (1.0 + jitterFrac * (2.0 * rng() - 1.0))
        var nextPoll = now.addingTimeInterval(jittered)

        if let newPct, newPct >= 100 {
            if let resetTs = limitingResetTs(newUsage), resetTs > nextPoll {
                nextPoll = resetTs
            }
        } else if let resetTs = earliestFutureResetTs(newUsage, now: now) {
            nextPoll = min(nextPoll, resetTs.addingTimeInterval(resetSlackS))
        }

        return Plan(nextPollAt: nextPoll, intervalS: interval)
    }

    private static func relevantWindows(_ usage: Usage?) -> [(pct: Double, resetsAt: Date?)] {
        guard let usage else { return [] }
        var out: [(Double, Date?)] = []
        if let fh = usage.fiveHour { out.append((fh.pct, parseISO8601(fh.resetsAt))) }
        if let sd = usage.sevenDay { out.append((sd.pct, parseISO8601(sd.resetsAt))) }
        for s in usage.scoped ?? [] { out.append((s.pct, parseISO8601(s.resetsAt))) }
        return out
    }

    /// Epoch of the last ≥100% relevant window's reset (the account becomes usable again then).
    private static func limitingResetTs(_ usage: Usage?) -> Date? {
        relevantWindows(usage).filter { $0.pct >= 100 }.compactMap(\.resetsAt).max()
    }

    /// Epoch of the next relevant-window reset ahead of `now`, whatever its utilization.
    private static func earliestFutureResetTs(_ usage: Usage?, now: Date) -> Date? {
        relevantWindows(usage).compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    private static func parseISO8601(_ s: String?) -> Date? {
        guard let s else { return nil }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: s)
    }
}

/// Per-account cadence state the leader keeps in memory while it holds the lease. Not persisted
/// across a leader handoff (a fresh leader just starts every account at its default interval) —
/// a deliberate v1 simplification vs. claude-swap's disk-persisted usage store; losing a few
/// polls' worth of learned cadence on handoff costs nothing but a slightly less-tuned interval
/// for one cycle.
struct AccountPollState {
    var lastUsage: Usage?
    var lastIntervalS: TimeInterval?
    var nextPollAt: Date = .distantPast
    var recent429At: Date?

    var hasRecent429: Bool {
        guard let recent429At else { return false }
        return Date().timeIntervalSince(recent429At) < PollPolicy.recent429WindowS
    }
}
