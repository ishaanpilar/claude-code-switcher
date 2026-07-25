import Foundation
import AppKit

/// Lightweight file logging for the About page's "Reveal logs" / bug-report flow. Appends
/// timestamped lines to `~/Library/Logs/Claude Code Switcher/ccswitch.log`, the standard place
/// a Mac user (or you, debugging a friend's install) would look. Deliberately records only app
/// events (switches, errors, lifecycle), never tokens or prompt contents, matching the rest of
/// the app.
enum Diagnostics {
    static let logDirectory: URL = {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("Logs/Claude Code Switcher", isDirectory: true)
    }()

    static var logFile: URL { logDirectory.appendingPathComponent("ccswitch.log") }

    private static let queue = DispatchQueue(label: "com.claudecodeswitcher.diagnostics")
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Fire-and-forget; serialized on its own queue so concurrent callers can't interleave a
    /// half-written line. Never throws, since logging must not be able to break a real action.
    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: logFile) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: logFile)
            }
        }
    }

    /// Opens the log folder in Finder (About page button). Ensures it exists first so the button
    /// never silently no-ops on a fresh install that hasn't logged anything yet.
    static func revealLogsInFinder() {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            try? Data().write(to: logFile)
        }
        NSWorkspace.shared.activateFileViewerSelecting([logFile])
    }
}
