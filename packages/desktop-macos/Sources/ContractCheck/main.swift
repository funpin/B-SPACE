import AppKit
import BSpaceCore
import BSpaceShell
import Network
import WebKit

// Runs the bridge contract check against the real shell: the same window
// controller, web view configuration and bridge the application uses, with no
// window on screen and its settings in a temporary folder. Loads
// contract/harness.html, lets it call every member of `window.backspace`,
// sends one event on every event channel, and compares what the page saw with
// what bridgeContract.json promises.
//
// Usage: ContractCheck --contract <json> --picker <html> --strings <json> --harness <html> [--out <json>]
// Exit status: 0 when the bridge keeps the contract, 1 when it does not,
// 2 when the check could not run.
//
// With --visit <address> in place of --harness it opens that address in the
// same shell instead, waits --settle seconds (5 by default) and prints what
// the page sees: where it ended up, its title, whether the bridge is there and
// whether the client drew anything. That is how a live instance is looked at
// without a person at the window. --script <file> asks the page something
// else: the file is the body of an async function, and what it returns is
// printed.
//
// With --check window-state in place of --harness it checks, on the displays of
// this machine, that the shell puts its window where window-state.json says,
// writes the file again when the window moves, and centres the window when
// the saved place is on no display. No window is shown.
//
// With --check local-storage-import --fixture <leveldb folder> it checks the
// import of the Electron build's localStorage in a data store that is never
// written to disk: the items of the fixture profile reach a page of their
// origin as they are, an origin is imported once, storage already in use is
// left alone, and the shell imports before it loads an instance. The one
// address it asks the network for does not exist (a .test name).
//
// With --check launch it checks what reaches the page from outside the app:
// a backspace:// link that arrives before the page listens for links is held
// and delivered once it does, a later one is delivered at once, anything else
// is dropped; and the auto-launch settings go through the bridge to a login
// item that registers nothing.
//
// With --check notifications it checks notifications and the badge on a page
// with a real origin, served from this process on the loopback address: what
// the page asks for reaches the presenter (one that only records), a click
// brings the payload back to the page, a click on a notification from another
// origin does not, and setBadgeCount sets and clears the Dock badge. Nothing
// is shown: no notification, no window.
//
// With --check menu it builds the menu bar in every language the shell has and
// checks that no item is left without a title or with a placeholder in it,
// that the items with shortcuts kept them, and that the shell's language
// follows what the page reports on set-language (and ignores a language it
// does not have), remembering it in language.json.
//
// With --check electron-profile --profile <folder> it reads the localStorage of
// an Electron profile the way the import does and prints, for every origin,
// how many items there are and how large they are; --keys yes adds the item
// names. Values are never printed: they hold the sign-in. Needs nothing else.

/// Members the harness reads but does not call: they navigate the window away
/// from the harness or act on a window that is not on screen. The picker and
/// the window buttons exercise them in a manual run.
let skippedCalls = ["minimize", "maximize", "close", "setInstanceUrl", "clearInstanceUrl"]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("ContractCheck: \(message)\n".utf8))
    exit(2)
}

func options() -> [String: String] {
    var result: [String: String] = [:]
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let name = arguments.removeFirst()
        guard name.hasPrefix("--"), !arguments.isEmpty else { fail("unexpected argument \(name)") }
        result[String(name.dropFirst(2))] = arguments.removeFirst()
    }
    return result
}

func fileURL(_ options: [String: String], _ name: String) -> URL {
    guard let path = options[name] else { fail("--\(name) is required") }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    guard FileManager.default.isReadableFile(atPath: url.path) else { fail("cannot read \(url.path)") }
    return url
}

/// What the page reported, compared with the contract. Returns one line per
/// thing that is not as promised.
func violations(report: [String: Any], members: [BridgeContract.Member]) -> [String] {
    var found: [String] = []
    guard report["present"] as? Bool == true else { return ["window.backspace is not defined"] }
    if report["frozen"] as? Bool != true { found.append("window.backspace can be modified by the page") }
    if let undeclared = report["undeclared"] as? [String], !undeclared.isEmpty {
        found.append("members the contract does not list: \(undeclared.joined(separator: ", "))")
    }
    if let removed = report["removedButCalled"] as? [String], !removed.isEmpty {
        found.append("removed callbacks were still called: \(removed.joined(separator: ", "))")
    }
    let agent = report["userAgent"] as? String ?? ""
    if agent.range(of: #"Version/\d+\.\d+ Safari/605\.1\.15 BSpaceDesktop/"#, options: .regularExpression) == nil {
        found.append("unexpected User-Agent: \(agent)")
    }

    let entries = (report["members"] as? [[String: Any]]) ?? []
    let received = (report["received"] as? [String: [Any]]) ?? [:]
    for member in members {
        guard let entry = entries.first(where: { $0["name"] as? String == member.name }) else {
            found.append("\(member.name): missing from the report")
            continue
        }
        if let threw = entry["threw"] as? String {
            found.append("\(member.name): threw \(threw)")
            continue
        }
        let memberType = entry["memberType"] as? String
        let returned = entry["returned"] as? String
        let called = entry["called"] as? Bool == true
        switch member.kind {
        case .value:
            if entry["value"] as? String != AppIdentity.platform {
                found.append("\(member.name): expected \"\(AppIdentity.platform)\", got \(String(describing: entry["value"]))")
            }
        case .fire:
            if memberType != "function" { found.append("\(member.name): not a function") }
            if called && returned != "undefined" { found.append("\(member.name): returned \(returned ?? "nothing recorded"), not undefined") }
        case .invoke:
            if memberType != "function" { found.append("\(member.name): not a function") }
            guard called else { continue }
            if returned != "promise" { found.append("\(member.name): returned \(returned ?? "nothing recorded"), not a Promise") }
            if entry["settled"] as? String != "fulfilled" {
                found.append("\(member.name): rejected with \(entry["error"] as? String ?? "no message")")
            }
        case .subscribe:
            if memberType != "function" { found.append("\(member.name): not a function") }
            let expected = member.unsubscribe == true ? "function" : "undefined"
            if called && returned != expected { found.append("\(member.name): returned \(returned ?? "nothing recorded"), not \(expected)") }
            guard let channel = member.channel else { continue }
            let payloads = received[channel] ?? []
            let delivered = payloads.count == 1 && (payloads[0] as? [String: Any])?["probe"] as? String == channel
            if !delivered { found.append("\(member.name): the event on \(channel) arrived \(payloads.count) times") }
        }
    }
    return found
}

/// Lists what the import would find in a profile, and ends the process.
func describeElectronProfile(_ profile: URL, withKeys: Bool) -> Never {
    let storage: ChromiumLocalStorage?
    do {
        storage = try ChromiumLocalStorage.read(profileDirectory: profile)
    } catch {
        fail("cannot read the profile's localStorage: \(error)")
    }
    guard let storage else {
        print("no localStorage database in \(profile.path)")
        exit(0)
    }
    for origin in storage.itemsByOrigin.keys.sorted() {
        let items = storage.itemsByOrigin[origin] ?? [:]
        let size = items.reduce(0) { $0 + $1.key.utf16.count + $1.value.utf16.count }
        print("\(origin): \(items.count) items, \(size) UTF-16 units")
        guard withKeys else { continue }
        for key in items.keys.sorted() {
            print("  \(key): \(items[key]?.utf16.count ?? 0)")
        }
    }
    exit(0)
}

let arguments = options()
if arguments["check"] == "electron-profile" {
    describeElectronProfile(fileURL(arguments, "profile"), withKeys: arguments["keys"] == "yes")
}
let contractURL = fileURL(arguments, "contract")
let pickerURL = fileURL(arguments, "picker")
let stringsURL = fileURL(arguments, "strings")
let visitAddress = arguments["visit"]
let checkName = arguments["check"]
let harnessURL = visitAddress == nil && checkName == nil ? fileURL(arguments, "harness") : nil

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("bspace-contract-check-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
let strings: DesktopStrings
do {
    strings = try DesktopStrings(data: Data(contentsOf: stringsURL))
} catch {
    fail("cannot read the strings: \(error)")
}
let environment = ShellEnvironment(
    resources: ShellResources(pickerURL: pickerURL, contractURL: contractURL, stringsURL: stringsURL),
    userDataDirectory: temporary,
    appVersion: "0.0.0-check",
    safariVersion: ShellEnvironment.installedSafariVersion(),
    overrideURL: nil,
    strings: strings,
    language: strings.english
)

/// The login item of a check run: remembers what it was asked and registers
/// nothing with the system.
final class CheckLoginItem: LoginItem {
    var isEnabled = false
    var refuses = false
    private(set) var requests: [Bool] = []

    struct Refused: Error {}

    func setEnabled(_ enabled: Bool) throws {
        requests.append(enabled)
        if refuses { throw Refused() }
        isEnabled = enabled
    }
}

/// The notification presenter of a check run: records what it is asked to
/// show and shows nothing.
final class CheckNotificationPresenter: NotificationPresenter {
    var onClick: (([AnyHashable: Any]) -> Void)?
    private(set) var shown: [NotificationRequest] = []

    func show(_ request: NotificationRequest) {
        shown.append(request)
    }
}

/// Serves one empty page on the loopback address, on a port the system picks:
/// a page with a real http origin, with nothing asked of the network outside
/// this machine.
final class LocalPageServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-page-server")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let body = "<!doctype html><title>check</title>"
                let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        listener.start(queue: queue)
    }

    /// The server's origin, once it is listening.
    func origin() -> String? {
        let deadline = Date().addingTimeInterval(5)
        while listener.port == nil && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        return listener.port.map { "http://127.0.0.1:\($0.rawValue)" }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

/// The window state check. Runs before anything else is created, with its own
/// window controllers, and ends the process.
func checkWindowState() -> Never {
    guard let screen = NSScreen.screens.first else { fail("there is no display to place a window on") }
    let primaryHeight = Double(screen.frame.height)
    func electron(_ rect: NSRect) -> PlainRect {
        WindowPlacement.flipped(
            PlainRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height),
            primaryDisplayHeight: primaryHeight
        )
    }
    func describe(_ rect: PlainRect?) -> String {
        guard let rect else { return "no position" }
        return "\(rect.x),\(rect.y) \(rect.width)x\(rect.height)"
    }
    func makeController() -> MainWindowController {
        do {
            return try MainWindowController(environment: environment, showsWindow: true, loginItem: CheckLoginItem(), notifications: nil)
        } catch {
            fail(String(describing: error))
        }
    }

    let workArea = electron(screen.visibleFrame)
    let store = WindowStateStore(directory: temporary)
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    // 1. A saved place inside the work area is where the window appears.
    let saved = WindowState(width: 960, height: 520, x: workArea.x + 24, y: workArea.y + 16, isMaximized: false)
    do {
        try store.save(saved)
    } catch {
        fail("cannot write the window state: \(error.localizedDescription)")
    }
    let first = makeController()
    let restored = electron(first.window.frame)
    if restored != saved.bounds {
        problems.append("saved \(describe(saved.bounds)), the window is at \(describe(restored))")
    }

    // 2. Moving and resizing the window is written back, in the file's
    //    coordinates, once the window has been still for a moment.
    var moved = first.window.frame
    moved.origin.x += 30
    moved.origin.y -= 20
    moved.size.width += 40
    moved.size.height += 20
    first.window.setFrame(moved, display: false)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let written = store.load()
    if written.bounds != electron(first.window.frame) {
        problems.append("after a move the window is at \(describe(electron(first.window.frame))), the file says \(describe(written.bounds))")
    }
    if written.bounds == saved.bounds {
        problems.append("moving the window did not change the file")
    }

    // 3. A place on no display is dropped: the saved size, centred.
    do {
        try store.save(WindowState(width: 960, height: 520, x: 90_000, y: 90_000, isMaximized: false))
    } catch {
        fail("cannot write the window state: \(error.localizedDescription)")
    }
    let second = makeController()
    let fallback = second.window.frame
    if fallback.width != 960 || fallback.height != 520 {
        problems.append("a lost place should keep the saved size, the window is \(fallback.width)x\(fallback.height)")
    }
    if !screen.frame.contains(fallback) {
        problems.append("a lost place should put the window on the primary display, it is at \(describe(electron(fallback)))")
    }

    // 4. Saving on request writes at once (what closing and quitting rely on).
    var nudged = second.window.frame
    nudged.origin.x += 10
    second.window.setFrame(nudged, display: false)
    second.saveWindowState()
    if store.load().bounds != electron(second.window.frame) {
        problems.append("saveWindowState() did not write the current place")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty ? "window state: restored, saved after a move, centred when lost" : "window state: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// Tells when a web view has finished loading.
final class LoadWatcher: NSObject, WKNavigationDelegate {
    var hasEnded = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { hasEnded = true }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { hasEnded = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        hasEnded = true
    }
}

/// Runs the main run loop until `isDone` or the time is up.
func wait(_ seconds: TimeInterval = 20, until isDone: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !isDone() && Date() < deadline {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
    }
    return isDone()
}

/// Runs `script` (the body of an async function) in an empty document of
/// `origin` in `store`, a web view of its own: what a page of that origin
/// would see. Nil when the document could not be made or the script failed.
func evaluate(_ script: String, at origin: String, in store: WKWebsiteDataStore) -> Any? {
    let configuration = WKWebViewConfiguration()
    configuration.websiteDataStore = store
    let view = WKWebView(frame: .zero, configuration: configuration)
    let watcher = LoadWatcher()
    view.navigationDelegate = watcher
    view.loadHTMLString("<!doctype html><title></title>", baseURL: URL(string: origin + "/"))
    guard wait(until: { watcher.hasEnded }) else { return nil }

    var answer: Result<Any, Error>?
    view.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { answer = $0 }
    guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
    return value
}

/// The localStorage import check. Ends the process.
func checkLocalStorageImport(fixture: URL) -> Never {
    let origin = "https://chat.example.test"
    let readAll = "return Object.fromEntries(Object.entries(window.localStorage));"
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    // The fixture, laid out as the Electron build's profile.
    let database = temporary.appendingPathComponent(ChromiumLocalStorage.relativePath, isDirectory: true)
    let expected: [String: String]
    do {
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: database)
        guard let items = try ChromiumLocalStorage.read(profileDirectory: temporary)?.itemsByOrigin[origin], !items.isEmpty else {
            fail("the fixture holds nothing for \(origin)")
        }
        expected = items
    } catch {
        fail("cannot prepare the fixture profile: \(error)")
    }

    func ledgerDirectory(_ name: String) -> URL {
        temporary.appendingPathComponent(name, isDirectory: true)
    }
    func run(_ importer: LocalStorageImporter, _ address: String) -> [String: LocalStorageImporter.Outcome]? {
        guard let url = URL(string: address) else { fail("bad address \(address)") }
        var outcomes: [String: LocalStorageImporter.Outcome]?
        importer.importIfNeeded(for: url) { outcomes = $0 }
        return wait(until: { outcomes != nil }) ? outcomes : nil
    }
    func stored(in store: WKWebsiteDataStore) -> [String: String]? {
        evaluate(readAll, at: origin, in: store) as? [String: String]
    }

    // 1. The items reach a page of their origin, all of them, as they are.
    let store = WKWebsiteDataStore.nonPersistent()
    let first = LocalStorageImporter(profileDirectory: temporary, ledgerDirectory: ledgerDirectory("one"), dataStore: store)
    let firstOutcomes = run(first, origin + "/channels/1")
    if firstOutcomes != [origin: .imported(expected.count)] {
        problems.append("a first import should bring over \(expected.count) items, got \(String(describing: firstOutcomes))")
    }
    if let found = stored(in: store) {
        if found != expected {
            let wrong = expected.keys.filter { found[$0] != expected[$0] }.sorted().prefix(5)
            problems.append("the page sees \(found.count) items, the profile has \(expected.count); first differences: \(wrong.joined(separator: ", "))")
        }
    } else {
        problems.append("could not read the storage back after the import")
    }

    // 2. Once per origin: the ledger stops a second import, at once.
    if LocalStorageImportLedger(directory: ledgerDirectory("one")).load() != [origin] {
        problems.append("the import was not recorded in the ledger")
    }
    var answeredAtOnce: [String: LocalStorageImporter.Outcome]?
    first.importIfNeeded(for: URL(fileURLWithPath: "/")) { answeredAtOnce = $0 }
    if answeredAtOnce != [:] { problems.append("a file address should be answered at once with nothing") }
    answeredAtOnce = nil
    if let url = URL(string: origin + "/") {
        first.importIfNeeded(for: url) { answeredAtOnce = $0 }
    }
    if answeredAtOnce != [:] { problems.append("an origin already imported should be answered at once with nothing") }

    // 3. Storage already in use is left alone, whatever the profile says.
    _ = evaluate("window.localStorage.setItem('backspace-language', 'de'); return true;", at: origin, in: store)
    let second = LocalStorageImporter(profileDirectory: temporary, ledgerDirectory: ledgerDirectory("two"), dataStore: store)
    let secondOutcomes = run(second, origin + "/")
    if secondOutcomes != [origin: .kept] {
        problems.append("storage in use should be kept, got \(String(describing: secondOutcomes))")
    }
    if stored(in: store)?["backspace-language"] != "de" {
        problems.append("the import overwrote storage that was in use")
    }
    if LocalStorageImportLedger(directory: ledgerDirectory("two")).load() != [origin] {
        problems.append("an origin whose storage was kept should be recorded too")
    }

    // 4. An http:// address that will be redirected to https:// gets the
    //    https:// origin's items.
    let redirected = WKWebsiteDataStore.nonPersistent()
    let third = LocalStorageImporter(profileDirectory: temporary, ledgerDirectory: ledgerDirectory("three"), dataStore: redirected)
    let thirdOutcomes = run(third, "http://chat.example.test/")
    if thirdOutcomes != [origin: .imported(expected.count)] {
        problems.append("an http:// address should import its https:// origin, got \(String(describing: thirdOutcomes))")
    }

    // 5. The shell imports before it loads an instance. The address does not
    //    exist, so the load fails; what matters is what is in the storage.
    let shellStore = WKWebsiteDataStore.nonPersistent()
    do {
        let shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: shellStore,
            loginItem: CheckLoginItem()
        )
        var hasEnded = false
        shell.onMainFrameLoadEnded = { _ in hasEnded = true }
        guard let url = URL(string: origin + "/") else { fail("bad address") }
        shell.load(url)
        if !wait(60, until: { hasEnded }) {
            problems.append("the shell's load of the instance never ended")
        }
        if stored(in: shellStore) != expected {
            problems.append("the shell loaded an instance without importing its storage first")
        }
        if LocalStorageImportLedger(directory: temporary).load() != [origin] {
            problems.append("the shell did not record its import")
        }
    } catch {
        fail(String(describing: error))
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "localStorage import: \(expected.count) items brought over, once per origin, storage in use kept"
        : "localStorage import: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The launch check: links and the auto-launch settings. Ends the process.
func checkLaunch() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let loginItem = CheckLoginItem()
    let shell: MainWindowController
    let blank = temporary.appendingPathComponent("blank.html", isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("<!doctype html><title></title>".utf8).write(to: blank)
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: loginItem
        )
    } catch {
        fail(String(describing: error))
    }

    /// Loads an empty page in the shell: a new document with the bridge in it.
    func loadBlank() {
        var hasEnded = false
        shell.onMainFrameLoadEnded = { _ in hasEnded = true }
        shell.load(blank)
        guard wait(until: { hasEnded }) else { fail("the empty page did not load") }
    }
    /// Runs the body of an async function in the page.
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    let listen = "window.__links = []; window.backspace.onDeepLink((link) => window.__links.push(link)); return true;"
    func links() -> [String]? {
        page("return window.__links === undefined ? null : window.__links;") as? [String]
    }
    func expectLinks(_ expected: [String], _ what: String) {
        if !wait(5, until: { links() == expected }) {
            problems.append("\(what): the page has \(String(describing: links())), expected \(expected)")
        }
    }

    // 1. Links that come before the page listens are held; the newest of
    //    them is delivered when it does.
    loadBlank()
    shell.openDeepLink("backspace://join/one")
    shell.openDeepLink("backspace://join/two")
    _ = page(listen)
    expectLinks(["backspace://join/two"], "a link held until the page listened")

    // 2. With a listener in place a link goes straight through.
    shell.openDeepLink("backspace://channel/1/2")
    expectLinks(["backspace://join/two", "backspace://channel/1/2"], "a link sent to a listening page")

    // 3. What is not a backspace:// link never reaches the page.
    shell.openDeepLink("https://example.test/")
    shell.openDeepLink("javascript:alert(1)")
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    expectLinks(["backspace://join/two", "backspace://channel/1/2"], "an address that is not a link")

    // 4. A new document has no listener: links are held again, and the ones
    //    already delivered do not come back.
    loadBlank()
    shell.openDeepLink("backspace://join/three")
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    if links() != nil { problems.append("a link reached a page that had not subscribed") }
    _ = page(listen)
    expectLinks(["backspace://join/three"], "a link held across a reload")

    // 5. The auto-launch settings, through the bridge.
    func settings(_ script: String) -> [String: Bool]? {
        page(script) as? [String: Bool]
    }
    func expectSettings(_ found: [String: Bool]?, openAtLogin: Bool, startMinimized: Bool, _ what: String) {
        if found != ["openAtLogin": openAtLogin, "startMinimized": startMinimized] {
            problems.append("\(what): got \(String(describing: found))")
        }
    }
    expectSettings(settings("return await window.backspace.getAutoLaunchSettings();"),
                   openAtLogin: false, startMinimized: true, "the settings of a fresh install")
    expectSettings(settings("return await window.backspace.setAutoLaunchSettings({ openAtLogin: true });"),
                   openAtLogin: true, startMinimized: true, "switching opening at login on")
    if !loginItem.isEnabled { problems.append("the login item was not registered") }
    expectSettings(settings("return await window.backspace.setAutoLaunchSettings({ startMinimized: false });"),
                   openAtLogin: true, startMinimized: false, "changing only the hidden start")
    expectSettings(settings("return await window.backspace.setAutoLaunchSettings();"),
                   openAtLogin: true, startMinimized: false, "a call with nothing to change")
    expectSettings(settings("return await window.backspace.setAutoLaunchSettings('junk');"),
                   openAtLogin: true, startMinimized: false, "a call with something that is not settings")
    if loginItem.requests != [true] {
        problems.append("the system should have been asked once, it was asked \(loginItem.requests)")
    }
    let file = AutoLaunchStore(directory: temporary).fileURL
    if (try? String(contentsOf: file, encoding: .utf8)) != #"{"openAtLogin":true,"startMinimized":false}"# {
        problems.append("auto-launch.json does not hold what was set")
    }
    // The system refuses: the answer is what it still says, not what was asked.
    loginItem.refuses = true
    expectSettings(settings("return await window.backspace.setAutoLaunchSettings({ openAtLogin: false });"),
                   openAtLogin: true, startMinimized: false, "a change the system refused")
    expectSettings(settings("return await window.backspace.getAutoLaunchSettings();"),
                   openAtLogin: true, startMinimized: false, "the settings after a refusal")

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "launch: links held until the page listens, auto-launch settings through the bridge"
        : "launch: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The notifications check. Ends the process.
func checkNotifications() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let presenter = CheckNotificationPresenter()
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: presenter
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }

    var hasEnded = false
    var loadError: Error?
    shell.onMainFrameLoadEnded = { error in
        hasEnded = true
        loadError = error
    }
    shell.load(address)
    guard wait(until: { hasEnded }), loadError == nil else {
        fail("the local page did not load: \(loadError?.localizedDescription ?? "no answer")")
    }

    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    func clicks() -> [[String: String]]? {
        page("return window.__clicks;") as? [[String: String]]
    }

    // 1. What the page asks for reaches the presenter, with the page's origin.
    _ = page("""
        window.__clicks = [];
        window.backspace.onNotificationClick((options) => window.__clicks.push(options));
        window.backspace.showNotification('Ann', 'hello', { spaceId: '1', channelId: '2' });
        window.backspace.showNotification('Plain');
        window.backspace.showNotification('', 'nothing to show');
        return true;
        """)
    let expected = [
        NotificationRequest(title: "Ann", body: "hello", origin: origin, optionsJSON: #"{"channelId":"2","spaceId":"1"}"#),
        NotificationRequest(title: "Plain", body: "", origin: origin, optionsJSON: nil),
    ]
    if !wait(5, until: { presenter.shown.count >= expected.count }) || presenter.shown != expected {
        problems.append("the presenter was asked for \(presenter.shown), expected \(expected)")
    }

    // 2. A click hands the payload back to the page; one without a payload,
    //    and one from another origin, only bring the window forward.
    if presenter.shown.count == expected.count {
        presenter.onClick?(presenter.shown[0].userInfo)
        presenter.onClick?(presenter.shown[1].userInfo)
    }
    presenter.onClick?(NotificationRequest(
        title: "Elsewhere", body: "", origin: "https://other.example.test", optionsJSON: #"{"channelId":"9"}"#
    ).userInfo)
    if !wait(5, until: { clicks()?.isEmpty == false }) {
        problems.append("a click did not reach the page")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    if clicks() != [["spaceId": "1", "channelId": "2"]] {
        problems.append("the page got the clicks \(String(describing: clicks())), expected one, with the payload it gave")
    }

    // 3. The badge on the Dock icon.
    func badge(after script: String) -> String? {
        _ = page(script + " return true;")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return NSApp.dockTile.badgeLabel
    }
    if badge(after: "window.backspace.setBadgeCount(7);") != "7" {
        problems.append("setBadgeCount(7) left the badge at \(String(describing: NSApp.dockTile.badgeLabel))")
    }
    if badge(after: "window.backspace.setBadgeCount(0);") != nil {
        problems.append("setBadgeCount(0) did not clear the badge")
    }
    if badge(after: "window.backspace.setBadgeCount(3); window.backspace.setBadgeCount('many');") != nil {
        problems.append("a count that is not a number did not clear the badge")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "notifications: asked for with the page's origin, clicks back to the same origin only, badge set and cleared"
        : "notifications: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The actions of the menu in a check run: they do nothing.
final class CheckMenuActions: NSObject, AppMenuActions {
    func openSourceCode(_ sender: Any?) {}
    func changeInstance(_ sender: Any?) {}
}

/// The menu check. Ends the process.
func checkMenu() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let shell: MainWindowController
    let blank = temporary.appendingPathComponent("blank.html", isDirectory: false)
    do {
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try Data("<!doctype html><title></title>".utf8).write(to: blank)
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil
        )
    } catch {
        fail(String(describing: error))
    }

    // 1. The menu bar, in every language.
    let actions = CheckMenuActions()
    let shortcuts: [String: String] = [
        "hide:": "h", "hideOtherApplications:": "h", "terminate:": "q",
        "undo:": "z", "redo:": "z", "cut:": "x", "copy:": "c", "paste:": "v", "selectAll:": "a",
        "performMiniaturize:": "m", "performClose:": "w",
    ]
    var titlesByLanguage: [DesktopLanguage: [String]] = [:]
    if strings.languages.count < 5 { problems.append("the catalog has \(strings.languages.count) languages, expected the web client's five") }
    for language in strings.languages {
        let menu = AppMenu.build(strings: strings, language: language, actions: actions)
        var titles: [String] = []
        var seen: Set<String> = []
        if menu.items.count != 3 { problems.append("\(language.code): \(menu.items.count) menus, expected 3") }
        for top in menu.items {
            titles.append(top.title)
            for item in top.submenu?.items ?? [] where !item.isSeparatorItem {
                titles.append(item.title)
                let action = item.action.map(NSStringFromSelector) ?? ""
                if item.title.isEmpty || item.title.contains("{") || item.title.contains("mac.") || item.title.contains("tray.") {
                    problems.append("\(language.code): an item with the title '\(item.title)' (\(action))")
                }
                if action.isEmpty { problems.append("\(language.code): '\(item.title)' does nothing") }
                if let shortcut = shortcuts[action] {
                    seen.insert(action)
                    if item.keyEquivalent != shortcut {
                        problems.append("\(language.code): '\(item.title)' has the shortcut '\(item.keyEquivalent)', expected '\(shortcut)'")
                    }
                }
                if action == "openSourceCode:" || action == "changeInstance:" {
                    seen.insert(action)
                    if item.target !== actions { problems.append("\(language.code): '\(item.title)' has no target") }
                }
            }
        }
        let expected = Set(shortcuts.keys).union(["openSourceCode:", "changeInstance:"])
        if seen != expected {
            problems.append("\(language.code): the menu lacks \(expected.subtracting(seen).sorted())")
        }
        titlesByLanguage[language] = titles
    }
    // A translation that is missing would repeat the English one.
    if let english = titlesByLanguage[strings.english] {
        for language in strings.languages where language != strings.english {
            let same = zip(english, titlesByLanguage[language] ?? []).filter { $0 == $1 }.map(\.0)
            // The app's name, and a word that is the same in both languages.
            if same.count > 2 {
                problems.append("\(language.code): these titles are the English ones: \(same)")
            }
        }
    }

    // 2. The language follows the page.
    var hasEnded = false
    shell.onMainFrameLoadEnded = { _ in hasEnded = true }
    shell.load(blank)
    guard wait(until: { hasEnded }) else { fail("the empty page did not load") }
    func page(_ script: String) {
        var isDone = false
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { _ in isDone = true }
        _ = wait(until: { isDone })
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    }
    var reported: [String] = []
    shell.onLanguageChanged = { reported.append($0.code) }
    let store = LanguageStore(directory: temporary)

    if shell.language != strings.english { problems.append("the shell should start in the language it was given") }
    page("window.backspace.setLanguage('ru');")
    if shell.language.code != "ru" || reported != ["ru"] {
        problems.append("setLanguage('ru') left the shell in \(shell.language.code), reported \(reported)")
    }
    if store.load() != "ru" { problems.append("language.json does not hold the language that was set") }
    page("window.backspace.setLanguage('xx'); window.backspace.setLanguage(); window.backspace.setLanguage(7);")
    if shell.language.code != "ru" || reported != ["ru"] || store.load() != "ru" {
        problems.append("a language the shell does not have changed it")
    }
    page("window.backspace.setLanguage('ru');")
    if reported != ["ru"] { problems.append("the same language again was reported as a change") }
    page("window.backspace.setLanguage('zh');")
    if shell.language.code != "zh" || reported != ["ru", "zh"] || store.load() != "zh" {
        problems.append("setLanguage('zh') left the shell in \(shell.language.code)")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "menu: built in \(strings.languages.count) languages, the language follows the page"
        : "menu: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

switch checkName {
case nil:
    break
case "menu":
    checkMenu()
case "notifications":
    checkNotifications()
case "launch":
    checkLaunch()
case "window-state":
    checkWindowState()
case "local-storage-import":
    checkLocalStorageImport(fixture: fileURL(arguments, "fixture"))
default:
    fail("--check takes window-state, local-storage-import, launch, notifications, menu or electron-profile")
}

let contract: BridgeContract
let controller: MainWindowController
do {
    contract = try BridgeContract(data: Data(contentsOf: contractURL))
    controller = try MainWindowController(environment: environment, showsWindow: false, loginItem: CheckLoginItem(), notifications: nil)
} catch {
    fail(String(describing: error))
}
let members = contract.members(of: .backspace)

func finish(report: [String: Any]) -> Never {
    try? FileManager.default.removeItem(at: temporary)
    let found = violations(report: report, members: members)
    let output: [String: Any] = ["violations": found, "report": report]
    guard let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) else {
        fail("the report is not serialisable")
    }
    if let path = arguments["out"] {
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            fail("cannot write \(path): \(error.localizedDescription)")
        }
    } else {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
    for line in found {
        FileHandle.standardError.write(Data("ContractCheck: \(line)\n".utf8))
    }
    exit(found.isEmpty ? 0 : 1)
}

/// What a page of a live instance says about itself.
let visitScript = """
const root = document.getElementById('root');
return {
  href: location.href,
  title: document.title,
  userAgent: navigator.userAgent,
  bridge: typeof window.backspace,
  platform: window.backspace ? window.backspace.platform : null,
  version: window.backspace ? await window.backspace.getVersion() : null,
  rootChildren: root ? root.children.length : -1,
  textSample: document.body ? document.body.innerText.replace(/\\s+/g, ' ').trim().slice(0, 200) : '',
};
"""

func visit(_ address: String) {
    guard let url = InstanceURLStore.loadableURL(address) else { fail("--visit takes an http or https address") }
    let settle = TimeInterval(arguments["settle"] ?? "5") ?? 5
    var script = visitScript
    if arguments["script"] != nil {
        guard let custom = try? String(contentsOf: fileURL(arguments, "script"), encoding: .utf8) else {
            fail("--script is not readable as UTF-8 text")
        }
        script = custom
    }
    var loaded = false
    controller.onMainFrameLoadEnded = { error in
        if let error { fail("\(address) did not load: \(error.localizedDescription)") }
        guard !loaded else { return }
        loaded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + settle) {
            controller.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { result in
                try? FileManager.default.removeItem(at: temporary)
                switch result {
                case .failure(let error):
                    fail("the page could not be asked: \(error.localizedDescription)")
                case .success(let value):
                    guard
                        let facts = value as? [String: Any],
                        let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
                    else { fail("the page gave no answer") }
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    exit(0)
                }
            }
        }
    }
    controller.load(url)
}

var started = false
func checkContract(harnessURL: URL) {
    controller.onMainFrameLoadEnded = { error in
        if let error { fail("the harness did not load: \(error.localizedDescription)") }
        guard !started else { return }
        started = true

        let table: [[String: Any]] = members.map { member in
            var row: [String: Any] = ["name": member.name, "kind": member.kind.rawValue]
            if let channel = member.channel { row["channel"] = channel }
            if let unsubscribe = member.unsubscribe { row["unsubscribe"] = unsubscribe }
            return row
        }
        controller.webView.callAsyncJavaScript(
            "window.contractCheck.prepare(bridge, members, skipCalls);",
            arguments: ["bridge": BridgeContract.Bridge.backspace.rawValue, "members": table, "skipCalls": skippedCalls],
            in: nil,
            in: .page
        ) { result in
            if case .failure(let error) = result { fail("prepare() failed: \(error.localizedDescription)") }
            for channel in contract.eventChannels(of: .backspace).sorted() {
                controller.bridge.emit(channel, payload: ["probe": channel])
            }
            controller.webView.callAsyncJavaScript("return await window.contractCheck.finish();", arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .failure(let error):
                    fail("finish() failed: \(error.localizedDescription)")
                case .success(let value):
                    guard let report = value as? [String: Any] else { fail("finish() returned no report") }
                    finish(report: report)
                }
            }
        }
    }

    controller.load(harnessURL)
}

DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
    fail("timed out after 30 seconds")
}
if let visitAddress {
    visit(visitAddress)
} else if let harnessURL {
    checkContract(harnessURL: harnessURL)
}
application.run()
