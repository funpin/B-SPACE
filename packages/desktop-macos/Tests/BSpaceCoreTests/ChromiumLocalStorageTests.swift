import Foundation
import Testing
@testable import BSpaceCore

/// The fixture `scripts/make-leveldb-fixture.mjs` writes: a profile folder
/// whose `Local Storage/leveldb` was produced by the real LevelDB library.
private let chat = "https://chat.example.test"
private let lan = "http://192.168.1.20:3000"

private func fixtureDatabase() throws -> URL {
    let url = try #require(Bundle.module.resourceURL)
        .appendingPathComponent("Fixtures/chromium-local-storage/leveldb", isDirectory: true)
    try #require(FileManager.default.fileExists(atPath: url.appendingPathComponent("CURRENT").path))
    return url
}

/// A copy of the fixture laid out as a profile, for tests that damage it.
private func profileCopy() throws -> (profile: URL, database: URL) {
    let profile = FileManager.default.temporaryDirectory
        .appendingPathComponent("bspace-profile-\(UUID().uuidString)", isDirectory: true)
    let database = profile.appendingPathComponent(ChromiumLocalStorage.relativePath, isDirectory: true)
    try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: try fixtureDatabase(), to: database)
    return (profile, database)
}

private func fileNamed(_ suffix: String, in directory: URL) throws -> URL {
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    return directory.appendingPathComponent(try #require(names.first { $0.hasSuffix(suffix) || $0.hasPrefix(suffix) }))
}

private func flipByte(at offset: Int, of file: URL) throws {
    var data = try Data(contentsOf: file)
    data[offset] ^= 0xff
    try data.write(to: file)
}

@Suite struct SnappyTests {
    @Test func copiesLiterals() throws {
        #expect(try Snappy.decompress([5, 0x10] + Array("hello".utf8)) == Array("hello".utf8))
        #expect(try Snappy.decompress([0]) == [])
    }

    @Test func readsALiteralWithItsLengthInTheNextByte() throws {
        let text = [UInt8](repeating: 0x41, count: 100)
        #expect(try Snappy.decompress([100, 0xf0, 99] + text) == text)
    }

    @Test func repeatsEarlierBytesWithEveryKindOfCopy() throws {
        let expected = Array("abcabcabc".utf8)
        let literal: [UInt8] = [9, 0x08] + Array("abc".utf8)
        // Six bytes from three back: the copy overlaps what it writes.
        #expect(try Snappy.decompress(literal + [0x09, 0x03]) == expected)
        #expect(try Snappy.decompress(literal + [0x16, 0x03, 0x00]) == expected)
        #expect(try Snappy.decompress(literal + [0x17, 0x03, 0x00, 0x00, 0x00]) == expected)
    }

    @Test func refusesDamagedInput() {
        #expect(throws: Snappy.Failure.truncated) { try Snappy.decompress([]) }
        #expect(throws: Snappy.Failure.truncated) { try Snappy.decompress([5, 0x10, 0x68]) }
        #expect(throws: Snappy.Failure.badOffset) { try Snappy.decompress([4, 0x01, 0x01]) }
        #expect(throws: Snappy.Failure.wrongLength) { try Snappy.decompress([5, 0x08] + Array("abc".utf8)) }
        #expect(throws: Snappy.Failure.wrongLength) { try Snappy.decompress([2, 0x08] + Array("abc".utf8)) }
        #expect(throws: Snappy.Failure.wrongLength) { try Snappy.decompress([100, 0xf0, 99], limit: 50) }
    }
}

@Suite struct CRC32CTests {
    @Test func matchesTheStandardCheckValue() {
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xe306_9283)
        #expect(CRC32C.checksum([UInt8]()) == 0)
    }

    @Test func continuesAcrossPieces() {
        let whole = CRC32C.checksum(Array("123456789".utf8))
        let first = CRC32C.checksum(Array("1234".utf8))
        #expect(CRC32C.checksum(Array("56789".utf8), continuing: first) == whole)
    }
}

@Suite struct ChromiumLocalStorageFixtureTests {
    @Test func readsWhatLevelDBWrote() throws {
        let (profile, _) = try profileCopy()
        defer { try? FileManager.default.removeItem(at: profile) }

        let storage = try #require(try ChromiumLocalStorage.read(profileDirectory: profile))
        // The storage partitioned under an embedding site is not an origin's own.
        #expect(Set(storage.itemsByOrigin.keys) == [chat, lan])
        #expect(storage.itemsByOrigin[lan] == ["backspace_token": "lan-token"])

        let items = try #require(storage.itemsByOrigin[chat])
        #expect(items.count == 311)
        #expect(items["backspace_token"] == "fixture-token-not-a-secret")
        #expect(items["greeting"] == "Привет, мир 👋")
        #expect(items["черновик:1"] == "текст черновика")
        #expect(items["empty"] == "")
        // Compressed in its table, and longer than one block of it.
        #expect(items["repetitive"] == String(repeating: "abcdefgh", count: 1500))
        #expect(items["filler:000"] == "value number 000")
        #expect(items["filler:149"] == "value number 149")
        #expect(items["filler:299"] == "value number 299")
    }

    @Test func takesTheNewestOfSeveralEntriesForAKey() throws {
        let storage = ChromiumLocalStorage(entries: try LevelDB.entries(in: try fixtureDatabase()))
        let items = try #require(storage.itemsByOrigin[chat])
        // A newer table over an older one.
        #expect(items["backspace-language"] == "ru")
        #expect(items["filler:150"] == "changed in the newer table")
        #expect(items["deleted-in-table"] == nil)
        // The write-ahead log over the tables.
        #expect(items["changed-in-log"] == "second")
        #expect(items["deleted-in-log"] == nil)
        #expect(items["log-only"] == "yes")
        // One record cut across two blocks of the log.
        #expect(items["long"] == String(repeating: "0123456789", count: 4000))
    }

    @Test func givesNothingForAProfileWithoutTheDatabase() throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("bspace-profile-\(UUID().uuidString)", isDirectory: true)
        #expect(try ChromiumLocalStorage.read(profileDirectory: empty) == nil)
    }

    @Test func keepsWhatCameBeforeARecordCutShortInTheLog() throws {
        let (profile, database) = try profileCopy()
        defer { try? FileManager.default.removeItem(at: profile) }

        let log = try fileNamed(".log", in: database)
        let data = try Data(contentsOf: log)
        try data.dropLast(10).write(to: log)

        let items = try #require(try ChromiumLocalStorage.read(profileDirectory: profile)?.itemsByOrigin[chat])
        // The last write never finished: the state before it stands.
        #expect(items["changed-in-log"] == "first")
        #expect(items["deleted-in-log"] == "gone too")
        #expect(items["long"] == nil)
        #expect(items["backspace-language"] == "ru")
    }

    @Test func refusesADatabaseWithAMissingTable() throws {
        let (profile, database) = try profileCopy()
        defer { try? FileManager.default.removeItem(at: profile) }

        let table = try fileNamed(".ldb", in: database)
        try FileManager.default.removeItem(at: table)
        #expect(throws: LevelDB.Failure.missing(table.lastPathComponent)) {
            try ChromiumLocalStorage.read(profileDirectory: profile)
        }
    }

    @Test func refusesADamagedTable() throws {
        let (profile, database) = try profileCopy()
        defer { try? FileManager.default.removeItem(at: profile) }

        let table = try fileNamed(".ldb", in: database)
        try flipByte(at: 100, of: table)
        #expect(throws: LevelDB.Failure.damaged("\(table.lastPathComponent): a block with a wrong checksum")) {
            try ChromiumLocalStorage.read(profileDirectory: profile)
        }
    }

    @Test func refusesADamagedManifest() throws {
        let (profile, database) = try profileCopy()
        defer { try? FileManager.default.removeItem(at: profile) }

        try flipByte(at: 20, of: try fileNamed("MANIFEST-", in: database))
        #expect(throws: LevelDB.Failure.self) {
            try ChromiumLocalStorage.read(profileDirectory: profile)
        }

        try Data("000013.log\n".utf8).write(to: database.appendingPathComponent("CURRENT"))
        #expect(throws: LevelDB.Failure.damaged("CURRENT does not name a manifest")) {
            try ChromiumLocalStorage.read(profileDirectory: profile)
        }
    }
}

@Suite struct ChromiumLocalStorageEntryTests {
    private func key(_ storageKey: String, _ item: [UInt8]) -> Data {
        Data("_\(storageKey)".utf8) + Data([0]) + Data(item)
    }

    @Test func decodesBothEncodings() {
        let storage = ChromiumLocalStorage(entries: [
            key(chat, [1] + Array("latin".utf8)): Data([1, 0x63, 0x61, 0x66, 0xe9]),
            key(chat, [0, 0x3a, 0x04]): Data([0, 0x3d, 0xd8, 0x4b, 0xdc]),
        ])
        #expect(storage.itemsByOrigin == [chat: ["latin": "café", "к": "👋"]])
    }

    @Test func skipsWhatIsNotAnItemOfAnOrigin() {
        let value = Data([1, 0x76])
        let storage = ChromiumLocalStorage(entries: [
            Data("VERSION".utf8): Data("1".utf8),
            Data("META:\(chat)".utf8): Data([8, 1]),
            Data("METAACCESS:\(chat)".utf8): Data([8, 1]),
            // Partitioned under another site, a path, a spelling a browser
            // would not produce, a scheme that is not the web's.
            key("https://embed.example.test/^0\(chat)", [1, 0x6b]): value,
            key("\(chat)/", [1, 0x6b]): value,
            key("HTTPS://CHAT.EXAMPLE.TEST", [1, 0x6b]): value,
            key("https://chat.example.test:443", [1, 0x6b]): value,
            key("file://", [1, 0x6b]): value,
            // An encoding byte that is neither, half a UTF-16 unit, nothing.
            key(chat, [2, 0x6b]): value,
            key(chat, [0, 0x6b]): value,
            key(chat, [1, 0x61]): Data(),
            key(chat, [1, 0x6f, 0x6b]): value,
        ])
        #expect(storage.itemsByOrigin == [chat: ["ok": "v"]])
    }
}

@Suite struct LocalStorageImportTests {
    @Test func listsTheOriginsALoadMayEndAt() throws {
        func candidates(_ address: String) throws -> [String] {
            LocalStorageImport.candidateOrigins(for: try #require(URL(string: address)))
        }
        #expect(try candidates("https://chat.example.test/channels/1") == [chat])
        #expect(try candidates("http://chat.example.test") == ["http://chat.example.test", chat])
        #expect(try candidates("http://chat.example.test:80/") == ["http://chat.example.test", chat])
        // A redirect from another port could go anywhere.
        #expect(try candidates("http://192.168.1.20:3000/") == [lan])
        #expect(try candidates("file:///Applications/picker.html") == [])
    }

    @Test func offersOnlyWhatHasItemsAndWasNotBroughtOver() throws {
        let storage = ChromiumLocalStorage(itemsByOrigin: [
            chat: ["backspace_token": "t"],
            "http://chat.example.test": [:],
        ])
        let url = try #require(URL(string: "http://chat.example.test/"))

        let pending = LocalStorageImport.pending(for: url, in: storage, alreadyImported: [])
        #expect(pending.map(\.origin) == [chat])
        #expect(pending.first?.items == ["backspace_token": "t"])
        #expect(LocalStorageImport.pending(for: url, in: storage, alreadyImported: [chat]).isEmpty)
    }

    @Test func remembersTheOriginsBroughtOver() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bspace-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = LocalStorageImportLedger(directory: directory)

        #expect(ledger.load().isEmpty)
        try ledger.record(lan)
        try ledger.record(chat)
        try ledger.record(lan)
        #expect(ledger.load() == [chat, lan])
        #expect(try String(contentsOf: ledger.fileURL, encoding: .utf8) == #"{"origins":["http://192.168.1.20:3000","https://chat.example.test"]}"#)

        try Data("not json".utf8).write(to: ledger.fileURL)
        #expect(ledger.load().isEmpty)
    }
}
