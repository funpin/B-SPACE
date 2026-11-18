import AppKit
import BSpaceCore
import BSpaceShell
import CoreMedia
import CoreVideo
import Network
import WebKit

// Runs the bridge contract check against the real shell: the same window
// controller, web view configuration and bridge the application uses, with no
// window on screen and its settings in a temporary folder. Loads
// contract/harness.html, lets it call every member of `window.backspace`,
// sends one event on every event channel, and compares what the page saw with
// what bridgeContract.json promises.
//
// Usage: ContractCheck --contract <json> --picker <html> --strings <json> --recovery <html>
//                      --harness <html> [--out <json>]
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
// With --check recovery it checks recovery mode on the real shell, with its
// clocks shortened: an address that cannot be loaded ends on the recovery
// page with the reason, a second failure changes what that page says without
// loading it again, Reload and Change Instance leave recovery, a page that
// never reports that it started is called stalled and one that reports is
// left alone, a page whose thread is stuck is called unresponsive, and Quit
// reaches the app.
//
// With --check drag it checks, on the real shell, which parts of the window
// the system is told it is dragged by: the top strip on a page that reported
// nothing, what `setDragRegions` reported once it has, the top strip again on
// the next page, and how those follow the window's size; that the page sees
// nothing of a press on such a part and all of one anywhere else; and that a
// double click asks the system's setting. The drag itself is the system's:
// it needs a real mouse and is not part of this check.
//
// With --check tray it checks the tray on the real shell, with something that
// records what the tray is given in place of the menu bar: the character
// plays the loop of the state the page reports and ignores a state that is
// not one, the menu has the row of buttons the page's context allows (fewer
// for a web client that does not report the camera, the screen share and the
// pointers), a pressed button comes back to the page as a `tray-action`, Open
// and Quit do what they say, the menu follows the page's language, and
// another page starts from an empty menu and a resting character.
//
// With --check activity it checks game detection on the real shell, with a
// list of processes and an answer of the network that the check makes up:
// the page hears of a game once when it starts and once when it ends and
// reads the same from `getCurrentActivity`, a newer dictionary that was
// fetched is saved with its tag and used, a second start reads the saved one
// and names its tag, and detection stops when the processes cannot be
// listed. Nothing is fetched; the real list of processes is read once, to
// see that the system gives it.
//
// With --check activity-network it fetches the games dictionary from the
// project's repository once, the way the app does, and prints what came
// back. It is the one check that uses the network, and is not part of
// contract-check.sh.
//
// With --check keybinds it checks the global keybinds on the real shell, with
// a keyboard and a permission that the check makes up: without the
// permission nothing is listened to, the page is told so and the system is
// asked once; with it the synced keybinds are listened for and a held key
// presses its action once, and a release the system never reported ends it
// all the same; an empty list stops the listening; a list that
// cannot be read changes nothing; the page's request opens the permission's
// settings; a listener the system will not start is reported; another page
// starts with no keybinds. No real key is listened to.
//
// With --check sources it checks the list of what can be shared on the real
// shell, with a list the check makes up: a focused window gets it in the
// shape the web client reads, a second request within a second and a window
// that is not focused get the list they had, two requests at once share one
// listing, and another page starts with nothing. The screen is not looked at.
//
// With --check sources-system it asks the system once for the real list and
// prints how many displays and windows there are and how large their
// pictures are; no name, title or picture is printed. It needs the Screen
// Recording permission and is not part of contract-check.sh.
//
// With --check media-channel it checks the local channel captured media
// reach the page on, on the real shell and a page served from the loopback
// address: a window with no page gets none; a connection that says a wrong
// token is closed and hears nothing; the one that says the token gets 240
// messages of 40 KB at 60 a second, and how long they took is printed; what
// the page says back reaches the shell; the token works once; a channel the
// shell did not open is not trusted; the channel closes with its page.
//
// With --check video-pipe [--size 1920x1080] it sends 300 frames the check
// draws itself, at 60 a second, through the encoder and the local channel
// to a worker of the page that decodes them into a track, the way the web
// client will: every frame has to be decoded, in the announced format, with
// no decoder error; the page's request for a key frame has to be honoured;
// a page that falls behind throws away what waits and starts again from a
// frame it asks for, and the check says how often that happened;
// how long a frame takes from being made to being decoded is printed.
// Nothing of the screen is captured. It measures the machine's hardware
// encoder and is not part of contract-check.sh.
//
// With --check capture it starts shares through the bridge, as the web client
// will, with a screen the check makes up: who picks the source is answered
// by what the client says it can do; a request without a source or for one
// that is gone starts nothing; a share is fitted into what was asked for and
// decoded in the page; a screen standing still gives a picture to a page that
// connects late and to a decoder that asks; a share ends when the page stops
// it, when the capture ends by itself (the page is told) and with its page.
// The real screen is not captured.
//
// With --check capture-web [--url http://localhost:5173/dev-native-capture.html]
// it loads the web package's workbench page from a running Vite server and
// has the web client's own capture code (its worker included) take a capture
// of a screen the check makes up: the track plays in a video element at the
// size asked for, follows other limits behind the same track, says when the
// capture ends, stops the capture when it is stopped, and reports a source
// that is gone. It needs the dev server and is not part of contract-check.sh.
//
// With --check capture-system [--size 1920x1080] [--frame-rate 60]
// [--seconds 5] it captures the main display for a few seconds through the
// whole path and prints the size, how many frames the page decoded and how
// long they took. The pictures go no further than the page of the check. It
// needs the Screen Recording permission and is not part of contract-check.sh.
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
let pickerSourceURL = fileURL(arguments, "picker")
let stringsURL = fileURL(arguments, "strings")
let recoveryURL = fileURL(arguments, "recovery")
let visitAddress = arguments["visit"]
let checkName = arguments["check"]
let harnessURL = visitAddress == nil && checkName == nil ? fileURL(arguments, "harness") : nil

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("bspace-contract-check-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

/// Where the checks keep their copy of the picker; removed when the process ends.
let pickerPagesFolder = FileManager.default.temporaryDirectory
    .appendingPathComponent("bspace-contract-check-pages-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

/// The picker as the checks load it: the page of the Electron build without
/// its one request to the network, a font imported from Google Fonts. Behind
/// a proxy that answers for every host name that request neither fails nor
/// ends, the page never finishes loading, and a check that waits for a page
/// would wait on the network. The copy is kept apart from the settings
/// folder, which the checks create and remove.
let pickerURL: URL = {
    guard let page = try? String(contentsOf: pickerSourceURL, encoding: .utf8) else {
        fail("--picker is not readable as UTF-8 text")
    }
    let offline = page
        .split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.contains("fonts.googleapis.com") }
        .joined(separator: "\n")
    let copy = pickerPagesFolder.appendingPathComponent("instance-picker.html")
    do {
        try FileManager.default.createDirectory(at: pickerPagesFolder, withIntermediateDirectories: true)
        try Data(offline.utf8).write(to: copy)
    } catch {
        fail("could not write the picker for the checks: \(error.localizedDescription)")
    }
    // Every check ends the process with exit(), which runs no defer.
    atexit { try? FileManager.default.removeItem(at: pickerPagesFolder) }
    return copy
}()
let strings: DesktopStrings
do {
    strings = try DesktopStrings(data: Data(contentsOf: stringsURL))
} catch {
    fail("cannot read the strings: \(error)")
}
let environment = ShellEnvironment(
    resources: ShellResources(pickerURL: pickerURL, contractURL: contractURL, stringsURL: stringsURL, recoveryURL: recoveryURL),
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

    func prepare() {}

    func show(_ request: NotificationRequest) {
        shown.append(request)
    }
}

/// A keyboard the check presses the keys of.
final class CheckKeyInputSource: KeyInputSource {
    var onInput: ((KeyInput) -> Void)?
    var onInterrupted: (() -> Void)?
    var isStarted = false
    var starts = 0
    /// False: the system will not start the listener.
    var canStart = true

    func start() -> Bool {
        starts += 1
        isStarted = canStart
        return canStart
    }

    func stop() {
        isStarted = false
    }

    func send(_ input: KeyInput) {
        onInput?(input)
    }
}

/// Says which keys are really down, as the check tells it to.
final class CheckKeyStateProbe: KeyStateProbe {
    /// The keys that are not down, whatever was reported.
    var releasedKeys: Set<UInt16> = []

    func isKeyDown(_ keyCode: UInt16) -> Bool {
        !releasedKeys.contains(keyCode)
    }

    func isMouseButtonDown(_ button: Int) -> Bool {
        true
    }
}

/// A permission the check gives and takes.
final class CheckKeybindPermission: KeybindPermission {
    var isGranted = false
    var requests = 0
    var settingsOpened = 0

    func request() {
        requests += 1
    }

    func openSettings() {
        settingsOpened += 1
    }
}

/// Says which processes are running, as the check tells it to.
final class CheckProcessLister: ProcessLister {
    /// Nil: the processes cannot be listed.
    var names: Set<String>? = []
    var asked = 0

    func runningProcessNames(completion: @escaping (Set<String>?) -> Void) {
        asked += 1
        let answer = names
        DispatchQueue.main.async { completion(answer) }
    }
}

/// Answers for the network, as the check tells it to, and keeps the tags it
/// was asked with.
final class CheckDictionaryFetcher: GameDictionaryFetcher {
    var answer: (status: Int, body: Data, etag: String?)?
    var knownTags: [String?] = []

    func fetch(knownTag: String?, completion: @escaping ((status: Int, body: Data, etag: String?)?) -> Void) {
        knownTags.append(knownTag)
        let answer = self.answer
        DispatchQueue.main.async { completion(answer) }
    }
}

/// Records what the tray is given, in place of the menu bar.
final class CheckTrayPresenter: TrayPresenter {
    var onCommand: ((TrayMenuCommand) -> Void)?
    var frames: [TrayFrame] = []
    var menu: [TrayMenuItem] = []

    func show(_ frame: TrayFrame) {
        frames.append(frame)
    }

    func setMenu(_ items: [TrayMenuItem]) {
        menu = items
    }

    /// The titles of the menu, one string per item.
    var titles: [String] {
        menu.map {
            switch $0 {
            case .separator: return "-"
            case .label(let title): return "(\(title))"
            case .action(let title, _): return title
            case .toggle(let title, let isOn, _): return (isOn ? "[x] " : "[ ] ") + title
            case .controls(let controls): return "{" + controls.map(\.title).joined(separator: " | ") + "}"
            }
        }
    }

    /// Chooses the item, or presses the button of the row, with this title.
    func choose(_ title: String) -> Bool {
        for item in menu {
            switch item {
            case .action(title, let command), .toggle(title, _, let command):
                onCommand?(command)
                return true
            case .controls(let controls):
                if let control = controls.first(where: { $0.title == title }) {
                    onCommand?(control.command)
                    return true
                }
            default:
                continue
            }
        }
        return false
    }
}

/// Serves pages on the loopback address, on a port the system picks: pages
/// with a real http origin, with nothing asked of the network outside this
/// machine. A path with no page of its own gets an empty one.
final class LocalPageServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "local-page-server")

    /// - Parameter pages: the document for a path ("/ready"), as HTML.
    init(pages: [String: String] = [:]) throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { request, _, _, _ in
                // "GET /path HTTP/1.1": the path is the second word.
                let line = request.flatMap { String(data: $0, encoding: .utf8) }?.split(separator: "\r\n").first ?? ""
                let path = line.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
                let body = pages[path] ?? "<!doctype html><title>check</title>"
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

/// A list of sources the check makes up; counts how often it is asked.
final class CheckScreenSourceLister: ScreenSourceLister {
    var sources: [ScreenSource] = []
    private(set) var asked = 0
    /// Holds the answers back until `answer()` is called.
    var holdsAnswers = false
    private var held: [() -> Void] = []

    func listSources(completion: @escaping ([ScreenSource]) -> Void) {
        asked += 1
        let sources = self.sources
        if holdsAnswers {
            held.append { completion(sources) }
        } else {
            DispatchQueue.main.async { completion(sources) }
        }
    }

    func answer() {
        let answers = held
        held = []
        answers.forEach { $0() }
    }
}

func checkSources() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let lister = CheckScreenSourceLister()
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil,
            screenSources: lister
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }
    var focused = true
    shell.isWindowFocused = { focused }

    func load(_ url: URL) {
        var hasEnded = false
        var loadError: Error?
        shell.onMainFrameLoadEnded = { error in
            hasEnded = true
            loadError = error
        }
        shell.load(url)
        guard wait(until: { hasEnded }), loadError == nil else {
            fail("the local page did not load: \(loadError?.localizedDescription ?? "no answer")")
        }
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    func listed() -> [[String: Any]]? {
        page("return await window.backspace.getScreenSources();") as? [[String: Any]]
    }
    func ids(_ list: [[String: Any]]?) -> [String]? {
        list?.compactMap { $0["id"] as? String }
    }

    let picture = Data([0x89, 0x50, 0x4e, 0x47])
    let display = ScreenSource(kind: .display(1), name: "Built-in Display", thumbnailPNG: picture)
    let window = ScreenSource(kind: .window(4821), name: "Notes", thumbnailPNG: picture, appIconPNG: Data([1, 2, 3]))
    lister.sources = [display, window]
    load(address)

    // 1. A focused window gets the list, in the shape the web client reads.
    let first = listed()
    if lister.asked != 1 || ids(first) != ["screen:1:0", "window:4821:0"] {
        problems.append("the first request listed \(String(describing: ids(first))) after \(lister.asked) listing(s)")
    }
    if let source = first?.last {
        if source["name"] as? String != "Notes" || source["isScreen"] as? Bool != false
            || source["thumbnailDataUrl"] as? String != "data:image/png;base64,iVBORw=="
            || source["appIconDataUrl"] as? String != "data:image/png;base64,AQID" {
            problems.append("a window reached the page as \(source)")
        }
    }
    if let source = first?.first, source["isScreen"] as? Bool != true || !(source["appIconDataUrl"] is NSNull) {
        problems.append("a display reached the page as \(source)")
    }

    // 2. Asked again at once, the page gets the list it had: no new pictures.
    lister.sources = [display]
    if ids(listed()) != ["screen:1:0", "window:4821:0"] || lister.asked != 1 {
        problems.append("a second request within a second took new pictures (\(lister.asked) listings)")
    }

    // 3. After a second it gets a new one.
    RunLoop.main.run(until: Date().addingTimeInterval(ScreenSourceGate.cacheInterval + 0.1))
    if ids(listed()) != ["screen:1:0"] || lister.asked != 2 {
        problems.append("a request a second later did not take new pictures (\(lister.asked) listings)")
    }

    // 4. A window that is not focused gets the list it had, however long ago.
    focused = false
    lister.sources = [display, window]
    RunLoop.main.run(until: Date().addingTimeInterval(ScreenSourceGate.cacheInterval + 0.1))
    if ids(listed()) != ["screen:1:0"] || lister.asked != 2 {
        problems.append("a window that is not focused took new pictures (\(lister.asked) listings)")
    }

    // 5. Two requests while one list is being made share it.
    focused = true
    lister.holdsAnswers = true
    _ = page("""
        window.__lists = [];
        window.backspace.getScreenSources().then((list) => window.__lists.push(list.length));
        window.backspace.getScreenSources().then((list) => window.__lists.push(list.length));
        return true;
        """)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    lister.answer()
    lister.holdsAnswers = false
    if !wait(5, until: { (page("return window.__lists;") as? [Int])?.count == 2 })
        || page("return window.__lists;") as? [Int] != [2, 2] || lister.asked != 3 {
        problems.append("two requests at once were answered \(String(describing: page("return window.__lists;"))) after \(lister.asked) listings, expected one listing for both")
    }

    // 6. Another page starts with nothing: unfocused, it gets no list at all.
    focused = false
    load(URL(string: origin + "/next")!)
    if ids(listed()) != [] || lister.asked != 3 {
        problems.append("another page was given the list made for the one before it")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "sources: listed for a focused window, at most once a second, shared by requests made at once, not carried to another page"
        : "sources: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

func checkMediaChannel() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
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
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }

    func load(_ url: URL) {
        var hasEnded = false
        var loadError: Error?
        shell.onMainFrameLoadEnded = { error in
            hasEnded = true
            loadError = error
        }
        shell.load(url)
        guard wait(until: { hasEnded }), loadError == nil else {
            fail("the local page did not load: \(loadError?.localizedDescription ?? "no answer")")
        }
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(30, until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    /// The page's side: connects, says `token` first, counts what arrives
    /// until `expected` messages have or the connection closes.
    let pageScript = """
        window.channel = (url, token, expected) => new Promise((resolve) => {
          const out = { opened: false, messages: 0, bytes: 0, delays: [] };
          let socket;
          try { socket = new WebSocket(url); } catch (error) { out.error = error.name; resolve(out); return; }
          socket.binaryType = 'arraybuffer';
          window.socket = socket;
          const finish = () => {
            const d = out.delays.sort((a, b) => a - b);
            delete out.delays;
            if (d.length) { out.p50 = d[Math.floor(d.length / 2)]; out.p95 = d[Math.floor(d.length * 0.95)]; out.max = d[d.length - 1]; }
            resolve(out);
          };
          socket.onopen = () => { out.opened = true; if (token !== null) socket.send(token); if (expected === 0) setTimeout(finish, 600); };
          socket.onmessage = (event) => {
            out.messages += 1;
            out.bytes += event.data.byteLength;
            out.delays.push(Date.now() - new DataView(event.data).getFloat64(0, true));
            if (out.messages === expected) finish();
          };
          socket.onclose = () => { out.closed = true; finish(); };
          setTimeout(finish, 12000);
        });
        return true;
        """
    func open() -> (LocalMediaChannel, LocalMediaChannel.Endpoint) {
        var opened: (LocalMediaChannel, LocalMediaChannel.Endpoint)?
        var failure: LocalMediaChannel.Failure?
        shell.openMediaChannel { result in
            switch result {
            case .success(let made): opened = (made.channel, made.endpoint)
            case .failure(let reason): failure = reason
            }
        }
        guard wait(10, until: { opened != nil || failure != nil }), let opened else {
            fail("the media channel did not open: \(String(describing: failure))")
        }
        return opened
    }
    func connect(_ endpoint: LocalMediaChannel.Endpoint, token: String?, expected: Int) -> [String: Any] {
        let said = token.map { "'\($0)'" } ?? "null"
        return page("return await window.channel('\(endpoint.url)', \(said), \(expected));") as? [String: Any] ?? [:]
    }

    // 0. A window that shows no page of a server gets no channel.
    var refusal: LocalMediaChannel.Failure?
    shell.openMediaChannel { result in
        if case .failure(let reason) = result { refusal = reason }
    }
    if !wait(5, until: { refusal != nil }) || refusal != .noPage {
        problems.append("a window with no page was given a media channel (\(String(describing: refusal)))")
    }

    load(address)
    _ = page(pageScript)
    let (channel, endpoint) = open()
    var connected = 0
    var disconnected = 0
    var heard: [Data] = []
    channel.onClientConnected = { connected += 1 }
    channel.onClientDisconnected = { disconnected += 1 }
    channel.onMessage = { heard.append($0) }

    if !endpoint.url.hasPrefix("wss://127.0.0.1:") || endpoint.token.count != 64 {
        problems.append("the page would be told to connect to \(endpoint.url) with a token of \(endpoint.token.count) characters")
    }
    if channel.send(Data([1, 2, 3])) {
        problems.append("a message was sent with nobody connected")
    }

    // 1. A connection that says the wrong thing, or nothing it should, is closed
    //    and hears nothing; neither spends the token.
    let wrong = connect(endpoint, token: String(repeating: "0", count: 64), expected: 0)
    if wrong["opened"] as? Bool != true || wrong["closed"] as? Bool != true || wrong["messages"] as? Int != 0 || connected != 0 {
        problems.append("a connection with a wrong token ended as \(wrong)")
    }

    // 2. The one that says the token gets the channel: 240 messages of 40 KB,
    //    60 a second, each stamped with the moment it left.
    var report: [String: Any]?
    shell.webView.callAsyncJavaScript(
        "return await window.channel('\(endpoint.url)', '\(endpoint.token)', 240);", arguments: [:], in: nil, in: .page
    ) { result in
        if case .success(let value) = result { report = value as? [String: Any] }
    }
    guard wait(10, until: { connected == 1 }) else {
        fail("the page said the token and was not let in")
    }
    var sent = 0
    var dropped = 0
    let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { timer in
        var message = Data(count: 40_000)
        var stamp = Date().timeIntervalSince1970 * 1000
        withUnsafeBytes(of: &stamp) { message.replaceSubrange(0..<8, with: $0) }
        if !channel.send(message) { dropped += 1 }
        sent += 1
        if sent == 240 { timer.invalidate() }
    }
    _ = wait(20, until: { report != nil })
    timer.invalidate()
    let messages = report?["messages"] as? Int ?? 0
    let p95 = report?["p95"] as? Double ?? -1
    if messages != 240 || report?["bytes"] as? Int != 240 * 40_000 || dropped != 0 {
        problems.append("the page got \(messages) of 240 messages (\(dropped) dropped): \(String(describing: report))")
    }
    // A loose bound: the number itself is printed, and a busy machine
    // must not fail the check.
    if p95 < 0 || p95 > 250 {
        problems.append("95 of 100 messages should arrive within 250 ms, took \(p95)")
    }

    // 3. What the page says after the token reaches the shell.
    _ = page("window.socket.send(new Uint8Array([7, 8, 9])); return true;")
    if !wait(5, until: { !heard.isEmpty }) || heard != [Data([7, 8, 9])] {
        problems.append("the shell heard \(heard.map { [UInt8]($0) }) from the page, expected one message")
    }

    // 4. The token works once: a second connection that says it is closed.
    let second = connect(endpoint, token: endpoint.token, expected: 0)
    if second["closed"] as? Bool != true || connected != 1 {
        problems.append("a second connection with the same token ended as \(second)")
    }

    // 5. A channel the shell did not open is not trusted: the page cannot
    //    reach it at all.
    var stranger: LocalMediaChannel?
    var strangerEndpoint: LocalMediaChannel.Endpoint?
    do {
        let made = try LocalMediaChannel(pageOrigin: origin)
        stranger = made
        made.start { result in
            if case .success(let endpoint) = result { strangerEndpoint = endpoint }
        }
    } catch {
        problems.append("another channel could not be made: \(error)")
    }
    if wait(5, until: { strangerEndpoint != nil }), let strangerEndpoint {
        let untrusted = connect(strangerEndpoint, token: strangerEndpoint.token, expected: 0)
        if untrusted["opened"] as? Bool != false {
            problems.append("the page reached a channel whose certificate the shell does not vouch for: \(untrusted)")
        }
    } else {
        problems.append("another channel did not start")
    }
    stranger?.stop()

    // 6. Another page: the channel closes, and nothing can connect to it.
    load(URL(string: origin + "/next")!)
    if !wait(5, until: { disconnected == 1 }) {
        problems.append("the channel outlived its page")
    }
    _ = page(pageScript)
    let after = connect(endpoint, token: endpoint.token, expected: 0)
    if after["opened"] as? Bool != false {
        problems.append("the next page reached the channel of the page before it: \(after)")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    let p50 = report?["p50"] as? Double ?? -1
    let longest = report?["max"] as? Double ?? -1
    print(problems.isEmpty
        ? "media channel: only the token opens it, once; 240 messages of 40 KB at 60 a second took \(String(format: "%.1f", p50)) ms at the median, \(String(format: "%.1f", p95)) at the 95th percentile, \(String(format: "%.1f", longest)) at most; closed with its page"
        : "media channel: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// Frames the check draws itself: squares that slide a little every frame,
/// with a line of noise every `noiseEvery` rows, so that every frame differs
/// from the last and the encoder has something to do. Nothing of the screen
/// is in them.
final class CheckFrameSource {
    let width: Int
    let height: Int
    /// One row in this many is noise that changes with every frame: 32 is a
    /// busy picture, 4 one that no bitrate carries well.
    private let noiseEvery: Int
    private var pool: CVPixelBufferPool?
    private let noise: [UInt8]
    /// One row of stripes, long enough to be read from any offset.
    private let stripes: [UInt8]
    /// How far along `stripes` the pattern repeats.
    private static let stripePeriod = 64 * 256

    init(width: Int, height: Int, noiseEvery: Int) {
        self.width = width
        self.height = height
        self.noiseEvery = max(1, noiseEvery)
        var state: UInt64 = 0x9e37_79b9_7f4a_7c15
        stripes = (0..<(width + Self.stripePeriod)).map { UInt8(truncatingIfNeeded: ($0 / 64) * 37) }
        noise = (0..<((1 << 16) + width)).map { _ in
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt8(truncatingIfNeeded: state >> 56)
        }
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary, &pool)
    }

    func frame(_ index: Int) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var made: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        guard let buffer = made else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)?.assumingMemoryBound(to: UInt8.self) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            // Rows are copied, not computed: the check has to keep up with
            // sixty frames a second at any size.
            noise.withUnsafeBufferPointer { noise in
                stripes.withUnsafeBufferPointer { stripes in
                    for y in 0..<height {
                        let row = luma + y * stride
                        if y % noiseEvery == 0 {
                            memcpy(row, noise.baseAddress! + ((y * 131 + index * 7919) & 0xffff), width)
                        } else {
                            // Squares that slide eight pixels a frame.
                            memcpy(row, stripes.baseAddress! + (index * 8 + 64 * (y / 64)) % Self.stripePeriod, width)
                        }
                    }
                }
            }
        }
        if let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            memset(chroma, 128, CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) * CVPixelBufferGetHeightOfPlane(buffer, 1))
        }
        return buffer
    }
}

/// The page's side of native capture, as the web client will have it: a
/// worker reads the channel, decodes, and writes the frames into a track it
/// hands to the page.
let videoPipePage = """
    const workerSource = `
      let decoder = null, writer = null, socket = null, writes = true, configuration = null, catchingUp = false;
      const stats = { formats: [], decoded: 0, delays: [], errors: [], firstAt: 0, lastAt: 0, keyFrames: 0, deltaFrames: 0, mostQueued: 0, fellBehind: 0, skipped: 0 };
      // More frames than this waiting to be decoded means the page cannot
      // keep up; what waits is thrown away and decoding starts again from
      // a frame asked for, so that being late never adds up.
      const mostWaiting = 4;
      function configure(message) {
        if (decoder) decoder.close();
        stats.formats.push({ codec: message.codec, width: message.width, height: message.height });
        decoder = new VideoDecoder({
          output: (frame) => {
            const now = Date.now();
            stats.decoded += 1;
            stats.delays.push(now - frame.timestamp / 1000);
            if (!stats.firstAt) stats.firstAt = now;
            stats.lastAt = now;
            if (!writes) { frame.close(); return; }
            writer.write(frame).then(() => frame.close(), (error) => { stats.errors.push('write: ' + error.name); frame.close(); });
          },
          error: (error) => stats.errors.push('decode: ' + error.name + ' ' + error.message),
        });
        configuration = {
          codec: message.codec, codedWidth: message.width, codedHeight: message.height,
          description: Uint8Array.from(atob(message.description), (c) => c.charCodeAt(0)),
          optimizeForLatency: true,
        };
        decoder.configure(configuration);
      }
      onmessage = (event) => {
        if (event.data.ask === 'stats') { stats.queued = decoder ? decoder.decodeQueueSize : -1; postMessage({ stats }); return; }
        if (event.data.ask === 'keyframe') { socket.send(JSON.stringify({ type: 'keyframe' })); return; }
        writes = event.data.sink !== 'none';
        const generator = new VideoTrackGenerator();
        writer = generator.writable.getWriter();
        postMessage({ track: generator.track }, [generator.track]);
        socket = new WebSocket(event.data.url);
        socket.binaryType = 'arraybuffer';
        socket.onopen = () => socket.send(event.data.token);
        socket.onmessage = (message) => {
          if (typeof message.data === 'string') { configure(JSON.parse(message.data)); return; }
          const view = new DataView(message.data);
          const key = view.getUint8(0) === 1;
          if (key) stats.keyFrames += 1; else stats.deltaFrames += 1;
          stats.mostQueued = Math.max(stats.mostQueued, decoder.decodeQueueSize);
          if (!catchingUp && decoder.decodeQueueSize > mostWaiting) {
            stats.fellBehind += 1;
            stats.skipped += decoder.decodeQueueSize;
            catchingUp = true;
            decoder.reset();
            decoder.configure(configuration);
            socket.send(JSON.stringify({ type: 'keyframe' }));
          }
          if (catchingUp) {
            if (!key) { stats.skipped += 1; return; }
            catchingUp = false;
          }
          decoder.decode(new EncodedVideoChunk({
            type: key ? 'key' : 'delta',
            timestamp: Math.round(view.getFloat64(1, true) * 1000),
            data: new Uint8Array(message.data, 9),
          }));
        };
      };
    `;
    // The shell waits for a web client to say it started.
    window.backspace.rendererReady();
    window.startPipe = (url, token, sink) => new Promise((resolve, reject) => {
      const worker = new Worker(URL.createObjectURL(new Blob([workerSource], { type: 'text/javascript' })));
      window.pipeWorker = worker;
      worker.onerror = (event) => reject(new Error(event.message));
      worker.onmessage = (event) => {
        if (!event.data.track) return;
        const video = document.createElement('video');
        video.muted = true;
        video.srcObject = new MediaStream([event.data.track]);
        document.body.appendChild(video);
        video.play().catch(() => {});
        window.pipeVideo = video;
        resolve(event.data.track.kind);
      };
      worker.postMessage({ url, token, sink });
    });
    window.pipeStats = () => new Promise((resolve) => {
      window.pipeWorker.onmessage = (event) => {
        if (!event.data.stats) return;
        const stats = event.data.stats;
        // The first second is the decoder starting up; what a share feels
        // like is the rest.
        const d = stats.delays.slice(60).sort((a, b) => a - b);
        const first = stats.delays.slice(0, 60);
        resolve({
          startUpMax: first.length ? Math.max(...first) : -1,
          formats: stats.formats, decoded: stats.decoded, errors: stats.errors,
          keyFrames: stats.keyFrames, deltaFrames: stats.deltaFrames, queued: stats.queued, mostQueued: stats.mostQueued,
          fellBehind: stats.fellBehind, skipped: stats.skipped,
          p50: d.length ? d[Math.floor(d.length / 2)] : -1,
          p95: d.length ? d[Math.floor(d.length * 0.95)] : -1,
          max: d.length ? d[d.length - 1] : -1,
          framesPerSecond: stats.decoded > 1 ? (stats.decoded - 1) * 1000 / (stats.lastAt - stats.firstAt) : 0,
          videoWidth: window.pipeVideo.videoWidth, videoHeight: window.pipeVideo.videoHeight,
        });
      };
      window.pipeWorker.postMessage({ ask: 'stats' });
    });
    return true;
    """

/// Frames the check draws, through the encoder and the channel, to a decoder
/// in a worker of the page and into a track. `size` is "1920x1080".
func checkVideoPipe(size: String, sink: String, noiseEvery: Int) -> Never {
    let parts = size.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2, parts[0] >= 16, parts[1] >= 16, parts[0] % 2 == 0, parts[1] % 2 == 0 else {
        fail("--size takes a width and a height in even pixels, as in 1920x1080")
    }
    let (width, height) = (parts[0], parts[1])
    let framesPerSecond = 60
    let frameCount = 300
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
        shell = try MainWindowController(
            environment: environment, showsWindow: false, websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(), notifications: nil
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }
    var hasEnded = false
    shell.onMainFrameLoadEnded = { _ in hasEnded = true }
    shell.load(address)
    guard wait(until: { hasEnded }) else { fail("the local page did not load") }

    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(30, until: { answer != nil }) else { return nil }
        switch answer {
        case .success(let value)?: return value
        case .failure(let error)?:
            FileHandle.standardError.write(Data("ContractCheck: the page threw: \(error.localizedDescription)\n".utf8))
            return nil
        case nil: return nil
        }
    }

    var opened: (channel: LocalMediaChannel, endpoint: LocalMediaChannel.Endpoint)?
    shell.openMediaChannel { result in
        if case .success(let made) = result { opened = made }
    }
    guard wait(10, until: { opened != nil }), let (channel, endpoint) = opened else {
        fail("the media channel did not open")
    }
    var connected = false
    channel.onClientConnected = { connected = true }

    let encoder: VideoEncoder
    do {
        encoder = try VideoEncoder(settings: .init(width: width, height: height, framesPerSecond: framesPerSecond))
    } catch {
        fail("the encoder could not be made: \(error)")
    }
    let counters = NSLock()
    var sentBytes = 0
    var dropped = 0
    var formats: [MediaWire.VideoFormat] = []
    encoder.onFormat = { format in
        counters.lock()
        formats.append(format)
        counters.unlock()
        channel.send(text: format.message)
    }
    encoder.onFrame = { message in
        let wasSent = channel.send(message)
        counters.lock()
        if wasSent { sentBytes += message.count } else { dropped += 1 }
        counters.unlock()
    }
    channel.onMessage = { message in
        if MediaWire.Request(message: message) == .keyFrame {
            encoder.requestKeyFrame()
        }
    }

    _ = page(videoPipePage)
    let kind = page("return await window.startPipe('\(endpoint.url)', '\(endpoint.token)', '\(sink)');") as? String
    if kind != "video" {
        problems.append("the page got no video track from its worker (\(String(describing: kind)))")
    }
    guard wait(10, until: { connected }) else { fail("the page's worker did not connect to the channel") }

    // Sixty frames a second from a thread of their own, as a capture gives them.
    let source = CheckFrameSource(width: width, height: height, noiseEvery: noiseEvery)
    let feeding = DispatchQueue(label: "check-frames")
    let timer = DispatchSource.makeTimerSource(queue: feeding)
    var fed = 0
    var isDone = false
    var drawing = 0.0
    var handing = 0.0
    let started = Date()
    timer.schedule(deadline: .now(), repeating: 1.0 / Double(framesPerSecond), leeway: .milliseconds(1))
    timer.setEventHandler {
        let beforeDrawing = CACurrentMediaTime()
        guard fed < frameCount, let frame = source.frame(fed) else {
            timer.cancel()
            encoder.finish()
            DispatchQueue.main.async { isDone = true }
            return
        }
        let beforeHanding = CACurrentMediaTime()
        encoder.encode(
            frame, presentationTime: CMTime(value: CMTimeValue(fed), timescale: CMTimeScale(framesPerSecond)),
            capturedAt: Date().timeIntervalSince1970 * 1000
        )
        drawing += beforeHanding - beforeDrawing
        handing += CACurrentMediaTime() - beforeHanding
        fed += 1
        // Half way through, the page asks for a frame to start from.
        if fed == frameCount / 2 {
            DispatchQueue.main.async {
                shell.webView.evaluateJavaScript("window.pipeWorker.postMessage({ ask: 'keyframe' });", completionHandler: nil)
            }
        }
    }
    timer.resume()
    guard wait(30, until: { isDone }) else { fail("the frames were not all encoded in 30 s") }
    let took = Date().timeIntervalSince(started)
    FileHandle.standardError.write(Data(String(
        format: "ContractCheck: a frame took %.1f ms to draw and %.1f ms to hand to the encoder (%@)\n",
        drawing * 1000 / Double(frameCount), handing * 1000 / Double(frameCount),
        encoder.isHardware ? "hardware" : "software"
    ).utf8))
    // The page may still be decoding what it was sent.
    var stats: [String: Any] = [:]
    let patience = Date().addingTimeInterval(10)
    repeat {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        stats = page("return await window.pipeStats();") as? [String: Any] ?? [:]
    } while (stats["decoded"] as? Int ?? 0) + (stats["skipped"] as? Int ?? 0) < frameCount && Date() < patience
    FileHandle.standardError.write(Data("ContractCheck: page: received \((stats["keyFrames"] as? Int ?? 0) + (stats["deltaFrames"] as? Int ?? 0)), "
        .appending("most queued in the decoder \(stats["mostQueued"] ?? "?"), still queued \(stats["queued"] ?? "?")\n").utf8))
    let decoded = stats["decoded"] as? Int ?? 0
    let errors = stats["errors"] as? [String] ?? []
    let p50 = stats["p50"] as? Double ?? -1
    let p95 = stats["p95"] as? Double ?? -1
    let longest = stats["max"] as? Double ?? -1
    let rate = stats["framesPerSecond"] as? Double ?? 0
    let keyFrames = stats["keyFrames"] as? Int ?? 0
    counters.lock()
    let (bytes, lost, announced) = (sentBytes, dropped, formats)
    counters.unlock()

    if announced.count != 1 || announced.first?.width != width || announced.first?.height != height {
        problems.append("the encoder announced \(announced.map { "\($0.codec) \($0.width)x\($0.height)" }), expected one format of \(width)x\(height)")
    }
    if !errors.isEmpty {
        problems.append("the page's decoder reported \(errors.prefix(3))")
    }
    let givenUp = encoder.framesDropped
    let fellBehind = stats["fellBehind"] as? Int ?? 0
    let skipped = stats["skipped"] as? Int ?? 0
    // A decoder that is reset also loses the frames it was working on,
    // which nothing counts: a few frames for each time the page fell behind.
    let accounted = decoded + skipped + givenUp
    if lost != 0 || accounted > frameCount || accounted < frameCount - 8 * fellBehind {
        problems.append("\(decoded) of \(frameCount) frames were decoded in the page; the encoder gave back \(givenUp), the channel dropped \(lost), the page skipped \(skipped)")
    }
    // A page that falls behind now and then on a busy machine is what the
    // skipping is for; one that skips a tenth of the frames cannot keep up.
    if skipped > frameCount / 10 {
        problems.append("the page fell behind \(fellBehind) time(s) and skipped \(skipped) of \(frameCount) frames")
    }
    if givenUp > frameCount / 20 {
        problems.append("the encoder gave back \(givenUp) of \(frameCount) frames without encoding them")
    }
    if keyFrames < 2 + fellBehind {
        problems.append("the page asked for a key frame and got none (\(keyFrames) key frame(s) in all)")
    }
    if stats["videoWidth"] as? Int != width || stats["videoHeight"] as? Int != height {
        problems.append("the page's video element shows \(String(describing: stats["videoWidth"]))x\(String(describing: stats["videoHeight"])), expected \(width)x\(height)")
    }
    // A decoder that is not told the frames come in order holds four to
    // twelve of them: 90 ms and more. A frame asked for half way through
    // is large and late, which is why this looks at the median.
    if p50 < 0 || p50 > 80 {
        problems.append("after the first second half of the frames should be in the page within 80 ms of being made, took \(p50)")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    let startUp = stats["startUpMax"] as? Double ?? -1
    let megabits = Double(bytes) * 8 / took / 1_000_000
    print(String(
        format: "video pipe %dx%d: %d frames in %.2f s, %@, %.1f Mbit/s; in the page %.1f frames/s, "
            + "made-to-decoded after the first second %.0f ms at the median, %.0f at the 95th percentile, "
            + "%.0f at most (%.0f at most in the first second); %d key frames, %d frames given back by the encoder; "
            + "the page fell behind %d time(s) and skipped %d frames%@",
        width, height, decoded, took, announced.first?.codec ?? "no format", megabits, rate, p50, p95, longest, startUp,
        keyFrames, givenUp, fellBehind, skipped,
        problems.isEmpty ? "" : "; \(problems.count) problem(s)"
    ))
    exit(problems.isEmpty ? 0 : 1)
}

/// A screen the check makes up: 1920 by 1200, showing frames the check draws.
/// It changes for `movingFrames` frames and then stands still.
final class CheckScreenCapturer: ScreenCapturer {
    var onEnded: (() -> Void)?
    private(set) var request: ScreenCaptureRequest?
    private(set) var isStopped = false
    private let movingFrames: Int
    private var source: CheckFrameSource?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "check-screen")

    init(movingFrames: Int) {
        self.movingFrames = movingFrames
    }

    func prepare(
        _ request: ScreenCaptureRequest,
        completion: @escaping (Result<(width: Int, height: Int), ScreenCaptureFailure>) -> Void
    ) {
        self.request = request
        guard case .display(1) = request.source else {
            DispatchQueue.main.async { completion(.failure(.noSource)) }
            return
        }
        let size = VideoShape.encodedSize(width: 1920, height: 1200, maxWidth: request.maxWidth, maxHeight: request.maxHeight)
        source = CheckFrameSource(width: size.width, height: size.height, noiseEvery: 32)
        DispatchQueue.main.async { completion(.success(size)) }
    }

    func begin(frame: @escaping (CVPixelBuffer, CMTime, Double) -> Void, completion: @escaping (Bool) -> Void) {
        guard let request, let source else {
            completion(false)
            return
        }
        var sent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(request.framesPerSecond), leeway: .milliseconds(1))
        timer.setEventHandler { [movingFrames] in
            guard sent < movingFrames, let picture = source.frame(sent) else {
                timer.cancel()
                return
            }
            frame(picture, CMClockGetTime(CMClockGetHostTimeClock()), Date().timeIntervalSince1970 * 1000)
            sent += 1
        }
        self.timer = timer
        timer.resume()
        DispatchQueue.main.async { completion(true) }
    }

    func stop() {
        isStopped = true
        timer?.cancel()
    }

    func endByItself() {
        timer?.cancel()
        onEnded?()
    }
}

/// A share through the bridge, as the web client will start one, with a
/// screen the check makes up.
func checkCapture() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    var capturers: [CheckScreenCapturer] = []
    var movingFrames = 90
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
        shell = try MainWindowController(
            environment: environment, showsWindow: false, websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(), notifications: nil,
            screenCapturer: {
                let capturer = CheckScreenCapturer(movingFrames: movingFrames)
                capturers.append(capturer)
                return capturer
            }
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }
    func load(_ url: URL) {
        var hasEnded = false
        shell.onMainFrameLoadEnded = { _ in hasEnded = true }
        shell.load(url)
        guard wait(until: { hasEnded }) else { fail("the local page did not load") }
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(30, until: { answer != nil }) else { return nil }
        switch answer {
        case .success(let value)?: return value
        case .failure(let error)?:
            FileHandle.standardError.write(Data("ContractCheck: the page threw: \(error.localizedDescription)\n".utf8))
            return nil
        case nil: return nil
        }
    }
    func start(_ options: String) -> [String: Any] {
        page("window.share = await window.backspace.startNativeScreenCapture(\(options)); return window.share;") as? [String: Any] ?? [:]
    }
    func stats() -> [String: Any] {
        page("return await window.pipeStats();") as? [String: Any] ?? [:]
    }
    func decoded() -> Int {
        stats()["decoded"] as? Int ?? 0
    }
    let connect = "return await window.startPipe(window.share.url, window.share.token, 'track');"

    load(address)
    _ = page(videoPipePage)
    _ = page("""
        window.ended = 0;
        window.endedIDs = [];
        window.backspace.onNativeScreenCaptureEnded((event) => { window.ended += 1; window.endedIDs.push(event && event.id); });
        return true;
        """)

    // 1. Who picks the source: the app, for a client that says it takes a
    //    native capture; WebKit, for one that does not.
    let modes = page("""
        return [
          await window.backspace.getScreenSharePickerMode({ nativeCapture: true }),
          await window.backspace.getScreenSharePickerMode(),
        ];
        """) as? [String]
    if modes != ["app", "system"] {
        problems.append("the picker modes were \(String(describing: modes)), expected app for a client that takes native capture and system otherwise")
    }

    // 2. A request that names no source, or one that is gone, starts nothing.
    let bad = start("{ maxWidth: 1280 }")
    let gone = start("{ sourceId: 'screen:77:0' }")
    if bad["ok"] as? Bool != false || bad["reason"] as? String != "bad-request"
        || gone["ok"] as? Bool != false || gone["reason"] as? String != "no-source" {
        problems.append("a request without a source was answered \(bad), one for a source that is gone \(gone)")
    }
    if capturers.last?.isStopped != true {
        problems.append("the capture that could not start was left running")
    }

    // 3. A screen that changes: three seconds at thirty frames a second,
    //    fitted into what was asked for.
    let moving = start("{ sourceId: 'screen:1:0', maxWidth: 1280, maxHeight: 720, frameRate: 30 }")
    if moving["ok"] as? Bool != true || moving["width"] as? Int != 1152 || moving["height"] as? Int != 720
        || moving["frameRate"] as? Int != 30 || (moving["url"] as? String)?.hasPrefix("wss://127.0.0.1:") != true {
        problems.append("the share was answered \(moving.filter { $0.key != "token" }), expected 1152 by 720 at 30")
    }
    if page(connect) as? String != "video" {
        problems.append("the page got no video track")
    }
    _ = wait(8, until: { capturers.last.map { _ in decoded() >= 60 } ?? false })
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    let first = stats()
    let firstDecoded = first["decoded"] as? Int ?? 0
    let format = (first["formats"] as? [[String: Any]])?.first
    if firstDecoded < 60 || format?["width"] as? Int != 1152 || format?["height"] as? Int != 720
        || first["videoWidth"] as? Int != 1152 || !(first["errors"] as? [String] ?? ["?"]).isEmpty {
        problems.append("of a screen that changed for 90 frames the page decoded \(firstDecoded), in \(String(describing: format)), with errors \(String(describing: first["errors"]))")
    }
    let movingCapturer = capturers.last

    // 4. A screen that stands still. The one frame it gives is long gone when
    //    the page connects, and the page still gets a picture; and another
    //    when its decoder asks for one. The capture before it runs on: the
    //    page previews a source while its share continues.
    let movingID = moving["id"] as? String ?? ""
    movingFrames = 1
    let still = start("{ sourceId: 'screen:1:0', maxWidth: 1280, maxHeight: 720, frameRate: 30 }")
    if movingCapturer?.isStopped != false || movingID.isEmpty || still["id"] as? String == movingID {
        problems.append("a second capture ended the first, or the two share an id")
    }
    _ = page("window.backspace.stopNativeScreenCapture('\(movingID)'); return true;")
    if !wait(5, until: { movingCapturer?.isStopped == true }) || capturers.last?.isStopped != false {
        problems.append("stopping a capture by its id did not stop that one alone")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    _ = page(connect)
    if still["ok"] as? Bool != true || !wait(5, until: { decoded() >= 1 }) {
        problems.append("a page that connected to a screen standing still got no picture")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    let before = decoded()
    _ = page("window.pipeWorker.postMessage({ ask: 'keyframe' }); return true;")
    if !wait(5, until: { decoded() > before }) {
        problems.append("the page asked for a key frame of a screen standing still and got none")
    }
    let afterKeyFrame = stats()
    if afterKeyFrame["deltaFrames"] as? Int != 0 {
        problems.append("a screen standing still sent \(String(describing: afterKeyFrame["deltaFrames"])) frames that need others, expected key frames only")
    }

    // 5. The capture ends by itself: the page is told, and the share is over.
    let endedBefore = page("return window.ended;") as? Int ?? -1
    capturers.last?.endByItself()
    if !wait(5, until: { page("return window.ended;") as? Int == endedBefore + 1 })
        || page("return window.endedIDs;") as? [String] != [still["id"] as? String ?? "?"] {
        problems.append("the page was not told which capture ended")
    }

    // 6. The page stops a share.
    movingFrames = 900
    _ = start("{ sourceId: 'screen:1:0', frameRate: 30 }")
    let running = capturers.last
    _ = page("window.backspace.stopNativeScreenCapture(window.share.id); return true;")
    if !wait(5, until: { running?.isStopped == true }) {
        problems.append("stopNativeScreenCapture left the capture running")
    }
    if page("return window.ended;") as? Int != endedBefore + 1 {
        problems.append("the page was told that a share it stopped itself had ended")
    }

    // 7. A page may have a few captures at once, and no more.
    let made = capturers.count
    var answers: [[String: Any]] = []
    for _ in 0...ScreenCaptureRequest.mostAtOnce {
        answers.append(start("{ sourceId: 'screen:1:0', maxWidth: 320, maxHeight: 200, frameRate: 5 }"))
    }
    if answers.dropLast().contains(where: { $0["ok"] as? Bool != true })
        || answers.last?["reason"] as? String != "too-many" {
        problems.append("\(ScreenCaptureRequest.mostAtOnce) captures at once should start and one more be refused; got \(answers.map { $0["ok"] ?? $0 })")
    }

    // 8. Another page: the captures of the one before it stop.
    let leftBehind = Array(capturers[made...])
    load(URL(string: origin + "/next")!)
    if !wait(5, until: { leftBehind.allSatisfy(\.isStopped) }) {
        problems.append("a capture outlived its page")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "capture: started through the bridge and fitted to what was asked; a screen standing still still gives a picture; several run at once, each stopped by its id, by itself or with its page"
        : "capture: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The web client's own capture code, in the shell, with a screen the check
/// makes up. `address` is the web package's workbench page
/// (`dev-native-capture.html`) on a running Vite server.
func checkCaptureWeb(address: String) -> Never {
    guard let url = URL(string: address) else { fail("--url takes the address of dev-native-capture.html") }
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    var capturers: [CheckScreenCapturer] = []
    var movingFrames = 3000
    var timings = RecoveryTimings()
    // The workbench page is not a web client and never says it started.
    timings.bootTimeout = 600
    let shell: MainWindowController
    do {
        shell = try MainWindowController(
            environment: environment, showsWindow: false, websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(), notifications: nil,
            screenCapturer: {
                let capturer = CheckScreenCapturer(movingFrames: movingFrames)
                capturers.append(capturer)
                return capturer
            },
            recoveryTimings: timings
        )
    } catch {
        fail(String(describing: error))
    }
    var hasEnded = false
    var loadError: Error?
    shell.onMainFrameLoadEnded = { error in
        hasEnded = true
        loadError = error
    }
    shell.load(url)
    guard wait(30, until: { hasEnded }), loadError == nil else {
        fail("\(address) did not load: \(loadError?.localizedDescription ?? "no answer"). Is the web package's dev server running?")
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(30, until: { answer != nil }) else { return nil }
        switch answer {
        case .success(let value)?: return value
        case .failure(let error)?:
            FileHandle.standardError.write(Data("ContractCheck: the page threw: \(error.localizedDescription)\n".utf8))
            return nil
        case nil: return nil
        }
    }
    func state() -> [String: Any] {
        page("return window.nativeCaptureWorkbench ? window.nativeCaptureWorkbench.state() : null;") as? [String: Any] ?? [:]
    }
    guard wait(30, until: { state()["available"] != nil }) else {
        fail("the workbench page did not start")
    }
    if state()["available"] as? Bool != true {
        problems.append("the web client does not see the shell's native capture")
    }

    // 1. A capture started by the web client's code plays in a video element.
    let started = page("""
        return await window.nativeCaptureWorkbench.start('screen:1:0', { maxWidth: 1280, maxHeight: 720, frameRate: 30 });
        """) as? [String: Any] ?? [:]
    if started["phase"] as? String != "running" || started["native"] as? Bool != true {
        problems.append("the capture did not start: \(started)")
    }
    if !wait(10, until: { state()["videoWidth"] as? Int == 1152 && state()["videoHeight"] as? Int == 720 }) {
        problems.append("the video element shows \(state()["videoWidth"] ?? "?") by \(state()["videoHeight"] ?? "?"), expected 1152 by 720")
    }
    let playedThen = state()["played"] as? Double ?? 0
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))
    let playedNow = state()["played"] as? Double ?? 0
    if playedNow - playedThen < 0.5 {
        problems.append("the video did not go on playing (\(playedThen) s, then \(playedNow) s)")
    }

    // 2. Other limits: a second capture behind the same track, and the first
    //    one stopped.
    let first = capturers.last
    let changed = page("""
        return await window.nativeCaptureWorkbench.reconfigure({ maxWidth: 640, maxHeight: 400, frameRate: 30 });
        """) as? [String: Any] ?? [:]
    if changed["error"] as? String != nil || capturers.count != 2 || changed["trackState"] as? String != "live" {
        problems.append("other limits were answered \(changed) with \(capturers.count) capture(s) made")
    }
    if !wait(10, until: { state()["videoWidth"] as? Int == 640 && state()["videoHeight"] as? Int == 400 }) {
        problems.append("after other limits the video element shows \(state()["videoWidth"] ?? "?") by \(state()["videoHeight"] ?? "?"), expected 640 by 400")
    }
    if !wait(5, until: { first?.isStopped == true }) || capturers.last?.isStopped != false {
        problems.append("the capture with the old limits was left running, or the new one was stopped")
    }

    // 3. The capture ends by itself: the track says so.
    capturers.last?.endByItself()
    if !wait(5, until: { state()["phase"] as? String == "ended" }) {
        problems.append("the track did not say that its capture ended (\(state()["phase"] ?? "?"))")
    }

    // 4. Stopping the track stops the capture.
    movingFrames = 3000
    _ = page("return await window.nativeCaptureWorkbench.start('screen:1:0', { frameRate: 30 });")
    let running = capturers.last
    let stopped = page("return window.nativeCaptureWorkbench.stop();") as? [String: Any] ?? [:]
    if stopped["phase"] as? String != "stopped" || !wait(5, until: { running?.isStopped == true }) {
        problems.append("stopping the track left the capture running (\(stopped))")
    }

    // 5. A source that is gone: the web client reports the failure.
    let gone = page("return await window.nativeCaptureWorkbench.start('screen:77:0', { frameRate: 30 });") as? [String: Any] ?? [:]
    if gone["phase"] as? String != "failed" || (gone["error"] as? String)?.contains("no-source") != true {
        problems.append("a source that is gone was answered \(gone)")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "capture, web client's side: its worker decodes the shell's capture into a track that plays, follows other limits behind the same track, says when the capture ends and stops it when stopped"
        : "capture, web client's side: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The real screen, for a few seconds, through the whole path to a decoder in
/// the page. Prints sizes, counts and times; the pictures stay in the page.
func checkCaptureSystem(size: String, framesPerSecond: Int, seconds: Double) -> Never {
    let parts = size.split(separator: "x").compactMap { Int($0) }
    guard parts.count == 2 else { fail("--size takes a width and a height, as in 1920x1080") }
    defer { try? FileManager.default.removeItem(at: temporary) }

    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer()
        shell = try MainWindowController(
            environment: environment, showsWindow: false, websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(), notifications: nil,
            screenCapturer: { SystemScreenCapturer() }
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let address = URL(string: origin + "/") else {
        fail("the local page server did not start")
    }
    var hasEnded = false
    shell.onMainFrameLoadEnded = { _ in hasEnded = true }
    shell.load(address)
    guard wait(until: { hasEnded }) else { fail("the local page did not load") }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(30, until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    _ = page(videoPipePage)
    let display = CGMainDisplayID()
    let reply = page("""
        window.share = await window.backspace.startNativeScreenCapture({
          sourceId: 'screen:\(display):0', maxWidth: \(parts[0]), maxHeight: \(parts[1]), frameRate: \(framesPerSecond),
        });
        return window.share;
        """) as? [String: Any] ?? [:]
    guard reply["ok"] as? Bool == true else {
        fail("the capture did not start: \(reply["reason"] ?? "no answer")")
    }
    _ = page("return await window.startPipe(window.share.url, window.share.token, 'track');")
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    let stats = page("return await window.pipeStats();") as? [String: Any] ?? [:]
    _ = page("window.backspace.stopNativeScreenCapture(window.share.id); return true;")

    let format = (stats["formats"] as? [[String: Any]])?.first
    print("captured the main display at \(reply["width"] ?? "?")x\(reply["height"] ?? "?"), asked for \(framesPerSecond) frames a second, for \(seconds) s")
    print("format in the page: \(format?["codec"] ?? "none") \(format?["width"] ?? "?")x\(format?["height"] ?? "?"); video element \(stats["videoWidth"] ?? "?")x\(stats["videoHeight"] ?? "?")")
    print(String(
        format: "decoded %d frames (%d key), %.1f a second while the screen changed; captured-to-decoded %.0f ms at the median, %.0f at the 95th percentile, %.0f at most",
        stats["decoded"] as? Int ?? 0, stats["keyFrames"] as? Int ?? 0, stats["framesPerSecond"] as? Double ?? 0,
        stats["p50"] as? Double ?? -1, stats["p95"] as? Double ?? -1, stats["max"] as? Double ?? -1
    ))
    print("the page fell behind \(stats["fellBehind"] ?? "?") time(s), skipped \(stats["skipped"] ?? "?"); decoder errors: \(stats["errors"] ?? "?")")
    exit((stats["decoded"] as? Int ?? 0) >= 1 && (stats["errors"] as? [String] ?? ["?"]).isEmpty ? 0 : 1)
}

/// Asks the system once for what can be shared and prints how many displays
/// and windows it gave and how large their pictures are. No name or title is
/// printed, and no picture leaves the process.
func checkSourcesSystem() -> Never {
    let lister = SystemScreenSourceLister(unnamedScreen: { "Screen \($0)" })
    var answer: [ScreenSource]?
    let started = Date()
    lister.listSources { answer = $0 }
    guard wait(30, until: { answer != nil }), let sources = answer else {
        fail("the system did not answer in 30 s")
    }
    let took = Date().timeIntervalSince(started)
    let displays = sources.filter(\.isScreen)
    let windows = sources.filter { !$0.isScreen }
    func sizes(_ list: [ScreenSource]) -> String {
        let bytes = list.map(\.thumbnailPNG.count)
        guard let smallest = bytes.min(), let largest = bytes.max() else { return "none" }
        return "\(smallest)...\(largest) bytes"
    }
    func dimensions(_ list: [ScreenSource]) -> String {
        Set(list.compactMap { source -> String? in
            guard let image = NSBitmapImageRep(data: source.thumbnailPNG) else { return nil }
            return "\(image.pixelsWide)x\(image.pixelsHigh)"
        }).sorted().prefix(6).joined(separator: ", ")
    }
    let bridged = sources.map(\.bridgeValue)
    let json = (try? JSONSerialization.data(withJSONObject: bridged))?.count ?? -1
    print("screen recording allowed: \(CGPreflightScreenCaptureAccess())")
    print("listed in \(String(format: "%.2f", took)) s: \(displays.count) display(s), \(windows.count) window(s)")
    print("display pictures: \(sizes(displays)); \(dimensions(displays))")
    print("window pictures: \(sizes(windows)); \(dimensions(windows))")
    print("windows with an application icon: \(windows.filter { $0.appIconPNG != nil }.count) of \(windows.count)")
    print("displays with a name of their own: \(displays.filter { !$0.name.hasPrefix("Screen ") }.count) of \(displays.count)")
    print("the whole list as the page gets it: \(json) bytes of JSON")
    let unique = Set(sources.map(\.id)).count == sources.count
    exit(unique && !displays.isEmpty ? 0 : 1)
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
                if action == "undo:" || action == "redo:" {
                    // AppKit rewrites these two when it validates the menu.
                    let own = item.title
                    item.title = "rewritten"
                    top.submenu?.update()
                    if item.title != own { problems.append("\(language.code): '\(own)' let its title be rewritten to '\(item.title)'") }
                }
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

/// The recovery check. Ends the process.
func checkRecovery() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer(pages: [
            "/silent": "<!doctype html><title>silent</title>",
            "/ready": "<!doctype html><title>ready</title><script>window.backspace.rendererReady();</script>",
        ])
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil,
            recoveryTimings: RecoveryTimings(
                bootTimeout: 1,
                hangPollInterval: 0.3,
                hangGrace: 1.5,
                crashLoopWindow: 60,
                watchesHangsOnlyWhenVisible: false
            )
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin() else { fail("the local page server did not start") }

    func address(_ text: String) -> URL {
        guard let url = URL(string: text) else { fail("bad address \(text)") }
        return url
    }
    func isShowing(_ file: URL) -> Bool {
        shell.webView.url?.path == file.path && !shell.webView.isLoading
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    func expectRecovery(_ code: RecoveryReason.Code, within seconds: TimeInterval, _ what: String) {
        guard wait(seconds, until: { isShowing(recoveryURL) }) else {
            problems.append("\(what): the recovery page did not open (the window shows \(shell.webView.url?.absoluteString ?? "nothing"))")
            return
        }
        if shell.recoveryState.reason?.code != code {
            problems.append("\(what): the reason is \(shell.recoveryState.reason?.code.rawValue ?? "none"), expected \(code.rawValue)")
        }
    }

    // 1. An address that cannot be loaded ends on the recovery page, which
    //    reads the reason over the bridge.
    shell.load(address("https://chat.example.test/"))
    expectRecovery(.loadFailed, within: 60, "an address that cannot be loaded")
    if shell.webView.url?.query != "lang=en" { problems.append("the recovery page was not given the shell's language") }
    let seen = page("return await window.backspace.getRecoveryState();") as? [String: Any]
    if seen?["mode"] as? String != "recovery" || (seen?["reason"] as? [String: String])?["code"] != "load-failed" {
        problems.append("the recovery page read the state \(String(describing: seen))")
    }

    // 2. A second failure while in recovery changes what the page says and
    //    does not load it again.
    _ = page("window.__details = []; window.backspace.onRecoveryStateChanged((state) => window.__details.push(state.reason.detail)); return true;")
    shell.load(address("https://other.example.test/"))
    let heard = wait(60, until: { ((page("return window.__details;") as? [String])?.count ?? 0) > 0 })
    let details = page("return window.__details;") as? [String] ?? []
    if !heard || details.count != 1 || !details[0].contains("other.example.test") {
        problems.append("a second failure should reach the same recovery page once, it heard \(details)")
    }

    // 3. Reload leaves recovery; with no instance saved it opens the picker.
    _ = page("window.backspace.recoveryAction('reload'); return true;")
    if !wait(until: { isShowing(pickerURL) }) { problems.append("Reload did not open the picker") }
    if shell.recoveryState.isRecovery { problems.append("Reload left the shell in recovery") }

    // 4. A page that loads and never reports that it started.
    shell.load(address(origin + "/silent"))
    expectRecovery(.rendererStalled, within: 10, "a web client that never reports")
    if shell.recoveryState.reason?.detail != "no rendererReady within 1000ms" {
        problems.append("the stall is described as '\(shell.recoveryState.reason?.detail ?? "")'")
    }

    // 5. Change Instance leaves recovery and opens the picker.
    _ = page("window.backspace.recoveryAction('change-instance'); return true;")
    if !wait(until: { isShowing(pickerURL) }) { problems.append("Change Instance did not open the picker") }
    if shell.recoveryState.isRecovery { problems.append("Change Instance left the shell in recovery") }

    // 6. A page that reports is left alone, well past the time allowed.
    let ready = address(origin + "/ready")
    shell.load(ready)
    RunLoop.main.run(until: Date().addingTimeInterval(3))
    if shell.webView.url != ready || shell.recoveryState.isRecovery {
        problems.append("a web client that reported was taken for a stalled one (\(shell.recoveryState.reason?.detail ?? "no reason"))")
    }

    // 7. The same page with its thread stuck stops answering.
    shell.webView.evaluateJavaScript("setTimeout(() => { for (;;) {} }, 50); 1", completionHandler: nil)
    expectRecovery(.unresponsive, within: 30, "a page whose thread is stuck")

    // 8. What the page can ask for, and what it cannot.
    var quitRequests = 0
    var opened: [String] = []
    shell.onQuitRequested = { quitRequests += 1 }
    shell.openInBrowser = { opened.append($0) }
    _ = page("window.backspace.recoveryAction('format-disk'); window.backspace.recoveryAction(); window.backspace.recoveryAction('install-update'); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if quitRequests != 0 || !opened.isEmpty || !isShowing(recoveryURL) || !shell.recoveryState.isRecovery {
        problems.append("an action that is not one, or an install with nothing downloaded, changed something")
    }
    _ = page("window.backspace.recoveryAction('check-update'); window.backspace.recoveryAction('open-releases'); return true;")
    if !wait(5, until: { opened.count == 2 }) || opened != [RecoveryAction.releasesAddress, RecoveryAction.releasesAddress] {
        problems.append("checking for updates and opening the releases should each open the releases page, opened \(opened)")
    }
    _ = page("window.backspace.recoveryAction('quit'); return true;")
    if !wait(5, until: { quitRequests == 1 }) { problems.append("Quit did not reach the app (\(quitRequests) requests)") }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "recovery: failed load, stalled start and stuck page end on the recovery page; reload, change instance and quit work"
        : "recovery: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The window drag check. Ends the process.
func checkDrag() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    // The page keeps what it saw of the mouse, and says it is ready.
    let recorder = """
    <!doctype html><title>drag</title><body style="margin:0;height:100vh"><script>
    window.__presses = [];
    for (const type of ['mousedown', 'mouseup', 'click']) {
      addEventListener(type, (event) => window.__presses.push(type + ' ' + event.clientX + ' ' + event.clientY), true);
    }
    window.backspace.rendererReady();
    </script></body>
    """
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer(pages: ["/first": recorder, "/second": recorder])
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
    guard let origin = server.origin() else { fail("the local page server did not start") }

    var doubleClicks = 0
    shell.titleBarDoubleClickAction = {
        doubleClicks += 1
        return .nothing
    }

    func open(_ path: String) {
        guard let url = URL(string: origin + path) else { fail("bad address \(path)") }
        var loaded = false
        shell.onMainFrameLoadEnded = { _ in loaded = true }
        shell.load(url)
        if !wait(until: { loaded && shell.webView.url == url }) { fail("\(path) did not load") }
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    var eventNumber = 0
    /// A press and a release at a point of the page, as the window gets them.
    func press(_ x: Double, _ y: Double, clicks: Int = 1) {
        let location = shell.webView.convert(NSPoint(x: x, y: y), to: nil)
        for (type, pressure) in [(NSEvent.EventType.leftMouseDown, Float(1)), (.leftMouseUp, Float(0))] {
            eventNumber += 1
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: shell.window.windowNumber,
                context: nil,
                eventNumber: eventNumber,
                clickCount: clicks,
                pressure: pressure
            ) else { fail("could not make a mouse event") }
            // Straight to the view: a window that is not on screen is sent
            // no mouse events, and where a press lands is AppKit's part.
            if type == .leftMouseDown {
                shell.webView.mouseDown(with: event)
            } else {
                shell.webView.mouseUp(with: event)
            }
        }
    }
    /// What the page saw since the last call. Waits until it has seen as
    /// many events as are expected, for a few seconds at most: a page that is
    /// laying itself out again after the window changed size answers a click
    /// late, and a click cut in half would be taken for a failure here and
    /// for a stray event by the next press. With nothing expected it waits
    /// long enough for a press the page should not get to have arrived.
    func seen(expecting count: Int = 0) -> [String] {
        var all: [String] = []
        let deadline = Date().addingTimeInterval(count == 0 ? 0.3 : 5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(count == 0 ? 0.3 : 0.1))
            guard let more = page("const seen = window.__presses; window.__presses = []; return seen;") as? [String] else {
                return all + ["no answer"]
            }
            all += more
        } while all.count < count && Date() < deadline
        return all
    }
    /// Whether the system is told the window is dragged by this point: no
    /// view that keeps the page a page lies over it.
    func movesWindow(_ x: Double, _ y: Double) -> Bool {
        !shell.stayRegionFrames.contains { $0.contains(NSPoint(x: x, y: y)) }
    }
    /// One press: whether the point drags the window, and what the page saw.
    func expect(_ x: Double, _ y: Double, drags expected: Bool, _ what: String) {
        let moves = movesWindow(x, y)
        press(x, y)
        // A whole click is three events: the press, the release, the click.
        let saw = seen(expecting: expected ? 0 : 3)
        if expected {
            if !moves || !saw.isEmpty {
                problems.append("\(what): expected a part that drags and nothing for the page, got \(moves ? "one that drags" : "one that stays a page") and \(saw)")
            }
        } else {
            let whole = ["mousedown \(Int(x)) \(Int(y))", "mouseup \(Int(x)) \(Int(y))", "click \(Int(x)) \(Int(y))"]
            if moves || saw != whole {
                problems.append("\(what): expected a part that stays a page and a whole click for it, got \(moves ? "one that drags" : "one that stays a page") and \(saw)")
            }
        }
    }
    func resize(width: Double, height: Double) {
        shell.window.setContentSize(NSSize(width: width, height: height))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    // 1. A page that reported nothing is dragged by the top strip, at any
    //    width of the window.
    resize(width: 1280, height: 800)
    open("/first")
    if !shell.webViewMovesWindow { problems.append("the system is not told that the web view moves the window") }
    if shell.reportedDragRegions != nil { problems.append("a page that reported nothing has regions") }
    expect(640, 10, drags: true, "the top strip of a page that reported nothing")
    expect(640, 31, drags: true, "the last row of the top strip")
    expect(640, 32, drags: false, "the first row under the top strip")
    expect(640, 400, drags: false, "the middle of the page")
    resize(width: 1500, height: 700)
    expect(1490, 10, drags: true, "the top strip at the far end of a window that grew")
    expect(1490, 40, drags: false, "under the top strip of a window that grew")
    resize(width: 1280, height: 800)

    // 2. A double click on it asks the system's setting, and the page sees
    //    nothing of it.
    press(640, 10, clicks: 2)
    let sawOfDoubleClick = seen()
    if doubleClicks != 1 || !sawOfDoubleClick.isEmpty {
        problems.append("a double click on the strip: asked the setting \(doubleClicks) time(s), the page saw \(sawOfDoubleClick)")
    }

    // 3. A window behind others is dragged by the first press.
    let far = shell.webView.convert(NSPoint(x: 640, y: 10), to: nil)
    if let first = NSEvent.mouseEvent(
        with: .leftMouseDown, location: far, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: shell.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
    ) {
        if !shell.webView.acceptsFirstMouse(for: first) { problems.append("the strip does not take the first press on a window behind others") }
    }

    // 4. What the page reports replaces the strip.
    _ = page("window.backspace.setDragRegions({ drag: [{ x: 0, y: 0, width: innerWidth, height: 60 }, { x: 200, y: 300, width: 100, height: 40 }], noDrag: [{ x: 100, y: 10, width: 50, height: 30 }] }); return true;")
    if !wait(until: { shell.reportedDragRegions != nil }) { problems.append("the page's report did not arrive") }
    expect(640, 50, drags: true, "a reported region, below where the strip ends")
    expect(120, 20, drags: false, "a reported exception inside the region")
    expect(160, 20, drags: true, "the region beside the exception")
    expect(640, 70, drags: false, "the page under the reported region")
    expect(250, 320, drags: true, "a reported region in the middle of the page")
    // A window that grew stays a page beside what was reported, until the
    // page measures itself again.
    resize(width: 1500, height: 800)
    expect(640, 50, drags: true, "a reported region after the window grew")
    expect(1400, 30, drags: false, "beside a reported region after the window grew")
    resize(width: 1280, height: 800)

    // 5. A report that cannot be read changes nothing.
    let standing = shell.reportedDragRegions
    _ = page("window.backspace.setDragRegions({ drag: 'everything' }); window.backspace.setDragRegions(); window.backspace.setDragRegions({ drag: [{ x: 0, y: 0, width: -5, height: 5 }] }); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if shell.reportedDragRegions != standing { problems.append("a report that cannot be read changed the regions") }

    // 6. A page that says it has nothing to drag by is believed.
    _ = page("window.backspace.setDragRegions({ drag: [], noDrag: [] }); return true;")
    if !wait(until: { shell.reportedDragRegions?.drag.isEmpty == true }) { problems.append("an empty report did not arrive") }
    expect(640, 10, drags: false, "the top of a page that reported nothing to drag by")

    // 7. The next page starts from the top strip again.
    open("/second")
    if shell.reportedDragRegions != nil { problems.append("the next page kept the regions of the last one") }
    expect(640, 10, drags: true, "the top strip of the next page")
    expect(640, 50, drags: false, "under the top strip of the next page")

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "drag: the system is told the window is dragged by the top strip, then by what the page reports; the page sees no press there and all of every other click"
        : "drag: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The tray check. Ends the process.
func checkTray() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    // The page keeps the tray actions it is sent, and says it is ready.
    let listener = """
    <!doctype html><title>tray</title><script>
    window.__actions = [];
    window.backspace.onTrayAction((action) => window.__actions.push(JSON.stringify(action)));
    window.backspace.rendererReady();
    </script>
    """
    let tray = CheckTrayPresenter()
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer(pages: ["/client": listener])
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil,
            tray: tray
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let client = URL(string: origin + "/client") else {
        fail("the local page server did not start")
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    /// The tray actions the page was sent since the last call. Waits for as
    /// many as are expected, a few seconds at most: a busy machine delivers
    /// them late.
    func actions(expecting count: Int) -> [String] {
        var all: [String] = []
        let deadline = Date().addingTimeInterval(5)
        repeat {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let more = page("const seen = window.__actions; window.__actions = []; return seen;") as? [String] else {
                return all + ["no answer"]
            }
            all += more
        } while all.count < count && Date() < deadline
        // One more look, for an action too many.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return all + (page("const seen = window.__actions; window.__actions = []; return seen;") as? [String] ?? [])
    }
    let ownItems = ["Show B:SPACE", "-", "Quit"]

    // 0. The frame images of the Electron build load as the menu bar needs
    //    them: every frame, 18 by 22 points whatever the file says of its
    //    resolution, as a template, with a second image for dense displays.
    let frames = SystemTrayPresenter.loadFrames(from: pickerSourceURL.deletingLastPathComponent())
    for frame in TrayFrame.allCases {
        guard let image = frames[frame] else {
            problems.append("the frame \(frame.rawValue) has no image")
            continue
        }
        let pixels = image.representations.map { "\($0.pixelsWide)x\($0.pixelsHigh)" }.sorted()
        if image.size != NSSize(width: 18, height: 22) || !image.isTemplate || pixels != ["18x22", "36x44"]
            || image.representations.contains(where: { $0.size != image.size }) {
            problems.append("the frame \(frame.rawValue) loads as \(image.size), template \(image.isTemplate), images \(pixels)")
        }
    }

    let missing = SystemTrayPresenter.missingControlSymbols()
    if !missing.isEmpty { problems.append("this system has no symbol for \(missing)") }

    // 1. Before any page: the app's own items, and the character at rest.
    if tray.titles != ownItems { problems.append("the menu before any page is \(tray.titles)") }
    if tray.frames != [.idle] { problems.append("the character starts with \(tray.frames.map(\.rawValue))") }

    var loaded = false
    shell.onMainFrameLoadEnded = { _ in loaded = true }
    shell.load(client)
    if !wait(until: { loaded && shell.webView.url == client }) { fail("the page did not load") }

    // 2. The character plays the loop of the state the page reports. With
    //    the system asking for reduced motion it shows the still frame only.
    let still = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    tray.frames = []
    _ = page("window.backspace.setTrayState('typing'); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(1.6))
    let expected: [TrayFrame] = still ? [.typingA] : [.typingA, .typingB, .typing, .typingA]
    if Array(tray.frames.prefix(expected.count)) != expected {
        problems.append("reporting 'typing' showed \(tray.frames.map(\.rawValue)), expected \(expected.map(\.rawValue)) first")
    }

    // 3. A state that is not one, and a still state, which ends the loop.
    _ = page("window.backspace.setTrayState('dancing'); window.backspace.setTrayState(); window.backspace.setTrayState('dnd'); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    tray.frames = []
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    if !tray.frames.isEmpty { problems.append("a still state kept changing frames: \(tray.frames.map(\.rawValue))") }

    // 4. A web client that does not report the camera, the screen share and
    //    the pointers gets the buttons it can answer for.
    let older = "signedIn: true, voice: { channelName: 'General' }, muted: true, deafened: false, status: 'online'"
    _ = page("window.backspace.setTrayContext({ \(older) }); return true;")
    let olderMenu = ["(In voice: General)", "{Microphone is off | Sound is on | Disconnect}", "-", "[ ] Do Not Disturb"] + ownItems
    if !wait(until: { tray.titles == olderMenu }) { problems.append("for an older web client the menu is \(tray.titles)") }

    //    One that does gets the whole row.
    _ = page("window.backspace.setTrayContext({ \(older), cameraOn: true, screenSharing: true, showPointers: true }); return true;")
    let inCall = [
        "(In voice: General)",
        "{Microphone is off | Sound is on | Viewers' pointers are shown | Turn off camera | Stop sharing | Disconnect}",
        "-", "[ ] Do Not Disturb",
    ] + ownItems
    if !wait(until: { tray.titles == inCall }) { problems.append("in a call the menu is \(tray.titles)") }

    // 5. A context that cannot be read changes nothing.
    _ = page("window.backspace.setTrayContext({ signedIn: 'yes' }); window.backspace.setTrayContext(); window.backspace.setTrayContext({ signedIn: true, voice: null, muted: false, deafened: false }); window.backspace.setTrayContext({ \(older), cameraOn: 'yes' }); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    if tray.titles != inCall { problems.append("a context that cannot be read changed the menu to \(tray.titles)") }

    // 6. A pressed button and a chosen item come back to the page.
    let pressed = ["Microphone is off", "Sound is on", "Viewers' pointers are shown", "Turn off camera", "Stop sharing", "Disconnect", "Do Not Disturb"]
    for title in pressed where !tray.choose(title) {
        problems.append("the menu has nothing called '\(title)'")
    }
    let sent = actions(expecting: pressed.count)
    let wanted = ["toggleMute", "toggleDeafen", "toggleShowPointers", "stopCamera", "stopScreenShare", "disconnect"].map { #"{"type":"\#($0)"}"# }
    if Array(sent.prefix(6)) != wanted || sent.count != 7 || !sent[6].contains("\"setStatus\"") || !sent[6].contains("\"dnd\"") {
        problems.append("the page was sent \(sent)")
    }

    // 7. The menu follows the page's language.
    _ = page("window.backspace.setLanguage('ru'); return true;")
    if !wait(until: { tray.titles.first == "(В голосовом: General)" }) {
        problems.append("after the page chose Russian the menu starts with \(tray.titles.first ?? "nothing")")
    }
    _ = page("window.backspace.setLanguage('en'); return true;")
    if !wait(until: { tray.titles == inCall }) { problems.append("back in English the menu is \(tray.titles)") }

    // 8. The app's own items.
    var quitRequests = 0
    var opened: [String] = []
    shell.onQuitRequested = { quitRequests += 1 }
    shell.openInBrowser = { opened.append($0) }
    for title in ["Quit", "Show B:SPACE"] where !tray.choose(title) {
        problems.append("the menu has no item '\(title)'")
    }
    if quitRequests != 1 { problems.append("Quit reached the app \(quitRequests) time(s)") }
    if !opened.isEmpty { problems.append("the tray menu opened \(opened)") }

    // 9. Another page (here the picker) starts from an empty menu and a
    //    resting character.
    _ = page("window.backspace.setTrayState('notify'); return true;")
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    tray.frames = []
    shell.changeInstance()
    if !wait(until: { shell.webView.url?.path == pickerURL.path && !shell.webView.isLoading }) {
        problems.append("the picker did not open")
    }
    if !wait(until: { tray.titles == ownItems }) { problems.append("on the picker the menu is \(tray.titles)") }
    if tray.frames.last != .idle { problems.append("on the picker the character shows \(tray.frames.last?.rawValue ?? "nothing new")") }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "tray: the character plays the reported state, the menu has the row of buttons the page allows and sends the pressed one back, in the page's language"
        : "tray: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// The game detection check. Ends the process.
func checkActivity() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let listener = """
    <!doctype html><title>activity</title><script>
    window.__seen = [];
    window.backspace.onActivityDetected((activity) => window.__seen.push(activity === null ? 'null' : JSON.stringify(activity)));
    window.backspace.rendererReady();
    </script>
    """
    let settings = environment.userDataDirectory
    let seed = pickerSourceURL.deletingLastPathComponent().appendingPathComponent("games.json")
    let fetchedBody = Data(#"{ "version": 9999, "games": [{ "id": "zz-check", "name": "ZZ Check Game", "processes": ["ZZ-Check-Game"], "type": "watching" }, { "id": "cs2", "name": "Counter-Strike 2", "processes": ["cs2"] }] }"#.utf8)
    let lister = CheckProcessLister()
    lister.names = ["finder"]
    let fetcher = CheckDictionaryFetcher()
    fetcher.answer = (status: 200, body: fetchedBody, etag: "\"check-tag\"")
    let detector = ActivityDetector(seedURL: seed, settingsDirectory: settings, lister: lister, fetcher: fetcher, pollInterval: 0.2)

    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer(pages: ["/client": listener])
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil,
            tray: nil,
            activity: detector
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin(), let client = URL(string: origin + "/client") else {
        fail("the local page server did not start")
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    func seen() -> [String] {
        page("return window.__seen;") as? [String] ?? ["no answer"]
    }
    func current() -> [String: Any]? {
        page("return await window.backspace.getCurrentActivity();") as? [String: Any]
    }
    func activity(_ json: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    // 1. Starting the shell starts the detector, which reads the dictionary
    //    shipped with the app and asks the network once, with no tag yet.
    shell.start(hidden: true)
    if !detector.isRunning { problems.append("the detector did not start with the shell") }
    var loaded = false
    shell.onMainFrameLoadEnded = { _ in loaded = true }
    RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    loaded = false
    shell.load(client)
    if !wait(until: { loaded && shell.webView.url == client }) { fail("the page did not load") }
    if fetcher.knownTags.count != 1 || fetcher.knownTags[0] != nil {
        problems.append("the network was asked \(fetcher.knownTags.count) time(s), with the tags \(fetcher.knownTags)")
    }

    // 2. The newer dictionary it was given is saved with its tag.
    let cache = settings.appendingPathComponent(GameDictionarySync.cacheFileName)
    let tag = settings.appendingPathComponent(GameDictionarySync.tagFileName)
    if (try? Data(contentsOf: cache)) != fetchedBody { problems.append("the fetched dictionary was not saved as it came") }
    if (try? String(contentsOf: tag, encoding: .utf8)) != "\"check-tag\"" { problems.append("the dictionary's tag was not saved") }

    // 3. Nothing known is running: the page hears nothing.
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    if !seen().isEmpty || current() != nil {
        problems.append("with nothing known running the page heard \(seen()) and read \(String(describing: current()))")
    }

    // 4. A game starts: the page hears of it once, and reads the same.
    let before = Date().timeIntervalSince1970 * 1000
    lister.names = ["finder", "cs2"]
    if !wait(5, until: { seen().count == 1 }) { problems.append("a running game was not reported: \(seen())") }
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let heard = seen()
    let started = activity(heard.first ?? "")
    let start = (started["timestamps"] as? [String: Any])?["start"] as? Double ?? 0
    if heard.count != 1 || started["type"] as? String != "playing" || started["name"] as? String != "Counter-Strike 2"
        || start < before || start > before + 10_000 {
        problems.append("a running game was reported as \(heard)")
    }
    if current()?["name"] as? String != "Counter-Strike 2" { problems.append("the page read \(String(describing: current())) while the game ran") }

    // 5. It ends: the page hears null once.
    lister.names = ["finder"]
    if !wait(5, until: { seen().count == 2 }) || seen().last != "null" || current() != nil {
        problems.append("the end of the game was reported as \(seen()), then read as \(String(describing: current()))")
    }

    // 6. A game only the fetched dictionary knows, in whatever case.
    lister.names = ["zz-check-game"]
    if !wait(5, until: { seen().count == 3 }) { problems.append("a game of the fetched dictionary was not reported: \(seen())") }
    let fetchedGame = activity(seen().last ?? "")
    if fetchedGame["name"] as? String != "ZZ Check Game" || fetchedGame["type"] as? String != "watching" {
        problems.append("a game of the fetched dictionary was reported as \(seen().last ?? "nothing")")
    }

    // 7. When the processes cannot be listed, detection stops asking.
    lister.names = nil
    if !wait(5, until: { !detector.isRunning }) { problems.append("detection went on without a list of processes") }
    let asked = lister.asked
    RunLoop.main.run(until: Date().addingTimeInterval(0.7))
    if lister.asked != asked { problems.append("the processes were asked for again after detection stopped") }

    // 8. A second start reads the saved dictionary and names its tag.
    let secondLister = CheckProcessLister()
    secondLister.names = ["zz-check-game"]
    let secondFetcher = CheckDictionaryFetcher()
    secondFetcher.answer = (status: 304, body: Data(), etag: nil)
    let second = ActivityDetector(seedURL: seed, settingsDirectory: settings, lister: secondLister, fetcher: secondFetcher, pollInterval: 0.2)
    second.start()
    if !wait(5, until: { second.current != nil }) || second.current?.name != "ZZ Check Game" {
        problems.append("a second start did not use the saved dictionary: \(String(describing: second.current))")
    }
    if secondFetcher.knownTags != ["\"check-tag\""] { problems.append("a second start asked the network with \(secondFetcher.knownTags)") }
    second.stop()

    // 9. The system's own list can be read, and this process is in it.
    var real: Set<String>??
    SystemProcessLister().runningProcessNames { real = .some($0) }
    if !wait(10, until: { real != nil }) {
        problems.append("the system's list of processes did not come")
    } else if let names = real ?? nil {
        if names.count < 20 || !names.contains("contractcheck") {
            problems.append("the system's list has \(names.count) names and \(names.contains("contractcheck") ? "this process" : "not this process")")
        }
    } else {
        problems.append("the system's list of processes could not be read")
    }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "activity: a game is reported once when it starts and once when it ends, a fetched dictionary is saved and used, detection stops without a list of processes"
        : "activity: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

/// Fetches the games dictionary from the network once. Ends the process.
func checkActivityNetwork() -> Never {
    var answer: (status: Int, body: Data, etag: String?)??
    NetworkGameDictionaryFetcher().fetch(knownTag: nil) { answer = .some($0) }
    guard wait(20, until: { answer != nil }), let received = answer ?? nil else {
        print("activity-network: no answer")
        exit(1)
    }
    let read = GameDictionary(data: received.body)
    print("activity-network: status \(received.status), \(received.body.count) bytes, tag \(received.etag ?? "none"), "
        + (read.map { "version \($0.version) with \($0.entries.count) games" } ?? "not a dictionary"))
    exit(received.status == 200 && read != nil ? 0 : 1)
}

/// The global keybinds check. Ends the process.
func checkKeybinds() -> Never {
    var problems: [String] = []
    defer { try? FileManager.default.removeItem(at: temporary) }

    let listener = """
    <!doctype html><title>keybinds</title><script>
    window.__actions = []; window.__status = []; window.__errors = [];
    window.backspace.onKeybindAction((action) => window.__actions.push(action.actionId + (action.pressed ? ' down' : ' up')));
    window.backspace.onAccessibilityStatus((status) => window.__status.push(status.trusted));
    window.backspace.onKeybindHookError((error) => window.__errors.push(error.message));
    window.backspace.rendererReady();
    </script>
    """
    let keyboard = CheckKeyInputSource()
    let permission = CheckKeybindPermission()
    let probe = CheckKeyStateProbe()
    let shell: MainWindowController
    let server: LocalPageServer
    do {
        server = try LocalPageServer(pages: ["/client": listener, "/other": listener])
        shell = try MainWindowController(
            environment: environment,
            showsWindow: false,
            websiteDataStore: .nonPersistent(),
            loginItem: CheckLoginItem(),
            notifications: nil,
            tray: nil,
            keybinds: KeybindCoordinator(source: keyboard, permission: permission, probe: probe, reconcileInterval: 0.2)
        )
    } catch {
        fail(String(describing: error))
    }
    guard let origin = server.origin() else { fail("the local page server did not start") }
    func open(_ path: String) {
        guard let url = URL(string: origin + path) else { fail("bad address \(path)") }
        var loaded = false
        shell.onMainFrameLoadEnded = { _ in loaded = true }
        shell.load(url)
        if !wait(until: { loaded && shell.webView.url == url }) { fail("\(path) did not load") }
    }
    func page(_ script: String) -> Any? {
        var answer: Result<Any, Error>?
        shell.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { answer = $0 }
        guard wait(until: { answer != nil }), case .success(let value)? = answer else { return nil }
        return value
    }
    /// What the page heard on one of its lists since the last call. Waits
    /// for as many entries as are expected, a few seconds at most, then looks
    /// once more for one too many. With nothing expected it waits long
    /// enough for something that should not come to have come.
    func taken(_ name: String, expecting count: Int = 0) -> [Any] {
        let take = "const seen = window.\(name); window.\(name) = []; return seen;"
        var all: [Any] = []
        let deadline = Date().addingTimeInterval(5)
        while all.count < count && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            guard let more = page(take) as? [Any] else { return all + ["no answer"] }
            all += more
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return all + (page(take) as? [Any] ?? ["no answer"])
    }
    let keyA = KeyCodes.hash("KeyA")
    let control = KeyCodes.hash("ControlLeft")
    let talk = "[{ actionId: 'talk', keys: [\(keyA)] }]"
    let combo = "[{ actionId: 'combo', keys: [\(control), \(keyA)] }, { actionId: 'side', keys: [], mouseButton: 4 }]"

    open("/client")

    // 1. Without the permission: not listening, the page is told, the
    //    system is asked.
    let first = page("return await window.backspace.syncKeybinds(\(talk));") as? Bool
    if first != false || keyboard.isStarted || permission.requests != 1 {
        problems.append("without the permission the sync answered \(String(describing: first)), listening \(keyboard.isStarted), asked the system \(permission.requests) time(s)")
    }
    if taken("__status", expecting: 1) as? [Bool] != [false] { problems.append("without the permission the page was not told once that it is missing") }
    if page("return await window.backspace.checkAccessibility();") as? Bool != false { problems.append("the permission was reported as given") }
    keyboard.send(.keyDown(keyCode: 0x00))
    if !taken("__actions").isEmpty { problems.append("a key was acted on without the permission") }

    // 2. The permission is given: the next look starts the listening.
    permission.isGranted = true
    if page("return await window.backspace.checkAccessibility();") as? Bool != true || !keyboard.isStarted {
        problems.append("after the permission was given the shell is \(keyboard.isStarted ? "listening" : "not listening")")
    }
    if taken("__status", expecting: 1) as? [Bool] != [true] { problems.append("the page was not told that the permission is there") }

    // 3. A held key presses its action once and releases it once.
    keyboard.send(.keyDown(keyCode: 0x00))
    keyboard.send(.keyDown(keyCode: 0x00))
    keyboard.send(.keyDown(keyCode: 0x00))
    keyboard.send(.keyUp(keyCode: 0x00))
    let single = taken("__actions", expecting: 2) as? [String] ?? []
    if single != ["talk down", "talk up"] { problems.append("a held key gave \(single)") }

    //    A release the system never reported is noticed: the key is found
    //    to be up, and the action ends once.
    keyboard.send(.keyDown(keyCode: 0x00))
    if taken("__actions", expecting: 1) as? [String] != ["talk down"] { problems.append("a key did not press its action before its release was lost") }
    probe.releasedKeys = [0x00]
    if taken("__actions", expecting: 1) as? [String] != ["talk up"] { problems.append("a lost release left the action pressed") }
    probe.releasedKeys = []

    // 4. An empty list stops the listening; a new one starts it again.
    if page("return await window.backspace.syncKeybinds([]);") as? Bool != false || keyboard.isStarted {
        problems.append("an empty list left the shell listening")
    }
    if page("return await window.backspace.syncKeybinds(\(combo));") as? Bool != true || !keyboard.isStarted {
        problems.append("a new list did not start the listening again")
    }

    // 5. A combination with a modifier, and a mouse button.
    keyboard.send(.flagsChanged(keyCode: 0x3B, flags: 0x40101))
    keyboard.send(.keyDown(keyCode: 0x00))
    keyboard.send(.flagsChanged(keyCode: 0x3B, flags: 0x100))
    keyboard.send(.keyUp(keyCode: 0x00))
    keyboard.send(.mouseDown(button: 3))
    keyboard.send(.mouseUp(button: 3))
    let mixed = taken("__actions", expecting: 4) as? [String] ?? []
    if mixed != ["combo down", "combo up", "side down", "side up"] { problems.append("a combination and a mouse button gave \(mixed)") }

    // 6. A list that cannot be read changes nothing.
    let afterBad = page("return await window.backspace.syncKeybinds([{ actionId: 'broken', keys: 'KeyA' }]);") as? Bool
    keyboard.send(.mouseDown(button: 3))
    keyboard.send(.mouseUp(button: 3))
    if afterBad != true || taken("__actions", expecting: 2) as? [String] != ["side down", "side up"] {
        problems.append("a list that cannot be read changed what is listened for")
    }

    // 7. The page's request opens the permission's settings; the Wayland
    //    portal has no status here.
    _ = page("window.backspace.openKeybindPermissionSettings(); return true;")
    if !wait(5, until: { permission.settingsOpened == 1 }) { problems.append("the permission's settings were opened \(permission.settingsOpened) time(s)") }
    let portal = page("return (await window.backspace.getKeybindPortalStatus()) === null;") as? Bool
    if portal != true { problems.append("the portal status is not null") }

    // 8. Another page starts with no keybinds, and nothing is listened to.
    keyboard.send(.mouseDown(button: 3))
    _ = taken("__actions")
    open("/other")
    if keyboard.isStarted { problems.append("another page left the shell listening for the keybinds of the last one") }

    // 9. A listener the system will not start is reported to the page.
    keyboard.canStart = false
    if page("return await window.backspace.syncKeybinds(\(talk));") as? Bool != false {
        problems.append("the sync said the shell is listening when the listener did not start")
    }
    if (taken("__errors", expecting: 1) as? [String])?.count != 1 { problems.append("a listener that did not start was not reported once") }

    for problem in problems {
        FileHandle.standardError.write(Data("ContractCheck: \(problem)\n".utf8))
    }
    print(problems.isEmpty
        ? "keybinds: nothing is listened to without the permission; with it a held key presses its action once; another page starts with none"
        : "keybinds: \(problems.count) problem(s)")
    exit(problems.isEmpty ? 0 : 1)
}

switch checkName {
case nil:
    break
case "keybinds":
    checkKeybinds()
case "activity":
    checkActivity()
case "activity-network":
    checkActivityNetwork()
case "tray":
    checkTray()
case "drag":
    checkDrag()
case "recovery":
    checkRecovery()
case "menu":
    checkMenu()
case "notifications":
    checkNotifications()
case "sources":
    checkSources()
case "media-channel":
    checkMediaChannel()
case "capture":
    checkCapture()
case "capture-web":
    checkCaptureWeb(address: arguments["url"] ?? "http://localhost:5173/dev-native-capture.html")
case "capture-system":
    checkCaptureSystem(
        size: arguments["size"] ?? "1920x1080",
        framesPerSecond: arguments["frame-rate"].flatMap { Int($0) } ?? 60,
        seconds: arguments["seconds"].flatMap { Double($0) } ?? 5
    )
case "video-pipe":
    checkVideoPipe(
        size: arguments["size"] ?? "1920x1080", sink: arguments["sink"] ?? "track",
        noiseEvery: arguments["noise-every"].flatMap { Int($0) } ?? 32
    )
case "sources-system":
    checkSourcesSystem()
case "launch":
    checkLaunch()
case "window-state":
    checkWindowState()
case "local-storage-import":
    checkLocalStorageImport(fixture: fileURL(arguments, "fixture"))
default:
    fail("--check takes window-state, local-storage-import, launch, notifications, menu, recovery, drag, tray, activity, keybinds, sources, sources-system, media-channel, video-pipe, capture, capture-web, capture-system or electron-profile")
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
                    guard var facts = value as? [String: Any] else { fail("the page gave no answer") }
                    // What the shell was told of the page's title bar: null
                    // when the page reported nothing and the top strip stands.
                    func plain(_ rects: [PlainRect]) -> [[String: Double]] {
                        rects.map { ["x": $0.x, "y": $0.y, "width": $0.width, "height": $0.height] }
                    }
                    facts["shellDragRegions"] = controller.reportedDragRegions.map {
                        ["drag": plain($0.drag), "noDrag": plain($0.noDrag)]
                    } ?? NSNull()
                    guard let data = try? JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys]) else {
                        fail("the page's answer is not JSON")
                    }
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
