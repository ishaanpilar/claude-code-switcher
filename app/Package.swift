// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeCodeSwitcher",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auth (magic-link sign-in), PostgREST (accounts/claims/usage tables), and Realtime
        // (live sync — BUILD_PLAN.md section 3d) all come from this one umbrella package.
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0"),
        // Auto-update (Check for Updates…, About pane) — see Engine/UpdaterProvider.swift and
        // app/appcast.xml for the feed this reads.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeSwitcher",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/ClaudeCodeSwitcher",
            linkerSettings: [
                // Sparkle ships as a dynamic framework. `swift build` alone only resolves it
                // relative to .build/ — fine for `swift run`, but build_app_bundle.sh relocates
                // the binary into Contents/MacOS/, so it needs this extra rpath pointing at the
                // standard app-bundle Contents/Frameworks/ location that script copies
                // Sparkle.framework into.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
            ]
        )
    ]
)
