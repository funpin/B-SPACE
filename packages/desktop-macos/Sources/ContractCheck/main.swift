import AppKit
import BSpaceCore
import BSpaceShell
import WebKit

// Runs the bridge contract check against the real shell: the same window
// controller, web view configuration and bridge the application uses, with no
// window on screen and its settings in a temporary folder. Loads
// contract/harness.html, lets it call every member of `window.backspace`,
// sends one event on every event channel, and compares what the page saw with
// what bridgeContract.json promises.
//
// Usage: ContractCheck --contract <json> --picker <html> --harness <html> [--out <json>]
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

let arguments = options()
let contractURL = fileURL(arguments, "contract")
let pickerURL = fileURL(arguments, "picker")
let visitAddress = arguments["visit"]
let harnessURL = visitAddress == nil ? fileURL(arguments, "harness") : nil

let temporary = FileManager.default.temporaryDirectory
    .appendingPathComponent("bspace-contract-check-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
let environment = ShellEnvironment(
    resources: ShellResources(pickerURL: pickerURL, contractURL: contractURL),
    userDataDirectory: temporary,
    appVersion: "0.0.0-check",
    safariVersion: ShellEnvironment.installedSafariVersion(),
    overrideURL: nil,
    language: "en"
)

let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let contract: BridgeContract
let controller: MainWindowController
do {
    contract = try BridgeContract(data: Data(contentsOf: contractURL))
    controller = try MainWindowController(environment: environment, showsWindow: false)
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
