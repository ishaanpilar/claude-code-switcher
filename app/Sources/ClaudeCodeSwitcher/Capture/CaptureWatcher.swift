import Foundation

/// Watches `~/.claude.json` for changes and reports them to `onChange`, event-driven via
/// `DispatchSourceFileSystemObject`, the practical equivalent of FSEvents for a single file
/// (full FSEvents is a directory-tree API; this is the standard GCD idiom when only one file
/// matters, and it has the same zero-idle-cost property BUILD_PLAN.md section 3d calls for:
/// no polling timer at all).
///
/// This class only detects that the file changed. It does not decide whether the change is an
/// ordinary switch or a brand-new login. That decision (known vs. unknown account_uuid, the
/// debounce, the retry-on-not-yet-landed-credential) lives in `AutoCaptureController`, which
/// consumes this watcher's callback. Keeping them separate means the watcher stays a dumb,
/// reusable primitive.
final class CaptureWatcher {
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private let path: String
    private let onChange: () -> Void

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        stop()
        fileDescriptor = open(path, O_EVTONLY)
        guard fileDescriptor >= 0 else {
            // The file may not exist yet (nobody has ever logged in), so retry shortly rather
            // than giving up; a fresh login will create it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.start() }
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.main
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            self.onChange()
            if flags.contains(.delete) || flags.contains(.rename) {
                // The file was replaced rather than written-in-place (common for atomic
                // config writers, including our own switch.py), so the old descriptor no
                // longer tracks the new inode. Re-open onto the new file.
                self.start()
            }
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.fileDescriptor)
            self.fileDescriptor = -1
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    deinit { stop() }
}
