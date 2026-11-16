import Foundation

/// The saved instance address: `instance-url.json` in the user-data folder, in
/// the format `packages/desktop/src/instanceUrl.ts` writes (`{"url":"…"}`), so
/// either shell reads what the other saved.
public struct InstanceURLStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("instance-url.json", isDirectory: false)
    }

    /// The saved address, or nil when there is none or the file is not what
    /// this app writes.
    public func load() -> String? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let url = object["url"] as? String
        else { return nil }
        return url
    }

    /// Written atomically: a crash mid-write leaves the previous file, not half
    /// of a new one (deviation 1 in the plan).
    public func save(_ url: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(withJSONObject: ["url": url], options: [.withoutEscapingSlashes])
        try data.write(to: fileURL, options: .atomic)
    }

    public func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// The address as a URL the window can load: `http` or `https` with a host.
    /// Anything else is refused before it is saved, where Electron saved it and
    /// then failed to load it.
    public static func loadableURL(_ string: String) -> URL? {
        guard let url = URL(string: string), WebOrigin.of(url) != nil else { return nil }
        return url
    }
}
