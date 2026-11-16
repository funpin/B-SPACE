import AppKit
import ProbeSupport
import WebKit

// WebKitProbe opens one page in a WKWebView, runs a script in it and writes a
// JSON report: what the script returned, what the page logged, how navigation
// went, what it tried to download and which permissions it asked for.
//
// It answers "how does the system WebKit behave here" with a measurement, for
// the pre-audit of the native macOS client and for the checks later stages
// repeat. It is not part of the application.

/// Installed at document start. Forwards console errors and uncaught failures
/// to the report and gives probe scripts `probeNative(op, args)`.
private let pageSupportScript = """
(() => {
  const describe = (value) => {
    try {
      if (typeof value === 'string') return value;
      if (value instanceof Error) return value.stack || value.message;
      return JSON.stringify(value);
    } catch (_) {
      return String(value);
    }
  };
  const post = (level, parts) => {
    try {
      window.webkit.messageHandlers.probeLog.postMessage({ level, text: parts.map(describe).join(' ') });
    } catch (_) {}
  };
  for (const level of ['error', 'warn']) {
    const original = console[level];
    console[level] = (...parts) => { post(level, parts); original.apply(console, parts); };
  }
  window.addEventListener('error', (event) => {
    post('uncaught', [`${event.message} @ ${event.filename}:${event.lineno}`]);
  });
  window.addEventListener('unhandledrejection', (event) => {
    const reason = event.reason;
    post('unhandledrejection', [reason && (reason.stack || reason.message) || String(reason)]);
  });
  window.probeNative = (op, args) => window.webkit.messageHandlers.probeNative.postMessage({ op, args: args || {} });
})();
"""

/// The editing toggles WKWebView validates as menu items. Their checked state
/// is the only public way to read what the view will do while the user types.
private let textCheckingActions = [
    "toggleContinuousSpellChecking:",
    "toggleGrammarChecking:",
    "toggleAutomaticSpellingCorrection:",
    "toggleAutomaticQuoteSubstitution:",
    "toggleAutomaticDashSubstitution:",
    "toggleAutomaticTextReplacement:",
    "toggleAutomaticLinkDetection:",
    "toggleSmartInsertDelete:",
]

/// Mean and spread of luminance (0–255) inside `rect`, which is given in points
/// from the top left corner of an image that is `pointWidth` points wide.
/// A sharp pattern has a large spread; the same pattern behind a blur has
/// almost none. Nil when the rectangle does not lie inside the image.
private func luminanceStats(of image: CGImage, rect: CGRect, pointWidth: Double) -> [String: Any]? {
    guard pointWidth > 0 else { return nil }
    let scale = Double(image.width) / pointWidth
    let pixelRect = CGRect(
        x: (rect.minX * scale).rounded(),
        y: (rect.minY * scale).rounded(),
        width: (rect.width * scale).rounded(),
        height: (rect.height * scale).rounded()
    )
    let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    guard pixelRect.width >= 1, pixelRect.height >= 1, bounds.contains(pixelRect),
          let cropped = image.cropping(to: pixelRect) else { return nil }

    let width = cropped.width
    let height = cropped.height
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(
            data: buffer.baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard drawn else { return nil }

    var sum = 0.0
    var sumOfSquares = 0.0
    var minimum = 255.0
    var maximum = 0.0
    let count = Double(width * height)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        let luminance = 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        sum += luminance
        sumOfSquares += luminance * luminance
        minimum = min(minimum, luminance)
        maximum = max(maximum, luminance)
    }
    let mean = sum / count
    let variance = max(0, sumOfSquares / count - mean * mean)
    return [
        "mean": (mean * 10).rounded() / 10,
        "spread": (variance.squareRoot() * 10).rounded() / 10,
        "min": minimum.rounded(),
        "max": maximum.rounded(),
        "pixels": width * height,
    ]
}

final class Probe: NSObject, NSApplicationDelegate, WKNavigationDelegate, WKUIDelegate,
    WKScriptMessageHandler, WKScriptMessageHandlerWithReply, WKDownloadDelegate {
    private let options: ProbeOptions
    private let startedAt = Date()
    private var window: NSWindow!
    private var webView: WKWebView!

    private var console: [[String: Any]] = []
    private var navigation: [[String: Any]] = []
    private var downloads: [[String: Any]] = []
    private var permissionRequests: [[String: Any]] = []
    private var dialogs: [[String: Any]] = []
    private var downloadTargets: [ObjectIdentifier: URL] = [:]

    private var scriptStarted = false
    private var finished = false
    private var eventNumber = 0

    init(options: ProbeOptions) {
        self.options = options
    }

    // MARK: Start

    func applicationDidFinishLaunching(_ notification: Notification) {
        var registered: [String: Any] = [:]
        for (key, raw) in options.defaults {
            switch raw {
            case "true": registered[key] = true
            case "false": registered[key] = false
            default: registered[key] = raw
            }
        }
        // Set, not registered: WebKit reads some of these with objectForKey and
        // writes its own values back, so a registered default could be shadowed
        // by what an earlier run left in this bundle's domain.
        for (key, value) in registered {
            UserDefaults.standard.set(value, forKey: key)
        }

        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        if let name = options.applicationNameForUserAgent {
            configuration.applicationNameForUserAgent = name
        }
        if options.ephemeral {
            configuration.websiteDataStore = .nonPersistent()
        }
        if options.unfilteredICE {
            // Private WebKit preference, for measuring only; the application
            // must never call it. Without capture permission WebKit hides host
            // addresses behind mDNS names, and two peer connections in one
            // page then never connect, so the encoder never runs. Passing nil
            // as the BOOL argument is NO.
            let selector = NSSelectorFromString("_setICECandidateFilteringEnabled:")
            if configuration.preferences.responds(to: selector) {
                configuration.preferences.perform(selector, with: nil)
            } else {
                console.append(["level": "probe", "text": "this WebKit has no ICE candidate filtering switch"])
            }
        }
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(source: pageSupportScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "probeLog")
        controller.addScriptMessageHandler(self, contentWorld: .page, name: "probeNative")

        let contentRect = NSRect(x: 0, y: 0, width: options.width, height: options.height)
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if options.titleBar == .hiddenInset {
            style.insert(.fullSizeContentView)
        }
        window = NSWindow(contentRect: contentRect, styleMask: style, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "WebKitProbe"
        if options.titleBar == .hiddenInset {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }

        webView = WKWebView(frame: contentRect, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isInspectable = true
        webView.autoresizingMask = [.width, .height]
        window.contentView = webView
        window.setContentSize(contentRect.size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY - 40))
        }

        if options.activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(webView)
        } else {
            window.orderFrontRegardless()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(options.timeoutSeconds)) { [weak self] in
            self?.finish(result: nil, scriptError: nil, timedOut: true)
        }

        webView.load(URLRequest(url: options.url))
    }

    // MARK: Script

    private func scheduleScript() {
        guard !scriptStarted else { return }
        scriptStarted = true
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(options.settleMilliseconds)) { [weak self] in
            self?.runScript()
        }
    }

    private func runScript() {
        let body: String
        if let path = options.scriptPath {
            do {
                body = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                finish(result: nil, scriptError: "cannot read \(path): \(error.localizedDescription)", timedOut: false)
                return
            }
        } else if let expression = options.callExpression {
            body = "return await (\(expression));"
        } else {
            finish(result: nil, scriptError: nil, timedOut: false)
            return
        }
        webView.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { [weak self] outcome in
            switch outcome {
            case .success(let value):
                self?.finish(result: value, scriptError: nil, timedOut: false)
            case .failure(let error):
                let details = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self?.finish(result: nil, scriptError: details ?? error.localizedDescription, timedOut: false)
            }
        }
    }

    private func finish(result: Any?, scriptError: String?, timedOut: Bool) {
        guard !finished else { return }
        finished = true

        let complete: () -> Void = { [self] in
            var report: [String: Any] = [
                "probe": [
                    "url": options.url.absoluteString,
                    "size": [options.width, options.height],
                    "titleBar": options.titleBar.rawValue,
                    "os": ProcessInfo.processInfo.operatingSystemVersionString,
                    "webKit": Bundle(for: WKWebView.self).infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
                    "bundleIdentifier": Bundle.main.bundleIdentifier ?? "none",
                ] as [String: Any],
                "navigation": navigation,
                "console": console,
                "downloads": downloads,
                "permissionRequests": permissionRequests,
                "dialogs": dialogs,
                "timedOut": timedOut,
                "elapsedMs": Int(Date().timeIntervalSince(startedAt) * 1000),
            ]
            if let result {
                report["result"] = JSONSerialization.isValidJSONObject(["value": result]) ? result : String(describing: result)
            }
            if let scriptError {
                report["scriptError"] = scriptError
            }
            write(report: report)
            exit(timedOut || scriptError != nil ? 1 : 0)
        }

        if let path = options.windowCapturePath {
            if let image = captureOwnWindow(),
               let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                do {
                    try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                } catch {
                    console.append(["level": "probe", "text": "window capture not written: \(error.localizedDescription)"])
                }
            } else {
                console.append(["level": "probe", "text": "window capture failed"])
            }
        }

        if let path = options.snapshotPath {
            snapshot(to: path) { [self] error in
                if let error {
                    console.append(["level": "probe", "text": "snapshot failed: \(error)"])
                }
                complete()
            }
        } else {
            complete()
        }
    }

    private func write(report: [String: Any]) {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            FileHandle.standardError.write("cannot encode the report: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(2)
        }
        if let path = options.outPath {
            do {
                try data.write(to: URL(fileURLWithPath: path), options: .atomic)
            } catch {
                FileHandle.standardError.write("cannot write \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
                exit(2)
            }
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write("\n".data(using: .utf8)!)
        }
    }

    private func snapshot(to path: String, completion: @escaping (String?) -> Void) {
        webView.takeSnapshot(with: nil) { image, error in
            guard let image,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:]) else {
                completion(error?.localizedDescription ?? "no image")
                return
            }
            do {
                try png.write(to: URL(fileURLWithPath: path), options: .atomic)
                completion(nil)
            } catch {
                completion(error.localizedDescription)
            }
        }
    }

    // MARK: Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any] else { return }
        console.append([
            "level": body["level"] as? String ?? "log",
            "text": body["text"] as? String ?? "",
        ])
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "probeNative is answered for the main frame only")
            return
        }
        guard let body = message.body as? [String: Any], let op = body["op"] as? String else {
            replyHandler(nil, "probeNative needs { op, args }")
            return
        }
        let args = body["args"] as? [String: Any] ?? [:]
        func number(_ key: String) -> Double? { (args[key] as? NSNumber)?.doubleValue }

        switch op {
        case "click":
            guard let x = number("x"), let y = number("y") else {
                replyHandler(nil, "click needs x and y")
                return
            }
            sendClick(x: x, y: y, right: args["button"] as? String == "right")
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(80)) { replyHandler(true, nil) }
        case "type":
            guard let text = args["text"] as? String else {
                replyHandler(nil, "type needs text")
                return
            }
            for character in text {
                sendKey(String(character))
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120)) { replyHandler(true, nil) }
        case "snapshot":
            guard let path = args["path"] as? String else {
                replyHandler(nil, "snapshot needs path")
                return
            }
            snapshot(to: path) { error in replyHandler(error == nil ? path : nil, error) }
        case "hide":
            window.orderOut(nil)
            replyHandler(true, nil)
        case "show":
            window.orderFrontRegardless()
            replyHandler(true, nil)
        case "resize":
            guard let width = number("width"), let height = number("height"), width > 0, height > 0 else {
                replyHandler(nil, "resize needs width and height")
                return
            }
            window.setContentSize(NSSize(width: width, height: height))
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { replyHandler(true, nil) }
        case "pageZoom":
            guard let value = number("value"), value > 0 else {
                replyHandler(nil, "pageZoom needs value")
                return
            }
            webView.pageZoom = value
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(150)) { replyHandler(true, nil) }
        case "pixelStats":
            guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height"),
                  width > 0, height > 0 else {
                replyHandler(nil, "pixelStats needs x, y, width and height")
                return
            }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if args["source"] as? String == "window" {
                guard let image = captureOwnWindow() else {
                    replyHandler(nil, "the window could not be captured")
                    return
                }
                // The capture covers the whole frame; the web view starts below the title bar.
                let titleBarHeight = Double(window.frame.height - webView.bounds.height)
                let stats = luminanceStats(of: image, rect: rect.offsetBy(dx: 0, dy: titleBarHeight), pointWidth: Double(window.frame.width))
                replyHandler(stats, stats == nil ? "the rectangle is outside the window" : nil)
            } else {
                webView.takeSnapshot(with: nil) { [weak self] image, error in
                    guard let self, let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                        replyHandler(nil, error?.localizedDescription ?? "no snapshot")
                        return
                    }
                    let stats = luminanceStats(of: cgImage, rect: rect, pointWidth: Double(self.webView.bounds.width))
                    replyHandler(stats, stats == nil ? "the rectangle is outside the view" : nil)
                }
            }
        case "textChecking":
            replyHandler(textCheckingState(), nil)
        case "windowInfo":
            replyHandler(windowInfo(), nil)
        default:
            replyHandler(nil, "unknown op \(op)")
        }
    }

    // MARK: Native operations

    private func nextEventNumber() -> Int {
        eventNumber += 1
        return eventNumber
    }

    /// `x`, `y`: points from the top left corner of the web view.
    private func sendClick(x: Double, y: Double, right: Bool) {
        let point = windowPoint(clientX: x, clientY: y, contentHeight: Double(webView.bounds.height))
        let location = NSPoint(x: point.x, y: point.y)
        let pairs: [(NSEvent.EventType, Float)] = right
            ? [(.rightMouseDown, 1), (.rightMouseUp, 0)]
            : [(.leftMouseDown, 1), (.leftMouseUp, 0)]
        for (type, pressure) in pairs {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: nextEventNumber(),
                clickCount: 1,
                pressure: pressure
            ) else { continue }
            window.sendEvent(event)
        }
    }

    private func sendKey(_ characters: String) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: 0
            ) else { continue }
            window.sendEvent(event)
        }
    }

    /// What the window server shows for this window, title bar included.
    ///
    /// `takeSnapshot` re-renders the page and may not match the screen (it is
    /// one of the things this probe checks), so the composited window is read
    /// as well. A process may capture its own windows without the Screen
    /// Recording permission. The function is looked up at run time because the
    /// SDK marks it unavailable in favour of ScreenCaptureKit, which would ask
    /// for that permission; this is a measuring aid, not application code.
    private func captureOwnWindow() -> CGImage? {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let onlyThisWindow: UInt32 = 1 << 3 // kCGWindowListOptionIncludingWindow
        let ignoreFraming: UInt32 = 1 << 0 // kCGWindowImageBoundsIgnoreFraming
        return createImage(.null, onlyThisWindow, UInt32(window.windowNumber), ignoreFraming)?.takeRetainedValue()
    }

    private func textCheckingState() -> [String: Any] {
        var state: [String: Any] = [:]
        for name in textCheckingActions {
            let action = NSSelectorFromString(name)
            let item = NSMenuItem(title: name, action: action, keyEquivalent: "")
            let responds = webView.responds(to: action)
            let enabled = responds && webView.validateUserInterfaceItem(item)
            state[name] = ["responds": responds, "enabled": enabled, "on": item.state == .on]
        }
        state["system"] = [
            "automaticQuoteSubstitution": NSSpellChecker.isAutomaticQuoteSubstitutionEnabled,
            "automaticDashSubstitution": NSSpellChecker.isAutomaticDashSubstitutionEnabled,
            "automaticSpellingCorrection": NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
            "automaticTextReplacement": NSSpellChecker.isAutomaticTextReplacementEnabled,
        ]
        return state
    }

    private func windowInfo() -> [String: Any] {
        func rect(_ value: NSRect) -> [String: Double] {
            ["x": Double(value.minX), "y": Double(value.minY), "width": Double(value.width), "height": Double(value.height)]
        }
        var info: [String: Any] = [
            "frame": rect(window.frame),
            "contentLayoutRect": rect(window.contentLayoutRect),
            "webViewBounds": rect(webView.bounds),
            "backingScaleFactor": Double(window.backingScaleFactor),
            "isKeyWindow": window.isKeyWindow,
            "isVisible": window.isVisible,
            "occlusionVisible": window.occlusionState.contains(.visible),
        ]
        // Top-left based, so the numbers compare directly with CSS coordinates.
        var buttons: [String: Any] = [:]
        let height = window.frame.height
        for (name, kind) in [("close", NSWindow.ButtonType.closeButton), ("miniaturize", .miniaturizeButton), ("zoom", .zoomButton)] {
            guard let button = window.standardWindowButton(kind) else { continue }
            let inWindow = button.convert(button.bounds, to: nil)
            buttons[name] = [
                "x": Double(inWindow.minX),
                "y": Double(height - inWindow.maxY),
                "width": Double(inWindow.width),
                "height": Double(inWindow.height),
            ]
        }
        info["buttons"] = buttons
        return info
    }

    // MARK: Navigation

    private func note(_ event: String, _ fields: [String: Any] = [:]) {
        var entry = fields
        entry["event"] = event
        entry["atMs"] = Int(Date().timeIntervalSince(startedAt) * 1000)
        navigation.append(entry)
    }

    private func fields(for error: Error) -> [String: Any] {
        let nsError = error as NSError
        return ["domain": nsError.domain, "code": nsError.code, "description": nsError.localizedDescription]
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.shouldPerformDownload {
            note("action-download", ["url": navigationAction.request.url?.absoluteString ?? ""])
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            note("response", ["status": http.statusCode, "url": http.url?.absoluteString ?? ""])
        }
        if !navigationResponse.canShowMIMEType {
            note("response-download", ["url": navigationResponse.response.url?.absoluteString ?? ""])
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("finished", ["url": webView.url?.absoluteString ?? ""])
        scheduleScript()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        note("failed-provisional", fields(for: error))
        // WebKitErrorDomain 102, "Frame load interrupted", is how WebKit reports
        // a navigation that turned into a download. The page is still there.
        let nsError = error as NSError
        if nsError.domain == "WebKitErrorDomain" && nsError.code == 102 { return }
        finish(result: nil, scriptError: nil, timedOut: false)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note("failed", fields(for: error))
        finish(result: nil, scriptError: nil, timedOut: false)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        note("server-redirect", ["url": webView.url?.absoluteString ?? ""])
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("content-process-terminated")
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    // MARK: Downloads

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let directory = URL(fileURLWithPath: options.downloadDirectory ?? NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("\(UUID().uuidString)-\(suggestedFilename)")
        downloadTargets[ObjectIdentifier(download)] = target
        downloads.append([
            "event": "started",
            "suggestedFilename": suggestedFilename,
            "mimeType": response.mimeType ?? "",
            "sourceScheme": response.url?.scheme ?? "",
        ])
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let target = downloadTargets[ObjectIdentifier(download)]
        let size = target.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? NSNumber }
        downloads.append(["event": "finished", "bytes": size?.intValue ?? -1])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        var entry = fields(for: error)
        entry["event"] = "failed"
        downloads.append(entry)
    }

    // MARK: UI delegate

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let kind: String
        switch type {
        case .camera: kind = "camera"
        case .microphone: kind = "microphone"
        case .cameraAndMicrophone: kind = "cameraAndMicrophone"
        @unknown default: kind = "unknown"
        }
        permissionRequests.append(["type": kind, "origin": "\(origin.protocol)://\(origin.host):\(origin.port)", "mainFrame": frame.isMainFrame])
        // Denied on purpose: granting would raise the system prompt on the
        // machine the probe runs on. Capture is measured by hand, not here.
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        note("window-open", ["url": navigationAction.request.url?.absoluteString ?? ""])
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        dialogs.append(["kind": "alert", "message": message])
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        dialogs.append(["kind": "confirm", "message": message])
        completionHandler(false)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        dialogs.append(["kind": "open-panel", "multiple": parameters.allowsMultipleSelection])
        completionHandler(nil)
    }
}

let options: ProbeOptions
do {
    options = try ProbeOptions.parse(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write("WebKitProbe: \(error)\n".data(using: .utf8)!)
    exit(64)
}

let application = NSApplication.shared
let probe = Probe(options: options)
application.delegate = probe
application.setActivationPolicy(options.activate ? .regular : .accessory)
application.run()
