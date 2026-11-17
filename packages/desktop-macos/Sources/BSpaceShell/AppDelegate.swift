import AppKit
import BSpaceCore

/// The application: one main window that outlives being closed, and a menu.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var mainWindow: MainWindowController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = AppMenu.build()
        do {
            let controller = try MainWindowController(environment: .ofRunningApplication())
            mainWindow = controller
            controller.start()
            NSApp.activate(ignoringOtherApps: true)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "\(AppIdentity.displayName) cannot start"
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
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
