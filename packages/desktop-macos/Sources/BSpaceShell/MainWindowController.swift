import AppKit
import BSpaceCore
import WebKit

/// A `WKWebView` without WebKit's own context menu. Electron shows none, and
/// the web client draws its own where it wants one.
final class ShellWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}

/// The main window: one `WKWebView` that shows either the server picker or the
/// web client of the chosen instance, with the `window.backspace` bridge.
public final class MainWindowController: NSObject {
    /// The chat surface of the "Kamen" design system. The window and the area
    /// behind the page are painted with it, so nothing flashes before the page
    /// draws itself.
    static let backgroundColor = NSColor(srgbRed: 0x0c / 255, green: 0x0c / 255, blue: 0x0e / 255, alpha: 1)

    /// The window shows itself this long after launch even when the first page
    /// has not finished loading, so a slow server never means no window.
    static let revealTimeout: TimeInterval = 3

    public let window: NSWindow
    public let webView: WKWebView
    public let bridge: BridgeHost

    /// Called each time a main-frame load ends, with the error when it failed.
    public var onMainFrameLoadEnded: ((Error?) -> Void)?
    /// Set once the app is quitting: closing the window then really closes it.
    public var isQuitting = false
    /// The language of everything the shell says itself. Follows the web
    /// client's choice, reported on `set-language`.
    public private(set) var language: DesktopLanguage
    /// Called when the web client reports another language.
    public var onLanguageChanged: ((DesktopLanguage) -> Void)?

    private let environment: ShellEnvironment
    private let instanceStore: InstanceURLStore
    private let showsWindow: Bool
    private var knownInstanceOrigins: Set<String> = []
    /// The address the shell asked for itself, until that load ends.
    private var shellLoad: URL?
    /// Counts the shell's own loads, so that one that waited for the import
    /// does not go ahead after a newer one was asked for.
    private var shellLoadCount = 0
    private let localStorageImporter: LocalStorageImporter
    private let autoLaunch: AutoLaunch
    private let notifications: NotificationPresenter?
    private var deepLinks = DeepLinkInbox()
    /// The app was started hidden: the window waits to be asked for.
    private var staysHidden = false
    private var hasRevealedWindow = false

    private let windowStateStore: WindowStateStore
    /// The frame the window has when it is neither zoomed nor full screen:
    /// what is saved while it is, so that the next launch restores a window
    /// that can be un-zoomed to a sensible size.
    private var normalFrame: NSRect?
    /// The saved state said the window was zoomed; applied when it first shows.
    private var restoresZoomed = false
    private var isFullScreen = false
    private var pendingStateSave: DispatchWorkItem?

    /// How long the window has to stay still before its place is written.
    static let stateSaveDelay: TimeInterval = 0.3

    /// - Parameters:
    ///   - showsWindow: false in a test run that drives the shell without
    ///     putting a window on screen.
    ///   - websiteDataStore: where the pages keep their data. A test run
    ///     passes one that is not written to disk.
    ///   - loginItem: the system's record of opening at login. A test run
    ///     passes one that registers nothing.
    ///   - notifications: what shows notifications; nil shows none. A test
    ///     run passes one that only records them.
    public init(
        environment: ShellEnvironment,
        showsWindow: Bool = true,
        websiteDataStore: WKWebsiteDataStore = .default(),
        loginItem: LoginItem = SystemLoginItem(),
        notifications: NotificationPresenter? = SystemNotificationPresenter()
    ) throws {
        self.environment = environment
        self.showsWindow = showsWindow
        self.notifications = notifications
        language = environment.language
        autoLaunch = AutoLaunch(
            store: AutoLaunchStore(directory: environment.userDataDirectory),
            loginItem: loginItem
        )
        // The Electron build keeps its Chromium profile in the user-data
        // folder itself.
        localStorageImporter = LocalStorageImporter(
            profileDirectory: environment.userDataDirectory,
            ledgerDirectory: environment.userDataDirectory,
            dataStore: websiteDataStore
        )
        instanceStore = InstanceURLStore(directory: environment.userDataDirectory)
        windowStateStore = WindowStateStore(directory: environment.userDataDirectory)

        let contract = try BridgeContract(data: Data(contentsOf: environment.resources.contractURL))
        bridge = BridgeHost(contract: contract, bridge: .backspace)

        TextCheckingDefaults.apply()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.applicationNameForUserAgent = environment.userAgentApplicationName
        // Electron's default: media plays without a gesture. Voice and the
        // notification sounds rely on it.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.isElementFullscreenEnabled = true
        try bridge.install(
            into: configuration.userContentController,
            contract: contract,
            values: ["platform": AppIdentity.platform]
        )

        let contentRect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        webView = ShellWebView(frame: contentRect, configuration: configuration)
        webView.autoresizingMask = [.width, .height]
        webView.underPageBackgroundColor = Self.backgroundColor
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        // There is no public way to open the inspector from a menu; this lets
        // Safari's Develop menu attach to the page (deviation 4).
        webView.isInspectable = true

        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = AppIdentity.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Electron's `hiddenInset`: an empty toolbar moves the window buttons
        // down and inward to where the web client leaves room for them.
        window.toolbar = NSToolbar(identifier: "main")
        window.toolbarStyle = .unifiedCompact
        window.contentMinSize = NSSize(width: 940, height: 500)
        window.backgroundColor = Self.backgroundColor
        window.isReleasedWhenClosed = false
        window.contentView = webView
        window.center()

        super.init()

        // Before the delegate is set: placing the window must not count as
        // the user moving it.
        restoreWindowState()
        bridge.attach(to: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.delegate = self
        registerBridgeHandlers()
        notifications?.onClick = { [weak self] userInfo in
            self?.notificationClicked(userInfo)
        }
    }

    // MARK: Loading

    /// Clears the caches Electron clears at launch, then loads the first page:
    /// the override address, else the saved instance, else the picker.
    ///
    /// - Parameter hidden: the window is not shown when the page is ready,
    ///   only when something asks for it (the Dock icon, a link, a second
    ///   launch). The page loads and connects all the same.
    public func start(hidden: Bool = false) {
        staysHidden = hidden
        let stale: Set<String> = [
            WKWebsiteDataTypeDiskCache,
            WKWebsiteDataTypeMemoryCache,
            WKWebsiteDataTypeServiceWorkerRegistrations,
        ]
        webView.configuration.websiteDataStore.removeData(ofTypes: stale, modifiedSince: .distantPast) { [weak self] in
            self?.loadInitialPage()
        }
        if showsWindow {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealTimeout) { [weak self] in
                self?.revealWindow()
            }
        }
    }

    private func loadInitialPage() {
        let saved = environment.overrideURL ?? instanceStore.load()
        if let saved, let url = InstanceURLStore.loadableURL(saved) {
            load(url)
        } else {
            loadPicker()
        }
    }

    /// Loads an address on the shell's own authority, past the policy that
    /// binds the page's navigations.
    public func load(_ url: URL) {
        shellLoad = url
        shellLoadCount += 1
        if url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            return
        }
        // An instance the Electron build was signed in to gets that build's
        // localStorage first, once (LocalStorageImporter). With nothing to
        // bring over this goes straight on.
        let count = shellLoadCount
        localStorageImporter.importIfNeeded(for: url) { [weak self] _ in
            guard let self, self.shellLoadCount == count else { return }
            self.shellLoad = url
            self.webView.load(URLRequest(url: url))
        }
    }

    public func loadPicker() {
        var components = URLComponents(url: environment.resources.pickerURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "lang", value: language.code)]
        load(components?.url ?? environment.resources.pickerURL)
    }

    private var isShowingPicker: Bool {
        webView.url?.isFileURL == true && webView.url?.path == environment.resources.pickerURL.path
    }

    // MARK: Window

    public func showWindow() {
        guard showsWindow else { return }
        if !hasRevealedWindow, restoresZoomed, !window.isZoomed {
            window.zoom(nil)
        }
        hasRevealedWindow = true
        window.makeKeyAndOrderFront(nil)
    }

    /// Shows the window for the first time, once its page is ready, unless
    /// the app was started hidden.
    private func revealWindow() {
        guard !hasRevealedWindow, !staysHidden else { return }
        showWindow()
    }

    // MARK: Menu actions

    /// Forgets the saved instance and opens the picker, with the window in
    /// front: "Change Instance" in the application menu.
    public func changeInstance() {
        instanceStore.clear()
        loadPicker()
        showWindow()
    }

    /// Opens the source code of the instance in the user's browser: the
    /// address the instance names for itself, or the project's own.
    public func openSourceCode() {
        let page = webView.url.flatMap { WebOrigin.of($0) }
        let instance = environment.overrideURL ?? instanceStore.load() ?? page
        guard let infoURL = SourceCode.instanceInfoURL(instanceAddress: instance) else {
            Self.openInBrowser(SourceCode.projectAddress)
            return
        }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 5
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            let answered = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let address = SourceCode.address(fromInstanceInfo: answered ? data : nil)
            DispatchQueue.main.async {
                Self.openInBrowser(address)
            }
        }.resume()
    }

    private static func openInBrowser(_ address: String) {
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Notifications

    /// A click on a notification brings the window forward and, if the page
    /// is still of the instance that asked for the notification, tells the
    /// page what to open.
    private func notificationClicked(_ userInfo: [AnyHashable: Any]) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        showWindow()
        NSApp.activate(ignoringOtherApps: true)
        if let payload = NotificationRequest.clickPayload(userInfo: userInfo, currentPageURL: webView.url) {
            bridge.emit("notification-click", payload: payload)
        }
    }

    // MARK: Links

    /// Takes a `backspace://` link from outside the app: sends it to the page,
    /// or keeps it until the page listens for links. Anything that is not
    /// such a link is ignored.
    ///
    /// - Parameter showingWindow: bring the window forward now. False for the
    ///   link the app was launched with: the window appears when its first
    ///   page is ready, as on any launch.
    public func openDeepLink(_ link: String, showingWindow: Bool = true) {
        guard DeepLink.accepts(link) else { return }
        if let ready = deepLinks.receive(link) {
            bridge.emit("deep-link", payload: ready)
        }
        if showingWindow {
            showWindow()
        }
    }

    // MARK: Window state

    private static func plain(_ rect: NSRect) -> PlainRect {
        PlainRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height)
    }

    /// The height of the primary display, the one whose corner both coordinate
    /// systems start from. AppKit lists it first.
    private static var primaryDisplayHeight: Double? {
        NSScreen.screens.first.map { Double($0.frame.height) }
    }

    /// Puts the window where `window-state.json` says, if that place is still
    /// on a display; otherwise gives it the saved size and centres it.
    private func restoreWindowState() {
        guard showsWindow, let primaryHeight = Self.primaryDisplayHeight else { return }
        let displays = NSScreen.screens.map { screen in
            DisplayGeometry(
                frame: WindowPlacement.flipped(Self.plain(screen.frame), primaryDisplayHeight: primaryHeight),
                workArea: WindowPlacement.flipped(Self.plain(screen.visibleFrame), primaryDisplayHeight: primaryHeight)
            )
        }
        let minimum = window.contentMinSize
        let state = WindowPlacement.restorable(
            windowStateStore.load(),
            displays: displays,
            minimumWidth: minimum.width,
            minimumHeight: minimum.height
        )
        if let bounds = state.bounds {
            let frame = WindowPlacement.flipped(bounds, primaryDisplayHeight: primaryHeight)
            window.setFrame(NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height), display: false)
        } else {
            window.setContentSize(NSSize(width: state.width, height: state.height))
            window.center()
        }
        normalFrame = window.frame
        restoresZoomed = state.isMaximized
    }

    private func windowFrameChanged() {
        guard showsWindow, !isFullScreen else { return }
        if !window.isZoomed {
            normalFrame = window.frame
        }
        pendingStateSave?.cancel()
        let save = DispatchWorkItem { [weak self] in self?.saveWindowState() }
        pendingStateSave = save
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stateSaveDelay, execute: save)
    }

    /// Writes the window's place now. Called when it has stopped moving, when
    /// it is closed and when the app quits. A full-screen window is not
    /// written: the state stays the one it had before it went full screen.
    public func saveWindowState() {
        pendingStateSave?.cancel()
        pendingStateSave = nil
        guard showsWindow, !isFullScreen, let primaryHeight = Self.primaryDisplayHeight else { return }
        let isZoomed = window.isZoomed
        let frame = isZoomed ? (normalFrame ?? window.frame) : window.frame
        let bounds = WindowPlacement.flipped(Self.plain(frame), primaryDisplayHeight: primaryHeight)
        let state = WindowState(width: bounds.width, height: bounds.height, x: bounds.x, y: bounds.y, isMaximized: isZoomed)
        do {
            try windowStateStore.save(state)
        } catch {
            // Losing the window's place is not worth interrupting anyone for.
            NSLog("[window] could not save the window state: %@", error.localizedDescription)
        }
    }

    // MARK: Bridge

    private static func bridgeValue(_ settings: AutoLaunchSettings) -> [String: Any] {
        ["openAtLogin": settings.openAtLogin, "startMinimized": settings.startMinimized]
    }

    private func registerBridgeHandlers() {
        let router = bridge.router

        router.onFire("minimize-window") { [weak self] _ in
            self?.window.miniaturize(nil)
        }
        router.onFire("maximize-window") { [weak self] _ in
            self?.window.zoom(nil)
        }
        router.onFire("close-window") { [weak self] _ in
            self?.window.performClose(nil)
        }
        router.onFire("set-connected-origins") { [weak self] arguments in
            guard let origins = arguments.array(at: 0) else { return }
            self?.knownInstanceOrigins = Set(origins.compactMap { $0 as? String }.filter { !$0.isEmpty })
        }

        router.onFire("show-notification") { [weak self] arguments in
            guard
                let self,
                let request = NotificationRequest(arguments: arguments, pageURL: self.webView.url)
            else { return }
            self.notifications?.show(request)
        }
        router.onFire("set-language") { [weak self] arguments in
            guard
                let self,
                let language = self.environment.strings.language(code: arguments.string(at: 0))
            else { return }
            do {
                try LanguageStore(directory: self.environment.userDataDirectory).save(language)
            } catch {
                NSLog("[language] could not remember the language: %@", error.localizedDescription)
            }
            guard language != self.language else { return }
            self.language = language
            self.onLanguageChanged?(language)
        }
        router.onFire("set-badge-count") { arguments in
            NSApp.dockTile.badgeLabel = BadgeCount.label(for: arguments.number(at: 0))
        }

        router.onSubscribe("deep-link") { [weak self] in
            guard let self, let waiting = self.deepLinks.listenerAppeared() else { return }
            self.bridge.emit("deep-link", payload: waiting)
        }

        router.onInvoke("get-auto-launch-settings", answering: { [autoLaunch] _ in
            .value(Self.bridgeValue(autoLaunch.current))
        })
        router.onInvoke("set-auto-launch-settings", answering: { [autoLaunch] arguments in
            let requested = arguments.object(at: 0) ?? [:]
            let (settings, failure) = autoLaunch.update(
                openAtLogin: requested["openAtLogin"] as? Bool,
                startMinimized: requested["startMinimized"] as? Bool
            )
            if let failure {
                NSLog("[auto-launch] the change was not fully applied: %@", failure.localizedDescription)
            }
            return .value(Self.bridgeValue(settings))
        })

        router.onInvoke("get-app-version", answering: { [environment] _ in
            .value(environment.appVersion)
        })
        router.onInvoke("is-sandboxed", answering: { _ in .value(false) })
        router.onInvoke("get-instance-url", answering: { [instanceStore] _ in
            instanceStore.load().map { .value($0) } ?? .null
        })
        router.onInvoke("set-instance-url", answering: { [weak self] arguments in
            guard let self else { return .undefined }
            guard let address = arguments.string(at: 0), let url = InstanceURLStore.loadableURL(address) else {
                return .failure("The instance address must be an http or https URL")
            }
            do {
                try self.instanceStore.save(address)
            } catch {
                return .failure("The instance address could not be saved: \(error.localizedDescription)")
            }
            self.load(url)
            return .undefined
        })
        router.onInvoke("clear-instance-url", answering: { [weak self] _ in
            self?.instanceStore.clear()
            self?.loadPicker()
            return .undefined
        })

        InterimReplies.register(on: router)
        let unhandled = router.unhandledChannels
        precondition(unhandled.isEmpty, "bridge channels without a handler: \(unhandled.joined(separator: ", "))")
    }
}

// MARK: - Navigation

extension MainWindowController: WKNavigationDelegate {
    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        // A link that asks for a new window has no target frame; allowing it
        // here hands it to `createWebViewWith`, which never opens one.
        guard let frame = navigationAction.targetFrame else {
            decisionHandler(.allow)
            return
        }
        // The policy is about what the window shows, as `will-navigate` is in
        // Electron; frames inside the page are the page's business.
        guard frame.isMainFrame, let target = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        let allowed = NavigationPolicy.isAllowed(NavigationRequest(
            target: target,
            currentURL: webView.url,
            pickerFileURL: environment.resources.pickerURL,
            knownInstanceOrigins: knownInstanceOrigins,
            shellLoad: shellLoad
        ))
        if !allowed {
            NSLog("[navigation] blocked a navigation to %@", target.absoluteString)
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // A new document: whatever listened for links in the old one is gone.
        deepLinks.pageChanged()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        mainFrameLoadEnded(error: nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        mainFrameLoadFailed(error)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        mainFrameLoadFailed(error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        deepLinks.pageChanged()
        NSLog("[navigation] the web content process ended; reloading")
        if let url = webView.url {
            load(url)
        } else {
            loadInitialPage()
        }
    }

    /// Not a failed load: a navigation the policy cancelled, one a newer
    /// navigation replaced, or one that became a download (WebKit reports that
    /// as `WebKitErrorDomain` 102, pre-audit 2.6).
    private static func isInterruption(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled { return true }
        return error.domain == "WebKitErrorDomain" && error.code == 102
    }

    private func mainFrameLoadFailed(_ error: Error) {
        guard !Self.isInterruption(error) else { return }
        NSLog("[navigation] load failed: %@", error.localizedDescription)
        let failedShellLoad = shellLoad
        mainFrameLoadEnded(error: error)
        // An instance that cannot be reached must not leave an empty window
        // with no way out: the picker opens with the saved address filled in,
        // to retry or to choose another. The recovery screen of stage 2 takes
        // this over.
        if let failedShellLoad, !failedShellLoad.isFileURL, !isShowingPicker {
            loadPicker()
        }
    }

    private func mainFrameLoadEnded(error: Error?) {
        shellLoad = nil
        revealWindow()
        onMainFrameLoadEnded?(error)
    }
}

// MARK: - Downloads

extension MainWindowController: WKDownloadDelegate {
    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else {
                completionHandler(nil)
                return
            }
            // The panel has already asked about replacing; WebKit refuses to
            // write over a file that exists.
            try? FileManager.default.removeItem(at: destination)
            completionHandler(destination)
        }
        if window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard !Self.isInterruption(error) else { return }
        NSLog("[download] failed: %@", error.localizedDescription)
        present(NSAlert(error: error)) { _ in }
    }
}

// MARK: - Page requests

extension MainWindowController: WKUIDelegate {
    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        switch NavigationPolicy.windowOpenDecision(url: url, knownInstanceOrigins: knownInstanceOrigins) {
        case .internalRoute(let route):
            bridge.emit("open-internal-route", payload: route)
        case .external(let url):
            NSWorkspace.shared.open(url)
        case .ignore:
            break
        }
        return nil
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        present(alert) { _ in completionHandler() }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: Self.systemString("OK"))
        alert.addButton(withTitle: Self.systemString("Cancel"))
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: Self.systemString("OK"))
        alert.addButton(withTitle: Self.systemString("Cancel"))
        alert.window.initialFirstResponder = field
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
        if window.isVisible {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Shows an alert on the window, or on its own when the window is hidden:
    /// a sheet on a window that is not on screen would never be answered.
    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if window.isVisible {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }

    /// A button title in the user's language, from AppKit's own strings.
    private static func systemString(_ key: String) -> String {
        Bundle(for: NSApplication.self).localizedString(forKey: key, value: key, table: nil)
    }
}

// MARK: - Window events

extension MainWindowController: NSWindowDelegate {
    public func windowDidBecomeKey(_ notification: Notification) {
        bridge.emit("window-focus-changed", payload: true)
    }

    public func windowDidResignKey(_ notification: Notification) {
        bridge.emit("window-focus-changed", payload: false)
    }

    public func windowDidResize(_ notification: Notification) {
        windowFrameChanged()
    }

    public func windowDidMove(_ notification: Notification) {
        windowFrameChanged()
    }

    public func windowWillEnterFullScreen(_ notification: Notification) {
        // Whatever was pending is the last frame before full screen: write it.
        saveWindowState()
        isFullScreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreen = false
    }

    /// Closing the window hides it; the app and its connection stay up, as in
    /// the Electron build. Quitting is the only way to really close it.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        saveWindowState()
        if isQuitting { return true }
        window.orderOut(nil)
        return false
    }
}
