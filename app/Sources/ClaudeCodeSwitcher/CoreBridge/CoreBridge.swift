import Foundation

/// Spawns `ccswitch-core` as a short-lived subprocess, one command per call, and decodes its
/// single-line JSON response. This is the entire boundary between the Swift decision layer and the
/// Python credential layer: all credential I/O in Python, all decisions in Swift. Nothing outside
/// this file should know how that subprocess is invoked.
///
/// Plaintext tokens cross this boundary on stdin only, never as an argument, since arguments are
/// visible to any process on the machine via `ps`.
actor CoreBridge {
    enum Location {
        /// A bundled, PyInstaller-built standalone binary: the packaged-app shape. No Python
        /// runtime required on the user's machine.
        case bundled(URL)
        /// Development shape: shells out to `uv run python -m ccswitch_core` inside `core/`.
        case devViaUV(coreDir: URL)
    }

    struct Config {
        var location: Location
    }

    private let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Resolves the core's location: a bundled binary first (the `CCSWITCH_CORE_BIN` override,
    /// then `Bundle.main.resourceURL`), else the dev `uv run` path (the `CCSWITCH_CORE_DIR`
    /// override, else `<repo>/core` found by walking up from the working directory, which is the
    /// layout `swift run` from `app/` produces).
    static func resolveDefault() -> CoreBridge {
        let env = ProcessInfo.processInfo.environment

        if let binPath = env["CCSWITCH_CORE_BIN"] {
            return CoreBridge(config: .init(location: .bundled(URL(fileURLWithPath: binPath))))
        }
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appendingPathComponent("ccswitch-core")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return CoreBridge(config: .init(location: .bundled(candidate)))
            }
        }
        if let devDir = env["CCSWITCH_CORE_DIR"] {
            return CoreBridge(config: .init(location: .devViaUV(coreDir: URL(fileURLWithPath: devDir))))
        }

        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for candidate in [cwd.appendingPathComponent("core"), cwd.deletingLastPathComponent().appendingPathComponent("core")] {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("pyproject.toml").path) {
                return CoreBridge(config: .init(location: .devViaUV(coreDir: candidate)))
            }
        }

        // Last resort: errors specifically the first time a command runs, rather than failing here
        // where nothing has requested anything yet.
        return CoreBridge(config: .init(location: .devViaUV(coreDir: cwd.appendingPathComponent("core"))))
    }

    /// Runs one `ccswitch-core` command. `stdin`, when provided, is written and closed before
    /// waiting on output; it's the only channel a plaintext token travels on locally. Throws
    /// `CoreBridgeError` for a structured `{"ok": false, ...}` response, or a generic error for a
    /// process-level failure such as a failed launch or non-JSON output.
    func run(_ arguments: [String], stdin: String? = nil) async throws -> Data {
        let process = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        switch config.location {
        case .bundled(let binURL):
            process.executableURL = binURL
            process.arguments = arguments
        case .devViaUV(let coreDir):
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["uv", "run", "python", "-m", "ccswitch_core"] + arguments
            process.currentDirectoryURL = coreDir
        }

        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        if let stdin, let data = stdin.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try stdinPipe.fileHandleForWriting.close()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        let stderrData = try stderrPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        guard let lastLine = lastNonEmptyLine(of: stdoutData) else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw CoreBridgeError(
                code: "no_output",
                message: "ccswitch-core produced no output (exit \(process.terminationStatus)): \(stderrText)"
            )
        }

        let envelope = try JSONDecoder().decode(CoreEnvelope.self, from: lastLine)
        if !envelope.ok {
            let err = envelope.error ?? CoreErrorPayload(code: "unknown", message: "ccswitch-core reported failure with no error detail")
            throw CoreBridgeError(code: err.code, message: err.message)
        }
        return lastLine
    }

    /// stdout should be exactly one JSON line, but logging or a stray print could add noise, so
    /// take the last non-blank line rather than assuming byte-perfect output.
    private func lastNonEmptyLine(of data: Data) -> Data? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let line = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        return Data(line.utf8)
    }
}

// MARK: - Typed command wrappers

extension CoreBridge {
    func snapshot() async throws -> Snapshot {
        let data = try await run(["snapshot"])
        return try JSONDecoder().decode(SnapshotEnvelope.self, from: data).asSnapshot
    }

    @discardableResult
    func addCurrent() async throws -> AccountIdentity {
        let data = try await run(["add-current"])
        return try JSONDecoder().decode(AccountEnvelope.self, from: data).account
    }

    @discardableResult
    func switchTo(accountUuid: String) async throws -> AccountIdentity {
        let data = try await run(["switch", "--account-uuid", accountUuid])
        return try JSONDecoder().decode(AccountEnvelope.self, from: data).account
    }

    /// `token` is plaintext: the caller must already have decrypted it from Supabase's ciphertext.
    /// Never logged, never placed in `arguments`.
    @discardableResult
    func importActivate(accountUuid: String, token: String, email: String?, organizationUuid: String?) async throws -> AccountIdentity {
        var args = ["import-activate", "--account-uuid", accountUuid]
        if let email { args += ["--email", email] }
        if let organizationUuid { args += ["--organization-uuid", organizationUuid] }
        let data = try await run(args, stdin: token)
        return try JSONDecoder().decode(AccountEnvelope.self, from: data).account
    }

    func exportToken(accountUuid: String) async throws -> String {
        let data = try await run(["export-token", "--account-uuid", accountUuid])
        return try JSONDecoder().decode(TokenEnvelope.self, from: data).token
    }

    func readUsage(accountUuid: String) async throws -> Usage {
        let data = try await run(["read-usage", "--account-uuid", accountUuid])
        return try JSONDecoder().decode(UsageEnvelope.self, from: data).usage
    }

    /// Same command with the token supplied directly rather than looked up from local backup. Lets
    /// the poll leader read usage for a shared account it decrypted with the team key but never
    /// captured locally, without having to import-activate it first.
    func readUsage(token: String) async throws -> Usage {
        let data = try await run(["read-usage"], stdin: token)
        return try JSONDecoder().decode(UsageEnvelope.self, from: data).usage
    }

    /// Refreshes a plaintext OAuth token given on stdin, for the auto-switch engine's freshen
    /// step: a candidate's stored token may be minutes from expiring by the time it's switched
    /// onto. A thrown `CoreBridgeError` carries the core's classification as `.code`
    /// (`invalid_grant` for a dead refresh-token lineage, `transient` for network trouble), so
    /// callers switch on that rather than string-matching the message.
    func refreshToken(_ token: String) async throws -> RefreshedToken {
        let data = try await run(["refresh-token"], stdin: token)
        return try JSONDecoder().decode(RefreshedToken.self, from: data)
    }

    /// Persists a token as `accountUuid`'s local backup without activating it: no
    /// `~/.claude.json` write, no Claude Code lock held. Called immediately after a successful
    /// `refreshToken` and before attempting to activate. A refresh token is typically single-use,
    /// so if the refreshed credential isn't saved first, a failed activate discards the only valid
    /// copy and every later attempt reads back the already-consumed one. That is what turns "a
    /// lock was briefly held" into "this account is permanently logged out".
    func saveCredentials(accountUuid: String, token: String) async throws {
        _ = try await run(["save-credentials", "--account-uuid", accountUuid], stdin: token)
    }

    @discardableResult
    func remove(accountUuid: String) async throws -> Bool {
        let data = try await run(["remove", "--account-uuid", accountUuid])
        return try JSONDecoder().decode(RemovedEnvelope.self, from: data).removed
    }
}

// Thin per-command decode targets, separate from CoreEnvelope because Codable can't decode "the
// rest of the fields after checking ok" in one pass without a nested container dance. These small
// purpose-built structs read more plainly.
private struct SnapshotEnvelope: Codable {
    let active: AccountIdentity?
    let knownAccounts: [KnownAccount]
    enum CodingKeys: String, CodingKey { case active; case knownAccounts = "known_accounts" }
    var asSnapshot: Snapshot { Snapshot(active: active, knownAccounts: knownAccounts) }
}
private struct AccountEnvelope: Codable { let account: AccountIdentity }
private struct TokenEnvelope: Codable { let token: String }
private struct UsageEnvelope: Codable { let usage: Usage }
private struct RemovedEnvelope: Codable { let removed: Bool }
