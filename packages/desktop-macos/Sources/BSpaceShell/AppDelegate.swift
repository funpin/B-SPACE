import AppKit
import BSpaceCore

/// The application: one running copy, one main window that outlives being
/// closed, and a menu.
public final class AppDelegate: NSObject, NSApplicationDelegate, AppMenuActions {
    private var mainWindow: MainWindowController?
    /// Links the system handed over before the window existed.
    private var linksBeforeLaunch: [String] = []
    private var secondInstanceObserver: NSObjectProtocol?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let bundleIdentifier = Bundle.main.bundleIdentifier
        let launchLink = linksBeforeLaunch.last ?? DeepLink.first(in: arguments)

        // Another copy is already running: it has been told to come forward
        // and given the link; this one has nothing to do.
        guard SingleInstanceGuard.claim(bundleIdentifier: bundleIdentifier, link: launchLink) else {
            exit(0)
        }
        secondInstanceObserver = SingleInstanceGuard.observe(bundleIdentifier: bundleIdentifier) { [weak self] link in
            self?.comeForward(link: link)
        }

        do {
            let environment = try ShellEnvironment.ofRunningApplication()
            let strings = environment.strings
            let controller = try MainWindowController(
                environment: environment,
                activity: ActivityDetector(
                    seedURL: environment.resources.gamesURL,
                    settingsDirectory: environment.userDataDirectory
                ),
                keybinds: KeybindCoordinator(),
                screenSources: SystemScreenSourceLister(unnamedScreen: { [weak self] number in
                    strings.text(
                        .captureScreen, in: self?.mainWindow?.language ?? environment.language,
                        ["number": String(number)]
                    )
                }),
                screenCapturer: { SystemScreenCapturer() }
            )
            mainWindow = controller
            // The menu follows the language of the web client.
            NSApp.mainMenu = AppMenu.build(strings: strings, language: controller.language, actions: self)
            controller.onQuitRequested = {
                NSApp.terminate(nil)
            }
            controller.onLanguageChanged = { [weak self] language in
                guard let self else { return }
                NSApp.mainMenu = AppMenu.build(strings: strings, language: language, actions: self)
            }
            LaunchContext.claimDeepLinks()

            // A launch by a link is a request to see the app, whatever the
            // login item says.
            let hidden = launchLink == nil && LaunchMode.startsHidden(
                arguments: arguments,
                launchedAtLogin: LaunchContext.wasLaunchedAtLogin(),
                startMinimized: AutoLaunchStore(directory: environment.userDataDirectory).load().startMinimized
            )
            controller.start(hidden: hidden)
            if let launchLink {
                controller.openDeepLink(launchLink, showingWindow: false)
            }
            linksBeforeLaunch = []
            if !hidden {
                NSApp.activate(ignoringOtherApps: true)
            }
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(AppIdentity.displayName) cannot start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// `backspace://` links the system sends to the app. One that launches
    /// the app comes before the launch has finished.
    public func application(_ application: NSApplication, open urls: [URL]) {
        for link in urls.map(\.absoluteString) where DeepLink.accepts(link) {
            if mainWindow == nil {
                linksBeforeLaunch.append(link)
            } else {
                comeForward(link: link)
            }
        }
    }

    public func openSourceCode(_ sender: Any?) {
        mainWindow?.openSourceCode()
    }

    public func changeInstance(_ sender: Any?) {
        mainWindow?.changeInstance()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Brings the window forward, with a link for the page if there is one.
    private func comeForward(link: String?) {
        guard let mainWindow else { return }
        if let link, DeepLink.accepts(link) {
            mainWindow.openDeepLink(link)
        } else {
            mainWindow.showWindow()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A click on the Dock icon brings back the window that closing hid.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        mainWindow?.showWindow()
        return false
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        mainWindow?.saveWindowState()
        mainWindow?.isQuitting = true
        return .terminateNow
    }
}
