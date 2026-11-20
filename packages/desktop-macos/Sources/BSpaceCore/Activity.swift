import Foundation

/// One game or app the shell can recognise by the name of its process. A port
/// of the dictionary side of `packages/desktop/src/activityDetector.ts`.
public struct GameEntry: Equatable {
    /// What an activity may be: the web client shows "Playing", "Listening
    /// to" and so on by it.
    public static let types: Set<String> = ["playing", "listening", "watching", "streaming"]

    public let id: String
    public let name: String
    /// The process names that mean it is running, as the dictionary has them.
    public let processes: [String]
    public let type: String

    public init(id: String, name: String, processes: [String], type: String) {
        self.id = id
        self.name = name
        self.processes = processes
        self.type = type
    }

    /// Reads one entry of a dictionary: an id, a name and at least one
    /// process name, all strings. A type that is not one becomes "playing".
    init?(json: Any) {
        guard
            let fields = json as? [String: Any],
            let id = fields["id"] as? String, !id.isEmpty,
            let name = fields["name"] as? String, !name.isEmpty,
            let listed = fields["processes"] as? [Any], !listed.isEmpty
        else { return nil }
        let processes = listed.compactMap { $0 as? String }
        guard processes.count == listed.count else { return nil }
        let type = (fields["type"] as? String).flatMap { Self.types.contains($0) ? $0 : nil } ?? "playing"
        self.init(id: id, name: name, processes: processes, type: type)
    }
}

/// The dictionary of games: `games.json`, shipped with the app, saved from
/// the network, or just fetched.
public struct GameDictionary: Equatable {
    public let version: Int
    public let entries: [GameEntry]

    /// Reads a dictionary in either of its formats: `{ version, games }`, or
    /// the older bare list, which is version 0. Entries that are not games
    /// are skipped. Nil for anything else, and for a dictionary with no entry
    /// left: that one could never match.
    public init?(data: Data) {
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        let version: Int
        let listed: [Any]
        if let list = json as? [Any] {
            version = 0
            listed = list
        } else if
            let object = json as? [String: Any],
            let number = object["version"] as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID(),
            let whole = Int(exactly: number.doubleValue),
            let games = object["games"] as? [Any]
        {
            version = whole
            listed = games
        } else {
            return nil
        }
        let entries = listed.compactMap(GameEntry.init(json:))
        guard !entries.isEmpty else { return nil }
        self.version = version
        self.entries = entries
    }

    /// The first listed game one of whose processes is running.
    ///
    /// - Parameter running: process names in lower case, as
    ///   `ProcessList.names` gives them.
    public func match(running: Set<String>) -> GameEntry? {
        entries.first { entry in
            entry.processes.contains { running.contains($0.lowercased()) }
        }
    }
}

public enum ProcessList {
    /// The command and its arguments that list what is running: one name a
    /// line, the executable's name without its folder. What the Electron
    /// build runs on macOS.
    public static let command = (executable: "/bin/ps", arguments: ["-c", "-A", "-o", "comm"])

    /// The names in that command's output, in lower case. The first line is
    /// dropped when it is the column's heading.
    public static func names(fromPs output: String) -> Set<String> {
        var names = Set<String>()
        for (index, line) in output.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let name = line.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { continue }
            if index == 0, name == "COMM" || name == "COMMAND" { continue }
            names.insert(name.lowercased())
        }
        return names
    }
}

/// What the web client is told over `activity-detected` and answers
/// `get-current-activity` with: a game or app that is running, and since when.
public struct DetectedActivity: Equatable {
    public let type: String
    public let name: String
    /// When it was first seen running, in milliseconds since 1970.
    public let startedAtMilliseconds: Int64

    public init(type: String, name: String, startedAtMilliseconds: Int64) {
        self.type = type
        self.name = name
        self.startedAtMilliseconds = startedAtMilliseconds
    }

    public var bridgeValue: [String: Any] {
        ["type": type, "name": name, "timestamps": ["start": startedAtMilliseconds]]
    }
}

/// Remembers what was detected last, so that the web client hears of a game
/// once when it starts and once when it ends, not at every look.
public struct ActivityTracker {
    public enum Change: Equatable {
        case started(DetectedActivity)
        case stopped
    }

    public private(set) var current: DetectedActivity?
    private var currentId: String?

    public init() {}

    /// - Parameter match: the game found running at this look, if any.
    public mutating func observe(_ match: GameEntry?, nowMilliseconds: Int64) -> Change? {
        guard let match else {
            guard currentId != nil else { return nil }
            currentId = nil
            current = nil
            return .stopped
        }
        guard match.id != currentId else { return nil }
        let activity = DetectedActivity(type: match.type, name: match.name, startedAtMilliseconds: nowMilliseconds)
        currentId = match.id
        current = activity
        return .started(activity)
    }
}

/// Keeping the dictionary current: the app ships with one, and a newer one
/// is fetched from the project's repository in the background and saved.
public enum GameDictionarySync {
    public static let remoteAddress = "https://raw.githubusercontent.com/funpin/B-SPACE/main/packages/desktop/resources/games.json"
    /// The fetched dictionary and the tag the server gave it, in the settings
    /// folder: the Electron build's files.
    public static let cacheFileName = "games-cache.json"
    public static let tagFileName = "games-cache-etag.txt"
    /// How often what is running is looked at.
    public static let pollInterval: TimeInterval = 15

    public enum Outcome: Equatable {
        /// Nothing to do: not modified, an error, or not a dictionary.
        case keep
        /// A dictionary that is not newer: only its tag is worth keeping, so
        /// that the next fetch is answered "not modified".
        case rememberTag(String)
        /// A newer dictionary: use it, save it and its tag.
        case adopt(GameDictionary, body: Data, etag: String?)
    }

    /// The dictionary to start with: the saved one or the shipped one,
    /// whichever is newer. The saved one wins a tie. (The Electron build
    /// takes the saved one whenever it can be read, so an app update with a
    /// newer dictionary waits for the network there.)
    public static func best(cache: Data?, seed: Data?) -> GameDictionary? {
        let saved = cache.flatMap(GameDictionary.init(data:))
        let shipped = seed.flatMap(GameDictionary.init(data:))
        guard let saved else { return shipped }
        guard let shipped else { return saved }
        return shipped.version > saved.version ? shipped : saved
    }

    /// What to do with the server's answer.
    public static func decide(status: Int, body: Data, etag: String?, currentVersion: Int) -> Outcome {
        guard status == 200, let fetched = GameDictionary(data: body) else { return .keep }
        guard fetched.version > currentVersion else {
            return etag.map(Outcome.rememberTag) ?? .keep
        }
        return .adopt(fetched, body: body, etag: etag)
    }
}
