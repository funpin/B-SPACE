import AppKit
import BSpaceShell

// The native macOS client of B:SPACE. Everything it does is in BSpaceShell
// (AppKit and WebKit) and BSpaceCore (logic without either); this file only
// starts the application.
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
