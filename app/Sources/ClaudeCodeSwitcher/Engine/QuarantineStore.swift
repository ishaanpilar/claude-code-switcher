import CryptoKit
import Foundation

/// One quarantined account: why, when, and — for locally-known accounts — a fingerprint of the
/// refresh token that failed, so a real re-login (which mints a new refresh token) can be told
/// apart from the same dead token still sitting there.
struct QuarantineEntry: Codable, Equatable {
    var reason: String
    var quarantinedAt: Date
    var refreshTokenFingerprint: String?
}

/// Disk-persisted quarantine list for `AutoSwitchEngine`, replacing its original in-memory `Set`
/// (see that file's header comment). Ported from claude-swap's `_release_recovered_quarantines`
/// idea: a quarantined account is auto-released the moment its refresh-token fingerprint changes
/// — a real re-login — rather than on a fixed timeout, since a genuinely dead refresh token
/// doesn't heal itself with time.
///
/// UserDefaults, matching `AutoSwitchSettings`'s own persistence choice (see that file's header
/// comment on why this app uses UserDefaults instead of claude-swap's settings.json).
enum QuarantineStore {
    private static let defaultsKey = "com.claudecodeswitcher.quarantine"

    static func load() -> [String: QuarantineEntry] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let entries = try? JSONDecoder().decode([String: QuarantineEntry].self, from: data)
        else { return [:] }
        return entries
    }

    static func save(_ entries: [String: QuarantineEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    /// SHA-256 of the refresh token embedded in a `claudeAiOauth`-shaped credential JSON string
    /// (the same shape `CoreBridge.exportToken`/`refreshToken` deal in) — never the token itself,
    /// so nothing sensitive sits in UserDefaults.
    static func fingerprint(ofCredentialJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let refreshToken = oauth["refreshToken"] as? String
        else { return nil }
        let digest = SHA256.hash(data: Data(refreshToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
