import AppKit
import BSpaceCore

/// The menu bar. Without an Edit menu a `WKWebView` has no Copy and Paste: the
/// key equivalents live on the menu items, not in the view.
///
/// This is the standard set, with English titles. The menu of the Electron
/// build (`buildAppMenuTemplate`: its own entries, in the five languages of the
/// web client, following the language chosen there) replaces it in stage 2.
enum AppMenu {
    static func build() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(submenu(title: AppIdentity.displayName, items: applicationItems()))
        menu.addItem(submenu(title: "Edit", items: editItems()))
        let windowMenu = submenu(title: "Window", items: windowItems())
        menu.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu
        return menu
    }

    private static func submenu(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String,
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    private static func applicationItems() -> [NSMenuItem] {
        let name = AppIdentity.displayName
        return [
            item("About \(name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"),
        ]
    }

    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", modifiers: [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
        ]
    }

    private static func windowItems() -> [NSMenuItem] {
        [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]
    }
}
