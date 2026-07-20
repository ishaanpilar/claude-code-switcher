// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeCodeSwitcher",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Auth (magic-link sign-in), PostgREST (accounts/claims/usage tables), and Realtime
        // (live sync — BUILD_PLAN.md section 3d) all come from this one umbrella package.
        .package(url: "https://github.com/supabase/supabase-swift.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "ClaudeCodeSwitcher",
            dependencies: [
                .product(name: "Supabase", package: "supabase-swift")
            ],
            path: "Sources/ClaudeCodeSwitcher"
        )
    ]
)
