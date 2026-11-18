import Foundation

/// One thing that can be shared: a display or a window.
///
/// The web client shows these as tiles in the stream setup screen and hands
/// the id of the chosen one back. The ids are spelled as the Electron build
/// spells them (`screen:<display>:0`, `window:<window>:0`), because the client
/// remembers the id of the source shared last time and a screen's id has to
/// survive a restart.
public struct ScreenSource: Equatable {
    public enum Kind: Equatable {
        /// A display, by its `CGDirectDisplayID`.
        case display(UInt32)
        /// A window, by its `CGWindowID`.
        case window(UInt32)
    }

    public var kind: Kind
    /// What the tile is called: the display's name, or the window's title.
    public var name: String
    /// A picture of it as PNG, no larger than `ScreenSourceRules.thumbnailBox`.
    public var thumbnailPNG: Data
    /// The icon of the window's application as PNG; a display has none.
    public var appIconPNG: Data?

    public init(kind: Kind, name: String, thumbnailPNG: Data, appIconPNG: Data? = nil) {
        self.kind = kind
        self.name = name
        self.thumbnailPNG = thumbnailPNG
        self.appIconPNG = appIconPNG
    }

    public var id: String {
        switch kind {
        case .display(let display): return "screen:\(display):0"
        case .window(let window): return "window:\(window):0"
        }
    }

    public var isScreen: Bool {
        if case .display = kind { return true }
        return false
    }

    /// What an id names, when it is spelled as `id` spells it.
    public static func kind(ofID id: String) -> Kind? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[2] == "0", let number = UInt32(parts[1]) else { return nil }
        switch parts[0] {
        case "screen": return .display(number)
        case "window": return .window(number)
        default: return nil
        }
    }

    /// The source as the page gets it: `ElectronScreenSource` of the web client.
    public var bridgeValue: [String: Any] {
        [
            "id": id,
            "name": name,
            "thumbnailDataUrl": Self.dataURL(thumbnailPNG),
            "appIconDataUrl": appIconPNG.map(Self.dataURL) ?? NSNull(),
            "isScreen": isScreen,
        ]
    }

    private static func dataURL(_ png: Data) -> String {
        "data:image/png;base64," + png.base64EncodedString()
    }
}

/// A window as the system lists it, before the shell decides whether it is
/// something a user would share.
public struct ShareableWindow: Equatable {
    public var id: UInt32
    public var title: String
    /// Whether an application owns it. The system's own surfaces have none.
    public var hasApplication: Bool
    /// The bundle identifier of that application; empty when it has none.
    public var bundleIdentifier: String
    /// The window's level: 0 for an ordinary window; menus, the Dock, panels
    /// that float above everything and the desktop are on other levels.
    public var layer: Int
    public var isOnScreen: Bool
    public var width: Double
    public var height: Double

    public init(
        id: UInt32, title: String, hasApplication: Bool, bundleIdentifier: String = "", layer: Int,
        isOnScreen: Bool, width: Double, height: Double
    ) {
        self.id = id
        self.title = title
        self.hasApplication = hasApplication
        self.bundleIdentifier = bundleIdentifier
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.width = width
        self.height = height
    }
}

public enum ScreenSourceRules {
    /// The box a thumbnail fits in, in pixels: what the Electron build asks
    /// its capturer for.
    public static let thumbnailBox = (width: 320, height: 180)
    /// The side of an application icon, in pixels.
    public static let iconSide = 32
    /// A window smaller than this on either side is a helper surface, not
    /// something to share.
    public static let smallestWindowSide = 48.0
    /// Parts of the system that draw their furniture in ordinary titled
    /// windows. Stage Manager is the one that matters: it keeps a small
    /// titled copy of every window in its strip, on the ordinary level, so
    /// without this every window in the strip would be listed twice.
    public static let systemFurniture: Set<String> = [
        "com.apple.WindowManager",
        "com.apple.dock",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.Spotlight",
        "com.apple.screencaptureui",
        "com.apple.loginwindow",
    ]

    /// Whether a window belongs in the list: an ordinary window of an
    /// application that is not part of the system's furniture, on screen,
    /// with a title, large enough to be a window.
    public static func isListed(_ window: ShareableWindow) -> Bool {
        window.hasApplication
            && !systemFurniture.contains(window.bundleIdentifier)
            && window.layer == 0
            && window.isOnScreen
            && !window.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && window.width >= smallestWindowSide
            && window.height >= smallestWindowSide
    }

    /// The size of a picture of something `width` by `height`, scaled to fit
    /// the thumbnail box with its proportions kept. Never larger than the
    /// thing itself, never smaller than one pixel.
    public static func thumbnailSize(width: Double, height: Double) -> (width: Int, height: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let scale = min(Double(thumbnailBox.width) / width, Double(thumbnailBox.height) / height, 1)
        return (max(1, Int((width * scale).rounded())), max(1, Int((height * scale).rounded())))
    }
}

/// Whether a request for the list may take new pictures.
///
/// A list holds pictures of every open window, and the page that asks is the
/// instance's web client: code from a server. The Electron build's rule
/// (`screenSharePolicy.ts`) is kept: only while the app's window is focused,
/// so a page polling on a timer cannot photograph what the user has switched
/// to, and no more often than once a second. Otherwise the page gets the list
/// it already had. That the request comes from the page of the window is
/// checked by the bridge for every channel.
public struct ScreenSourceGate {
    public enum Decision: Equatable {
        case enumerate
        case serveLast
    }

    /// How long a list stands in for a new one.
    public static let cacheInterval: TimeInterval = 1

    private var lastEnumeratedAt: Date?
    private var lastServed: [ScreenSource] = []

    public init() {}

    public func decision(windowFocused: Bool, now: Date) -> Decision {
        guard windowFocused else { return .serveLast }
        if let lastEnumeratedAt, now.timeIntervalSince(lastEnumeratedAt) < Self.cacheInterval {
            return .serveLast
        }
        return .enumerate
    }

    /// The list a request gets when it may not take a new one.
    public var last: [ScreenSource] { lastServed }

    public mutating func served(_ sources: [ScreenSource], at now: Date) {
        lastServed = sources
        lastEnumeratedAt = now
    }

    /// Forgets the list: the page it was made for is gone.
    public mutating func reset() {
        lastServed = []
        lastEnumeratedAt = nil
    }
}
