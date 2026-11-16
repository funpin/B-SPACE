// swift-tools-version: 6.0
import PackageDescription

// The native macOS client. For now this package holds only WebKitProbe, the
// measuring harness of the pre-audit (docs/superpowers/plans/2026-11-16-macos-native-client.md,
// stage 0). The application targets arrive with stage 1.
let package = Package(
    name: "BSpaceMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "ProbeSupport",
            path: "Sources/ProbeSupport"
        ),
        .executableTarget(
            name: "WebKitProbe",
            dependencies: ["ProbeSupport"],
            path: "Sources/WebKitProbe"
        ),
        .testTarget(
            name: "ProbeSupportTests",
            dependencies: ["ProbeSupport"],
            path: "Tests/ProbeSupportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
