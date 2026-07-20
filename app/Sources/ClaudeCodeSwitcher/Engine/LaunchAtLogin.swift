import Foundation
import ServiceManagement

/// "Launch at login" via `SMAppService` (BUILD_PLAN.md Phase 0 mentioned this as a scaffolding
/// item; wired up now that there's a Settings surface for it). Reflects the *actual* registered
/// state rather than a preference that could drift from it — `isEnabled` reads the live status.
///
/// Requires a real signed `.app` bundle to register (see `scripts/build_app_bundle.sh`); from a
/// bare `swift run` binary `register()` throws, which `set` surfaces to the caller rather than
/// pretending it worked.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
