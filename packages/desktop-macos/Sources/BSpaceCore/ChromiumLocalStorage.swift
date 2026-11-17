import Foundation

/// The `localStorage` of a Chromium profile, read from its
/// `Local Storage/leveldb` database. The Electron build keeps the web client's
/// sign-in and settings there; the native app reads them once, so that moving
/// from one build to the other does not sign anyone out.
///
/// In that database an item is one entry:
///
///     key    _<origin> 0x00 <item key>
///     value  <item value>
///
/// where the item's key and value each start with a byte naming their
/// encoding: 0 for UTF-16 (little-endian), 1 for Latin-1. The other entries
/// (`VERSION`, `META:…`, `METAACCESS:…`) are bookkeeping and are skipped.
public struct ChromiumLocalStorage: Equatable {
    /// Where the database is, inside a profile folder.
    public static let relativePath = "Local Storage/leveldb"

    /// The items of every origin that has any, keyed by the origin as a
    /// browser spells it (`https://host`, `http://host:3000`).
    ///
    /// Only an origin's own storage is here. The storage of a frame embedded
    /// in another site is partitioned, its key names both sites, and it is
    /// left out: nothing the app loads as a top-level page would read it.
    public let itemsByOrigin: [String: [String: String]]

    public init(itemsByOrigin: [String: [String: String]]) {
        self.itemsByOrigin = itemsByOrigin
    }

    /// From the entries of the database (`LevelDB.entries(in:)`).
    public init(entries: [Data: Data]) {
        var items: [String: [String: String]] = [:]
        for (entryKey, entryValue) in entries {
            guard
                entryKey.first == UInt8(ascii: "_"),
                let separator = entryKey.firstIndex(of: 0),
                let storageKey = String(bytes: entryKey[entryKey.index(after: entryKey.startIndex)..<separator], encoding: .utf8),
                Self.isOrigin(storageKey),
                let key = Self.decode(entryKey[entryKey.index(after: separator)...]),
                let value = Self.decode(entryValue)
            else { continue }
            items[storageKey, default: [:]][key] = value
        }
        itemsByOrigin = items
    }

    /// The `localStorage` of the profile in `profileDirectory`, or nil when
    /// the profile has no such database (there is no Electron profile, or it
    /// never stored anything).
    public static func read(profileDirectory: URL) throws -> ChromiumLocalStorage? {
        let directory = profileDirectory.appendingPathComponent(relativePath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("CURRENT").path) else {
            return nil
        }
        return ChromiumLocalStorage(entries: try LevelDB.entries(in: directory))
    }

    /// True for a storage key that is exactly an origin: what `WebOrigin`
    /// gives back for it is the key itself.
    private static func isOrigin(_ storageKey: String) -> Bool {
        guard let url = URL(string: storageKey) else { return false }
        return WebOrigin.of(url) == storageKey
    }

    private static func decode(_ bytes: Data) -> String? {
        guard let encoding = bytes.first else { return nil }
        let text = bytes.dropFirst()
        switch encoding {
        case 0:
            guard text.count % 2 == 0 else { return nil }
            var units: [UInt16] = []
            units.reserveCapacity(text.count / 2)
            var index = text.startIndex
            while index < text.endIndex {
                units.append(UInt16(text[index]) | UInt16(text[text.index(after: index)]) << 8)
                index = text.index(index, offsetBy: 2)
            }
            // A lone surrogate, which a JavaScript string may hold and a
            // Swift one may not, becomes U+FFFD.
            return String(decoding: units, as: UTF16.self)
        case 1:
            return String(String.UnicodeScalarView(text.map { Unicode.Scalar($0) }))
        default:
            return nil
        }
    }
}

/// Which origins have already had their `localStorage` brought over:
/// `local-storage-import.json` in the user-data folder. The import is offered
/// to an origin once; after that the native app's own storage is the truth,
/// whatever the Electron profile says.
public struct LocalStorageImportLedger {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("local-storage-import.json", isDirectory: false)
    }

    public func load() -> Set<String> {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let origins = object["origins"] as? [Any]
        else { return [] }
        return Set(origins.compactMap { $0 as? String })
    }

    public func record(_ origin: String) throws {
        var origins = load()
        guard origins.insert(origin).inserted else { return }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["origins": origins.sorted()],
            options: [.withoutEscapingSlashes]
        )
        try data.write(to: fileURL, options: .atomic)
    }
}

public enum LocalStorageImport {
    /// The origins a load of `url` may end at, the address's own first. An
    /// `http://` address on the default port may be answered with a redirect
    /// to `https://` on the same host, and then that is where the web client
    /// kept its storage.
    public static func candidateOrigins(for url: URL) -> [String] {
        guard let origin = WebOrigin.of(url) else { return [] }
        guard
            origin.hasPrefix("http://"),
            let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
            components.port == nil || components.port == 80,
            var secure = URLComponents(url: url, resolvingAgainstBaseURL: true)
        else { return [origin] }
        secure.scheme = "https"
        secure.port = nil
        guard let secureURL = secure.url, let secureOrigin = WebOrigin.of(secureURL) else { return [origin] }
        return [origin, secureOrigin]
    }

    /// What is to be brought over for a load of `url`: the candidate origins
    /// that have items in the profile and are not in the ledger yet.
    public static func pending(
        for url: URL,
        in storage: ChromiumLocalStorage,
        alreadyImported: Set<String>
    ) -> [(origin: String, items: [String: String])] {
        candidateOrigins(for: url).compactMap { origin in
            guard !alreadyImported.contains(origin), let items = storage.itemsByOrigin[origin], !items.isEmpty else {
                return nil
            }
            return (origin, items)
        }
    }
}
