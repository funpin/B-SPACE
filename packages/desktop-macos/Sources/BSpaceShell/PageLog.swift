import Foundation
import WebKit

/// The page's warnings and errors, written to a file. A development build
/// only (`ShellEnvironment.pageLogURL`).
///
/// What goes wrong in the web client is said on the page's console, and a
/// build that is being tried has no inspector open: without this, a share
/// that does not start leaves nothing to read. The file holds what the page
/// logged with `console.warn` and `console.error`, errors nobody caught and
/// promises nobody handled, one line each, and is started again when it
/// grows past a megabyte.
final class PageLog: NSObject, WKScriptMessageHandler {
    static let handlerName = "bspacePageLog"
    private static let mostBytes: UInt64 = 1_000_000

    private let url: URL
    private let queue = DispatchQueue(label: "page-log")

    init(url: URL) {
        self.url = url
    }

    /// Wraps the page's console and listens for what nobody caught. Runs at
    /// document start, in the main frame, in the page's own world: that is
    /// where the console the web client writes to lives.
    private static let script = """
        (() => {
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(handlerName);
          if (!handler) return;
          const describe = (value) => {
            if (value instanceof Error) return value.name + ': ' + value.message;
            if (typeof value === 'string') return value;
            try { return JSON.stringify(value); } catch { return String(value); }
          };
          const post = (level, values) => {
            try { handler.postMessage({ level, text: values.map(describe).join(' ').slice(0, 2000) }); } catch {}
          };
          for (const level of ['warn', 'error']) {
            const original = console[level];
            console[level] = (...values) => { post(level, values); original.apply(console, values); };
          }
          addEventListener('error', (event) => post('uncaught', [event.message, event.filename + ':' + event.lineno]));
          addEventListener('unhandledrejection', (event) => post('rejection', [event.reason]));
          post('loaded', [location.origin + location.pathname]);
        })();
        """

    func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, contentWorld: .page, name: Self.handlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let level = body["level"] as? String, let text = body["text"] as? String else { return }
        let stamp = ISO8601DateFormatter.string(
            from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime, .withFractionalSeconds]
        )
        let line = "\(stamp) \(level.prefix(12)) \(text.prefix(2000).replacingOccurrences(of: "\n", with: " "))\n"
        queue.async { [url] in
            let manager = FileManager.default
            let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > Self.mostBytes {
                try? manager.removeItem(at: url)
            }
            if !manager.fileExists(atPath: url.path) {
                try? manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let file = try? FileHandle(forWritingTo: url) else { return }
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: Data(line.utf8))
        }
    }
}
