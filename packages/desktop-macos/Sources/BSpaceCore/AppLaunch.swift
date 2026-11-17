import Foundation

// How the app is started and reached from outside: opening at login, starting
// hidden, `backspace://` links, and a second copy of the app being launched.
// The parts that touch the system are in BSpaceShell; what is decided is here.

// MARK: - Opening at login

/// The auto-launch settings as the web client sees them.
public struct AutoLaunchSettings: Equatable {
    /// Whether the app opens when the user logs in.
    public var openAtLogin: Bool
    /// Whether, when it does, it starts with its window hidden.
    public var startMinimized: Bool

    /// What Electron starts from: not opened at login, and hidden if it is.
    public static let `default` = AutoLaunchSettings(openAtLogin: false, startMinimized: true)

    public init(openAtLogin: Bool, startMinimized: Bool) {
        self.openAtLogin = openAtLogin
        self.startMinimized = startMinimized
    }
}

/// `auto-launch.json` in the user-data folder, in the format
/// `packages/desktop/src/main.ts` writes. The file is the truth for
/// `startMinimized` only: whether the app opens at login is the system's to
/// say, and the copy kept here is never read back.
public struct AutoLaunchStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("auto-launch.json", isDirectory: false)
    }

    public func load() -> AutoLaunchSettings {
        guard
            let data = try? Data(contentsOf: fileURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .default }
        return AutoLaunchSettings(
            openAtLogin: Self.bool(object["openAtLogin"]) ?? AutoLaunchSettings.default.openAtLogin,
            startMinimized: Self.bool(object["startMinimized"]) ?? AutoLaunchSettings.default.startMinimized
        )
    }

    public func save(_ settings: AutoLaunchSettings) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONSerialization.data(
            withJSONObject: ["openAtLogin": settings.openAtLogin, "startMinimized": settings.startMinimized],
            options: [.sortedKeys]
        )
        try data.write(to: fileURL, options: .atomic)
    }

    /// A JSON boolean, and not a number: `JSONSerialization` gives both as
    /// `NSNumber`, and `1` is not `true` to the code that wrote the file.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}

/// The system's record of whether the app opens at login.
public protocol LoginItem: AnyObject {
    var isEnabled: Bool { get }
    func setEnabled(_ enabled: Bool) throws
}

/// The auto-launch settings: read for the web client and changed by it.
public struct AutoLaunch {
    private let store: AutoLaunchStore
    private let loginItem: LoginItem

    public init(store: AutoLaunchStore, loginItem: LoginItem) {
        self.store = store
        self.loginItem = loginItem
    }

    public var current: AutoLaunchSettings {
        AutoLaunchSettings(openAtLogin: loginItem.isEnabled, startMinimized: store.load().startMinimized)
    }

    /// Changes the fields that are given and leaves the others as they are.
    /// The system is asked only when `openAtLogin` really changes.
    ///
    /// The answer is the state after the change as the system reports it, not
    /// the state that was asked for: if the system refused, the web client's
    /// switch goes back. `failure` says what went wrong, if anything did.
    public func update(openAtLogin: Bool?, startMinimized: Bool?) -> (settings: AutoLaunchSettings, failure: Error?) {
        let before = current
        var failure: Error?
        if let openAtLogin, openAtLogin != before.openAtLogin {
            do {
                try loginItem.setEnabled(openAtLogin)
            } catch {
                failure = error
            }
        }
        let after = AutoLaunchSettings(
            openAtLogin: loginItem.isEnabled,
            startMinimized: startMinimized ?? before.startMinimized
        )
        do {
            try store.save(after)
        } catch {
            failure = failure ?? error
        }
        return (after, failure)
    }
}

// MARK: - Starting hidden

public enum LaunchMode {
    /// The argument Electron's login item passes on the platforms where a
    /// login item can carry arguments. Honoured here too.
    public static let hiddenArgument = "--hidden"

    /// Whether the window stays hidden until the user asks for it: the app
    /// was told to on its command line, or the system opened it at login and
    /// the user chose "start minimized".
    public static func startsHidden(arguments: [String], launchedAtLogin: Bool, startMinimized: Bool) -> Bool {
        arguments.contains(hiddenArgument) || (launchedAtLogin && startMinimized)
    }
}

// MARK: - Links

public enum DeepLink {
    public static let scheme = "backspace"

    /// True for a `backspace://` link. Anything else handed to the app as a
    /// link is dropped before it reaches the page.
    public static func accepts(_ link: String) -> Bool {
        link.lowercased().hasPrefix(scheme + "://")
    }

    /// The first link among command-line arguments, if there is one.
    public static func first(in arguments: [String]) -> String? {
        arguments.first(where: accepts)
    }

    /// Whether the bundle's Info.plist says it opens `backspace://` links.
    /// A development bundle does not, so that it never takes them from the
    /// installed app.
    public static func isDeclared(infoDictionary: [String: Any]?) -> Bool {
        let types = infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] ?? []
        return types.contains { type in
            let schemes = type["CFBundleURLSchemes"] as? [String] ?? []
            return schemes.contains { $0.lowercased() == scheme }
        }
    }
}

/// Holds a link until the page can take it. A link can arrive before the web
/// client has subscribed to links (the app was launched by the link, or the
/// page is reloading); the bridge says when a subscription appears.
public struct DeepLinkInbox: Equatable {
    private var isListening = false
    private var held: String?

    public init() {}

    /// A link came in. Returns it if it should be sent to the page now;
    /// otherwise it is kept, replacing an earlier one that was still waiting.
    public mutating func receive(_ link: String) -> String? {
        guard DeepLink.accepts(link) else { return nil }
        if isListening { return link }
        held = link
        return nil
    }

    /// The page subscribed to links. Returns the link that was waiting.
    public mutating func listenerAppeared() -> String? {
        isListening = true
        defer { held = nil }
        return held
    }

    /// The page was replaced by another document: its subscription is gone.
    public mutating func pageChanged() {
        isListening = false
    }
}

// MARK: - A second copy of the app

/// One running copy of the app.
public struct RunningInstance: Equatable {
    public let processIdentifier: Int32
    /// When the process started, if the system could say.
    public let startTime: Date?

    public init(processIdentifier: Int32, startTime: Date?) {
        self.processIdentifier = processIdentifier
        self.startTime = startTime
    }
}

public enum SingleInstance {
    /// Of several copies running at once, the one that stays: the one that
    /// started first. Two copies launched together each see the other, and
    /// both must reach the same answer, so equal or unknown times fall back
    /// to the lower process identifier.
    public static func survivor(of instances: [RunningInstance]) -> RunningInstance? {
        instances.min { first, second in
            let firstTime = first.startTime ?? .distantFuture
            let secondTime = second.startTime ?? .distantFuture
            if firstTime != secondTime { return firstTime < secondTime }
            return first.processIdentifier < second.processIdentifier
        }
    }

    /// The name of the notification a copy that gives way sends to the one
    /// that stays, to bring its window forward and hand over a link.
    public static func notificationName(bundleIdentifier: String) -> String {
        bundleIdentifier + ".second-instance"
    }
}
