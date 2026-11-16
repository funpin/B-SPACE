import Foundation
import Testing
@testable import BSpaceCore

@Suite struct UserAgentTests {
    private let sequoia = OperatingSystemVersion(majorVersion: 15, minorVersion: 5, patchVersion: 0)
    private let current = OperatingSystemVersion(majorVersion: 27, minorVersion: 2, patchVersion: 0)

    @Test func presentsTheInstalledSafari() {
        let name = UserAgent.applicationName(safariVersion: "27.2", systemVersion: current, appVersion: "2.4.0")
        #expect(name == "Version/27.2 Safari/605.1.15 BSpaceDesktop/2.4.0")
        let patched = UserAgent.applicationName(safariVersion: "18.5.1", systemVersion: sequoia, appVersion: "2.4.0")
        #expect(patched == "Version/18.5 Safari/605.1.15 BSpaceDesktop/2.4.0")
        let major = UserAgent.applicationName(safariVersion: "26", systemVersion: current, appVersion: "2.4.0")
        #expect(major == "Version/26.0 Safari/605.1.15 BSpaceDesktop/2.4.0")
    }

    @Test func fallsBackToTheSystemVersion() {
        #expect(UserAgent.applicationName(safariVersion: nil, systemVersion: current, appVersion: "2.4.0").hasPrefix("Version/27.2 "))
        #expect(UserAgent.applicationName(safariVersion: "unknown", systemVersion: sequoia, appVersion: "2.4.0").hasPrefix("Version/18.5 "))
    }

    @Test func keepsTheVersionASingleProductToken() {
        let name = UserAgent.applicationName(safariVersion: "27.2", systemVersion: current, appVersion: "2.4.0 (dev)/x")
        #expect(name.hasSuffix("BSpaceDesktop/2.4.0devx"))
        #expect(UserAgent.applicationName(safariVersion: "27.2", systemVersion: current, appVersion: "").hasSuffix("BSpaceDesktop/0"))
    }
}

@Suite struct AppIdentityTests {
    @Test func keepsTheInstalledAppsFolderUnlessABuildNamesAnother() {
        #expect(AppIdentity.userDataDirectoryName(infoDictionary: nil) == "Backspace")
        #expect(AppIdentity.userDataDirectoryName(infoDictionary: [:]) == "Backspace")
        #expect(AppIdentity.userDataDirectoryName(infoDictionary: ["BSpaceUserDataDirectory": "Backspace-Dev"]) == "Backspace-Dev")
    }

    @Test func refusesAFolderNameThatIsAPath() {
        for name in ["", "  ", "..", ".", "../Backspace", "a/b"] {
            #expect(AppIdentity.userDataDirectoryName(infoDictionary: ["BSpaceUserDataDirectory": name]) == "Backspace")
        }
        #expect(AppIdentity.userDataDirectoryName(infoDictionary: ["BSpaceUserDataDirectory": 7]) == "Backspace")
    }
}

@Suite struct InstanceURLStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("bspace-store-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func savesWhatElectronReadsAndReadsWhatElectronSaves() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = InstanceURLStore(directory: directory)

        #expect(store.load() == nil)
        try store.save("https://chat.example.com")
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"url":"https://chat.example.com"}"#)
        #expect(store.load() == "https://chat.example.com")

        // What `JSON.stringify({ url })` writes in the Electron build.
        try Data(#"{"url":"https://other.example.org"}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == "https://other.example.org")

        store.clear()
        #expect(store.load() == nil)
        store.clear()
    }

    @Test func readsNothingFromAFileItDidNotWrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = InstanceURLStore(directory: directory)

        for content in ["", "not json", "[]", "{}", #"{"url":7}"#, #"{"url":null}"#] {
            try Data(content.utf8).write(to: store.fileURL)
            #expect(store.load() == nil)
        }
    }

    @Test func loadsOnlyWebAddresses() {
        #expect(InstanceURLStore.loadableURL("https://chat.example.com")?.absoluteString == "https://chat.example.com")
        #expect(InstanceURLStore.loadableURL("http://192.168.1.20:3005") != nil)
        for address in ["", "chat.example.com", "file:///etc/passwd", "javascript:alert(1)", "https://", "backspace://join/x"] {
            #expect(InstanceURLStore.loadableURL(address) == nil)
        }
    }
}
