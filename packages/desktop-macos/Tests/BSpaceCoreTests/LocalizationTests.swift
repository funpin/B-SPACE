import Foundation
import Testing
@testable import BSpaceCore

/// `packages/desktop/src/desktopStrings.json`, found from this file's place in
/// the repository: the tests read the catalog both shells use, not a copy.
private let catalogURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent() // BSpaceCoreTests
    .deletingLastPathComponent() // Tests
    .deletingLastPathComponent() // desktop-macos
    .deletingLastPathComponent() // packages
    .appendingPathComponent("desktop/src/desktopStrings.json")

private func repositoryStrings() throws -> DesktopStrings {
    try DesktopStrings(data: Data(contentsOf: catalogURL))
}

/// The repository catalog with something changed in it.
private func catalog(_ edit: (inout [String: [String: String]]) -> Void) throws -> Data {
    var decoded = try JSONDecoder().decode([String: [String: String]].self, from: Data(contentsOf: catalogURL))
    edit(&decoded)
    return try JSONEncoder().encode(decoded)
}

@Suite struct DesktopLanguageTests {
    @Test func listsTheLanguagesOfTheCatalogEnglishFirst() throws {
        let strings = try repositoryStrings()
        #expect(strings.languages.map(\.code) == ["en", "de", "pt", "ru", "zh"])
        #expect(strings.english.code == "en")
    }

    @Test func aLanguageAddedToTheCatalogIsALanguageOfTheShell() throws {
        let strings = try DesktopStrings(data: try catalog { $0["fr"] = $0["en"] })
        #expect(strings.languages.map(\.code) == ["en", "de", "fr", "pt", "ru", "zh"])
        #expect(strings.language(tag: "fr-CA")?.code == "fr")
    }

    @Test func knowsOnlyTheLanguagesItHasStringsFor() throws {
        let strings = try repositoryStrings()
        #expect(strings.language(code: "ru")?.code == "ru")
        #expect(strings.language(code: "fr") == nil)
        #expect(strings.language(code: "RU") == nil)
        #expect(strings.language(code: "") == nil)
        #expect(strings.language(code: nil) == nil)
    }

    @Test func takesTheBaseOfALanguageTag() throws {
        let strings = try repositoryStrings()
        #expect(strings.language(tag: "de-AT")?.code == "de")
        #expect(strings.language(tag: "zh-Hans-CN")?.code == "zh")
        #expect(strings.language(tag: "pt_BR")?.code == "pt")
        #expect(strings.language(tag: " RU ")?.code == "ru")
        #expect(strings.language(tag: "fr-FR") == nil)
        #expect(strings.language(tag: "") == nil)
        #expect(strings.language(tag: nil) == nil)
    }

    @Test func prefersTheStoredChoiceThenTheSystemThenEnglish() throws {
        let strings = try repositoryStrings()
        #expect(strings.resolve(stored: "ru", systemLanguage: "de-DE").code == "ru")
        #expect(strings.resolve(stored: nil, systemLanguage: "de-DE").code == "de")
        #expect(strings.resolve(stored: "fr", systemLanguage: "de-DE").code == "de")
        #expect(strings.resolve(stored: nil, systemLanguage: "fr-FR").code == "en")
        #expect(strings.resolve(stored: nil, systemLanguage: nil).code == "en")
    }

    @Test func remembersTheLanguageInElectronsFile() throws {
        let strings = try repositoryStrings()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bspace-language-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LanguageStore(directory: directory)

        #expect(store.load() == nil)
        try store.save(try #require(strings.language(code: "pt")))
        #expect(store.load() == "pt")
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == #"{"language":"pt"}"#)

        try Data(#"{"language":7}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
        try Data("not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)
    }
}

@Suite struct DesktopStringsTests {
    @Test func readsTheRepositoryCatalog() throws {
        let strings = try repositoryStrings()
        let english = strings.english
        let russian = try #require(strings.language(code: "ru"))
        let german = try #require(strings.language(code: "de"))
        #expect(strings.text(.editMenu, in: english) == "Edit")
        #expect(strings.text(.editMenu, in: russian) == "Правка")
        #expect(strings.text(.changeInstance, in: german) == "Instanz wechseln")
        #expect(strings.text(.quit, in: english, ["name": "B:SPACE"]) == "Quit B:SPACE")
        #expect(strings.text(.quit, in: russian, ["name": "B:SPACE"]) == "Завершить B:SPACE")
        #expect(strings.text(.hide, in: german, ["name": "B:SPACE"]) == "B:SPACE ausblenden")
    }

    @Test func leavesAPlaceholderWithNoValueAsWritten() throws {
        let strings = try repositoryStrings()
        #expect(strings.text(.about, in: strings.english) == "About {name}")
        #expect(strings.text(.copy, in: strings.english, ["name": "B:SPACE"]) == "Copy")
    }

    @Test func hasATextForEveryKeyInEveryLanguage() throws {
        let strings = try repositoryStrings()
        for language in strings.languages {
            for key in DesktopStrings.Key.allCases {
                let text = strings.text(key, in: language)
                #expect(!text.isEmpty && text != key.rawValue, "\(language.code): \(key.rawValue)")
            }
        }
    }

    @Test func hasThePermissionTextsInEveryLanguage() throws {
        let strings = try repositoryStrings()
        let english = strings.permissionTexts(in: strings.english)
        #expect(english.keys.sorted() == [
            "NSAudioCaptureUsageDescription", "NSCameraUsageDescription", "NSMicrophoneUsageDescription",
        ])
        for language in strings.languages where language != strings.english {
            let texts = strings.permissionTexts(in: language)
            #expect(texts.keys.sorted() == english.keys.sorted(), "\(language.code)")
            // A translation, not the English text again.
            #expect(texts.allSatisfy { $0.value != english[$0.key] && $0.value.contains("B:SPACE") }, "\(language.code)")
        }
    }

    @Test func refusesACatalogThatWouldLeaveSomethingWithoutItsText() throws {
        #expect(throws: DesktopStrings.Failure(description: "the string catalog has no 'en'")) {
            try DesktopStrings(data: try catalog { $0["en"] = nil })
        }
        #expect(throws: DesktopStrings.Failure(description: "'de' lacks mac.menu.paste")) {
            try DesktopStrings(data: try catalog { $0["de"]?["mac.menu.paste"] = nil })
        }
        #expect(throws: DesktopStrings.Failure(description: "'ru' lacks menu.edit")) {
            try DesktopStrings(data: try catalog { $0["ru"]?["menu.edit"] = "" })
        }
        #expect(throws: DesktopStrings.Failure(description: "'zh' lacks mac.permission.NSCameraUsageDescription")) {
            try DesktopStrings(data: try catalog { $0["zh"]?["mac.permission.NSCameraUsageDescription"] = nil })
        }
        #expect(throws: DesktopStrings.Failure.self) {
            try DesktopStrings(data: Data("[]".utf8))
        }
    }
}

@Suite struct SourceCodeTests {
    @Test func asksTheInstanceItWasLoadedFrom() {
        #expect(SourceCode.instanceInfoURL(instanceAddress: "https://chat.example.test/channels/1")?.absoluteString
            == "https://chat.example.test/api/instance/info")
        #expect(SourceCode.instanceInfoURL(instanceAddress: "http://192.168.1.20:3000")?.absoluteString
            == "http://192.168.1.20:3000/api/instance/info")
        #expect(SourceCode.instanceInfoURL(instanceAddress: "file:///Applications/picker.html") == nil)
        #expect(SourceCode.instanceInfoURL(instanceAddress: nil) == nil)
    }

    @Test func takesTheAddressTheInstanceNames() {
        func address(_ json: String) -> String {
            SourceCode.address(fromInstanceInfo: Data(json.utf8))
        }
        #expect(address(#"{"sourceCodeUrl":"https://git.example.test/fork"}"#) == "https://git.example.test/fork")
        #expect(address(#"{"sourceCodeUrl":"HTTP://git.example.test/fork"}"#) == "HTTP://git.example.test/fork")
    }

    @Test func fallsBackToTheProjectsOwn() {
        func address(_ json: String) -> String {
            SourceCode.address(fromInstanceInfo: Data(json.utf8))
        }
        #expect(address(#"{"sourceCodeUrl":"javascript:alert(1)"}"#) == SourceCode.projectAddress)
        #expect(address(#"{"sourceCodeUrl":"file:///etc/passwd"}"#) == SourceCode.projectAddress)
        #expect(address(#"{"sourceCodeUrl":42}"#) == SourceCode.projectAddress)
        #expect(address(#"{"name":"an instance"}"#) == SourceCode.projectAddress)
        #expect(address("not json") == SourceCode.projectAddress)
        #expect(SourceCode.address(fromInstanceInfo: nil) == SourceCode.projectAddress)
    }
}
