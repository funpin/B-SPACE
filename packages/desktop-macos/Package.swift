// swift-tools-version: 6.0
import PackageDescription

// The native macOS client (docs/superpowers/plans/2026-11-16-macos-native-client.md).
//
//   BSpaceCore     logic with no AppKit or WebKit in it, covered by tests
//   BSpaceShell    the window, the web view and the bridge
//   BSpaceApp      the application: starts BSpaceShell (scripts/bundle.sh wraps it)
//   ContractCheck  drives BSpaceShell through the bridge contract check
//   WebKitProbe    the measuring harness of the stage 0 pre-audit
//   CaptureProbe   the stage 4 experiment: does a system audio capture that
//                  excludes the application leave out what its web view plays
let package = Package(
    name: "BSpaceMac",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "BSpaceCore",
            path: "Sources/BSpaceCore"
        ),
        .target(
            name: "BSpaceShell",
            dependencies: ["BSpaceCore"],
            path: "Sources/BSpaceShell"
        ),
        .executableTarget(
            name: "BSpaceApp",
            dependencies: ["BSpaceShell"],
            path: "Sources/BSpaceApp"
        ),
        .executableTarget(
            name: "ContractCheck",
            dependencies: ["BSpaceCore", "BSpaceShell"],
            path: "Sources/ContractCheck"
        ),
        .testTarget(
            name: "BSpaceCoreTests",
            dependencies: ["BSpaceCore"],
            path: "Tests/BSpaceCoreTests",
            // A LevelDB database written by the real library
            // (scripts/make-leveldb-fixture.mjs).
            resources: [.copy("Fixtures")]
        ),
        .target(
            name: "ProbeSupport",
            path: "Sources/ProbeSupport"
        ),
        .executableTarget(
            name: "WebKitProbe",
            dependencies: ["ProbeSupport"],
            path: "Sources/WebKitProbe"
        ),
        .executableTarget(
            name: "CaptureProbe",
            dependencies: ["ProbeSupport"],
            path: "Sources/CaptureProbe"
        ),
        .testTarget(
            name: "ProbeSupportTests",
            dependencies: ["ProbeSupport"],
            path: "Tests/ProbeSupportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
