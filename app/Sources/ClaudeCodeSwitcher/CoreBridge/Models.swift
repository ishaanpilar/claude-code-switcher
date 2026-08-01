import Foundation

/// Mirrors the JSON shapes `ccswitch-core` prints on stdout (core/src/ccswitch_core/__main__.py).
/// Kept in one file so the wire contract between Swift and Python has a single source of truth
/// on this side, so if a core command's output shape changes this is the only file that follows.

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

    /// Shared by both usage windows and `ScopedUsage`, which use the same wire format.
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
/// on the Python side). The keys are already camelCase on the wire (`organizationUuid`),
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

/// Answers the only two questions Swift ever asks of a plaintext OAuth credential, without
/// modelling the token: the JSON is Claude Code's, and treating it as opaque everywhere else is
/// what keeps this app compatible when its shape drifts.
enum OAuthCredential {
    /// `claudeAiOauth.expiresAt` in epoch ms, or nil for anything unparseable (including a raw
    /// managed API key). Comparable across machines at token-lifetime granularity: lifetimes are
    /// hours, clock skew is seconds, so "larger expiresAt" reliably identifies the newer of two
    /// lineages of the same account.
    static func expiresAtMs(_ token: String) -> Double? {
        guard let data = token.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let expiresAt = oauth["expiresAt"] as? Double
        else { return nil }
        return expiresAt
    }

    /// Whether the token expires inside Claude Code's own 5-minute refresh window plus margin:
    /// the same 10-minute FRESHEN_BUFFER_MS claude-swap tuned. Unparseable tokens report false,
    /// so a managed API key is never "freshened".
    static func isNearExpiry(_ token: String) -> Bool {
        guard let expiresAt = expiresAtMs(token) else { return false }
        let nowMs = Date().timeIntervalSince1970 * 1000
        return nowMs + 10 * 60 * 1000 >= expiresAt
    }

    /// The newer of several copies of the same account's credential, by `expiresAtMs`. nil only
    /// when `tokens` is empty.
    static func newest(of tokens: [String]) -> String? {
        tokens.max { (expiresAtMs($0) ?? 0) < (expiresAtMs($1) ?? 0) }
    }
}

/// Outcome of the `sync-active` command: whether the active account's local backup had to be
/// brought back in line with the credential Claude Code is actually using. `synced == false` is
/// the ordinary case, not a failure — `reason` distinguishes "nothing had drifted" from the
/// several ways there was nothing to sync (see `switch.sync_active_credential`).
struct CredentialSync: Codable {
    let synced: Bool
    let reason: String
    let accountUuid: String?
    let email: String?

    enum CodingKeys: String, CodingKey {
        case synced
        case reason
        case accountUuid = "account_uuid"
        case email
    }
}

/// The envelope every ccswitch-core command prints: `{"ok": true, ...}` or
/// `{"ok": false, "error": {...}}`. Decoded generically, then the caller decodes
/// the specific payload once `ok` is confirmed true. See CoreBridge.run().
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
