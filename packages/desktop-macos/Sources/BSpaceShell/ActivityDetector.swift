import BSpaceCore
import Foundation

/// What tells the detector which processes are running.
public protocol ProcessLister: AnyObject {
    /// Calls back on the main queue with the names of the running processes
    /// in lower case, or with nil when they could not be listed.
    func runningProcessNames(completion: @escaping (Set<String>?) -> Void)
}

/// Lists the processes with the system's `ps`, as the Electron build does:
/// the names are then the ones the games dictionary was written against.
public final class SystemProcessLister: ProcessLister {
    private let queue = DispatchQueue(label: "process-list", qos: .utility)

    public init() {}

    public func runningProcessNames(completion: @escaping (Set<String>?) -> Void) {
        queue.async {
            let names = Self.list()
            DispatchQueue.main.async { completion(names) }
        }
    }

    private static func list() -> Set<String>? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessList.command.executable)
        process.arguments = ProcessList.command.arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        // Read before waiting: a full pipe would stop `ps` from ever ending.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return ProcessList.names(fromPs: String(decoding: data, as: UTF8.self))
    }
}

/// What fetches a newer games dictionary.
public protocol GameDictionaryFetcher: AnyObject {
    /// Asks for the dictionary, saying which copy is already here by its tag.
    /// Calls back on the main queue with the status, the body and the tag of
    /// the answer, or with nil when there was none.
    func fetch(knownTag: String?, completion: @escaping ((status: Int, body: Data, etag: String?)?) -> Void)
}

/// Fetches the dictionary from the project's repository.
public final class NetworkGameDictionaryFetcher: GameDictionaryFetcher {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    public func fetch(knownTag: String?, completion: @escaping ((status: Int, body: Data, etag: String?)?) -> Void) {
        guard let url = URL(string: GameDictionarySync.remoteAddress) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        // The Electron build's own name for this request; it says nothing of
        // the user or the machine.
        request.setValue("Backspace-Desktop/1.0", forHTTPHeaderField: "User-Agent")
        if let knownTag {
            request.setValue(knownTag, forHTTPHeaderField: "If-None-Match")
        }
        session.dataTask(with: request) { data, response, _ in
            let answer = (response as? HTTPURLResponse).map { http in
                (status: http.statusCode, body: data ?? Data(), etag: http.value(forHTTPHeaderField: "ETag"))
            }
            DispatchQueue.main.async { completion(answer) }
        }.resume()
    }
}

/// Notices a game or app the dictionary knows among the running processes
/// and says when it starts and ends. A port of
/// `packages/desktop/src/activityDetector.ts`.
///
/// It looks every fifteen seconds. The dictionary is the saved one or the
/// one shipped with the app, whichever is newer; a newer one is fetched once
/// at start, saved for next time and used from the next look on, without
/// forgetting what was detected.
public final class ActivityDetector {
    /// Called on the main queue when a game starts (with it) or ends (with nil).
    public var onChange: ((DetectedActivity?) -> Void)?
    /// What is detected now.
    public var current: DetectedActivity? { tracker.current }
    /// Whether it is looking.
    public private(set) var isRunning = false

    private let seedURL: URL?
    private let cacheURL: URL
    private let tagURL: URL
    private let lister: ProcessLister
    private let fetcher: GameDictionaryFetcher?
    private let pollInterval: TimeInterval
    private var dictionary: GameDictionary?
    private var tracker = ActivityTracker()
    private var timer: Timer?
    private var isLooking = false

    /// - Parameters:
    ///   - seedURL: the dictionary shipped with the app, if there is one.
    ///   - settingsDirectory: where the fetched dictionary and its tag are kept.
    ///   - fetcher: nil fetches nothing; the dictionary then only changes
    ///     with the app.
    public init(
        seedURL: URL?,
        settingsDirectory: URL,
        lister: ProcessLister = SystemProcessLister(),
        fetcher: GameDictionaryFetcher? = NetworkGameDictionaryFetcher(),
        pollInterval: TimeInterval = GameDictionarySync.pollInterval
    ) {
        self.seedURL = seedURL
        cacheURL = settingsDirectory.appendingPathComponent(GameDictionarySync.cacheFileName)
        tagURL = settingsDirectory.appendingPathComponent(GameDictionarySync.tagFileName)
        self.lister = lister
        self.fetcher = fetcher
        self.pollInterval = pollInterval
    }

    deinit {
        timer?.invalidate()
    }

    /// Starts looking. Does nothing when no dictionary can be read: there is
    /// nothing to look for.
    public func start() {
        guard !isRunning else { return }
        dictionary = GameDictionarySync.best(
            cache: try? Data(contentsOf: cacheURL),
            seed: seedURL.flatMap { try? Data(contentsOf: $0) }
        )
        guard let dictionary else {
            NSLog("[activity] no games dictionary can be read: detection is off")
            return
        }
        NSLog("[activity] looking for %ld games, dictionary version %ld", dictionary.entries.count, dictionary.version)
        isRunning = true
        look()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.look()
        }
        fetchNewerDictionary()
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func look() {
        // The look before this one has not answered yet.
        guard isRunning, !isLooking else { return }
        isLooking = true
        lister.runningProcessNames { [weak self] names in
            guard let self else { return }
            self.isLooking = false
            guard self.isRunning else { return }
            guard let names else {
                // Without the list there is nothing to detect by, and asking
                // again every fifteen seconds would only fill the log.
                NSLog("[activity] the running processes cannot be listed: detection stops")
                self.stop()
                return
            }
            let match = self.dictionary?.match(running: names)
            let now = Int64((Date().timeIntervalSince1970 * 1000).rounded())
            switch self.tracker.observe(match, nowMilliseconds: now) {
            case .started(let activity):
                self.onChange?(activity)
            case .stopped:
                self.onChange?(nil)
            case nil:
                break
            }
        }
    }

    private func fetchNewerDictionary() {
        guard let fetcher else { return }
        let knownTag = (try? String(contentsOf: tagURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        fetcher.fetch(knownTag: knownTag?.isEmpty == false ? knownTag : nil) { [weak self] answer in
            guard let self, let answer, let current = self.dictionary else { return }
            switch GameDictionarySync.decide(
                status: answer.status, body: answer.body, etag: answer.etag, currentVersion: current.version
            ) {
            case .keep:
                break
            case .rememberTag(let tag):
                self.save(tag: tag)
            case .adopt(let fetched, let body, let etag):
                do {
                    try self.write(body, to: self.cacheURL)
                } catch {
                    NSLog("[activity] could not save the fetched dictionary: %@", error.localizedDescription)
                }
                if let etag { self.save(tag: etag) }
                // What is detected now stays detected: only the list changes.
                self.dictionary = fetched
                NSLog("[activity] dictionary version %ld fetched, %ld games", fetched.version, fetched.entries.count)
            }
        }
    }

    /// Losing the tag only costs one download.
    private func save(tag: String) {
        try? write(Data(tag.utf8), to: tagURL)
    }

    /// Writes a file of the settings folder whole or not at all. On a first
    /// run the folder may not be there yet.
    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}
