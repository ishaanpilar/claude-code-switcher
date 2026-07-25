import Foundation

/// Turn-count attribution: "who is consuming how much" is answered by counting prompts, not by
/// tracking wall-clock claim time. A Claude Code `UserPromptSubmit` hook POSTs one row per prompt
/// to the `log_turn` RPC. This file is the app side of that: installing and removing the hook with
/// consent, and keeping the small state file the script reads up to date.
///
/// A standalone shell script rather than a route through `ccswitch-core`, because it runs on every
/// prompt submission and isn't Claude Code credential I/O (the one thing the Python core is
/// reserved for). It's this app's own Supabase session talking to its own backend, so a plain
/// `curl` script avoids a `uv run` cold start per prompt.
enum AttributionHookService {
    private static var claudeDir: URL {
        let configPath = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? (NSHomeDirectory() + "/.claude")
        return URL(fileURLWithPath: configPath)
    }
    private static var hooksDir: URL { claudeDir.appendingPathComponent("hooks") }
    private static var scriptURL: URL { hooksDir.appendingPathComponent("ccswitch-log-turn.sh") }
    private static var settingsURL: URL { claudeDir.appendingPathComponent("settings.json") }

    /// `~/.ccswitch/session.env`: small, `chmod 600`, shell-sourceable key=value pairs. Not JSON,
    /// because the hook script must parse it with no dependency beyond `/bin/sh` (a fresh Mac has
    /// no guaranteed `jq`), and `. session.env` in a POSIX shell does that for free.
    private static var sessionStateURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ccswitch/session.env")
    }

    private static let scriptContents = """
    #!/bin/sh
    # Installed by Claude Code Switcher. Fires on every UserPromptSubmit: reads the current
    # Supabase session and active pool account from session.env, which the app keeps fresh,
    # then logs one turn. Best-effort, so missing state or a network failure exits 0
    # silently rather than interrupting the prompt.
    set -eu
    STATE="$HOME/.ccswitch/session.env"
    [ -f "$STATE" ] || exit 0
    . "$STATE"
    [ -n "${CCSWITCH_ACCESS_TOKEN:-}" ] && [ -n "${CCSWITCH_TEAM_ID:-}" ] || exit 0

    ACCOUNT_JSON="null"
    if [ -n "${CCSWITCH_ACTIVE_ACCOUNT_ID:-}" ]; then
      ACCOUNT_JSON="\\"${CCSWITCH_ACTIVE_ACCOUNT_ID}\\""
    fi

    curl -s -o /dev/null -m 3 -X POST "${CCSWITCH_SUPABASE_URL}/rest/v1/rpc/log_turn" \\
      -H "apikey: ${CCSWITCH_SUPABASE_ANON_KEY}" \\
      -H "Authorization: Bearer ${CCSWITCH_ACCESS_TOKEN}" \\
      -H "Content-Type: application/json" \\
      -d "{\\"p_team\\":\\"${CCSWITCH_TEAM_ID}\\",\\"p_account\\":${ACCOUNT_JSON},\\"p_event\\":\\"prompt_submit\\"}" \\
      >/dev/null 2>&1 &
    exit 0
    """

    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: scriptURL.path) else { return false }
        return hookEntryPresent(in: readSettings())
    }

    /// Writes the script and merges the hook entry into `settings.json`, never overwriting
    /// unrelated hooks the user or another tool already configured there.
    static func install() throws {
        try FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        var settings = readSettings()
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        var promptSubmit = (hooks["UserPromptSubmit"] as? [[String: Any]]) ?? []
        if !hookEntryPresent(in: settings) {
            promptSubmit.append([
                "matcher": "",
                "hooks": [["type": "command", "command": scriptURL.path]],
            ])
        }
        hooks["UserPromptSubmit"] = promptSubmit
        settings["hooks"] = hooks
        try writeSettings(settings)
    }

    /// Removes only our hook entry, matched on command path, plus the script file. Any other hooks
    /// in `settings.json` are left untouched.
    static func uninstall() throws {
        var settings = readSettings()
        if var hooks = settings["hooks"] as? [String: Any],
           var promptSubmit = hooks["UserPromptSubmit"] as? [[String: Any]] {
            promptSubmit.removeAll { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { ($0["command"] as? String) == scriptURL.path }
            }
            hooks["UserPromptSubmit"] = promptSubmit
            settings["hooks"] = hooks
            try writeSettings(settings)
        }
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: sessionStateURL)
    }

    private static func hookEntryPresent(in settings: [String: Any]) -> Bool {
        guard let hooks = settings["hooks"] as? [String: Any],
              let promptSubmit = hooks["UserPromptSubmit"] as? [[String: Any]]
        else { return false }
        return promptSubmit.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { ($0["command"] as? String) == scriptURL.path }
        }
    }

    private static func readSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: settingsURL, options: .atomic)
    }

    // MARK: - Session state the hook script reads

    /// Called whenever any state the hook needs might have changed: a token refresh, a team
    /// switch, an active-account switch. Cheap and idempotent, so callers don't diff first.
    static func writeSessionState(accessToken: String, teamId: UUID, activeAccountId: UUID?) {
        let lines = [
            "CCSWITCH_SUPABASE_URL=\(SupabaseConfig.projectURL.absoluteString)",
            "CCSWITCH_SUPABASE_ANON_KEY=\(SupabaseConfig.publishableKey)",
            "CCSWITCH_ACCESS_TOKEN=\(accessToken)",
            "CCSWITCH_TEAM_ID=\(teamId.uuidString)",
            "CCSWITCH_ACTIVE_ACCOUNT_ID=\(activeAccountId?.uuidString ?? "")",
        ]
        let contents = lines.joined(separator: "\n") + "\n"
        let dir = sessionStateURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? contents.write(to: sessionStateURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sessionStateURL.path)
    }

    static func clearSessionState() {
        try? FileManager.default.removeItem(at: sessionStateURL)
    }
}
