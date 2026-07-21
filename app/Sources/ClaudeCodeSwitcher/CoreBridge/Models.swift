import Foundation

/// Mirrors the JSON shapes `ccswitch-core` prints on stdout (core/src/ccswitch_core/__main__.py).
/// Kept in one file so the wire contract between Swift and Python has a single source of truth
/// on this side — if a core command's output shape changes, this is the only file that follows.

struct AccountIdentity: Codable, Equatable, Identifiable {
    let accountUuid: String
    let email: String
    let organizationUuid: String?

    var id: String { accountUuid }

    enum CodingKeys: String, CodingKey {
        case accountUuid = "account_uuid"
        case email
        case organizationUuid = "organization_uuid"
    }
}

struct KnownAccount: Codable, Equatable, Identifiable {
    let accountUuid: String
    let email: String
    let organizationUuid: String?
    let capturedAt: String
    let updatedAt: String

    var id: String { accountUuid }

    enum CodingKeys: String, CodingKey {
        case accountUuid = "account_uuid"
        case email
        case organizationUuid = "organization_uuid"
        case capturedAt = "captured_at"
        case updatedAt = "updated_at"
    }
}

struct Snapshot: Codable {
    let active: AccountIdentity?
    let knownAccounts: [KnownAccount]

    enum CodingKeys: String, CodingKey {
        case active
        case knownAccounts = "known_accounts"
    }
}

struct UsageWindow: Codable, Equatable {
    let pct: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case pct
        case resetsAt = "resets_at"
    }

    /// "resets in 3h 12m" (or "resets now" once past it) for display next to a usage bar.
    /// nil when the API didn't send a reset time for this window.
    var resetsInLabel: String? { Self.countdownLabel(to: resetsAt) }

    /// Shared by both usage windows and `ScopedUsage` — same wire format, same countdown shape
    /// as the (currently unused) Python-side `oauth.format_reset`, kept in sync intentionally.
    static func countdownLabel(to resetsAt: String?) -> String? {
        guard let resetsAt, let date = parseISO8601(resetsAt) else { return nil }
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "resets now" }
        let days = seconds / 86400
        let hours = (seconds % 86400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "resets in \(days)d \(hours)h" }
        if hours > 0 { return "resets in \(hours)h \(minutes)m" }
        return "resets in \(minutes)m"
    }

    private static func parseISO8601(_ s: String) -> Date? {
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFractional.date(from: s)
    }
}

struct ScopedUsage: Codable, Equatable, Identifiable {
    let name: String
    let pct: Double
    let resetsAt: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, pct
        case resetsAt = "resets_at"
    }
}

struct Usage: Codable, Equatable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?
    let scoped: [ScopedUsage]?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case scoped
    }

    /// The single number that drives switch decisions and the menu-bar title:
    /// the tighter of the two rolling windows (whichever is closer to its limit).
    var tightestPct: Double? {
        switch (fiveHour?.pct, sevenDay?.pct) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

/// The optional identity hint a token-refresh response may carry (`oauth._parse_token_account`
/// on the Python side) — note the keys are camelCase already on the wire (`organizationUuid`),
/// unlike most of this file's snake_case core output, because that struct is built by hand from
/// the OAuth token endpoint's own response shape rather than going through the core's usual
/// output pipeline.
struct TokenAccountHint: Codable, Equatable {
    let uuid: String
    let email: String?
    let organizationUuid: String?
}

struct RefreshedToken: Codable {
    let token: String
    let tokenAccount: TokenAccountHint?

    enum CodingKeys: String, CodingKey {
        case token
        case tokenAccount = "token_account"
    }
}

/// The envelope every ccswitch-core command prints: `{"ok": true, ...}` or
/// `{"ok": false, "error": {...}}`. Decoded generically, then the caller decodes
/// the specific payload out of `raw` once `ok` is confirmed true — see CoreBridge.run().
struct CoreEnvelope: Codable {
    let ok: Bool
    let error: CoreErrorPayload?
}

struct CoreErrorPayload: Codable {
    let code: String
    let message: String
}

struct CoreBridgeError: Error, LocalizedError {
    let code: String
    let message: String

    var errorDescription: String? { message }
}
