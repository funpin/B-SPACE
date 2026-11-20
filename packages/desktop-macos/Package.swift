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
//   StreamProbe    the stage 4 experiment of plan section 12: publish a screen
//                  share into a LiveKit room from the shell's own capture
let package = Package(
    name: "BSpaceMac",
    // The app is released for macOS 26 and newer: the bundle's
    // LSMinimumSystemVersion (scripts/bundle.sh) is what says so to the
    // system. The package is built for 15, the newest this file can name
    // with the toolchains it is built by (Swift 6.0 tools, an SDK of 15.5
    // on the development machine), and old enough for a CI runner on 15 to
    // run the tests.
    platforms: [.macOS(.v15)],
    dependencies: [
        // LiveKit's client library (Apache-2.0): the shell's own connection
        // to a call, with WebRTC and its hardware encoders inside. This is
        // the project's fork of it: release 2.19.0 with three additions the
        // shell's screen share needs (a screen share audio track, a bitrate
        // floor, a new encoding for a published track; the fork's FORK.md
        // says what and why). Pinned to a commit of its `b-space` branch.
        .package(
            url: "https://github.com/funpin/client-sdk-swift.git",
            revision: "2be5bece6cd8db7ca5d6be3c01ff79e573f61989"
        ),
    ],
    targets: [
        .target(
            name: "BSpaceCore",
            path: "Sources/BSpaceCore"
        ),
        .target(
            name: "BSpaceShell",
            dependencies: [
                "BSpaceCore",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
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
        .executableTarget(
            name: "StreamProbe",
            dependencies: [
                "BSpaceCore", "BSpaceShell",
                .product(name: "LiveKit", package: "client-sdk-swift"),
            ],
            path: "Sources/StreamProbe"
        ),
        .testTarget(
            name: "ProbeSupportTests",
            dependencies: ["ProbeSupport"],
            path: "Tests/ProbeSupportTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
