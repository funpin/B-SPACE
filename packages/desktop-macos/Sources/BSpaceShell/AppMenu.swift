import AppKit
import BSpaceCore

/// What the app's own menu items do. The standard ones (Hide, Copy, Minimize
/// and the rest) go to whoever AppKit finds for them.
@objc public protocol AppMenuActions: AnyObject {
    func openSourceCode(_ sender: Any?)
    func changeInstance(_ sender: Any?)
}

/// The menu bar: the application menu, Edit and Window, as
/// `buildAppMenuTemplate` lays them out in the Electron build, in the language
/// the web client is set to. Rebuilt when that language changes.
///
/// Without an Edit menu a `WKWebView` has no Copy and Paste: the key
/// equivalents live on the menu items, not in the view.
///
/// Two differences from the Electron build. There is no "Toggle Developer
/// Tools": a `WKWebView`'s inspector cannot be opened from code (plan,
/// deviation 4). And Window has Close, the standard Command-W, which the
/// Electron menu lacks. The update items come with the updater, in stage 5.
public enum AppMenu {
    public static func build(strings: DesktopStrings, language: DesktopLanguage, actions: AppMenuActions) -> NSMenu {
        let name = AppIdentity.displayName
        func text(_ key: DesktopStrings.Key) -> String {
            strings.text(key, in: language, ["name": name])
        }
        func own(_ key: DesktopStrings.Key, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: text(key), action: action, keyEquivalent: "")
            item.target = actions
            return item
        }
        func standard(
            _ key: DesktopStrings.Key,
            _ action: Selector,
            _ keyEquivalent: String = "",
            modifiers: NSEvent.ModifierFlags = .command
        ) -> NSMenuItem {
            let item = NSMenuItem(title: text(key), action: action, keyEquivalent: keyEquivalent)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            item.submenu = menu
            return item
        }

        let menu = NSMenu()
        menu.addItem(submenu(name, [
            standard(.about, #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            own(.sourceCode, #selector(AppMenuActions.openSourceCode(_:))),
            .separator(),
            own(.changeInstance, #selector(AppMenuActions.changeInstance(_:))),
            .separator(),
            standard(.hide, #selector(NSApplication.hide(_:)), "h"),
            standard(.hideOthers, #selector(NSApplication.hideOtherApplications(_:)), "h", modifiers: [.command, .option]),
            standard(.showAll, #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            standard(.quit, #selector(NSApplication.terminate(_:)), "q"),
        ]))
        menu.addItem(submenu(text(.editMenu), [
            standard(.undo, Selector(("undo:")), "z"),
            standard(.redo, Selector(("redo:")), "z", modifiers: [.command, .shift]),
            .separator(),
            standard(.cut, #selector(NSText.cut(_:)), "x"),
            standard(.copy, #selector(NSText.copy(_:)), "c"),
            standard(.paste, #selector(NSText.paste(_:)), "v"),
            standard(.selectAll, #selector(NSText.selectAll(_:)), "a"),
        ]))
        let window = submenu(text(.windowMenu), [
            standard(.minimize, #selector(NSWindow.performMiniaturize(_:)), "m"),
            standard(.zoom, #selector(NSWindow.performZoom(_:))),
            standard(.close, #selector(NSWindow.performClose(_:)), "w"),
            .separator(),
            standard(.bringAllToFront, #selector(NSApplication.arrangeInFront(_:))),
        ])
        menu.addItem(window)
        NSApp.windowsMenu = window.submenu
        return menu
    }
}
