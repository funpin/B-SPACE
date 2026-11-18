import AppKit
import BSpaceCore
import WebKit

/// A transparent view laid over a part of the page that must stay a page.
///
/// The system starts a window drag itself, from the rectangles of the views
/// that say they move the window (`mouseDownCanMoveWindow`), and a view that
/// says it does not takes its rectangle out of them. It lets every press
/// through to the web view under it.
final class StayView: NSView {
    override var mouseDownCanMoveWindow: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The content of the main window: the web view, filling it, and over the web
/// view the views that keep everything but the page's title bar a page.
final class ShellContentView: NSView {
    private(set) var stayViews: [StayView] = []
    /// Called when the view's size changes.
    var onResize: (() -> Void)?

    /// Top left origin, so a rectangle of the page is a frame here.
    override var isFlipped: Bool { true }

    /// Puts a web view under the views that keep the page a page, in place of
    /// the one that was there.
    func show(_ webView: NSView) {
        for view in subviews where !(view is StayView) {
            view.removeFromSuperview()
        }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView, positioned: .below, relativeTo: nil)
    }

    /// Lays a view over each rectangle, reusing the views there are.
    func setStayRects(_ rects: [NSRect]) {
        while stayViews.count > rects.count {
            stayViews.removeLast().removeFromSuperview()
        }
        while stayViews.count < rects.count {
            let view = StayView()
            stayViews.append(view)
            addSubview(view)
        }
        for (view, rect) in zip(stayViews, rects) where view.frame != rect {
            view.frame = rect
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }
}

/// A `WKWebView` without WebKit's own context menu (Electron shows none, and
/// the web client draws its own where it wants one), which the window can be
/// moved by.
final class ShellWebView: WKWebView {
    /// Whether pressing the mouse button at this point of the page drags the
    /// window. The point is in the page's coordinates: from its top left
    /// corner.
    var dragsWindow: ((NSPoint) -> Bool)?
    /// Called with a press on a part that drags the window, in place of the
    /// page.
    var onWindowDragMouseDown: ((NSEvent) -> Void)?
    /// The press that is going on was kept from the page: so is the rest of it.
    private var keepsPressFromPage = false

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }

    /// A web view never lets its window be moved by it; this one does, and
    /// `StayView`s over it take back everything but the page's title bar. The
    /// system reads the answer when it lays the window out, not at each
    /// press, so it cannot depend on where the mouse is. Asking for the drag
    /// at the press instead (`performDrag(with:)`) is what Chromium does. It
    /// needs the app to answer the press in time, and on a machine in a bad
    /// state it was seen to start the drag only now and then, where this
    /// held (README, "Dragging the window").
    override var mouseDownCanMoveWindow: Bool { true }

    /// The system moves the window by the page's title bar without asking,
    /// and the press still comes here. The page does not get it.
    override func mouseDown(with event: NSEvent) {
        if let dragsWindow, let onWindowDragMouseDown, dragsWindow(pagePoint(of: event)) {
            keepsPressFromPage = true
            onWindowDragMouseDown(event)
            return
        }
        keepsPressFromPage = false
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !keepsPressFromPage else { return }
        super.mouseDragged(with: event)
    }

    /// A release with no press before it would look to the page like the end
    /// of a drag that began somewhere else.
    override func mouseUp(with event: NSEvent) {
        guard !keepsPressFromPage else {
            keepsPressFromPage = false
            return
        }
        super.mouseUp(with: event)
    }

    /// A title bar moves its window on the first press even when the window
    /// is behind others. Everything else on the page keeps WebKit's answer.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, let dragsWindow, dragsWindow(pagePoint(of: event)) {
            return true
        }
        return super.acceptsFirstMouse(for: event)
    }

    /// The view is flipped, and nothing zooms or insets the page, so a point
    /// of the view is a point of the page's viewport.
    private func pagePoint(of event: NSEvent) -> NSPoint {
        convert(event.locationInWindow, from: nil)
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
    /// The web view the window shows. It is replaced by a new one when its
    /// page stops answering (`replaceWebView`), so nothing should hold on to
    /// it across a turn of the run loop.
    public private(set) var webView: WKWebView
    /// What every web view of this window is made from: the bridge, the data
    /// store and the User-Agent are in it.
    private let webViewConfiguration: WKWebViewConfiguration
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
    /// Called when the recovery page asks to quit.
    public var onQuitRequested: (() -> Void)?
    /// What a double click on the title bar does, by the system's setting.
    public var titleBarDoubleClickAction: () -> TitleBarDoubleClick = {
        let defaults = UserDefaults.standard
        return TitleBarDoubleClick.action(
            setting: defaults.string(forKey: "AppleActionOnDoubleClick"),
            minimizesOnDoubleClick: defaults.bool(forKey: "AppleMiniaturizeOnDoubleClick")
        )
    }
    /// What the page of the window reported with `setDragRegions`, if it has.
    public var reportedDragRegions: DragRegions? { dragMap.reported }
    /// The parts of the window laid over to stay a page, in the page's
    /// coordinates. The system drags the window by everything else.
    public var stayRegionFrames: [NSRect] { contentView.stayViews.map(\.frame) }
    /// Whether the system is told that the web view moves the window.
    public var webViewMovesWindow: Bool {
        webView.mouseDownCanMoveWindow && window.isMovableByWindowBackground && webView.superview === contentView
    }
    /// Whether the window is the one the user is working in. Pictures of the
    /// screen are taken for the page only while it is. A test run replaces it.
    public var isWindowFocused: () -> Bool = { false }
    /// Opens an address in the user's browser. A test run replaces it.
    public var openInBrowser: (String) -> Void = { address in
        guard let url = URL(string: address) else { return }
        NSWorkspace.shared.open(url)
    }

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
    private let tray: TrayCoordinator?
    private let activity: ActivityDetector?
    private let keybinds: KeybindCoordinator?
    private let screenSources: ScreenSourceService?

    private let timings: RecoveryTimings
    private var recovery = RecoveryMode()
    private var bootWatch = BootWatch()
    private var hangWatch = HangWatch()
    private var crashGuard = CrashLoopGuard()
    private var bootTimer: DispatchWorkItem?
    private var hangTimer: Timer?
    private var deepLinks = DeepLinkInbox()
    private var dragMap = WindowDragMap() {
        didSet { layOutStayViews() }
    }
    private let contentView: ShellContentView
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
    ///   - tray: what draws the tray; nil shows none. A test run passes one
    ///     that only records what it was given.
    ///   - keybinds: what listens for the global keybinds; nil listens for
    ///     none. The app passes one that listens to the real keyboard, a test
    ///     run one that is fed made-up keys.
    ///   - screenSources: what lists the displays and windows that can be
    ///     shared; nil lists none. The app passes one that asks the system,
    ///     a test run one with a made-up list.
    ///   - activity: what notices a running game; nil detects none. The app
    ///     passes one that lists the real processes and fetches the
    ///     dictionary, a test run one that does neither.
    ///   - recoveryTimings: the clocks of recovery mode. A test run shortens
    ///     them.
    public init(
        environment: ShellEnvironment,
        showsWindow: Bool = true,
        websiteDataStore: WKWebsiteDataStore = .default(),
        loginItem: LoginItem = SystemLoginItem(),
        notifications: NotificationPresenter? = SystemNotificationPresenter(),
        tray: TrayPresenter? = SystemTrayPresenter(),
        activity: ActivityDetector? = nil,
        keybinds: KeybindCoordinator? = nil,
        screenSources: ScreenSourceLister? = nil,
        recoveryTimings: RecoveryTimings = RecoveryTimings()
    ) throws {
        self.activity = activity
        self.keybinds = keybinds
        self.screenSources = screenSources.map(ScreenSourceService.init(lister:))
        self.environment = environment
        self.showsWindow = showsWindow
        self.notifications = notifications
        self.tray = tray.map {
            TrayCoordinator(presenter: $0, strings: environment.strings, language: environment.language)
        }
        timings = recoveryTimings
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
        webViewConfiguration = configuration
        let firstWebView = Self.makeWebView(frame: contentRect, configuration: configuration)
        webView = firstWebView

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
        // The system starts the drag, from the views that say they move the
        // window: see `ShellWebView.mouseDownCanMoveWindow`.
        window.isMovableByWindowBackground = true
        contentView = ShellContentView(frame: contentRect)
        contentView.show(firstWebView)
        window.contentView = contentView
        window.center()

        super.init()

        // Before the delegate is set: placing the window must not count as
        // the user moving it.
        restoreWindowState()
        takeTitleBarPresses(of: firstWebView)
        contentView.onResize = { [weak self] in
            self?.layOutStayViews()
        }
        layOutStayViews()
        bridge.attach(to: webView)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.delegate = self
        isWindowFocused = { [weak self] in
            NSApp.isActive && self?.window.isKeyWindow == true
        }
        registerBridgeHandlers()
        self.tray?.onCommand = { [weak self] command in
            self?.trayItemChosen(command)
        }
        self.keybinds?.onEvent = { [weak self] event in
            self?.bridge.emit("keybind-action", payload: event.bridgeValue)
        }
        // The web client's name for it is Electron's permission; here it is
        // Input Monitoring.
        self.keybinds?.onPermissionStatus = { [weak self] granted in
            self?.bridge.emit("accessibility-status", payload: ["trusted": granted])
        }
        self.keybinds?.onListenerError = { [weak self] message in
            self?.bridge.emit("keybind-hook-error", payload: ["message": message])
        }
        // The web client shows it as the user's activity, when they let it.
        self.activity?.onChange = { [weak self] detected in
            self?.bridge.emit("activity-detected", payload: detected?.bridgeValue ?? NSNull())
        }
        notifications?.onClick = { [weak self] userInfo in
            self?.notificationClicked(userInfo)
        }
        hangTimer = Timer.scheduledTimer(withTimeInterval: timings.hangPollInterval, repeats: true) { [weak self] _ in
            self?.askWhetherThePageAnswers()
        }
    }

    deinit {
        hangTimer?.invalidate()
        bootTimer?.cancel()
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
        activity?.start()
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

    // MARK: Window

    public func showWindow() {
        guard showsWindow else { return }
        if !hasRevealedWindow, restoresZoomed, !window.isZoomed {
            window.zoom(nil)
        }
        if !hasRevealedWindow {
            // The user is looking at the app for the first time in this run.
            notifications?.prepare()
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

    /// Opens the picker, with the window in front: "Change Instance" in the
    /// application menu. The saved instance is kept: the picker shows it and
    /// offers to cancel, and it is replaced only when another is chosen.
    public func changeInstance() {
        perform(.changeInstance)
    }

    // MARK: Web view

    private static func makeWebView(frame: NSRect, configuration: WKWebViewConfiguration) -> ShellWebView {
        let view = ShellWebView(frame: frame, configuration: configuration)
        view.autoresizingMask = [.width, .height]
        view.underPageBackgroundColor = backgroundColor
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        // There is no public way to open the inspector from a menu; this lets
        // Safari's Develop menu attach to the page (deviation 4).
        view.isInspectable = true
        return view
    }

    /// Puts a new web view in the window in place of the current one, whose
    /// process is then ended by WebKit. For a page that has stopped answering:
    /// every load, even of another page, is first put to the process of the
    /// page on screen, so a stuck page cannot be navigated away from. There
    /// is no public call that ends the process; letting go of its view does.
    private func replaceWebView() {
        let stuck = webView
        stuck.navigationDelegate = nil
        stuck.uiDelegate = nil

        let fresh = Self.makeWebView(frame: stuck.frame, configuration: webViewConfiguration)
        webView = fresh
        takeTitleBarPresses(of: fresh)
        bridge.attach(to: fresh)
        fresh.navigationDelegate = self
        fresh.uiDelegate = self
        contentView.show(fresh)

        // The new view has no page: nothing listens, nothing is loading.
        shellLoad = nil
        deepLinks.pageChanged()
        dragMap.pageChanged()
        tray?.pageChanged()
        keybinds?.pageChanged()
        screenSources?.pageChanged()
        apply(bootWatch.pageCommitted())
        hangWatch.reset()
    }

    // MARK: Dragging the window

    /// Lays the views that keep the page a page over everything the window
    /// is not dragged by. Done again whenever the page says where its title
    /// bar is, another page is shown, or the window changes size: a window
    /// that grew stays a page beside what the page last reported until the
    /// page has measured itself again.
    private func layOutStayViews() {
        let size = contentView.bounds.size
        let rects = dragMap.stayRects(width: Double(size.width), height: Double(size.height))
        contentView.setStayRects(rects.map { NSRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) })
    }

    /// Has the web view hand over the presses on the parts of the page that
    /// stand for a title bar.
    private func takeTitleBarPresses(of view: ShellWebView) {
        view.dragsWindow = { [weak self] point in
            self?.dragMap.canDrag(x: Double(point.x), y: Double(point.y)) ?? false
        }
        view.onWindowDragMouseDown = { [weak self] event in
            self?.titleBarPressed(event)
        }
    }

    /// A press on the page's title bar. The system has already begun moving
    /// the window by it; two presses do what the system's setting says a
    /// double click on a title bar does. The page sees neither.
    private func titleBarPressed(_ event: NSEvent) {
        switch event.clickCount {
        case 2:
            // A full-screen window has no title bar to double-click.
            guard !window.styleMask.contains(.fullScreen) else { return }
            switch titleBarDoubleClickAction() {
            case .zoom:
                window.zoom(nil)
            case .minimize:
                window.miniaturize(nil)
            case .nothing:
                break
            }
        default:
            break
        }
    }

    // MARK: Recovery

    /// What the recovery page and the web client read: whether the shell is
    /// in recovery, and why.
    public var recoveryState: RecoveryState { recovery.state }

    /// Shows the recovery page with the reason, in a window brought forward
    /// even if the app was started hidden: there is something the user has to
    /// decide. Already in recovery, only what the page says changes.
    private func enterRecovery(_ reason: RecoveryReason) {
        NSLog("[recovery] entered: %@, %@", reason.code.rawValue, reason.detail)
        if reason.code == .unresponsive {
            replaceWebView()
        }
        let mustLoadThePage = recovery.enter(reason)
        recoveryStateChanged()
        guard mustLoadThePage else { return }

        let page = environment.resources.recoveryURL
        var components = URLComponents(url: page, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "lang", value: language.code)]
        load(components?.url ?? page)
        staysHidden = false
        showWindow()
        if showsWindow {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func exitRecovery(by action: RecoveryAction) {
        guard recovery.state.isRecovery else { return }
        recovery.exit()
        NSLog("[recovery] exited (%@)", action.rawValue)
        recoveryStateChanged()
    }

    private func recoveryStateChanged() {
        bridge.emit("recovery-state-changed", payload: recovery.state.bridgeValue)
    }

    /// Carries out what the recovery page, or the menu, asked for.
    public func perform(_ action: RecoveryAction) {
        switch action {
        case .reload:
            // Out of recovery before the load: if it fails or stalls again,
            // recovery is entered afresh.
            exitRecovery(by: action)
            loadInitialPage()
        case .changeInstance:
            exitRecovery(by: action)
            loadPicker()
            showWindow()
        case .openReleases, .checkUpdate:
            // The updater is stage 5 of the port. Until then "check for
            // updates" does what a person would: opens the latest release.
            openInBrowser(RecoveryAction.releasesAddress)
        case .quit:
            onQuitRequested?()
        case .installUpdate:
            // Nothing is ever downloaded for it to install before stage 5.
            break
        }
    }

    private func apply(_ command: BootWatch.Command?) {
        guard let command else { return }
        bootTimer?.cancel()
        bootTimer = nil
        guard command == .arm else { return }
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.bootWatch.timedOut() else { return }
            self.bootTimer = nil
            self.enterRecovery(RecoveryReason(
                code: .rendererStalled,
                detail: "no rendererReady within \(Int(self.timings.bootTimeout * 1000))ms"
            ))
        }
        bootTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + timings.bootTimeout, execute: timer)
    }

    /// One poll of the hang watch: only a page of an instance is watched, and
    /// by default only while its window is on screen.
    private func askWhetherThePageAnswers() {
        let isWebPage = webView.url.flatMap { WebOrigin.of($0) } != nil
        let isWatched = isWebPage
            && !recovery.state.isRecovery
            && (window.isVisible || !timings.watchesHangsOnlyWhenVisible)
        guard isWatched else {
            hangWatch.reset()
            return
        }
        switch hangWatch.tick(at: Date(), pollInterval: timings.hangPollInterval, grace: timings.hangGrace) {
        case .ask:
            webView.evaluateJavaScript("1") { [weak self] _, _ in
                self?.hangWatch.answered()
            }
        case .wait:
            break
        case .hung:
            hangWatch.reset()
            enterRecovery(RecoveryReason(
                code: .unresponsive,
                detail: "main thread blocked >\(Int(timings.hangGrace * 1000))ms"
            ))
        }
    }

    /// Opens the source code of the instance in the user's browser: the
    /// address the instance names for itself, or the project's own.
    /// An item of the tray menu was chosen.
    private func trayItemChosen(_ command: TrayMenuCommand) {
        switch command {
        case .control(let action):
            // The web client carries it out, as its voice bar or status
            // picker would.
            bridge.emit("tray-action", payload: action.bridgeValue)
        case .show:
            showWindow()
            activateApp()
        case .quit:
            onQuitRequested?()
        }
    }

    /// Brings the app in front of the others, when it has a window to show.
    private func activateApp() {
        guard showsWindow else { return }
        NSApp.activate(ignoringOtherApps: true)
    }

    public func openSourceCode() {
        let page = webView.url.flatMap { WebOrigin.of($0) }
        let instance = environment.overrideURL ?? instanceStore.load() ?? page
        guard let infoURL = SourceCode.instanceInfoURL(instanceAddress: instance) else {
            openInBrowser(SourceCode.projectAddress)
            return
        }
        var request = URLRequest(url: infoURL)
        request.timeoutInterval = 5
        URLSession(configuration: .ephemeral).dataTask(with: request) { data, response, _ in
            let answered = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
            let address = SourceCode.address(fromInstanceInfo: answered ? data : nil)
            DispatchQueue.main.async { [weak self] in
                self?.openInBrowser(address)
            }
        }.resume()
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
            self.tray?.setLanguage(language)
            self.onLanguageChanged?(language)
        }
        router.onFire("set-badge-count") { arguments in
            NSApp.dockTile.badgeLabel = BadgeCount.label(for: arguments.number(at: 0))
        }

        // The web client decides what the character in the tray is doing
        // and which quick controls its menu offers. Anything malformed is
        // ignored and the tray stays as it was.
        router.onFire("set-tray-state") { [weak self] arguments in
            guard let state = TrayState(arguments: arguments) else { return }
            self?.tray?.setState(state)
        }
        router.onFire("set-tray-context") { [weak self] arguments in
            guard let context = TrayContext(arguments: arguments) else { return }
            self?.tray?.setContext(context)
        }

        router.onFire("set-drag-regions") { [weak self] arguments in
            // A report that cannot be read leaves the last one standing.
            guard let self, let regions = DragRegions(arguments: arguments) else { return }
            self.dragMap.report(regions)
        }

        router.onFire("renderer-ready") { [weak self] _ in
            guard let self else { return }
            self.apply(self.bootWatch.rendererReady())
        }
        router.onFire("recovery-action") { [weak self] arguments in
            guard let action = arguments.string(at: 0).flatMap(RecoveryAction.init(rawValue:)) else { return }
            self?.perform(action)
        }
        router.onInvoke("get-recovery-state", answering: { [weak self] _ in
            .value((self?.recovery.state ?? RecoveryState()).bridgeValue)
        })

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
        // Global keybinds. A list that cannot be read changes nothing: the
        // answer is still whether the shell is listening.
        router.onInvoke("keybinds-sync", answering: { [weak self] arguments in
            guard let keybinds = self?.keybinds else { return .value(false) }
            guard let list = Keybind.list(arguments: arguments) else { return .value(keybinds.isListening) }
            return .value(keybinds.sync(list))
        })
        router.onInvoke("check-accessibility", answering: { [weak self] _ in
            .value(self?.keybinds?.checkPermission() ?? false)
        })
        router.onFire("open-keybind-permission-settings") { [weak self] _ in
            self?.keybinds?.openPermissionSettings()
        }
        // The portal is how the Electron build registers shortcuts on
        // Wayland; everywhere else its status is null and a retry is nothing.
        router.onInvoke("keybind-portal-status", answering: { _ in .null })
        router.onFire("keybind-portal-retry") { _ in }

        router.onInvoke("get-current-activity", answering: { [weak self] _ in
            self?.activity?.current.map { .value($0.bridgeValue) } ?? .null
        })
        // What can be shared, with a picture of each. The pictures are of the
        // user's screen and the page is a server's code: see `ScreenSourceGate`.
        router.onInvoke("get-screen-sources") { [weak self] _, reply in
            guard let self, let screenSources = self.screenSources else {
                reply(.value([Any]()))
                return
            }
            screenSources.sources(windowFocused: self.isWindowFocused()) { sources in
                reply(.value(sources.map(\.bridgeValue)))
            }
        }

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
        // A new document: whatever listened for links in the old one is gone,
        // what it said of its title bar, of the tray and of its keybinds is
        // gone, the pictures of the screen made for it are not the next
        // page's, and the web client in it has yet to say it started.
        deepLinks.pageChanged()
        dragMap.pageChanged()
        tray?.pageChanged()
        keybinds?.pageChanged()
        screenSources?.pageChanged()
        apply(bootWatch.pageCommitted())
        hangWatch.reset()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        apply(bootWatch.loadFinished(url: webView.url))
        mainFrameLoadEnded(error: nil)
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        mainFrameLoadFailed(error, beforeCommit: false)
    }

    public func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        mainFrameLoadFailed(error, beforeCommit: true)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        deepLinks.pageChanged()
        dragMap.pageChanged()
        tray?.pageChanged()
        keybinds?.pageChanged()
        screenSources?.pageChanged()
        apply(bootWatch.pageCommitted())
        hangWatch.reset()
        // WebKit ends this process for its own reasons too (the system is
        // short of memory), so once is a reload. Twice in a row is a page
        // that keeps crashing.
        if crashGuard.processEnded(at: Date(), window: timings.crashLoopWindow) {
            enterRecovery(RecoveryReason(
                code: .renderGone,
                detail: "the web content process ended twice within \(Int(timings.crashLoopWindow))s"
            ))
            return
        }
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

    /// - Parameter beforeCommit: the navigation failed before any of the new
    ///   page was shown.
    private func mainFrameLoadFailed(_ error: Error, beforeCommit: Bool) {
        guard !Self.isInterruption(error) else { return }
        NSLog("[navigation] load failed: %@", error.localizedDescription)
        let failedShellLoad = shellLoad
        let wasShellLoad = failedShellLoad != nil
        mainFrameLoadEnded(error: error)
        // A navigation the page itself started, and that failed before
        // anything of it was shown, leaves the page it came from on screen
        // and working: there is nothing to recover from. (Chromium replaces
        // the page with an error page, so the Electron build recovers there
        // too.) A load the shell asked for, or one with no page behind it,
        // or one that broke off half shown, leaves the window with nothing
        // usable in it.
        guard !beforeCommit || wasShellLoad || webView.url == nil else { return }
        // The error does not always say which address failed; for the
        // shell's own load the shell knows.
        let failure = error as NSError
        let address = failure.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            ?? (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL)?.absoluteString
            ?? failedShellLoad?.absoluteString
            ?? webView.url?.absoluteString
            ?? "an unknown address"
        enterRecovery(RecoveryReason(
            code: .loadFailed,
            detail: "\(failure.code) \(failure.localizedDescription) @ \(address)"
        ))
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

    /// The microphone and the camera. WebKit asks the shell before it asks
    /// the system; a granted request leaves the system's own question as the
    /// only one the user sees.
    public func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        let decision = MediaCapturePolicy.decision(
            isMainFrame: frame.isMainFrame,
            requestOrigin: WebOrigin.of(scheme: origin.protocol, host: origin.host, port: origin.port),
            pageURL: webView.url
        )
        let devices: String
        switch type {
        case .camera: devices = "the camera"
        case .microphone: devices = "the microphone"
        case .cameraAndMicrophone: devices = "the camera and the microphone"
        @unknown default: devices = "a capture device"
        }
        NSLog(
            "[media] %@ asked for %@: %@", frame.isMainFrame ? "the page" : "a frame of \(origin.host)",
            devices, decision == .grant ? "granted" : "denied"
        )
        decisionHandler(decision == .grant ? .grant : .deny)
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
        // The user may be back from granting the permission in System Settings.
        keybinds?.appBecameActive()
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
