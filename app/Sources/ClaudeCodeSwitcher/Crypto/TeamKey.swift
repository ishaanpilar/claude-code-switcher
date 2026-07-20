import CryptoKit
import Foundation
import Security

/// The team's shared symmetric encryption key: generation, local Keychain storage, and
/// export/import as a copy-pasteable string for onboarding a new member.
///
/// BUILD_PLAN.md section 5 specified libsodium secretbox (XSalsa20-Poly1305); this uses Apple's
/// CryptoKit `ChaChaPoly` (IETF ChaCha20-Poly1305, RFC 8439) instead — functionally equivalent
/// authenticated symmetric encryption at a 256-bit key size, ships with macOS, and there's no
/// interop requirement with an existing libsodium deployment to justify the extra swift-sodium
/// dependency on a green-field client.
///
/// The key itself never touches Supabase (matches the plan exactly): it's generated once by the
/// team's first member, exported as a string, and handed to each new member out-of-band (verbally,
/// a private message, however the group already talks) during onboarding — see OnboardingView.
/// A fully compromised Supabase project therefore leaks only ciphertext, never a usable token.
enum TeamKeyStore {
    private static let service = "com.claudecodeswitcher.teamkey"

    static func generate() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Base64 — the form shown to the user to copy/paste to a teammate during onboarding.
    static func export(_ key: SymmetricKey) -> String {
        key.withUnsafeBytes { Data($0) }.base64EncodedString()
    }

    static func `import`(_ encoded: String) -> SymmetricKey? {
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespacesAndNewlines)),
              data.count == 32
        else { return nil }
        return SymmetricKey(data: data)
    }

    static func store(_ key: SymmetricKey, teamId: UUID) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamId.uuidString,
        ]
        SecItemDelete(baseQuery as CFDictionary)  // idempotent re-store (e.g. after a key refresh)

        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else { throw TeamKeyError.keychainWrite(status) }
    }

    static func load(teamId: UUID) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: teamId.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }
}

enum TeamKeyError: Error, LocalizedError {
    case keychainWrite(OSStatus)
    case noKey
    case encryptFailed
    case decryptFailed

    var errorDescription: String? {
        switch self {
        case .keychainWrite(let status): return "Keychain write failed (OSStatus \(status))"
        case .noKey: return "No team key stored on this device yet"
        case .encryptFailed: return "Encryption failed"
        case .decryptFailed: return "Decryption failed — wrong team key, or the data is corrupted"
        }
    }
}

/// Encrypt/decrypt for one account's token — the payload that becomes `account_tokens.ciphertext`
/// / `.nonce` (0002_accounts.sql). The Poly1305 authentication tag is appended to the ciphertext
/// bytes before base64 (a fixed 16-byte suffix), rather than adding a third stored column, so the
/// schema only needs the two columns it already has.
enum TeamCrypto {
    private static let tagLength = 16

    static func encrypt(_ plaintext: String, key: SymmetricKey) throws -> (ciphertext: String, nonce: String) {
        guard let data = plaintext.data(using: .utf8) else { throw TeamKeyError.encryptFailed }
        let nonce = ChaChaPoly.Nonce()
        let sealed: ChaChaPoly.SealedBox
        do {
            sealed = try ChaChaPoly.seal(data, using: key, nonce: nonce)
        } catch {
            throw TeamKeyError.encryptFailed
        }
        let combined = sealed.ciphertext + sealed.tag
        return (combined.base64EncodedString(), Data(nonce).base64EncodedString())
    }

    static func decrypt(ciphertext: String, nonce: String, key: SymmetricKey) throws -> String {
        guard let combined = Data(base64Encoded: ciphertext),
              let nonceData = Data(base64Encoded: nonce),
              combined.count > tagLength
        else { throw TeamKeyError.decryptFailed }

        let tag = combined.suffix(tagLength)
        let ct = combined.prefix(combined.count - tagLength)

        do {
            let sealedNonce = try ChaChaPoly.Nonce(data: nonceData)
            let box = try ChaChaPoly.SealedBox(nonce: sealedNonce, ciphertext: ct, tag: tag)
            let plainData = try ChaChaPoly.open(box, using: key)
            guard let text = String(data: plainData, encoding: .utf8) else { throw TeamKeyError.decryptFailed }
            return text
        } catch let error as TeamKeyError {
            throw error
        } catch {
            throw TeamKeyError.decryptFailed
        }
    }
}
