import Foundation
import Testing
@testable import BSpaceCore

private final class FakeLoginItem: LoginItem {
    var isEnabled: Bool
    var refuses = false
    private(set) var requests: [Bool] = []

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
    }

    struct Refused: Error {}

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if refuses { throw Refused() }
        isEnabled = enabled
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("bspace-launch-\(UUID().uuidString)", isDirectory: true)
}

@Suite struct AutoLaunchStoreTests {
    @Test func startsFromElectronsDefaults() {
        let store = AutoLaunchStore(directory: temporaryDirectory())
        #expect(store.load() == AutoLaunchSettings(openAtLogin: false, startMinimized: true))
    }

    @Test func readsAndWritesElectronsFile() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutoLaunchStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(#"{"openAtLogin":true,"startMinimized":false}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == AutoLaunchSettings(openAtLogin: true, startMinimized: false))

        try store.save(AutoLaunchSettings(openAtLogin: false, startMinimized: true))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"openAtLogin":false,"startMinimized":true}"#)
    }

    @Test func takesTheDefaultForAFieldThatIsNotABoolean() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AutoLaunchStore(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try Data(#"{"openAtLogin":1,"startMinimized":"no"}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == .default)
        try Data(#"{"startMinimized":false}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == AutoLaunchSettings(openAtLogin: false, startMinimized: false))
        try Data("[]".utf8).write(to: store.fileURL)
        #expect(store.load() == .default)
    }
}

@Suite struct AutoLaunchTests {
    private func make(enabled: Bool = false) -> (AutoLaunch, FakeLoginItem, AutoLaunchStore, URL) {
        let directory = temporaryDirectory()
        let store = AutoLaunchStore(directory: directory)
        let item = FakeLoginItem(isEnabled: enabled)
        return (AutoLaunch(store: store, loginItem: item), item, store, directory)
    }

    @Test func readsOpeningAtLoginFromTheSystemAndTheRestFromTheFile() throws {
        let (autoLaunch, item, store, directory) = make(enabled: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // The file's copy of openAtLogin is stale on purpose: it is not read.
        try store.save(AutoLaunchSettings(openAtLogin: false, startMinimized: false))

        #expect(autoLaunch.current == AutoLaunchSettings(openAtLogin: true, startMinimized: false))
        item.isEnabled = false
        #expect(autoLaunch.current == AutoLaunchSettings(openAtLogin: false, startMinimized: false))
    }

    @Test func changesOnlyTheFieldsThatAreGiven() {
        let (autoLaunch, item, store, directory) = make()
        defer { try? FileManager.default.removeItem(at: directory) }

        var result = autoLaunch.update(openAtLogin: true, startMinimized: nil)
        #expect(result.settings == AutoLaunchSettings(openAtLogin: true, startMinimized: true))
        #expect(result.failure == nil)
        #expect(item.requests == [true])

        result = autoLaunch.update(openAtLogin: nil, startMinimized: false)
        #expect(result.settings == AutoLaunchSettings(openAtLogin: true, startMinimized: false))
        #expect(store.load() == AutoLaunchSettings(openAtLogin: true, startMinimized: false))
        // The system was not asked again: opening at login did not change.
        #expect(item.requests == [true])

        result = autoLaunch.update(openAtLogin: true, startMinimized: nil)
        #expect(item.requests == [true])
        result = autoLaunch.update(openAtLogin: nil, startMinimized: nil)
        #expect(result.settings == AutoLaunchSettings(openAtLogin: true, startMinimized: false))
        #expect(item.requests == [true])

        result = autoLaunch.update(openAtLogin: false, startMinimized: true)
        #expect(result.settings == AutoLaunchSettings(openAtLogin: false, startMinimized: true))
        #expect(item.requests == [true, false])
    }

    @Test func answersWithWhatTheSystemSaysWhenItRefuses() {
        let (autoLaunch, item, store, directory) = make()
        defer { try? FileManager.default.removeItem(at: directory) }
        item.refuses = true

        let result = autoLaunch.update(openAtLogin: true, startMinimized: false)
        #expect(result.settings == AutoLaunchSettings(openAtLogin: false, startMinimized: false))
        #expect(result.failure is FakeLoginItem.Refused)
        // The part that does not need the system is kept all the same.
        #expect(store.load().startMinimized == false)
    }
}

@Suite struct LaunchModeTests {
    @Test func startsHiddenWhenToldToOrWhenOpenedAtLoginMinimized() {
        func hidden(_ arguments: [String], atLogin: Bool, minimized: Bool) -> Bool {
            LaunchMode.startsHidden(arguments: arguments, launchedAtLogin: atLogin, startMinimized: minimized)
        }
        #expect(!hidden([], atLogin: false, minimized: true))
        #expect(hidden([], atLogin: true, minimized: true))
        #expect(!hidden([], atLogin: true, minimized: false))
        #expect(hidden(["--hidden"], atLogin: false, minimized: false))
        #expect(!hidden(["--hiddenish", "hidden"], atLogin: false, minimized: false))
    }
}

@Suite struct DeepLinkTests {
    @Test func acceptsOnlyTheAppsOwnLinks() {
        #expect(DeepLink.accepts("backspace://join/abc123"))
        #expect(DeepLink.accepts("Backspace://channel/1/2"))
        #expect(!DeepLink.accepts("backspace:join/abc123"))
        #expect(!DeepLink.accepts("https://backspace://join"))
        #expect(!DeepLink.accepts(" backspace://join/abc123"))
        #expect(!DeepLink.accepts(""))
    }

    @Test func findsALinkAmongArguments() {
        #expect(DeepLink.first(in: ["--hidden", "backspace://join/a", "backspace://join/b"]) == "backspace://join/a")
        #expect(DeepLink.first(in: ["--hidden", "-psn_0_1"]) == nil)
    }

    @Test func readsWhetherTheBundleOpensLinks() {
        let declared: [String: Any] = [
            "CFBundleURLTypes": [
                ["CFBundleURLName": "Other", "CFBundleURLSchemes": ["other"]],
                ["CFBundleURLName": "B:SPACE", "CFBundleURLSchemes": ["backspace"]],
            ],
        ]
        #expect(DeepLink.isDeclared(infoDictionary: declared))
        #expect(!DeepLink.isDeclared(infoDictionary: ["CFBundleURLTypes": [["CFBundleURLSchemes": ["other"]]]]))
        #expect(!DeepLink.isDeclared(infoDictionary: [:]))
        #expect(!DeepLink.isDeclared(infoDictionary: nil))
    }

    @Test func holdsALinkUntilThePageListens() {
        var inbox = DeepLinkInbox()
        #expect(inbox.receive("backspace://join/one") == nil)
        // A newer link replaces one that was still waiting.
        #expect(inbox.receive("backspace://join/two") == nil)
        #expect(inbox.listenerAppeared() == "backspace://join/two")
        // Delivered once: a second subscription gets nothing.
        #expect(inbox.listenerAppeared() == nil)
        #expect(inbox.receive("backspace://join/three") == "backspace://join/three")
    }

    @Test func holdsAgainWhenThePageIsReplaced() {
        var inbox = DeepLinkInbox()
        _ = inbox.listenerAppeared()
        inbox.pageChanged()
        #expect(inbox.receive("backspace://channel/1/2") == nil)
        #expect(inbox.listenerAppeared() == "backspace://channel/1/2")
    }

    @Test func dropsWhatIsNotALink() {
        var inbox = DeepLinkInbox()
        #expect(inbox.receive("https://example.test/") == nil)
        #expect(inbox.listenerAppeared() == nil)
        #expect(inbox.receive("javascript:alert(1)") == nil)
    }
}

@Suite struct SingleInstanceTests {
    private let early = Date(timeIntervalSince1970: 1_000)
    private let late = Date(timeIntervalSince1970: 2_000)

    @Test func keepsTheCopyThatStartedFirst() {
        let first = RunningInstance(processIdentifier: 900, startTime: early)
        let second = RunningInstance(processIdentifier: 100, startTime: late)
        #expect(SingleInstance.survivor(of: [first, second]) == first)
        #expect(SingleInstance.survivor(of: [second, first]) == first)
    }

    @Test func breaksATieTheSameWayFromBothSides() {
        let lower = RunningInstance(processIdentifier: 100, startTime: early)
        let higher = RunningInstance(processIdentifier: 200, startTime: early)
        #expect(SingleInstance.survivor(of: [lower, higher]) == lower)
        #expect(SingleInstance.survivor(of: [higher, lower]) == lower)

        let unknownLower = RunningInstance(processIdentifier: 100, startTime: nil)
        let unknownHigher = RunningInstance(processIdentifier: 200, startTime: nil)
        #expect(SingleInstance.survivor(of: [unknownHigher, unknownLower]) == unknownLower)
    }

    @Test func prefersAKnownStartTimeToAnUnknownOne() {
        let known = RunningInstance(processIdentifier: 900, startTime: late)
        let unknown = RunningInstance(processIdentifier: 100, startTime: nil)
        #expect(SingleInstance.survivor(of: [unknown, known]) == known)
        #expect(SingleInstance.survivor(of: []) == nil)
    }

    @Test func namesItsNotificationAfterTheBundle() {
        #expect(SingleInstance.notificationName(bundleIdentifier: "com.backspace.desktop.dev") == "com.backspace.desktop.dev.second-instance")
    }
}
