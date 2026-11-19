import BSpaceCore
import WebKit

/// Brings the Electron build's `localStorage` for an instance into the web
/// view's own storage, once, before that instance's page is first loaded: the
/// sign-in and the client's settings then survive the move from one build to
/// the other. The Electron profile is only read.
///
/// The items are written by a second web view that never shows and loads
/// nothing from the network: an empty document given the instance's origin, in
/// the same data store as the main web view. `localStorage` belongs to the
/// origin, so what that document writes is what the instance's page reads.
/// The items reach it as arguments of a function call, never as page source,
/// and only a document of their own origin ever receives them.
///
/// An origin is offered its items once (`LocalStorageImportLedger`), and only
/// if its storage in the web view is still empty: what the native app has
/// stored itself is newer than the Electron profile and is never overwritten.
public final class LocalStorageImporter: NSObject {
    public enum Outcome: Equatable {
        /// The items were written; how many.
        case imported(Int)
        /// The web view already had items for the origin; nothing was written.
        case kept
        /// Writing was refused by the page (the storage quota, for one). What
        /// had been written was removed again.
        case refused(String)
        /// The import did not run to an answer: it is tried again next time.
        case interrupted(String)
    }

    /// How long one origin may take before the load goes ahead without it.
    static let timeout: TimeInterval = 10

    private let profileDirectory: URL
    private let ledger: LocalStorageImportLedger
    private let dataStore: WKWebsiteDataStore
    /// The profile's storage, read at most once per run. The outer optional
    /// is "not read yet", the inner one "there is none".
    private var storage: ChromiumLocalStorage??

    private var queue: [(origin: String, items: [String: String])] = []
    private var outcomes: [String: Outcome] = [:]
    private var completion: (([String: Outcome]) -> Void)?
    private var seedView: WKWebView?
    private var watchdog: DispatchWorkItem?

    /// - Parameters:
    ///   - profileDirectory: the Electron build's user-data folder, which is
    ///     also its Chromium profile.
    ///   - ledgerDirectory: where the list of imported origins is kept.
    ///   - dataStore: the main web view's data store.
    public init(profileDirectory: URL, ledgerDirectory: URL, dataStore: WKWebsiteDataStore) {
        self.profileDirectory = profileDirectory
        ledger = LocalStorageImportLedger(directory: ledgerDirectory)
        self.dataStore = dataStore
    }

    /// Imports what there is to import for a load of `url`, then calls
    /// `completion` on the main thread with what happened, by origin. When
    /// there is nothing to import the call is made at once, before this
    /// returns. One import runs at a time: a second request made while one is
    /// running is answered at once with nothing.
    public func importIfNeeded(for url: URL, completion: @escaping ([String: Outcome]) -> Void) {
        guard self.completion == nil else {
            completion([:])
            return
        }
        let candidates = LocalStorageImport.candidateOrigins(for: url)
        let imported = ledger.load()
        guard candidates.contains(where: { !imported.contains($0) }), let storage = profileStorage() else {
            completion([:])
            return
        }
        queue = LocalStorageImport.pending(for: url, in: storage, alreadyImported: imported)
        guard !queue.isEmpty else {
            completion([:])
            return
        }
        outcomes = [:]
        self.completion = completion
        seedNext()
    }

    private func profileStorage() -> ChromiumLocalStorage? {
        if let storage { return storage }
        let read: ChromiumLocalStorage?
        do {
            read = try ChromiumLocalStorage.read(profileDirectory: profileDirectory)
        } catch {
            // The user signs in again; nothing on the server is lost.
            NSLog("[import] cannot read the Electron profile's localStorage: %@", String(describing: error))
            read = nil
        }
        storage = .some(read)
        return read
    }

    private func seedNext() {
        guard let next = queue.first, let originURL = URL(string: next.origin + "/") else {
            let finished = completion
            completion = nil
            queue = []
            finished?(outcomes)
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        seedView = view

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(next.origin, .interrupted("no answer in \(Int(Self.timeout)) s"))
        }
        watchdog = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timeout)

        view.loadHTMLString("<!doctype html><meta charset=\"utf-8\"><title></title>", baseURL: originURL)
    }

    private static let seedScript = """
        const storage = window.localStorage;
        if (storage.length > 0) return "kept";
        try {
            for (const [key, value] of items) storage.setItem(key, value);
        } catch (error) {
            storage.clear();
            return "refused: " + ((error && error.name) || String(error));
        }
        return "imported";
        """

    private func seed(_ view: WKWebView) {
        guard let next = queue.first, view === seedView else { return }
        let pairs = next.items.map { [$0.key, $0.value] }
        view.callAsyncJavaScript(
            Self.seedScript,
            arguments: ["items": pairs],
            in: nil,
            in: .defaultClient
        ) { [weak self] result in
            switch result {
            case .success(let answer as String) where answer == "imported":
                self?.finish(next.origin, .imported(pairs.count))
            case .success(let answer as String) where answer == "kept":
                self?.finish(next.origin, .kept)
            case .success(let answer as String) where answer.hasPrefix("refused: "):
                self?.finish(next.origin, .refused(String(answer.dropFirst("refused: ".count))))
            case .success(let answer):
                self?.finish(next.origin, .interrupted("unexpected answer \(String(describing: answer))"))
            case .failure(let error):
                self?.finish(next.origin, .interrupted(error.localizedDescription))
            }
        }
    }

    private func finish(_ origin: String, _ outcome: Outcome) {
        // The first answer for the origin being imported counts; a late one
        // (the timeout after the page answered, or the reverse) is dropped.
        guard queue.first?.origin == origin else { return }
        watchdog?.cancel()
        watchdog = nil
        seedView?.navigationDelegate = nil
        seedView = nil
        queue.removeFirst()
        outcomes[origin] = outcome

        switch outcome {
        case .imported(let count):
            NSLog("[import] localStorage of %@: %d items brought over from the Electron profile", origin, count)
        case .kept:
            NSLog("[import] localStorage of %@: already in use here, the Electron profile's is left out", origin)
        case .refused(let reason):
            NSLog("[import] localStorage of %@: the page refused it (%@)", origin, reason)
        case .interrupted(let reason):
            NSLog("[import] localStorage of %@: not imported this time (%@)", origin, reason)
        }
        if case .interrupted = outcome {
            // Not recorded: the next launch tries again.
        } else {
            do {
                try ledger.record(origin)
            } catch {
                NSLog("[import] cannot record the import of %@: %@", origin, error.localizedDescription)
            }
        }
        seedNext()
    }
}

extension LocalStorageImporter: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        seed(webView)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === seedView, let origin = queue.first?.origin else { return }
        finish(origin, .interrupted(error.localizedDescription))
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        guard webView === seedView, let origin = queue.first?.origin else { return }
        finish(origin, .interrupted(error.localizedDescription))
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === seedView, let origin = queue.first?.origin else { return }
        finish(origin, .interrupted("the web content process ended"))
    }
}
